# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    # Serializes cancellation/source withdrawal with the final provider request.
    # Already accepted provider messages cannot be recalled by local withdrawal.
    class CityServiceDeliveryGuard
      def self.call(notification:, payload:) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
        return yield unless notification.topic == "city_service_alerts"

        context = payload["context"].to_h
        event = CityServiceEvent.find_by(id: context["event_id"], decidim_organization_id: notification.decidim_organization_id)
        unless event
          notification.update!(status: "skipped", reason: "service_event_unavailable")
          return
        end

        CityServiceIncident.synchronize(event.organization) do
          event.with_lock do
            unless CityServiceSources.enabled?(event.source_key) && CityServiceSources.alerts_enabled? && event.delivery_current?(context["event_revision"]) && notification.expires_at <= event.ends_at
              notification.update!(status: "skipped", reason: "service_event_changed_or_expired")
              next
            end
            if CityServicePhoneDelivery.phone_audience_unverified?(event)
              notification.update!(status: "skipped", reason: "phone_audience_unverified")
              next
            end
            receipt_id = context["platform_delivery_id"]
            if receipt_id
              receipt = Decidim::Bih::PlatformDelivery.find_by(id: receipt_id, user: notification.user)
              unless receipt
                notification.update!(status: "skipped", reason: "platform_receipt_missing")
                next
              end
              unless receipt.identity == CityServiceIncidentIdentity.delivery_identity(event)
                notification.update!(status: "skipped", reason: "incident_identity_changed")
                next
              end
              receipt.with_lock do
                unless receipt.fallback_requested_at && receipt.fallback_due?
                  notification.update!(status: "skipped", reason: receipt.acknowledged_at ? "platform_delivery_confirmed" : "fallback_not_due")
                  next
                end
                notification.user.with_lock do
                  user = notification.user
                  unless user.confirmed_at.present? && !user.blocked? && !user.deleted?
                    notification.update!(status: "skipped", reason: "account_unavailable")
                    next
                  end
                  selected = notification.channels & %w(viber whatsapp)
                  available = CityServicePhoneDelivery.channels(organization: event.organization)
                  snapshot = payload["template"]
                  current_template = CityServicePhoneDelivery.template(event) if selected.include?("whatsapp")
                  template_current = !selected.include?("whatsapp") ||
                                     (snapshot.present? && current_template &&
                                      CityServicePhoneDelivery.template_digest(snapshot) == CityServicePhoneDelivery.template_digest(current_template))
                  unless selected.present? && (selected - available).empty? && template_current
                    notification.update!(status: "skipped", reason: "delivery_channel_revoked")
                    next
                  end
                  unless selected.all? { |channel| Decidim::Bih::NotificationPreferences.permitted?(notification.user, topic: :city_service_alerts, channel:) }
                    notification.update!(status: "skipped", reason: "eligibility_changed")
                    next
                  end
                  dispatch_in_current_area(notification, event) { yield }
                end
              end
            else
              # Legacy queue records lack delivery evidence; never turn those
              # into an immediate external send after upgrading.
              notification.update!(status: "skipped", reason: "platform_receipt_missing")
            end
          end
        end
      end

      def self.dispatch_in_current_area(notification, event)
        profile = Decidim::Bih::CitizenProfile.find_by(organization: event.organization, user: notification.user)
        unless profile
          notification.update!(status: "skipped", reason: "recipient_area_changed")
          return
        end

        profile.with_lock do
          unless CityServiceAlertNotificationJob.recipient_current?(event, notification.decidim_user_id) &&
                 CityServiceBoardVisibility.current_for_recipient?(event:, user_id: notification.decidim_user_id)
            notification.update!(status: "skipped", reason: "recipient_area_changed")
            next
          end
          yield
        end
      end
    end
  end
end
