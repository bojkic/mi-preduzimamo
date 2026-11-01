# frozen_string_literal: true

require "digest"

module DecidimApp
  module Bijeljina
    class CityServiceFallbackAudience
      # The operator view receives aggregates only. Retry also returns private
      # notification IDs to its service so the queued set matches that view.
      # The fingerprint binds membership AND current exclusion outcomes so a
      # changed audience invalidates a previously confirmed preview.
      def self.preview(organization:, area_slugs:, expires_at: nil, text: nil, channels: ["viber"], template: nil, event: nil, retry_failed: false)
        return retry_preview(organization:, area_slugs:, expires_at:, text:, channels:, template:, event:) if retry_failed

        ids = CityServiceAlertNotificationJob.recipient_ids_for(organization:, area_slugs:)
        outcomes = []
        excluded = Hash.new(0)
        eligible = 0
        deadlines = []
        identity = CityServiceIncidentIdentity.delivery_identity(event) if event&.publication_revision.present?
        Decidim::User.where(id: ids, decidim_organization_id: organization.id).order(:id).find_each do |user|
          receipt = Decidim::Bih::PlatformDelivery.find_by(user:, identity:) if identity
          active = user.confirmed_at.present? && !user.blocked? && !user.deleted?
          decision = if active
                       Decidim::Bih::AccountNotifications.preview(user:, organization:, topic: :city_service_alerts,
                                                                   channels:, template:, text:)
                     else
                       { eligible: false, channels: [], reasons: {} }
                     end
          reason = if !active
                     "account_unavailable"
                   elsif expires_at && expires_at <= Time.current
                     "expired"
                   elsif receipt&.acknowledged_at
                     "platform_acknowledged"
                   elsif receipt&.fallback_requested_at
                     "fallback_already_requested"
                   elsif receipt && receipt.expires_at <= Time.current
                     "expired"
                   elsif decision[:eligible]
                     nil
                   else
                     decision[:reasons].values.compact.first || "ineligible"
                   end
          reason ? excluded[reason] += 1 : eligible += 1
          deadlines << receipt.deadline_at if !reason && receipt
          outcomes << [user.id, reason, decision[:channels], receipt&.id, receipt&.deadline_at&.iso8601]
        end
        deadline = deadlines.min || Time.current + Decidim::Bih::PlatformDelivery::ACK_WAIT
        deadline = [deadline, expires_at].min if expires_at
        { total: outcomes.length, eligible_viber: eligible, eligible_phone: eligible, excluded:, deadline_at: deadline,
          channels:, template_digest: CityServicePhoneDelivery.template_digest(template),
          acknowledgment_wait_seconds: Decidim::Bih::PlatformDelivery::ACK_WAIT.to_i,
          audience_fingerprint: Digest::SHA256.hexdigest(JSON.generate(outcomes)) }
      end

      def self.retry_preview(organization:, area_slugs:, expires_at:, text:, channels:, template:, event:)
        ids = CityServiceAlertNotificationJob.recipient_ids_for(organization:, area_slugs:)
        digest = Digest::SHA256.hexdigest("city_service_alerts:city-alert:#{event.viber_dedupe_key}")
        notifications = Decidim::Bih::AccountNotification.where(organization:, decidim_user_id: ids, topic: "city_service_alerts",
                                                                deduplication_digest: digest, status: %w(rejected failed)).order(:id)
        outcomes = []
        excluded = Hash.new(0)
        eligible = 0
        eligible_notification_ids = []
        notifications.each do |notification|
          payload = notification.payload.to_h
          receipt = Decidim::Bih::PlatformDelivery.find_by(user: notification.user,
                                                            identity: CityServiceIncidentIdentity.delivery_identity(event))
          user = notification.user
          active = user.confirmed_at.present? && !user.blocked? && !user.deleted?
          decision = if active
                       Decidim::Bih::AccountNotifications.preview(
                         user:, organization:, topic: :city_service_alerts,
                         channels: Array(payload["channels"]) & channels, template: payload["template"], text: payload["text"] || text
                       )
                     else
                       { eligible: false, channels: [], reasons: {} }
                     end
          reason = if !active
                     "account_unavailable"
                   elsif notification.expires_at <= Time.current || expires_at <= Time.current
                     "expired"
                   elsif payload.dig("context", "event_id").to_s != event.id.to_s ||
                         payload.dig("context", "event_revision") != event.publication_revision
                     "stale_revision"
                   elsif !receipt&.fallback_due?
                     "platform_acknowledged_or_not_due"
                   elsif decision[:eligible]
                     nil
                   else
                     decision[:reasons].values.compact.first || "ineligible"
                   end
          if reason
            excluded[reason] += 1
          else
            eligible += 1
            eligible_notification_ids << notification.id
          end
          outcomes << [notification.id, notification.status, reason, decision[:channels], receipt&.id,
                       CityServicePhoneDelivery.template_digest(payload["template"])]
        end
        { total: notifications.size, eligible_viber: eligible, eligible_phone: eligible, excluded:,
          deadline_at: [Time.current, expires_at].min, channels:, template_digest: CityServicePhoneDelivery.template_digest(template),
          acknowledgment_wait_seconds: Decidim::Bih::PlatformDelivery::ACK_WAIT.to_i,
          audience_fingerprint: Digest::SHA256.hexdigest(JSON.generate(outcomes)), eligible_notification_ids: }
      end

      def self.retry_channels(event)
        digest = Digest::SHA256.hexdigest("city_service_alerts:city-alert:#{event.viber_dedupe_key}")
        Decidim::Bih::AccountNotification.where(organization: event.organization, topic: "city_service_alerts",
                                                deduplication_digest: digest, status: %w(rejected failed))
                                         .flat_map { |notification| Array(notification.payload.to_h["channels"]) }.uniq & %w(viber whatsapp)
      end
    end
  end
end
