# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    # Evaluates the edited notice inside a rollback-only savepoint. The signed
    # confirmation binds both the original revision and exact edited attributes.
    class CityServiceApprovalPreview
      Result = Struct.new(:status, :token, :recipients, :boards, :deadline, :viber_audience, :channels, :template, keyword_init: true)

      def initialize(event:, actor:, attributes:, retry_failed: false)
        @event = event
        @actor = actor
        @attributes = attributes.to_h.deep_stringify_keys
        @retry_failed = retry_failed
      end

      def call
        return Result.new(status: :stale_review) unless @event.weather_region_review_current?

        return build_result(@event.answer_review_token) if @event.board_published? || @event.published?

        result = nil
        original = @event.answer_review_token
        @event.class.transaction(requires_new: true) do
          reviewed = CityServiceEventReview.new(event: @event, actor: @actor, attributes: @attributes).call
          result = reviewed == :updated ? build_result(original) : Result.new(status: reviewed)
          raise ActiveRecord::Rollback
        end
        @event.reload
        result
      end

      def valid?(token)
        valid_result(token).present?
      end

      def valid_result(token)
        signed = verifier.verified(token, purpose: "city_notice_fallback")
        return unless signed

        result = call
        return unless result.status == :ready

        fresh = verifier.verified(result.token, purpose: "city_notice_fallback")
        result if signed == fresh
      end

      private

      def build_result(original)
        return Result.new(status: :phone_audience_unverified) if CityServicePhoneDelivery.phone_audience_unverified?(@event)

        preview = CityServiceEventPreview.new(@event).call
        channels = CityServicePhoneDelivery.channels(organization: @event.organization)
        channels &= CityServiceFallbackAudience.retry_channels(@event) if @retry_failed
        # The legacy combined review path has no published board destination
        # yet. Its established Viber behavior remains available; the named
        # WhatsApp template is offered only for an already published board.
        channels &= ["viber"] unless @event.board_published? || @event.published?
        template = CityServicePhoneDelivery.template(@event) if channels.include?("whatsapp")
        channels -= ["whatsapp"] unless template
        result = Result.new(status: :ready, recipients: preview.recipient_count, boards: preview.target_komsiluk_slugs.size,
                            channels:, template:)
        result.viber_audience = CityServiceFallbackAudience.preview(organization: @event.organization,
                                                                    area_slugs: preview.target_area_slugs, expires_at: @event.ends_at, text: @event.viber_text,
                                                                    channels:, template:, event: @event, retry_failed: @retry_failed)
        result.deadline = result.viber_audience.fetch(:deadline_at)
        result.token = verifier.generate(payload(original, preview, result.viber_audience), expires_in: 10.minutes, purpose: "city_notice_fallback")
        result
      end

      def payload(original, preview, viber_audience)
        target = CityServiceEventPreview.new(@event)
        areas = target.send(:resolve_target).recipient_areas
        recipients = areas.flat_map do |area|
          target.send(:resolver_for, area)&.recipient_ids(exclude_user_id: nil, honor_opt_out: true,
                                                          notification_topic: CityServiceAlertPolicy::OPT_OUT_TOPIC, notification_channel: CityServiceAlertPolicy::OPT_OUT_CHANNEL,
                                                          fallback_key: CityServiceAlertPolicy::LEGACY_OPT_OUT_KEY)
        end.compact.flatten.uniq.sort
        { "viber_audience" => viber_audience.fetch(:audience_fingerprint), "ack_wait" => viber_audience.fetch(:acknowledgment_wait_seconds),
          "channels" => viber_audience.fetch(:channels), "template" => viber_audience.fetch(:template_digest),
          "retry_failed" => @retry_failed,
          "event" => @event.id, "actor" => @actor.id, "revision" => original,
          "attributes" => Digest::SHA256.hexdigest(@attributes.sort.to_json),
          "audience" => Digest::SHA256.hexdigest(recipients.to_json), "boards" => preview.target_komsiluk_slugs.sort,
          "boundaries" => Digest::SHA256.hexdigest(Decidim::Bih::LocalArea.where(organization: @event.organization).order(:id).pluck(:id, :slug, :boundary).to_json) }
      end

      def verifier
        Rails.application.message_verifier("city_notice_approval")
      end
    end
  end
end
