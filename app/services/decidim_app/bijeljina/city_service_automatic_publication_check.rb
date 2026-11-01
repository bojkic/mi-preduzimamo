# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    # A check describes the publication the operator actually saw. It is never
    # an approval for a future source correction or a new policy evaluation.
    class CityServiceAutomaticPublicationCheck
      def self.current_decision(event)
        return unless event.publication_revision.present?

        CityServiceAutomationDecision.where(event_id: event.id, outcome: "published", publication_revision: event.publication_revision)
                                     .order(id: :desc).first
      end

      def initialize(event:, actor:)
        @event = event
        @actor = actor
      end

      def mark_ok!(expected_revision:, expected_digest:)
        return :not_authorized unless authorized?

        CityServiceIncident.synchronize(@event.organization) do
          @event.with_lock do
            @event.reload
            return :stale_review unless current_revision?(expected_revision) &&
                                        current_digest?(expected_digest)
            return :not_publishable unless (@event.board_published? || @event.published?) && @event.publication_blocker.nil?

            decision = self.class.current_decision(@event)
            return :not_automatic unless decision
            return :already_checked if decision.checked_for?(@event)

            save_check!(decision, "ok", expected_revision)
          end
        end
      end

      # Called only after the existing withdrawal service has succeeded.
      # An old decision stays inspectable and the new publication starts unchecked.
      def mark_resolution!(expected_revision:, result:)
        return :not_authorized unless authorized?
        return :invalid_selection unless %w(corrected withdrawn).include?(result)

        CityServiceIncident.synchronize(@event.organization) do
          @event.with_lock do
            @event.reload
            history = Array(@event.extraction_metadata["publication_history"])
            return :stale_review unless history.any? { |item| item["revision"] == expected_revision }
            return :not_publishable if result == "corrected" && !(@event.board_published? || @event.published?)
            return :not_publishable if result == "withdrawn" && !@event.dismissed?

            decision = CityServiceAutomationDecision.where(event_id: @event.id, outcome: "published", publication_revision: expected_revision)
                                                    .order(id: :desc).first
            return :not_automatic unless decision

            decision.with_lock { save_check!(decision, result, expected_revision) }
          end
        end
      end

      private

      def authorized?
        Decidim::Bih::OperatorAuthorization.allowed?(@actor, :city_alerts_manage, organization: @event.organization) &&
          @actor.organization == @event.organization
      end

      def current_digest?(expected)
        expected.present? && ActiveSupport::SecurityUtils.secure_compare(
          CityServiceAutomationDecision.evidence_digest(@event), expected.to_s
        )
      end

      def current_revision?(expected)
        expected.present? && ActiveSupport::SecurityUtils.secure_compare(@event.publication_revision.to_s, expected.to_s)
      end

      def save_check!(decision, result, revision)
        decision.update!(checked_at: Time.current, checked_by: @actor, check_result: result,
                         checked_publication_revision: revision, checked_policy_version: CityServiceAutomationPolicy::VERSION,
                         checked_evidence_digest: CityServiceAutomationDecision.evidence_digest(@event))
        Decidim::Bih::OperatorAuditEvent.record!(organization: @event.organization, actor: @actor,
          event_type: "city_alert_auto_#{result}", permission: "city_alerts_manage", resource: @event,
          metadata: { decision_id: decision.id, publication_revision: revision, policy_version: CityServiceAutomationPolicy::VERSION })
        :checked
      end
    end
  end
end
