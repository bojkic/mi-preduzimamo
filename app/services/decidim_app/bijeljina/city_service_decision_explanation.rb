# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    # Short, truthful operator copy. Technical codes stay in the details panel.
    class CityServiceDecisionExplanation
      AUTOMATION_BLOCKERS = %w(source_not_in_automatic_cohort source_not_current_and_complete incomplete_source
                               source_changed ai_review_required routine_profile_required non_alert_notice unresolved_coverage coverage_requires_review already_handled
                               human_review_required duplicate_review no_board_targets).freeze
      PUBLICATION_BLOCKERS = %w(invalid_lifecycle incomplete_source missing_time invalid_time expired no_target).freeze
      EXTRA_REASONS = %w(station_unknown station_ambiguous station_placed water_board_placed auto_published shadow_review
                         manual_review ready unknown).freeze
      REASONS = (AUTOMATION_BLOCKERS + PUBLICATION_BLOCKERS + EXTRA_REASONS).uniq.freeze
      PRIORITY = %w(non_alert_notice human_review_required invalid_lifecycle incomplete_source source_not_current_and_complete
                    source_changed ai_review_required routine_profile_required missing_time invalid_time expired station_unknown station_ambiguous
                    unresolved_coverage coverage_requires_review duplicate_review no_board_targets
                    source_not_in_automatic_cohort already_handled).freeze

      def initialize(entry)
        @entry = entry
        @event = entry.event
      end

      def text(locale: I18n.locale, area: nil)
        key = reason
        options = { station: station_label, area: area.presence || area_label, count: unresolved_count }
        I18n.t("decidim_app.admin.city_service_events.decision_explanations.#{key}", locale:, **options,
               default: I18n.t("decidim_app.admin.city_service_events.decision_explanations.unknown", locale:))
      end

      def reason
        return "station_placed" if station_placed? && @entry.automatic_decision && @entry.status == "published"
        return "water_board_placed" if water_board_placed? && @entry.automatic_decision && @entry.status == "published"
        return "auto_published" if @entry.automatic_decision && @entry.status == "published"
        return "ready" if @entry.status == "ready"
        return "shadow_review" if @entry.decision&.mode == "shadow" && Array(@entry.decision.blockers).empty?

        reasons = Array(@entry.decision&.blockers).map(&:to_s)
        reasons << @entry.blocker.to_s if @entry.blocker
        reasons << station_issue if station_issue
        PRIORITY.find { |key| reasons.include?(key) } || (reasons.empty? ? "manual_review" : "unknown")
      end

      def secondary_reasons
        (Array(@entry.decision&.blockers).map(&:to_s) - [reason]).filter_map do |key|
          key if REASONS.include?(key)
        end
      end

      def method_label(locale: I18n.locale)
        key = if @entry.automatic_decision
                "automatic"
              elsif @event.reviewed_by_id.present?
                "operator"
              elsif current_ai_decision?
                "ai"
              else
                "parser"
              end
        I18n.t("decidim_app.admin.city_service_events.decision_explanations.methods.#{key}", locale:)
      end

      private

      def current_ai_decision?
        ai = @event.extraction_metadata["ai_classification"].to_h
        ai["source_content_version"] == @event.content_version && %w(accepted rejected disagreement review).include?(ai["status"])
      end

      def station_issue
        resolution = @event.extraction_metadata["station_place"].to_h
        return "station_unknown" if resolution["status"] == "unknown"
        return "station_ambiguous" if resolution["status"] == "ambiguous"
      end

      def station_placed?
        @event.extraction_metadata.dig("confidence_by_field", "place") == "provider_station_name"
      end

      def water_board_placed?
        @event.source_key == "water_service" && @event.extraction_metadata.dig("coverage", "scope_precision") == "unspecified_street_segment" &&
          @event.extraction_metadata.dig("coverage", "board_placement") == "verified_full_geometry_intersection"
      end

      def station_label
        @event.extraction_metadata["station_label"].presence || @event.extraction_metadata.dig("station_place", "station_label").presence || "?"
      end

      def area_label
        @event.target_komsiluk_slugs.first || @event.area_slugs.first || "?"
      end

      def unresolved_count
        Array(@event.extraction_metadata.dig("coverage", "unresolved_places")).size
      end
    end
  end
end
