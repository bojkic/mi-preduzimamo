# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    # Operator corrections are local reviewed facts, never a new provider revision.
    class CityServiceEventReview
      TEXT_FIELDS = %w(title summary recommended_action viber_text review_note).freeze
      FACT_FIELDS = %w(event_type severity lifecycle targeting_level affected_area_slugs starts_at ends_at).freeze
      TIME_PATTERN = /\A\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(?::\d{2})?(?:[+-]\d{2}:\d{2})?\z/

      def initialize(event:, actor:, attributes:)
        @event = event
        @actor = actor
        @attributes = attributes.to_h.stringify_keys
      end

      def call
        return :not_authorized unless Decidim::Bih::OperatorAuthorization.allowed?(@actor, :city_alerts_manage, organization: @event.organization)

        @event.with_lock do
          return :stale_review unless current_review?

          return :facts_confirmation_required if @attributes["facts_reviewed"] != "1" && changed_fact_inputs?

          changes = @attributes.slice(*TEXT_FIELDS)
          changes.merge!(reviewed_facts) if @attributes["facts_reviewed"] == "1"
          from_state = @event.state
          @event.update!(changes)
          @event.update!(extraction_metadata: @event.extraction_metadata.except("publication_correction_pending"))
          @event.mark_reviewed!(actor: @actor, note: @attributes["review_note"])
          CityServiceCoverageRegistry.remember!(@event, actor: @actor)
          record_audit(from_state)
        end
        :updated
      rescue ArgumentError, ActiveRecord::RecordInvalid
        :invalid_facts
      end

      private

      def current_review?
        @event.weather_region_review_current? && %w(pending_review failed).include?(@event.state) && @attributes["content_version"].to_s == @event.content_version.to_s &&
          ActiveSupport::SecurityUtils.secure_compare(@event.answer_review_token, @attributes["review_token"].to_s)
      end

      def changed_fact_inputs?
        @attributes["reuse_coverage"] == "1" || changed_classification_inputs? || changed_area_inputs? || changed_time_inputs?
      end

      def changed_classification_inputs?
        %w(event_type severity lifecycle targeting_level).any? { |key| @attributes.has_key?(key) && @attributes[key] != @event.public_send(key) }
      end

      def changed_area_inputs?
        return false unless @attributes.has_key?("area_ids")

        selected = Array(@attributes["area_ids"]).compact_blank.map(&:to_i).sort
        stored = Decidim::Bih::LocalArea.where(decidim_organization_id: @event.decidim_organization_id, slug: @event.area_slugs).pluck(:id).sort
        selected != stored
      end

      def changed_time_inputs?
        %w(starts_at ends_at).any? do |field|
          key = "#{field}_local"
          next false unless @attributes.has_key?(key)

          value = @attributes[key].presence
          parsed = value && reviewed_time(value)
          parsed != @event.public_send(field)&.change(usec: 0)
        end
      end

      def reviewed_facts
        raise ArgumentError if @attributes["review_note"].blank?

        facts = @attributes.slice("event_type", "severity", "lifecycle", "targeting_level")
        validate_classification!(facts)
        facts["affected_area_slugs"] = reviewed_areas(facts.fetch("targeting_level"))
        facts["starts_at"] = reviewed_time(@attributes["starts_at_local"])
        facts["ends_at"] = reviewed_time(@attributes["ends_at_local"])
        raise ArgumentError unless facts["ends_at"] > facts["starts_at"]

        validate_reusable_coverage!(facts)
        facts.merge("extraction_metadata" => corrected_metadata(facts))
      end

      def validate_reusable_coverage!(facts)
        return unless @attributes["reuse_coverage"] == "1"

        expires = Date.iso8601(@attributes["coverage_valid_until"].to_s)
        raise ArgumentError unless expires.between?(Date.current, Date.current + 90)
        raise ArgumentError unless %w(mz komsiluk).include?(facts["targeting_level"]) && @event.affected_text.present?
        raise ArgumentError if @event.source_url.blank?

        @coverage_valid_until = expires.iso8601
      end

      def validate_classification!(facts)
        allowed_types = CityServiceNoticeClassifier::EVENT_TYPES
        raise ArgumentError unless allowed_types.include?(facts["event_type"]) && CityServiceEvent::SEVERITIES.include?(facts["severity"])
        raise ArgumentError unless CityServiceEvent::LIFECYCLES.excluding("superseded", "unknown").include?(facts["lifecycle"])
        raise ArgumentError unless %w(mz komsiluk citywide).include?(facts["targeting_level"])
      end

      def reviewed_areas(kind)
        ids = Array(@attributes["area_ids"]).map(&:to_s).compact_blank.uniq
        validate_area_ids!(ids)
        return [] if kind == "citywide" && ids.empty?
        raise ArgumentError if kind == "citywide" || ids.empty?

        areas = Decidim::Bih::LocalArea.where(decidim_organization_id: @event.decidim_organization_id, kind:, id: ids).order(:slug).to_a
        raise ArgumentError unless areas.size == ids.size

        @reviewed_area_ids = areas.map(&:id)
        areas.map(&:slug)
      end

      def validate_area_ids!(ids)
        raise ArgumentError if ids.size > 200 || ids.any? { |id| !id.match?(/\A[1-9]\d*\z/) }
      end

      def reviewed_time(value)
        value = value.to_s.strip.tr(" ", "T")
        raise ArgumentError unless TIME_PATTERN.match?(value)

        date = Date.iso8601(value[0, 10])
        clock = value[11, 8].split(/[+-]/).first.split(":").map(&:to_i)
        validate_clock!(clock)

        local = Time.utc(date.year, date.month, date.day, *clock)
        periods = Time.find_zone!("Europe/Sarajevo").tzinfo.periods_for_local(local)
        if value.match?(/[+-]\d{2}:\d{2}\z/)
          explicit = Time.new(date.year, date.month, date.day, clock[0], clock[1], clock.fetch(2, 0), value[-6, 6])
          raise ArgumentError unless periods.any? { |period| period.utc_total_offset == explicit.utc_offset }

          explicit.utc
        else
          raise ArgumentError unless periods.one?

          local - periods.sole.utc_total_offset
        end
      end

      def validate_clock!(clock)
        raise ArgumentError unless clock[0].between?(0, 23) && clock[1].between?(0, 59) && clock.fetch(2, 0).between?(0, 59)
      end

      def corrected_metadata(facts)
        metadata = @event.extraction_metadata.deep_dup
        previous = metadata["operator_review"].to_h
        original = previous["original"] || { "facts" => @event.attributes.slice(*FACT_FIELDS), "text" => @event.attributes.slice("title", "summary", "affected_text"),
                                             "extraction_metadata" => metadata.deep_dup }
        metadata["coverage"] = {
          "status" => "resolved",
          "affected_places" => facts["affected_area_slugs"].map do |slug|
            { "slug" => slug, "kind" => facts["targeting_level"], "relation" => "part", "source" => "operator_correction" }
          end,
          "citywide_evidence" => ("operator_correction" if facts["targeting_level"] == "citywide")
        }
        metadata["confidence_by_field"] = metadata.fetch("confidence_by_field", {}).merge("place" => "operator_correction")
        metadata["operator_review"] = {
          "original" => original, "facts" => facts, "reviewed_at" => Time.current.iso8601,
          "reviewed_by_id" => @actor.id, "source_content_version" => @event.content_version,
          "place_ids" => @reviewed_area_ids || [], "place_kind" => facts["targeting_level"],
          "provenance" => "operator_correction", "timezone" => "Europe/Sarajevo",
          "reuse_coverage" => @coverage_valid_until.present?, "coverage_valid_until" => @coverage_valid_until
        }
        metadata
      end

      def record_audit(from_state)
        Decidim::Bih::OperatorAuditEvent.record!(
          organization: @event.organization, actor: @actor, event_type: "city_service_event_reviewed", permission: "city_alerts_manage",
          role: Decidim::Bih::OperatorAuthorization.role_for(@actor, :city_alerts_manage, organization: @event.organization), resource: @event,
          metadata: { from_state:, to_state: @event.state, content_version: @event.content_version,
                      operator_correction: @attributes["facts_reviewed"] == "1", reviewed_facts: @event.attributes.slice(*FACT_FIELDS) }
        )
      end
    end
  end
end
