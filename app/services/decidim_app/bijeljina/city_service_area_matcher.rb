# frozen_string_literal: true

require_relative "place_alias_registry"

module DecidimApp
  module Bijeljina
    class CityServiceAreaMatcher
      CITYWIDE_PATTERN = /\b(?:
        (?:cijel\w*|cel\w*|citav\w*)\s+(?:podrucj\w*\s+)?(?:grad\w*|bijeljin\w*)|
        svim\s+(?:potrosacima|korisnicima)\s+(?:u|na[ ]podrucju)\s+(?:gradu|grada|bijeljini)
      )\b/x
      NORMAL_SERVICE_PATTERN = /\b(?:uredn\w*|normaln\w*|redovno (?:vodosnabdijevanje|snabdijevanje)|bez prekida|nesmetan\w*)\b/
      BACKGROUND_PATTERN = /\b(?:sjediste|sediste|adresa preduzeca|kontakt|poslovnica)\b/
      NETWORK_PLACE_PATTERN = /\b(dalekovod|dv|trafostanica|ts|izvod|feeder|ulica|ulice|ulici|ulicu|ul|naselje|naselju|rejon)\s+(.+)/

      Match = Struct.new(:slugs, :targeting_level, :unknown?, :coverage, keyword_init: true)
      Resolution = Struct.new(:status, :areas, :source, :warning, keyword_init: true) do
        STATUSES = [:ok, :ambiguous, :unknown].freeze

        def initialize(**attributes)
          attributes[:status] = attributes.fetch(:status).to_sym
          raise ArgumentError, "unknown area resolution status" unless STATUSES.include?(attributes[:status])

          attributes[:areas] = Array(attributes[:areas]).freeze
          super
          freeze
        end
      end

      def initialize(organization:, alias_registry: nil)
        @organization = organization
        @alias_registry = alias_registry
      end

      # Parsers should pass only their affected-place span. The additional role
      # guard prevents a normal-service sentence or provider address from making
      # an otherwise unmapped notice citywide. It is deliberately conservative.
      # Keep affected, ambiguous and unresolved evidence together in the returned coverage contract.
      # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
      def match(text, affected_text: nil)
        affected = affected_scope(affected_text || text)
        unresolved = unresolved_places(affected)
        area_text = affected.split(/[,;\n]/).map { |clause| fold(clause).gsub(NETWORK_PLACE_PATTERN, " ") }.join("; ")
        mentions = alias_registry.mentions(area_text)
        unresolved += unresolved_local_places(area_text, mentions)
        unresolved += unlisted_settlements(affected)
        groups = mentions.group_by { |mention| [mention.start, mention.finish] }.values.map { |group| same_place_group(group) }
        ambiguous = groups.select { |group| group.map { |mention| mention.entry.id }.uniq.size > 1 }
        certain = groups.select { |group| group.map { |mention| mention.entry.id }.uniq.one? }.flatten
        matches = certain.map { |mention| mention.entry.area }.uniq
        slugs = matches.map(&:slug).uniq.sort
        citywide = slugs.empty? && ambiguous.empty? && unresolved.empty? && citywide?(fold(affected))
        coverage = {
          "alias_revision" => alias_registry.revision,
          "status" => coverage_status(slugs, citywide, ambiguous, unresolved),
          "affected_places" => certain.map do |mention|
            { "slug" => mention.entry.slug, "kind" => mention.entry.kind, "relation" => affected_relation(mention, area_text),
              "evidence" => mention.token, "source" => mention.entry.source }
          end.uniq,
          "ambiguous_places" => ambiguous.map { |group| { "evidence" => group.first.token, "candidate_slugs" => group.map { |mention| mention.entry.slug }.uniq.sort } },
          "unresolved_places" => unresolved,
          "notification_candidates" => overlap_candidates(matches),
          "citywide_evidence" => (fold(affected)[CITYWIDE_PATTERN] if citywide)
        }
        Match.new(slugs:, targeting_level: citywide ? "citywide" : targeting_level(matches),
                  unknown?: slugs.empty? && !citywide, coverage:)
      end
      # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

      # Water articles often list one affected place per semicolon, with the
      # parenthetical settlement providing context. Check EVERY clause: a city
      # street must not disappear just because village names elsewhere match.
      def match_water_clauses(text)
        clauses = text.to_s.split(/[;\n]/).map(&:strip).reject(&:empty?)
        return match(text) if clauses.empty? || (clauses.size == 1 && !clauses.first.match?(/\([^()]+\)/))

        combined = match(text)
        if clauses.size > 30
          coverage = combined.coverage.merge("status" => "unknown", "complete" => false,
                                             "clause_count" => clauses.size, "resolved_clause_count" => 0,
                                             "unresolved_clause_count" => clauses.size,
                                             "unresolved_places" => [{ "kind" => "location_list", "evidence" => text.to_s[0, 500],
                                                                       "reason" => "too_many_location_clauses" }])
          return Match.new(slugs: [], targeting_level: "unknown", unknown?: true, coverage:)
        end
        rows = clauses.map do |clause|
          parsed = clause.match(/\A([^();]+?)\s*\(([^();]+)\)\z/)
          settlement = parsed && PlaceAliasRegistry.normalize(parsed[2])
          local = match(clause)
          # A bare street in Bijeljina needs verified street geometry. The city
          # label is context, not proof that the street has board coverage.
          resolved = parsed && settlement != "bijeljina" && local.coverage.fetch("status") == "resolved" && local.slugs.any?
          { "evidence" => clause, "status" => resolved ? "resolved" : "unresolved",
            "candidate_slugs" => local.slugs }
        end
        missing = rows.reject { |row| row.fetch("status") == "resolved" }
        coverage = combined.coverage.merge(
          "clauses" => rows, "clause_count" => rows.size,
          "resolved_clause_count" => rows.size - missing.size, "unresolved_clause_count" => missing.size,
          "complete" => missing.empty?,
          "unresolved_places" => combined.coverage.fetch("unresolved_places") + missing.map do |row|
            { "kind" => "location_clause", "evidence" => row.fetch("evidence"), "reason" => "location_clause_not_verified" }
          end
        )
        return Match.new(slugs: combined.slugs, targeting_level: combined.targeting_level,
                         unknown?: combined.unknown?, coverage:) if missing.empty?

        coverage["status"] = combined.slugs.any? ? "partial" : "unknown"
        Match.new(slugs: [], targeting_level: "unknown", unknown?: true, coverage:)
      end

      # An asset label can mention a familiar place without establishing that
      # place as its service footprint. Keep this separate from affected areas.
      def contextual_places(asset_label:)
        query = PlaceAliasRegistry.normalize(asset_label)
        prefix = /\A(?:ts|cts|dv|trafostanica|dalekovod)\s+(?:\d+(?:\s+\d+)*\s*kv\s+)?/
        return [] unless query.match?(prefix)

        query = query.sub(prefix, "").gsub(/\bcentar\b|\d+/, " ").squish
        alias_registry.mentions(query).map(&:entry).uniq(&:id).map do |entry|
          { "slug" => entry.slug, "kind" => entry.kind, "name" => entry.label,
            "relation" => "context_only", "source" => "provider_asset_label", "evidence" => asset_label.to_s }
        end
      end

      # Maintenance can name upstream equipment outside the affected span.
      # Preserve its source role instead of promoting it to outage coverage.
      def maintenance_contextual_places(reason:)
        query = PlaceAliasRegistry.normalize(reason)
        return [] if query.match?(BACKGROUND_PATTERN)

        asset = query[/\b(?:ts|cts|dv|trafostanica|dalekovod)\s+.+/]
        return [] unless asset

        contextual_places(asset_label: asset).map do |place|
          place.merge("source" => "provider_maintenance_reason", "evidence" => reason.to_s)
        end
      end

      # A citizen can ask about the city as a query scope without claiming an
      # outage affects the whole city. Ingestion must continue to use #match.
      def match_query(text)
        matched = match(text)
        return matched unless matched.unknown?
        return matched if matched.coverage.fetch("ambiguous_places").any? || matched.coverage.fetch("unresolved_places").any?

        query = fold(text)
        city = query.match(/\b(?:(?:u|za|na podrucju)\s+(?:grad[au]\s+)?)?bijeljin[aiue]\b/)
        return matched unless city

        remainder = query.dup
        remainder[city.begin(0)...city.end(0)] = " "
        # A second unresolved location cue must not be widened to city scope.
        return matched if remainder.match?(/\b(?:u|kod|mz|komsiluk|naselj\w*|ulic\w*|rejon|mjesna zajednica|mesna zajednica)\b/)

        Match.new(slugs: [], targeting_level: "citywide", unknown?: false,
                  coverage: matched.coverage.merge("status" => "resolved", "scope_role" => "citizen_query", "citywide_evidence" => city[0]))
      end

      # Typed reference lookup never converts a street, stop, settlement or
      # feeder into an administrative area without a verified crosswalk.
      def resolve_place(query:, kind: nil)
        alias_registry.resolve(query:, kind:)
      end

      # A slug is an internal identifier. It reached a citizen reply at least
      # once ("mz-dasnica"), which is why the public name is now resolved here,
      # next to the only place that knows the tenant's areas, rather than being
      # reconstructed from the slug by whoever renders it. An unknown slug
      # yields nil rather than a prettified guess.
      def display_names(slugs)
        wanted = Array(slugs).map(&:to_s).uniq
        return {} if wanted.empty?

        local_areas.each_with_object({}) do |area, names|
          next unless wanted.include?(area.slug)

          label = PlaceAliasRegistry.display_name(area.translated_name)
          names[area.slug] = label if label.present?
        end
      end

      # Slug plus public name, in the order asked for, for a coverage contract.
      def public_places(slugs)
        names = display_names(slugs)
        Array(slugs).map(&:to_s).uniq.map { |slug| { "slug" => slug, "name" => names[slug] }.compact }
      end

      # Structured v1 callers pass a stable slug or a bounded name candidate;
      # current-turn coordinates are a separate source and never imply home or
      # membership. Conflicting name/location evidence remains ambiguous.
      def resolve(area_slug: nil, area_query: nil, location: nil, place_kind: nil)
        named = resolve_named(area_slug, area_query, place_kind)
        located = resolve_location(location, place_kind:)

        return Resolution.new(status: :ok, areas: [], source: :unspecified) unless named || located
        return named unless located
        return located unless named
        return named if named.status == :unknown
        return located if located.status == :unknown

        return located if located.status == :ambiguous

        shared = named.areas & located.areas
        return Resolution.new(status: :ok, areas: shared, source: :named_and_current_location) if shared.any?

        Resolution.new(
          status: :ambiguous,
          areas: (named.areas + located.areas).uniq,
          source: :conflicting_sources,
          warning: "area_location_conflict"
        )
      end

      private

      attr_reader :organization

      def local_areas
        @local_areas ||= Decidim::Bih::LocalArea
                         .where(decidim_organization_id: organization.id)
                         .order(:kind, :slug)
                         .to_a
      end

      def resolve_named(area_slug, area_query, place_kind)
        return explicit_slug_resolution(area_slug, place_kind) if area_slug.present?
        return nil if area_query.blank?

        kinds = place_kind ? [place_kind.to_s] : %w(mz komsiluk)
        matches = alias_registry.mentions(area_query, kinds:).map { |mention| mention.entry.area }.uniq
        named_resolution(matches)
      end

      def explicit_slug_resolution(area_slug, place_kind)
        area = local_areas.find { |candidate| candidate.slug == area_slug.to_s && (place_kind.blank? || candidate.kind == place_kind.to_s) }
        Resolution.new(
          status: area ? :ok : :unknown,
          areas: [area].compact,
          source: :explicit_slug,
          warning: ("area_not_found" unless area)
        )
      end

      def named_resolution(matches)
        status = if matches.one?
                   :ok
                 elsif matches.any?
                   :ambiguous
                 else
                   :unknown
                 end
        Resolution.new(
          status:,
          areas: matches.sort_by { |area| [area.kind, area.slug] },
          source: :explicit_name,
          warning: ({ ambiguous: "area_name_ambiguous", unknown: "area_not_found" }[status])
        )
      end

      # Keep coordinate, accuracy and boundary guards in the order they constrain location certainty.
      # rubocop:disable Metrics/CyclomaticComplexity
      def resolve_location(location, place_kind: nil)
        return nil unless location.respond_to?(:[])

        latitude = coordinate(location, :latitude)
        longitude = coordinate(location, :longitude)
        return Resolution.new(status: :unknown, areas: [], source: :current_location, warning: "location_outside_reviewed_areas") unless latitude && longitude

        accuracy = location_accuracy(location)
        return Resolution.new(status: :unknown, areas: [], source: :current_location, warning: "location_accuracy_invalid") if accuracy == :invalid

        located = Decidim::Bih::Geo::AreaLocator.new.resolve(lat: latitude, lon: longitude, organization:)
        areas = location_areas(located, place_kind)
        if areas.any? { |area| uncertain_boundary?(area, latitude, longitude, accuracy || 1.0) }
          return Resolution.new(status: :ambiguous, areas:, source: :current_location, warning: "location_near_area_boundary")
        end

        Resolution.new(
          status: areas.any? ? :ok : :unknown,
          areas:,
          source: :current_location,
          warning: ("location_outside_reviewed_areas" if areas.empty?)
        )
      end
      # rubocop:enable Metrics/CyclomaticComplexity

      def location_areas(located, place_kind)
        areas = [located[:komsiluk], located[:mz]].compact
        place_kind ? areas.select { |area| area.kind == place_kind.to_s } : areas
      end

      def location_accuracy(location)
        value = location[:accuracy] || location["accuracy"] || location[:accuracy_meters] || location["accuracy_meters"]
        return if value.nil?

        accuracy = Float(value)
        accuracy.finite? && accuracy >= 0 ? accuracy : :invalid
      rescue ArgumentError, TypeError
        :invalid
      end

      # Compare the reported error radius against every exterior and hole edge
      # of the chosen polygon. Local equirectangular metres are sufficient for
      # conservative Bijeljina boundary checks; membership assignment is separate.
      def uncertain_boundary?(area, latitude, longitude, accuracy)
        return false unless area.respond_to?(:boundary) && area.boundary.is_a?(Hash)

        boundary = area.boundary
        polygons = boundary["type"] == "Polygon" ? [boundary["coordinates"]] : Array(boundary["coordinates"])
        scale_x = 111_320.0 * Math.cos(latitude * Math::PI / 180.0)
        polygons.any? do |rings|
          Array(rings).any? do |ring|
            Array(ring).each_cons(2).any? do |left, right|
              ax = (left[0] - longitude) * scale_x
              ay = (left[1] - latitude) * 111_320.0
              bx = (right[0] - longitude) * scale_x
              by = (right[1] - latitude) * 111_320.0
              dx = bx - ax
              dy = by - ay
              length_squared = (dx * dx) + (dy * dy)
              fraction = length_squared.zero? ? 0 : (-((ax * dx) + (ay * dy)) / length_squared).clamp(0, 1)
              Math.hypot(ax + (fraction * dx), ay + (fraction * dy)) <= [accuracy * 1.01, 1.0].max
            end
          end
        end
      end

      def coordinate(location, key)
        value = location[key] || location[key.to_s]
        number = Float(value)
        return if !number.finite? || (key == :latitude && !number.between?(-90, 90)) || (key == :longitude && !number.between?(-180, 180))

        number
      rescue ArgumentError, TypeError
        nil
      end

      def alias_registry
        @alias_registry ||= PlaceAliasRegistry.new(areas: local_areas)
      end

      def affected_scope(text)
        text.to_s.split(/(?<=[.!?;])\s+|\n+/).filter_map do |sentence|
          normalized = fold(sentence)
          # Preserve an affected clause before an explicit contrast to normal
          # service elsewhere; discard pure normal-service/background clauses.
          if (contrast = normalized.match(/\b(?:dok|a|na ostalim|u ostalim|ostali)\b.*#{NORMAL_SERVICE_PATTERN}/))
            sentence = normalized[0...contrast.begin(0)]
          end
          next if fold(sentence).match?(NORMAL_SERVICE_PATTERN) || fold(sentence).match?(BACKGROUND_PATTERN)

          sentence
        end.join("; ")
      end

      def unresolved_places(text)
        text.split(/[,;\n]/).flat_map { |clause| fold(clause).scan(NETWORK_PLACE_PATTERN) }.map do |label, value|
          kind = case label
                 when "dalekovod", "dv", "trafostanica", "ts", "izvod", "feeder" then "feeder"
                 when "ulica", "ulice", "ulici", "ulicu", "ul" then "street"
                 when "rejon" then "service_zone"
                 else "settlement"
                 end
          { "kind" => kind, "evidence" => "#{label} #{value}".strip, "reason" => "geographic_crosswalk_not_reviewed" }
        end
      end

      def unresolved_local_places(text, mentions)
        remainder = PlaceAliasRegistry.normalize(text)
        mentions.each { |mention| remainder[mention.start...mention.finish] = " " * (mention.finish - mention.start) }
        remainder.scan(/\b(mz|mjesna zajednica|mesna zajednica|komsiluk)\s+([a-z0-9][a-z0-9 ]{0,100})/).map do |label, value|
          { "kind" => label == "komsiluk" ? "komsiluk" : "mz", "evidence" => "#{label} #{value}".strip,
            "reason" => "place_not_reviewed" }
        end
      end

      # A provider's settlement list ("Naseljena mjesta: A, B i C") names every
      # affected place. One we cannot place must be recorded, or a list that
      # resolved only partly reads as fully covered and publishes on its own.
      SETTLEMENT_LABEL = /\Anaselj\w*(?:\s+mjest\w*)?\s+/
      LIST_QUALIFIER = /\A(?:dio|dijelovi|donj\w*|gornj\w*|srednj\w*)\z/

      # Split the raw text: folding drops the commas that separate the places.
      def unlisted_settlements(text)
        label, list = text.to_s.split(":", 2)
        return [] unless list && "#{fold(label)} ".match?(SETTLEMENT_LABEL)

        list.split(/\s*[,;]\s*|\s+(?:i|и)\s+/).filter_map do |item|
          name = PlaceAliasRegistry.normalize(item).sub(/\Adio\s+/, "")
          next if name.empty? || name.match?(LIST_QUALIFIER) || alias_registry.mentions(name).any?

          { "kind" => "locality", "evidence" => name, "reason" => "containment_not_verified" }
        end.uniq
      end

      def coverage_status(slugs, citywide, ambiguous, unresolved)
        return "ambiguous" if ambiguous.any?
        return "partial" if slugs.any? && unresolved.any?
        return "resolved" if slugs.any? || citywide

        "unknown"
      end

      def affected_relation(mention, text)
        prefix = PlaceAliasRegistry.normalize(text)[0...mention.start]
        prefix.match?(/\b(?:cijel\w*|cel\w*|citav\w*)\s*\z/) ? "whole" : "part"
      end

      def overlap_candidates(matches)
        mz_slugs = matches.select { |area| area.kind == "mz" }.map(&:slug)
        return [] if mz_slugs.empty?

        local_areas.select { |area| area.kind == "komsiluk" }.filter_map do |area|
          links = reviewed_mz_links(area)
          next if !links.intersect?(mz_slugs) || matches.include?(area)

          { "slug" => area.slug, "kind" => area.kind, "relation" => "possible_overlap", "evidence" => "local_area_mz_overlap" }
        end
      end

      # A village's komšiluk and MZ can share a name and be one place: the
      # komšiluk lies in that MZ alone, and no other komšiluk reaches into it.
      # The name then picks one board, so keep the MZ. Any other pairing (Janja,
      # Dvorovi, Velika Obarska) is a real choice and stays ambiguous.
      def same_place_group(group)
        entries = group.map(&:entry).uniq(&:id)
        return group unless entries.map(&:kind).sort == %w(komsiluk mz)

        mz, komsiluk = entries.sort_by { |entry| entry.kind == "mz" ? 0 : 1 }
        return group unless sole_komsiluk?(komsiluk.area, mz.slug)

        group.select { |mention| mention.entry.id == mz.id }
      end

      def sole_komsiluk?(komsiluk, mz_slug)
        return false unless komsiluk.respond_to?(:primary_mz_slug) && komsiluk.primary_mz_slug == mz_slug
        return false unless (reviewed_mz_links(komsiluk) - [mz_slug]).empty?

        local_areas.none? { |area| area.kind == "komsiluk" && area.slug != komsiluk.slug && reviewed_mz_links(area).include?(mz_slug) }
      end

      def reviewed_mz_links(area)
        [area.respond_to?(:primary_mz_slug) ? area.primary_mz_slug : nil,
         *(area.respond_to?(:overlapping_mz_slugs) ? Array(area.overlapping_mz_slugs) : [])].compact
      end

      def targeting_level(matches)
        kinds = matches.map(&:kind).uniq
        return "unknown" if kinds.empty?
        return kinds.first if kinds.one?

        "mz"
      end

      def citywide?(folded)
        folded.match?(CITYWIDE_PATTERN) && !folded.match?(NORMAL_SERVICE_PATTERN)
      end

      def fold(value)
        Decidim::Bih::Text.fold(value.to_s)
      end
    end
  end
end
