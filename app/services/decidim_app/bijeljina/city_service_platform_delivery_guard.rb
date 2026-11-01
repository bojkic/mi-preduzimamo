# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    class CityServicePlatformDeliveryGuard
      def self.call(receipt:) # rubocop:disable Metrics/CyclomaticComplexity
        context = receipt.fallback_context
        return yield if context["event_id"].blank?

        event = CityServiceEvent.find_by(id: context["event_id"], decidim_organization_id: receipt.decidim_organization_id)
        return unless event

        CityServiceIncident.synchronize(event.organization) do
          event.with_lock do
            return unless context["event_revision"].present? && event.publication_revision == context["event_revision"]
            return unless %w(board_published published).include?(event.state) && event.publication_blocker.nil?
            return if receipt.expires_at <= Time.current
            return unless receipt.identity == CityServiceIncidentIdentity.delivery_identity(event)
            return unless CityServiceAlertNotificationJob.recipient_current?(event, receipt.decidim_user_id)
            return unless CityServiceBoardVisibility.current_for_recipient?(event:, user_id: receipt.decidim_user_id)

            yield
          end
        end
      end
    end
  end
end
