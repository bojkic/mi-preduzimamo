# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    # Persist optional Viber fallback authorization while delivering the shared
    # platform inbox and push identity first. Queue acceptance is not a receipt.
    # Historical Viber field/class names remain queue-compatible.
    class CityServiceAlertNotificationJob < Decidim::Bih::ChunkedBellJob
      MESSAGE_CLASS = "city.service_alert_viber"

      self.log_arguments = false

      queue_as :integrations

      def perform(opts = {}) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
        opts = opts.with_indifferent_access
        organization = Decidim::Organization.find_by(id: opts[:organization_id])
        return unless organization

        event = CityServiceEvent.for_organization(organization).find_by(id: opts[:event_id])
        return unless event

        CityServiceIncident.synchronize(event.organization) do
          event.with_lock do
            return unless CityServiceSources.enabled?(event.source_key) && CityServiceSources.alerts_enabled? && event.delivery_current?(opts[:event_revision])
            return if CityServicePhoneDelivery.phone_audience_unverified?(event)
            return unless current_deduplication?(event, opts)

            text = event.viber_text.presence || [event.title, event.summary].compact_blank.join(" - ")
            return if text.blank?

            return unless event.incident_id && event.extraction_metadata["board_audience_identity"].present?

            identity = opts[:delivery_identity].presence || CityServiceIncidentIdentity.delivery_identity(event)
            return unless identity == CityServiceIncidentIdentity.delivery_identity(event)

            # No pre-release worker may create a historical audience. An empty
            # capture remains empty; an old explicit chunk only narrows it.
            return unless event.extraction_metadata["board_audience_identity"] == identity

            receipts = Decidim::Bih::PlatformDelivery.where(organization:, identity:, cancelled_at: nil,
                                                            komsiluk_post_id: event.komsiluk_post_id_values)
            receipts = receipts.where(decidim_user_id: Array(opts[:user_ids])) if opts.has_key?(:user_ids)
            each_eligible_user(organization, receipts.pluck(:decidim_user_id)) do |user|
              next if opted_out?(user)
              next unless CityServiceBoardVisibility.current_for_recipient?(event:, user_id: user.id)

              receipt = receipts.find_by(user:)
              next unless receipt

              next unless authorize_captured_receipt(receipt, event, opts)

              Decidim::Bih::KomsilukNoticeDeliveryJob.perform_now(receipt.id)
              CityServiceFallbackJob.set(wait_until: receipt.deadline_at).perform_later(receipt.id)
            end
          end
        end
      end

      def self.recipient_current?(event, user_id)
        recipient_ids(event).include?(user_id)
      end

      def self.recipient_ids(event)
        slugs = if event.targeting_level == "citywide"
                  Decidim::Bih::LocalArea.komsiluci.where(decidim_organization_id: event.decidim_organization_id).pluck(:slug)
                else
                  event.area_slugs
                end
        recipient_ids_for(organization: event.organization, area_slugs: slugs)
      end

      def self.recipient_ids_for(organization:, area_slugs:)
        areas = Decidim::Bih::LocalArea.where(decidim_organization_id: organization.id, slug: area_slugs)
        areas.flat_map do |area|
          resolver = case area.kind
                     when "komsiluk"
                       Decidim::Bih::Komsiluk::MembershipResolver.for_komsiluk(organization:, komsiluk_id: area.id)
                     when "mz"
                       Decidim::Bih::Komsiluk::MembershipResolver.for_mz(organization:, mz_area: area)
                     end
          resolver ? resolver.recipient_ids(exclude_user_id: nil, honor_opt_out: false) : []
        end.uniq
      end

      private

      # The enclosing event transaction retains row locks through dispatch.
      # Take the post before the receipt so replay keeps the same lock order as
      # source publication and moderation.
      def authorize_captured_receipt(receipt, event, opts)
        post = receipt.komsiluk_post
        return false unless post

        post.with_lock do
          receipt.with_lock do
            next false unless Decidim::Bih::Komsiluk::NoticePublishing.current_receipt?(receipt)

            receipt.update!(fallback_requested_at: receipt.fallback_requested_at || Time.current,
                            fallback_context: receipt.fallback_context.merge(
                              "event_id" => event.id, "event_revision" => opts[:event_revision],
                              "dedupe_key" => opts[:dedupe_key], "channels" => Array(opts[:channels]).presence || ["viber"],
                              "template" => opts[:template]
                            ))
            true
          end
        end
      end

      def current_deduplication?(event, opts)
        event.viber_dedupe_key.present? && event.viber_dedupe_key == opts[:dedupe_key]
      end

      def opted_out?(user)
        !Decidim::Bih::NotificationPreferences.enabled?(
          user,
          topic: CityServiceAlertPolicy::OPT_OUT_TOPIC,
          channel: CityServiceAlertPolicy::OPT_OUT_CHANNEL,
          fallback_key: CityServiceAlertPolicy::LEGACY_OPT_OUT_KEY
        )
      end
    end
  end
end
