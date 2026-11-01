# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    class CityServiceEffectJob < ApplicationJob
      queue_as :integrations
      self.log_arguments = false

      def perform(id)
        effect = CityServiceEffect.find_by(id:)
        return unless effect

        CityServiceIncident.synchronize(effect.event.organization) { dispatch_current_effect(effect) }
      rescue StandardError => e
        record_failure(effect, e)
        raise
      end

      private

      def dispatch_current_effect(effect)
        event = effect.event
        event.with_lock do
          effect.with_lock do
            return if effect.completed_at

            effect.update!(attempts: effect.attempts + 1, last_attempt_at: Time.current)
            if event.publication_blocker || event.publication_revision != effect.payload["event_revision"] ||
               effect.payload["delivery_identity"] != CityServiceIncidentIdentity.delivery_identity(event)
              effect.update!(completed_at: Time.current, error_code: "event_changed_or_expired")
              return
            end
            retirement_reason = dispatch(effect)
            effect.update!(completed_at: Time.current, error_code: retirement_reason)
          end
        end
      end

      def record_failure(effect, error)
        return unless effect&.persisted?

        effect.with_lock do
          effect.update!(attempts: effect.attempts + 1, error_code: error.class.name, last_attempt_at: Time.current) unless effect.completed_at
        end
      end

      def dispatch(effect)
        payload = effect.payload.symbolize_keys
        if effect.kind == "board"
          post = Decidim::Bih::KomsilukPost.find_by(id: payload.fetch(:post_id), decidim_organization_id: effect.event.decidim_organization_id)
          return "post_unavailable" unless post && CityServiceBoardVisibility.current?(post)
          # This marker also represents a deliberately empty captured audience.
          # Pre-release effects have no defensible historical audience snapshot;
          # retire them without capturing current members or replaying old sends.
          return "legacy_publication_uncaptured" if post.notification_capture_identity.blank?
          return "publication_identity_changed" unless post.notification_capture_identity == payload[:delivery_identity]

          Decidim::Bih::Komsiluk::NoticePublishing.replay_captured!(post:, identity: payload.fetch(:delivery_identity))
        else
          CityServiceAlertNotificationJob.perform_now(payload)
        end
        nil
      end
    end
  end
end
