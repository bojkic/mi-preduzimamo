# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    class CityServiceDeliveryRetry
      Result = Struct.new(:status, :retried_count, keyword_init: true)

      def self.call(event:, actor:, review_token:)
        return Result.new(status: :not_authorized, retried_count: 0) unless Decidim::Bih::OperatorAuthorization.allowed?(actor, :city_alerts_manage,
                                                                                                                         organization: event.organization)

        event.with_lock do
          return Result.new(status: :stale_review, retried_count: 0) unless ActiveSupport::SecurityUtils.secure_compare(event.answer_review_token, review_token.to_s)

          entry = CityServiceWorkflow.new(organization: event.organization).entries.fetch(event.id)
          return Result.new(status: :not_publishable, retried_count: 0) unless entry.status == "published" && event.delivery_current?(event.publication_revision)
          return Result.new(status: :phone_audience_unverified, retried_count: 0) if CityServicePhoneDelivery.phone_audience_unverified?(event)

          digest = Digest::SHA256.hexdigest("city_service_alerts:city-alert:#{event.viber_dedupe_key}")
          notifications = Decidim::Bih::AccountNotification.where(organization: event.organization, topic: "city_service_alerts", deduplication_digest: digest,
                                                                  status: %w(rejected failed)).order(:id).lock.to_a
          channels = CityServicePhoneDelivery.channels(organization: event.organization) & CityServiceFallbackAudience.retry_channels(event)
          template = CityServicePhoneDelivery.template(event) if channels.include?("whatsapp")
          channels -= ["whatsapp"] unless template
          audience = CityServiceFallbackAudience.preview(
            organization: event.organization, area_slugs: CityServiceEventPreview.new(event).call.target_area_slugs,
            expires_at: event.ends_at, text: event.viber_text, channels:, template:, event:, retry_failed: true
          )
          eligible_ids = audience.fetch(:eligible_notification_ids)
          eligible = notifications.select { |notification| eligible_ids.include?(notification.id) && matching_revision?(notification, event) }
          return Result.new(status: :nothing_to_retry, retried_count: 0) if eligible.empty?

          previous = eligible.map { |notification| { notification_id: notification.id, status: notification.status, reason: notification.reason } }
          eligible.each do |notification|
            notification.update!(status: "pending", reason: "operator_retry_requested")
            Decidim::Bih::AccountNotifications.enqueue_pending(notification)
          end
          Decidim::Bih::OperatorAuditEvent.record!(organization: event.organization, actor:, event_type: "city_service_delivery_retried",
                                                   permission: "city_alerts_manage",
                                                   role: Decidim::Bih::OperatorAuthorization.role_for(actor, :city_alerts_manage, organization: event.organization),
                                                   resource: event, metadata: { retried_count: eligible.size, previous_attempts: previous })
          Result.new(status: :delivery_retry_queued, retried_count: eligible.size)
        end
      end

      def self.matching_revision?(notification, event)
        context = notification.payload.fetch("context", {})
        notification.expires_at > Time.current && context["event_id"].to_s == event.id.to_s && context["event_revision"] == event.publication_revision
      end
      private_class_method :matching_revision?
    end
  end
end
