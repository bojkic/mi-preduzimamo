# frozen_string_literal: true

require "digest"

module DecidimApp
  module Bijeljina
    class CityServiceAutomation
      def initialize(organization:)
        @organization = organization
        @policy = CityServiceAutomationPolicy.new(organization:)
      end

      def call(events:)
        Array(events).map { |event| evaluate!(event) }
      end

      def blockers(event)
        reasons = source_blockers(event) + coverage_blockers(event)
        reasons << event.publication_blocker.to_s if event.publication_blocker
        reasons << "already_handled" unless event.pending_review?
        reasons << "human_review_required" if human_review?(event)
        reasons << "duplicate_review" if CityServiceIncidentReview.new(event:).candidates.any? { |row| %w(same separate).exclude?(row[:decision]) }
        reasons << "no_board_targets" if CityServiceEventPreview.new(event).board_target_slugs.empty?
        reasons.uniq
      end

      def evaluate!(event)
        raise ArgumentError, "event organization mismatch" unless event.decidim_organization_id == @organization.id

        CityServiceIncident.synchronize(@organization) do
          event.lock!
          mode = @policy.mode(event.source_key)
          reasons = blockers(event)
          record = CityServiceAutomationDecision.find_or_initialize_by(event:, policy_version: CityServiceAutomationPolicy::VERSION,
                                                                       content_version: event.content_version.to_s)
          # Re-observing the same revision must not erase proof that this
          # policy published it; changed content creates a distinct decision.
          return record if publication_record_current?(record, event)

          record.assign_attributes(mode:, outcome: reasons.empty? ? "eligible" : "review", blockers: reasons,
                                   target_slugs: CityServiceEventPreview.new(event).board_target_slugs)
          record.save!
          if mode == "automatic" && reasons.empty?
            result = CityServiceEventPublisher.new(event, actor: nil).publish_automatically!(policy_version: CityServiceAutomationPolicy::VERSION)
            record.update!(outcome: result.status.to_s, publication_revision: event.reload.publication_revision)
          end
          record
        end
      end

      private

      def publication_record_current?(record, event)
        record.persisted? && record.outcome == "published" && (event.board_published? || event.published?) && event.publication_blocker.nil?
      end

      def human_review?(event)
        # Weather candidates are severe or extreme today. Keep the explicit
        # source exclusion even if a future parser changes their severity.
        event.source_key == "weather_warnings" || %w(emergency safety).include?(event.severity) ||
          event.targeting_level == "citywide" || event.extraction_metadata["requires_human_review"]
      end

      def source_blockers(event)
        reasons = []
        reasons << "source_disabled_by_owner" unless CityServiceSources.enabled?(event.source_key)
        reasons << "source_not_in_automatic_cohort" unless CityServiceAutomationPolicy::AUTOMATIC_SOURCES.include?(event.source_key)
        reasons << "source_not_current_and_complete" unless current_source?(event)
        reasons << "incomplete_source" unless event.extraction_metadata["source_snapshot_complete"] == true
        reasons << "source_changed" if event.extraction_metadata["source_document_changed"] || event.extraction_metadata["publication_correction_pending"]
        reasons << "non_alert_notice" if %w(not_relevant routine_service_info bulky_waste_collection).include?(event.event_type)
        reasons << "routine_profile_required" if event.source_key == "road_conditions" && !verified_routine_road_profile?(event)
        reasons << "ai_review_required" if event.source_key == "city_official_notices" && !approved_city_classification?(event)
        reasons
      end

      def verified_routine_road_profile?(event)
        profile = event.extraction_metadata["routine_board_profile"].to_h
        profile["status"] == "validated" && profile["source_content_version"] == event.content_version &&
          profile["event_type"] == event.event_type && profile["severity"] == event.severity
      end

      def approved_city_classification?(event)
        decision = event.extraction_metadata["ai_classification"].to_h
        event.extraction_metadata["source_document_complete"] == true && event.extraction_metadata["ai_source_text"].present? &&
          decision["status"] == "accepted" && decision["source_content_version"] == event.content_version &&
          decision["version"] == CityServiceAiAssessment::VERSION &&
          decision["source_article_hash"] == Digest::SHA256.hexdigest(event.extraction_metadata["ai_source_text"].to_s.strip) &&
          decision["publish"] == true && decision["needs_review"] == false &&
          decision["delivery_recommendation"] != "operator_review" &&
          decision["event_type"] == event.event_type && decision["severity"] == event.severity
      end

      def current_source?(event)
        snapshot = DecidimApp::CityServiceSourceSnapshot.find_by(source_key: event.source_key)
        max_age = CityServiceSources::HEALTH_MAX_AGES.fetch(event.source&.fetch(:scrape_cadence), 1.hour)
        snapshot && snapshot.last_success_at && snapshot.last_success_at.between?(Time.current - max_age, Time.current) &&
          snapshot.source_version == CityServiceSourceCheckStore.new.version_for(event.source) &&
          snapshot.check_payload["error_code"].blank? && %w(ok empty unreviewed).include?(snapshot.check_payload["status"])
      end

      def coverage_blockers(event)
        coverage = event.extraction_metadata["coverage"].to_h
        reasons = []
        unless coverage["status"] == "resolved" && event.area_slugs.any? && Array(coverage["unresolved_places"]).empty? && Array(coverage["ambiguous_places"]).empty?
          reasons << "unresolved_coverage"
        end
        if event.source_key == "water_service"
          clauses = event.affected_text.to_s.split(/[;\n]/).map(&:strip).reject(&:empty?)
          if clauses.size > 1 && (coverage["clause_count"].to_i != clauses.size ||
                                  coverage["resolved_clause_count"].to_i != clauses.size ||
                                  coverage["unresolved_clause_count"].to_i.positive?)
            reasons << "unresolved_coverage"
          end
        end
        reasons << "coverage_requires_review" unless trusted_coverage?(event, coverage)
        reasons
      end

      def trusted_coverage?(event, coverage)
        return false unless coverage["source_content_version"] == event.content_version || event.extraction_metadata.dig("confidence_by_field", "place") == "reviewed_alias"
        return false if event.extraction_metadata.dig("confidence_by_field", "place") == "operator_mapping" && !CityServiceCoverageRegistry.resolve(event)
        return trusted_water_board_placement?(event, coverage) if coverage["scope_precision"] == "unspecified_street_segment"
        return station_evidence_current?(event, coverage) if event.extraction_metadata.dig("confidence_by_field", "place") == "provider_station_name"

        %w(reviewed_alias full_named_street_geometry municipal_settlement_geometry municipal_place_containment operator_mapping).include?(
          event.extraction_metadata.dig("confidence_by_field", "place")
        )
      end

      def station_evidence_current?(event, coverage)
        place = event.extraction_metadata["station_place"].to_h
        return false unless event.targeting_level == "komsiluk" && event.area_slugs == [place["slug"]]
        return false unless place["status"] == "resolved" && place["rule_version"] == CityServiceStationPlace::VERSION &&
                            place["source_content_version"] == event.content_version && place["scope_precision"] == "part_of_area" &&
                            coverage["station_resolution_version"] == CityServiceStationPlace::VERSION &&
                            coverage["scope_precision"] == "part_of_area"
        return false unless [event.title, event.summary, event.viber_text].all? { |copy| copy.to_s.include?("dio komšiluka") }

        resolved = CityServiceStationPlace.new(organization: @organization).resolve(event, recheck: true)
        resolved.resolved? && resolved.slug == place["slug"] && resolved.area_id == place["area_id"] &&
          resolved.alias_revision == place["alias_revision"] && resolved.boundary_hash == place["boundary_hash"] &&
          resolved.station_label == place["station_label"]
      end

      def trusted_water_board_placement?(event, coverage)
        return false unless event.source_key == "water_service" && event.targeting_level == "komsiluk"
        return false unless coverage["source_content_version"] == event.content_version &&
                            event.extraction_metadata.dig("confidence_by_field", "place") == "verified_water_location_geometry"
        return false unless coverage["scope"] == "source_named_water_locations" && coverage["status"] == "resolved" &&
                            coverage["complete"] == true && coverage["board_placement"] == "verified_full_geometry_intersection" &&
                            coverage["water_mixed_coverage_revision"] == water_mixed_coverage_revision
        return false unless event.extraction_metadata["canonical_article_url"] == event.source_url &&
                            event.extraction_metadata["source_snapshot_complete"] == true &&
                            event.extraction_metadata.dig("water_board_copy", "source_content_version") == event.content_version

        source_clauses = event.affected_text.to_s.split(/[;\n]/, -1).map(&:strip)
        clauses = Array(coverage["clauses"])
        return false if source_clauses.empty? || source_clauses.any?(&:blank?) || clauses.map { |row| row["evidence"] } != source_clauses
        return false unless clauses.any? { |row| %w(street settlement_part).include?(row["kind"]) }
        return false unless coverage["clause_count"] == clauses.size && coverage["resolved_clause_count"] == clauses.size &&
                            coverage["unresolved_clause_count"] == 0 &&
                            clauses.all? { |row| %w(street settlement_part settlement).include?(row["kind"]) &&
                                                 row["status"] == "resolved" && Array(row["board_slugs"]).any? }

        board_slugs = clauses.flat_map { |row| row["board_slugs"] }.uniq.sort
        places = Array(coverage["affected_places"]).select { |place| place["kind"] == "komsiluk" }.map { |place| place["slug"] }.uniq.sort
        return false unless board_slugs == places && board_slugs == event.area_slugs

        [event.title, event.summary, event.viber_text].all? { |copy| copy.to_s.include?("dio komšiluka") }
      end

      def water_mixed_coverage_revision
        @water_mixed_coverage_revision ||= CityServiceWaterMixedCoverage.new(organization: @organization).revision
      end
    end
  end
end
