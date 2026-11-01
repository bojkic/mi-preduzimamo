# frozen_string_literal: true

require "digest"

module DecidimApp
  module Bijeljina
    # Background preparation only. Reuses the registration geocoder and the
    # independent MZ/komsiluk polygon resolver; never assigns citizen membership
    # or converts a representative street/settlement point into outage coverage.
    class CityServiceAreaPreparation
      VERSION = "2026-09-25.1"
      KEY = "area_review_suggestions"

      def initialize(organization:, geocoder: Decidim::Bih::Geo::Geocoder, cache: Rails.cache, max_geocodes: 2)
        @organization = organization
        @geocoder = geocoder
        @cache = cache
        @remaining = max_geocodes
        @matcher = CityServiceAreaMatcher.new(organization:)
      end

      def call(events:, geocode: false, deadline: nil)
        events.each do |event|
          next unless event.decidim_organization_id == @organization.id && event.state == "pending_review"

          prepare_place_context(event)
          next if operator_reviewed?(event)
          next if refresh_automatic_mapping(event)
          next unless event.targeting_level == "unknown"

          next if apply_known_mapping(event)

          persist_suggestions(event, prepare(event, geocode:, deadline:))
        end
      end

      private

      def refresh_automatic_mapping(event)
        refresh_station_mapping(event) || refresh_water_mixed_mapping(event) || refresh_water_settlement_mapping(event) ||
          refresh_street_mapping(event) || refresh_prepared_crosswalk(event)
      end

      def station_place
        @station_place ||= CityServiceStationPlace.new(organization: @organization)
      end

      def refresh_station_mapping(event)
        old = event.extraction_metadata["station_place"].to_h
        return false unless old["status"] == "resolved"

        current = station_place.resolve(event, recheck: true)
        same = old["rule_version"] == CityServiceStationPlace::VERSION && current.resolved? &&
               old["slug"] == current.slug && old["alias_revision"] == current.alias_revision &&
               old["boundary_hash"] == current.boundary_hash && old["station_label"] == current.station_label
        return false if same

        event.with_lock do
          previous = event.extraction_metadata["station_place"].to_h
          return false unless event.pending_review? && !operator_reviewed?(event) && previous == old

          metadata = event.extraction_metadata.deep_dup
          metadata["coverage"] = metadata.dig("coverage", "original_extraction") || { "status" => "unknown" }
          metadata["station_place"] = station_result_metadata(current, event.content_version)
          metadata["confidence_by_field"] = metadata.fetch("confidence_by_field", {}).merge("place" => "unknown")
          metadata.delete(KEY)
          copy = old["previous_copy"].to_h
          event.update!(targeting_level: "unknown", affected_area_slugs: [], extraction_metadata: metadata,
                        title: copy.fetch("title", event.title), summary: copy.fetch("summary", event.summary),
                        viber_text: copy.fetch("viber_text", event.viber_text))
        end
        true
      end

      def persist_suggestions(event, suggestions)
        event.with_lock do
          next unless event.state == "pending_review" && event.targeting_level == "unknown" && !operator_reviewed?(event)

          existing = event.extraction_metadata[KEY].to_h
          next if existing.except("checked_at") == suggestions.except("checked_at")

          event.update!(extraction_metadata: event.extraction_metadata.merge(KEY => suggestions))
        end
      end

      def prepare_place_context(event)
        version = event.content_version
        source_fields = event.extraction_metadata.slice("feeder", "reason")
        places = feeder_places(event)
        context = { "version" => VERSION, "source_content_version" => version, "places" => places }
        event.with_lock do
          return unless event.pending_review? && event.content_version == version && event.extraction_metadata.slice("feeder", "reason") == source_fields

          existing = event.extraction_metadata["place_context"]
          return if existing == context || (existing.nil? && places.empty?)

          metadata = event.extraction_metadata.except("place_context")
          metadata["place_context"] = context if places.any?
          event.update!(extraction_metadata: metadata)
        end
      end

      def feeder_places(event)
        return [] unless event.source_key == "electricity_outages" && event.content_version.present?

        @matcher.contextual_places(asset_label: event.extraction_metadata["feeder"]) +
          @matcher.maintenance_contextual_places(reason: event.extraction_metadata["reason"])
      end

      def refresh_water_mixed_mapping(event)
        previous = event.extraction_metadata.fetch("coverage", {})
        return false unless automatic_water_mixed_mapping?(event, previous)
        return false if previous["water_mixed_coverage_revision"] == water_mixed_coverage.revision

        version = event.content_version
        coverage = water_mixed_coverage.match(event)
        return false unless coverage

        event.with_lock do
          current = event.extraction_metadata.fetch("coverage", {})
          return false unless event.pending_review? && event.content_version == version && automatic_water_mixed_mapping?(event, current)
          return false unless current["water_mixed_coverage_revision"] == previous["water_mixed_coverage_revision"]

          coverage["previous_mapping"] = { "water_mixed_coverage_revision" => current["water_mixed_coverage_revision"],
                                           "affected_area_slugs" => event.area_slugs, "reason" => "water_location_geometry_changed" }
          changes = prepared_coverage_changes(event, coverage, mixed_water_confidence(coverage))
          changes[:extraction_metadata] = changes.fetch(:extraction_metadata).except(KEY)
          event.update!({ targeting_level: "unknown", affected_area_slugs: [] }.merge(changes))
        end
        true
      end

      def automatic_water_mixed_mapping?(event, coverage)
        coverage["water_mixed_coverage_revision"].present? && coverage["source_content_version"] == event.content_version && !operator_reviewed?(event)
      end

      def water_mixed_coverage
        @water_mixed_coverage ||= CityServiceWaterMixedCoverage.new(organization: @organization)
      end

      def mixed_water_confidence(coverage)
        coverage["scope_precision"] == "unspecified_street_segment" ? "verified_water_location_geometry" : "municipal_settlement_geometry"
      end

      def refresh_water_settlement_mapping(event)
        previous = event.extraction_metadata.fetch("coverage", {})
        return false unless automatic_water_settlement_mapping?(event, previous)
        return false if previous["water_settlement_coverage_revision"] == water_settlement_coverage.revision

        version = event.content_version
        coverage = water_settlement_coverage.match(event) || unresolved_water_settlement_mapping(version)
        event.with_lock do
          current = event.extraction_metadata.fetch("coverage", {})
          return false unless event.pending_review? && event.content_version == version && automatic_water_settlement_mapping?(event, current)
          return false unless current["water_settlement_coverage_revision"] == previous["water_settlement_coverage_revision"]

          coverage["previous_mapping"] = { "water_settlement_coverage_revision" => current["water_settlement_coverage_revision"],
                                           "affected_area_slugs" => event.area_slugs, "reason" => "settlement_or_boundary_revision_changed" }
          changes = prepared_coverage_changes(event, coverage, coverage.fetch("complete") ? "municipal_settlement_geometry" : "unknown")
          changes[:extraction_metadata] = changes.fetch(:extraction_metadata).except(KEY)
          event.update!({ targeting_level: "unknown", affected_area_slugs: [] }.merge(changes))
        end
        true
      end

      def automatic_water_settlement_mapping?(event, coverage)
        coverage["water_settlement_coverage_revision"].present? && coverage["source_content_version"] == event.content_version && !operator_reviewed?(event)
      end

      def unresolved_water_settlement_mapping(version)
        { "status" => "unknown", "complete" => false, "source_content_version" => version,
          "water_settlement_coverage_revision" => water_settlement_coverage.revision, "scope" => "named_settlement_no_longer_resolved",
          "affected_places" => [], "unresolved_places" => [], "ambiguous_places" => [], "notification_candidates" => [],
          "reason" => "settlement_or_boundary_revision_changed" }
      end

      def water_settlement_coverage
        @water_settlement_coverage ||= CityServiceWaterSettlementCoverage.new(organization: @organization)
      end

      def refresh_street_mapping(event)
        previous = event.extraction_metadata.fetch("coverage", {})
        return false unless automatic_street_mapping?(event, previous)

        @street_coverage ||= CityServiceStreetCoverage.new(organization: @organization)
        return false if previous["street_coverage_revision"] == @street_coverage.revision

        version = event.content_version
        coverage = @street_coverage.match(event) || unresolved_street_mapping(version)
        event.with_lock do
          current = event.extraction_metadata.fetch("coverage", {})
          return false unless refreshable_street_mapping?(event, current, version)
          return false unless current["street_coverage_revision"] == previous["street_coverage_revision"]

          coverage["previous_mapping"] = { "street_coverage_revision" => current["street_coverage_revision"],
                                           "affected_area_slugs" => event.area_slugs, "reason" => "street_or_boundary_revision_changed" }
          changes = prepared_coverage_changes(event, coverage, coverage.fetch("complete") ? "full_named_street_geometry" : "unknown")
          changes[:extraction_metadata] = changes.fetch(:extraction_metadata).except(KEY)
          event.update!({ targeting_level: "unknown", affected_area_slugs: [] }.merge(changes))
        end
        true
      end

      def refresh_prepared_crosswalk(event)
        previous = event.extraction_metadata.fetch("coverage", {})
        return false unless automatic_crosswalk?(event, previous)

        @source_crosswalk ||= CityServiceAreaCrosswalk.new(organization: @organization, matcher: @matcher)
        return false if previous["crosswalk_revision"] == @source_crosswalk.revision

        version = event.content_version
        coverage = @source_crosswalk.match(event) || unresolved_crosswalk(version)
        event.with_lock do
          current = event.extraction_metadata.fetch("coverage", {})
          return false unless refreshable_crosswalk?(event, current, version)
          return false unless current["crosswalk_revision"] == previous["crosswalk_revision"]

          coverage["previous_mapping"] = { "coverage" => current.except("previous_mapping", "original_extraction"),
                                           "affected_area_slugs" => event.area_slugs, "reason" => "settlement_or_boundary_revision_changed" }
          changes = prepared_coverage_changes(event, coverage, coverage.fetch("complete") ? "municipal_place_containment" : "unknown")
          changes[:extraction_metadata] = changes.fetch(:extraction_metadata).except(KEY)
          event.update!({ targeting_level: "unknown", affected_area_slugs: [] }.merge(changes))
        end
        true
      end

      def refreshable_crosswalk?(event, coverage, version)
        event.pending_review? && event.content_version == version && automatic_crosswalk?(event, coverage)
      end

      def automatic_crosswalk?(event, coverage)
        coverage["crosswalk_revision"].present? && coverage["street_coverage_revision"].blank? &&
          coverage["source_content_version"] == event.content_version && !operator_reviewed?(event)
      end

      def unresolved_crosswalk(version)
        { "status" => "unknown", "complete" => false, "source_content_version" => version, "crosswalk_revision" => @source_crosswalk.revision,
          "scope" => "named_settlement_no_longer_resolved", "affected_places" => [], "unresolved_places" => [],
          "ambiguous_places" => [], "notification_candidates" => [], "reason" => "settlement_or_boundary_revision_changed" }
      end

      def refreshable_street_mapping?(event, coverage, version)
        event.pending_review? && event.content_version == version && automatic_street_mapping?(event, coverage)
      end

      def automatic_street_mapping?(event, coverage)
        coverage["street_coverage_revision"].present? && coverage["source_content_version"] == event.content_version &&
          !operator_reviewed?(event)
      end

      def operator_reviewed?(event)
        event.extraction_metadata["operator_review"].present? || event.reviewed_at.present? || event.reviewed_by_id.present?
      end

      def unresolved_street_mapping(version)
        { "status" => "unknown", "complete" => false, "source_content_version" => version, "street_coverage_revision" => @street_coverage.revision,
          "scope" => "named_street_no_longer_resolved", "affected_places" => [], "unresolved_places" => [],
          "ambiguous_places" => [], "notification_candidates" => [], "reason" => "street_or_boundary_revision_changed" }
      end

      def apply_known_mapping(event)
        return true if apply_reviewed_mapping(event)
        # Clause-aware water evidence is authoritative for the whole list. No
        # single-source resolver may silently discard a failed clause.
        if event.source_key == "water_service"
          coverage = event.extraction_metadata.fetch("coverage", {})
          return apply_water_mixed_coverage(event) if coverage["clauses"].present?
          return false if coverage["unresolved_clause_count"].to_i.positive?
        end

        apply_water_settlement_coverage(event) || apply_street_coverage(event) || apply_source_crosswalk(event) || apply_station_place(event)
      end

      def apply_station_place(event)
        resolved = station_place.resolve(event)
        return false if resolved.status == "not_applicable"

        version = event.content_version
        event.with_lock do
          return false unless event.pending_review? && event.targeting_level == "unknown" && !operator_reviewed?(event) && event.content_version == version

          metadata = event.extraction_metadata.deep_dup
          metadata["station_label"] = resolved.station_label
          metadata["station_place"] = station_result_metadata(resolved, version)
          if resolved.resolved?
            metadata["station_place"]["previous_copy"] = event.attributes.slice("title", "summary", "viber_text")
            metadata["coverage"] = station_coverage(event, resolved)
            metadata["confidence_by_field"] = metadata.fetch("confidence_by_field", {}).merge("place" => "provider_station_name")
            copy = station_copy(event, resolved)
            event.update!(targeting_level: "komsiluk", affected_area_slugs: [resolved.slug], extraction_metadata: metadata,
                          title: copy.fetch(:title), summary: copy.fetch(:summary), viber_text: copy.fetch(:viber_text))
          else
            event.update!(extraction_metadata: metadata) unless event.extraction_metadata == metadata
          end
        end
        resolved.resolved?
      end

      def station_result_metadata(result, version)
        { "status" => result.status, "rule_version" => CityServiceStationPlace::VERSION,
          "source_content_version" => version, "station_label" => result.station_label,
          "normalized_label" => result.normalized_label, "candidate_slugs" => result.candidate_slugs,
          "slug" => result.slug, "name" => result.name, "area_id" => result.area_id,
          "alias_revision" => result.alias_revision, "boundary_hash" => result.boundary_hash,
          "scope_precision" => ("part_of_area" if result.resolved?) }
      end

      def station_coverage(event, result)
        { "status" => "resolved", "complete" => true, "source_content_version" => event.content_version,
          "station_resolution_version" => CityServiceStationPlace::VERSION, "alias_revision" => result.alias_revision,
          "scope_precision" => "part_of_area", "clause_count" => 1, "resolved_clause_count" => 1, "unresolved_clause_count" => 0,
          "affected_places" => [{ "slug" => result.slug, "kind" => "komsiluk", "relation" => "part_of_area",
                                  "source" => "provider_station_name", "evidence" => result.station_label }],
          "unresolved_places" => [], "ambiguous_places" => [], "notification_candidates" => [],
          "original_extraction" => event.extraction_metadata.fetch("coverage", {}) }
      end

      def station_copy(event, result)
        title = "Planirano isključenje struje — dio komšiluka #{result.name}"
        zone = "Europe/Sarajevo"
        window = if event.starts_at && event.ends_at
                   from = event.starts_at.in_time_zone(zone).strftime("%d.%m.%Y. u %H:%M")
                   to = event.ends_at.in_time_zone(zone).strftime("%d.%m.%Y. u %H:%M")
                   "od #{from} do #{to}"
                 else
                   "termin treba provjeriti"
                 end
        source = "trafostanica #{result.station_label}"
        reason = event.extraction_metadata["reason"].to_s.squish
        body = "#{title}; #{source}; #{window}."
        body += " Razlog: #{reason}." if reason.present?
        { title: title.truncate(120), summary: body.truncate(500), viber_text: body.truncate(500) }
      end

      def apply_water_mixed_coverage(event)
        coverage = water_mixed_coverage.match(event)
        persist_prepared_coverage(event, coverage, coverage ? mixed_water_confidence(coverage) : "unknown")
      end

      def apply_water_settlement_coverage(event)
        return false unless event.source_key == "water_service"

        coverage = water_settlement_coverage.match(event)
        confidence = coverage && coverage.fetch("complete") ? "municipal_settlement_geometry" : "unknown"
        persist_prepared_coverage(event, coverage, confidence)
      end

      def apply_source_crosswalk(event)
        @source_crosswalk ||= CityServiceAreaCrosswalk.new(organization: @organization, matcher: @matcher)
        persist_prepared_coverage(event, @source_crosswalk.match(event), "municipal_place_containment")
      end

      def apply_street_coverage(event)
        @street_coverage ||= CityServiceStreetCoverage.new(organization: @organization)
        persist_prepared_coverage(event, @street_coverage.match(event), "full_named_street_geometry")
      end

      def persist_prepared_coverage(event, coverage, confidence)
        return false unless coverage

        event.with_lock do
          unless event.pending_review? && event.targeting_level == "unknown" && !operator_reviewed?(event) && event.content_version == coverage.fetch("source_content_version")
            return false
          end

          changes = prepared_coverage_changes(event, coverage, confidence)
          event.update!(changes) unless changes.all? { |key, value| event.public_send(key) == value }
        end
        coverage.fetch("complete")
      end

      def prepared_coverage_changes(event, coverage, confidence)
        original = event.extraction_metadata.fetch("coverage", {})
        coverage["original_extraction"] = original["original_extraction"] || original
        confidence = "partial_street_geometry" if partial_street_geometry?(coverage)
        confidence = event.extraction_metadata.fetch("confidence_by_field", {}).merge("place" => confidence)
        changes = { extraction_metadata: event.extraction_metadata.merge("coverage" => coverage, "confidence_by_field" => confidence) }
        qualify_water_board_copy(event, coverage, changes)
        return changes unless coverage.fetch("complete")

        places = coverage.fetch("affected_places")
        kind = places.any? { |place| place.fetch("kind") == "komsiluk" } ? "komsiluk" : "mz"
        changes.merge(targeting_level: kind, affected_area_slugs: places.select { |place| place.fetch("kind") == kind }.map { |place| place.fetch("slug") }.uniq)
      end

      def qualify_water_board_copy(event, coverage, changes)
        return unless event.source_key == "water_service" && coverage["scope"] == "source_named_water_locations"

        saved = event.extraction_metadata["water_board_copy"].to_h
        original = saved["source_content_version"] == event.content_version ? saved.fetch("original", {}) : {}
        original = event.attributes.slice("title", "summary", "viber_text") if original.empty?
        if coverage["complete"] && coverage["board_placement"] == "verified_full_geometry_intersection" &&
           coverage["scope_precision"] == "unspecified_street_segment"
          changes[:extraction_metadata]["water_board_copy"] = { "source_content_version" => event.content_version, "original" => original }
          changes[:title] = "Mogući prekidi vode — dio komšiluka: #{original.fetch("title")}".truncate(120)
          changes[:summary] = "Prekid vode može zahvatiti dio komšiluka. #{original.fetch("summary")}".truncate(500)
          changes[:viber_text] = "Prekid vode može zahvatiti dio komšiluka. #{original.fetch("viber_text").presence || original.fetch("summary")}".truncate(500)
        elsif saved["source_content_version"] == event.content_version
          changes[:extraction_metadata].delete("water_board_copy")
          changes.merge!(original.symbolize_keys)
        end
      end

      def partial_street_geometry?(coverage)
        coverage["street_coverage_revision"].present? && coverage.fetch("affected_places", []).any? { |place| place["geometry_complete"] == false }
      end

      def apply_reviewed_mapping(event)
        return false if event.affected_text.blank? || event.source_url.blank?

        registry_mapping = CityServiceCoverageRegistry.resolve(event)
        return apply_registry_mapping(event, registry_mapping) if registry_mapping

        # A registry record supersedes legacy event-based approval. Expiry,
        # revocation or changed boundaries cannot resurrect that old approval.
        return false if CityServiceCoverage.exists?(organization: event.organization, identity_key: CityServiceCoverageRegistry.identity(event))

        previous = reviewed_mapping_for(event)
        return false unless previous

        slugs = previous.area_slugs
        areas = Decidim::Bih::LocalArea.where(organization: @organization, kind: previous.targeting_level, slug: slugs).to_a
        return false if slugs.empty? || areas.size != slugs.size

        event.with_lock do
          return false unless mapping_applicable?(event)

          event.update!(targeting_level: previous.targeting_level, affected_area_slugs: slugs,
                        extraction_metadata: event.extraction_metadata.merge(
                          "coverage" => { "status" => "resolved", "affected_places" => mapped_places(areas),
                                          "mapping_event_id" => previous.id, "valid_until" => previous.extraction_metadata.dig("operator_review", "coverage_valid_until") },
                          "confidence_by_field" => event.extraction_metadata.fetch("confidence_by_field", {}).merge("place" => "operator_mapping")
                        ))
        end
        true
      end

      def mapping_applicable?(event)
        event.pending_review? && event.targeting_level == "unknown" && !operator_reviewed?(event)
      end

      def apply_registry_mapping(event, registry_mapping)
        event.with_lock do
          return false unless mapping_applicable?(event)
          return false unless CityServiceCoverageRegistry.resolve(event)&.id == registry_mapping.id

          event.update!(targeting_level: registry_mapping.targeting_level, affected_area_slugs: registry_mapping.area_slugs,
                        extraction_metadata: event.extraction_metadata.merge(
                          "coverage" => { "status" => "resolved", "source_content_version" => event.content_version,
                                          "mapping_id" => registry_mapping.id, "complete" => true,
                                          "affected_places" => registry_mapping.area_slugs.map do |slug|
                                            { "slug" => slug, "kind" => registry_mapping.targeting_level, "relation" => "part", "source" => "operator_mapping" }
                                          end },
                          "confidence_by_field" => event.extraction_metadata.fetch("confidence_by_field", {}).merge("place" => "operator_mapping")
                        ))
        end
        true
      end

      def mapped_places(areas)
        areas.map { |area| { "slug" => area.slug, "kind" => area.kind, "relation" => "part", "source" => "operator_mapping" } }
      end

      def reviewed_mapping_for(event)
        CityServiceEvent.for_organization(@organization)
                        .where(source_key: event.source_key, source_url: event.source_url, affected_text: event.affected_text)
                        .where(state: %w(pending_review answer_approved board_published published))
                        .where("extraction_metadata #>> '{operator_review,reuse_coverage}' = 'true'")
                        .where.not(id: event.id).order(reviewed_at: :desc).limit(20).find { |candidate| valid_mapping?(candidate, event) }
      end

      def valid_mapping?(candidate, event)
        review = candidate.extraction_metadata.fetch("operator_review")
        expires = Date.iso8601(review["coverage_valid_until"].to_s)
        candidate.facts_confirmed? && candidate.extraction_metadata["feeder"] == event.extraction_metadata["feeder"] &&
          candidate.extraction_metadata["tj"] == event.extraction_metadata["tj"] &&
          expires >= Date.current && event.ends_at && event.ends_at.in_time_zone("Europe/Sarajevo").to_date <= expires
      rescue Date::Error
        false
      end

      def prepare(event, geocode:, deadline:)
        coverage = @matcher.match(event.affected_text).coverage
        candidates = coverage.fetch("ambiguous_places").flat_map do |place|
          place.fetch("candidate_slugs").map do |slug|
            { "slug" => slug, "evidence" => place.fetch("evidence"), "method" => "name_candidate" }
          end
        end
        candidates.concat(prepared_place_candidates(event))
        candidates.concat(feeder_context_candidates(event))
        public_address_queries(coverage, event:).first(12).each do |query|
          slugs = geocoded_slugs(query, geocode:, deadline:)
          candidates.concat(slugs.map { |slug| { "slug" => slug, "evidence" => query, "method" => "geocoder_point_in_polygon" } })
        end
        # A refresh without network must not erase earlier bounded suggestions.
        previous = event.extraction_metadata[KEY].to_h
        candidates += Array(previous["candidates"]) if previous["source_content_version"] == event.content_version
        valid_slugs = Decidim::Bih::LocalArea.where(organization: @organization).pluck(:slug)
        candidates.select! { |row| valid_slugs.include?(row["slug"]) }
        { "version" => VERSION, "source_content_version" => event.content_version,
          "candidates" => candidates.uniq, "requires_coverage_review" => true,
          "reason" => suggestion_reason(candidates),
          "checked_at" => Time.current.iso8601 }
      end

      def prepared_place_candidates(event)
        coverage = event.extraction_metadata.fetch("coverage", {})
        return [] unless coverage["source_content_version"] == event.content_version
        return [] unless coverage["crosswalk_revision"].present? || coverage["street_coverage_revision"].present? || coverage["water_settlement_coverage_revision"].present?

        coverage.fetch("affected_places", []).map do |place|
          { "slug" => place.fetch("slug"), "evidence" => place.fetch("evidence"), "method" => place.fetch("source", "municipal_place_containment") }
        end
      end

      def suggestion_reason(candidates)
        return "provider_location_evidence_needed" if candidates.all? { |candidate| candidate["method"] == "feeder_context_only" }

        "confirm_source_coverage_not_just_point"
      end

      # Source tables also omit "ulica" after NN izlaz and use plural
      # settlement headings. Only public affected-location spans are inputs.
      # An asset name is context for a reviewer, never geocoder input/coverage.
      def public_address_queries(coverage, event: nil)
        queries = coverage.fetch("unresolved_places").select { |place| %w(street settlement).include?(place["kind"]) }.flat_map do |place|
          place.fetch("evidence").split(/\s+i\s+(?:dio\s+)?(?=ulic[aeiu]\s)/)
        end
        queries.concat(source_address_queries(event)) if event
        queries.map { |query| normalize_query(query) }.compact_blank.uniq
      end

      def source_address_queries(event)
        text = event.affected_text.to_s.gsub(/[^,;:()\n]+/) { |part| Decidim::Bih::Text.fold(part) }
        return water_address_queries(text) if event.source_key == "water_service"
        return [] unless event.source_key == "electricity_outages"

        if (street = text.match(/\A(?:\d+|svi)\s+nn\s+izlaz[ai]?\s+(?:dio\s+)?(.+)\z/))
          return street[1].split(/\s+i\s+(?:dio\s+)?(?=ulic[aeiu]\s)/)
        end

        settlement_text = text.sub(/\Anaseljen[oa]\s+mjest[oa]\s*:\s*|\Anaselja\s*:\s*/, "")
        return [] if settlement_text == text && !event.extraction_metadata["feeder"].to_s.match?(/\ADV\b/i)
        return [] if settlement_text.match?(/\b(?:nn|izlaz|potrosac|dalekovod|trafostanica)\w*\b/)

        settlement_text.split(/[,;]|\s+i\s+(?=(?:dio\s+)?[a-z]{3})/).map { |part| part.strip.sub(/\Adio\s+/, "") }
      end

      def water_address_queries(text)
        text.split(/;|\n/).filter_map do |part|
          match = part.strip.match(/\A([^()]+)\s*\(([^()]+)\)\z/)
          "#{match[1].strip}, #{match[2].strip}" if match
        end
      end

      def feeder_context_candidates(event)
        feeder_places(event).map do |place|
          { "slug" => place.fetch("slug"), "kind" => place.fetch("kind"), "name" => place.fetch("name"),
            "evidence" => place.fetch("evidence"), "method" => "feeder_context_only" }
        end
      end

      def normalize_query(query)
        query.strip.sub(/\A(?:ulic[aeiu]|ul|naselje|naselju)\s+/i, "").strip
      end

      def lookup_allowed?(geocode, deadline)
        geocode && @remaining.positive? && (!deadline || deadline.remaining_seconds > 7)
      end

      def geocoded_slugs(query, geocode:, deadline:)
        return [] if query.length > 240

        coordinates = cached_coordinates(query, geocode:, deadline:)
        return [] if coordinates.blank?

        result = @matcher.resolve(location: { latitude: coordinates[:lat], longitude: coordinates[:lon] })
        return [] unless result.status == :ok

        result.areas.map(&:slug)
      end

      def cached_coordinates(query, geocode:, deadline:)
        # Source grammar (ulice/ulicu) is not part of the address name.
        # Canonicalize before caching so repeated inflections share one lookup.
        query = normalize_query(query)
        key = "milica/public-place/#{GeocoderScope::VERSION}/#{@organization.id}/#{Digest::SHA256.hexdigest(query)}"
        coordinates = @cache.read(key)
        # Global lease also spaces calls to a public Nominatim-compatible
        # endpoint. A competing refresh simply retries on the next collection.
        if coordinates.nil? && lookup_allowed?(geocode, deadline) && @cache.write("milica/public-place/geocoder-lease", true, unless_exist: true, expires_in: 6.seconds)
          @remaining -= 1
          coordinates = CityServiceNoticeCollector.send(:within_deadline, deadline, max_seconds: 5) do
            @geocoder.coordinates("#{query}, Bijeljina, Bosna i Hercegovina")
          end
          @cache.write(key, coordinates || {}, expires_in: coordinates ? 7.days : 1.hour)
        end
        coordinates
      rescue StandardError => e
        # Optional geocoding must not turn an otherwise successful utility
        # collection into a source outage. Log the class, never the query.
        Rails.logger.warn("[CityServiceAreaPreparation] address suggestion failed: #{e.class}")
        nil
      end
    end
  end
end
