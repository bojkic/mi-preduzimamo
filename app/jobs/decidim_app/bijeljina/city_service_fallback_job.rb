# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    # Durable receipt rows recover missed scheduling. A timeout means unknown,
    # not proven failure; a late display can still duplicate a dispatched Viber.
    class CityServiceFallbackJob < Decidim::ApplicationJob
      queue_as :integrations
      self.log_arguments = false

      def self.recover_pending!
        Decidim::Bih::PlatformDelivery.where.not(fallback_requested_at: nil)
                                      .where(acknowledged_at: nil, account_notification_id: nil)
                                      .where("deadline_at <= ? AND expires_at > ?", Time.current, Time.current)
                                      .limit(500).pluck(:id).each { |id| perform_later(id) }
      end

      def perform(receipt_id) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
        receipt = Decidim::Bih::PlatformDelivery.find_by(id: receipt_id)
        return unless receipt&.fallback_requested_at

        context = receipt.fallback_context
        event = CityServiceEvent.find_by(id: context["event_id"], decidim_organization_id: receipt.decidim_organization_id)
        return unless event

        CityServiceIncident.synchronize(event.organization) do
          event.with_lock do
            return unless CityServiceSources.enabled?(event.source_key) && CityServiceSources.alerts_enabled? && event.delivery_current?(context["event_revision"])
            return if CityServicePhoneDelivery.phone_audience_unverified?(event)
            return unless event.viber_dedupe_key == context["dedupe_key"]
            return unless receipt.identity == CityServiceIncidentIdentity.delivery_identity(event)

            receipt.with_lock do
              return unless receipt.fallback_due?
              return if receipt.account_notification_id

              channels = Array(context["channels"]).presence || ["viber"]
              channels &= %w(viber whatsapp)
              snapshot = context["template"].presence
              current_template = CityServicePhoneDelivery.template(event) if channels.include?("whatsapp")
              template = snapshot if snapshot && current_template &&
                                     CityServicePhoneDelivery.template_digest(snapshot) == CityServicePhoneDelivery.template_digest(current_template)
              channels -= ["whatsapp"] unless template
              return if channels.empty?

              text = event.viber_text.presence || [event.title, event.summary].compact_blank.join(" - ")
              notification = Decidim::Bih::AccountNotifications.enqueue!(
                user: receipt.user, organization: event.organization, topic: :city_service_alerts,
                text: text[0, CityServiceNoticeClassifier::VIBER_LIMIT], channels:, template:,
                deduplication_key: receipt.identity, expires_at: event.ends_at,
                message_class: CityServiceAlertNotificationJob::MESSAGE_CLASS, enqueue_job: false,
                context: context.merge("platform_delivery_id" => receipt.id)
              )
              receipt.update!(account_notification_id: notification.id)
            end
          end
        end
        if receipt.account_notification_id
          Decidim::Bih::AccountNotifications.enqueue_pending(
            Decidim::Bih::AccountNotification.find(receipt.account_notification_id)
          )
        end
      end
    end
  end
end
