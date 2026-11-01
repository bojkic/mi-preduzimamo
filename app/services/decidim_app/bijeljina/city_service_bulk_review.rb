# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    class CityServiceBulkReview
      MAX_ITEMS = 80
      ACTIONS = %w(review dismiss).freeze
      Result = Struct.new(:status, :affected_count, keyword_init: true)

      def initialize(organization:, actor:, action:, selections:, note:)
        @organization = organization
        @actor = actor
        @action = action.to_s
        @selections = selections.to_h
        @note = note.to_s.strip
      end

      def call
        return result(:not_authorized) unless Decidim::Bih::OperatorAuthorization.allowed?(@actor, :city_alerts_manage, organization: @organization)
        return result(:invalid_selection) unless valid_request?

        CityServiceEvent.transaction do
          events = CityServiceEvent.for_organization(@organization).where(id: @selections.keys).order(:id).lock.to_a
          return result(:stale_review) unless events.size == @selections.size && events.all? { |event| current?(event) && workflow.entries.fetch(event.id).editable? }

          events.each { |event| apply(event) }
          result(:updated, events.size)
        end
      end

      private

      def valid_request?
        ACTIONS.include?(@action) && @note.present? && @note.length <= 2000 && @selections.size.between?(1, MAX_ITEMS) &&
          @selections.all? { |id, receipt| id.to_s.match?(/\A[1-9]\d*\z/) && receipt.is_a?(Hash) && receipt["review_token"].to_s.match?(/\A[0-9a-f]{64}\z/) }
      end

      def workflow
        @workflow ||= CityServiceWorkflow.new(organization: @organization)
      end

      def current?(event)
        receipt = @selections.fetch(event.id.to_s)
        (@action == "dismiss" || event.weather_region_review_current?) &&
          %w(pending_review failed).include?(event.state) && receipt["content_version"].to_s == event.content_version.to_s &&
          ActiveSupport::SecurityUtils.secure_compare(event.answer_review_token, receipt.fetch("review_token"))
      end

      def apply(event)
        from_state = event.state
        event.update!(state: "dismissed", dismissed_at: Time.current) if @action == "dismiss"
        event.mark_reviewed!(actor: @actor, note: @note)
        Decidim::Bih::OperatorAuditEvent.record!(
          organization: @organization, actor: @actor, event_type: @action == "dismiss" ? "city_service_event_dismissed" : "city_service_event_reviewed",
          permission: "city_alerts_manage", role: Decidim::Bih::OperatorAuthorization.role_for(@actor, :city_alerts_manage, organization: @organization), resource: event,
          metadata: { from_state:, to_state: event.state, content_version: event.content_version, bulk_action: @action, operator_correction: false }
        )
      end

      def result(status, count = 0)
        Result.new(status:, affected_count: count)
      end
    end
  end
end
