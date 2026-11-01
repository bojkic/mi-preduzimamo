# frozen_string_literal: true

module DecidimApp
  module Infobip
    # Accepts citizen-initiated Viber Business Messages, WhatsApp, Messenger
    # and Instagram messages from Infobip. The public endpoints only
    # authenticate, validate account/channel boundaries, persist a minimal
    # encrypted receipt and enqueue processing.
    #
    # viber_bm is the two-way transport MIlica runs on. It is deliberately NOT
    # the Viber Bot, which is a separately-billed product with its own endpoint
    # (DecidimApp::Viber::WebhookController) and its own kill switch.
    class WebhookController < ActionController::Base # rubocop:disable Rails/ApplicationController
      include DecidimApp::BoundedWebhookBody

      CHANNEL_SECRET_KEYS = {
        "viber_bm" => "VIBER_BM_WEBHOOK_SECRET",
        "whatsapp" => "WHATSAPP_WEBHOOK_SECRET",
        "messenger" => "MESSENGER_WEBHOOK_SECRET",
        "instagram" => "INSTAGRAM_WEBHOOK_SECRET"
      }.freeze
      SHARED_SECRET_KEY = "INFOBIP_CHAT_WEBHOOK_SECRET"
      MIN_WEBHOOK_SECRET_BYTES = 16

      skip_forgery_protection

      def viber_bm
        receive("viber_bm")
      end

      def whatsapp
        receive("whatsapp")
      end

      def messenger
        receive("messenger")
      end

      def instagram
        receive("instagram")
      end

      private

      def receive(route_channel)
        return head(:unauthorized) unless authorized?(route_channel)
        return if reject_oversized_webhook

        accept_deliveries(route_channel)
        head :ok
      rescue StandardError => e
        # Once a channel is active, an unresolved tenant or any other failure
        # before the minimal encrypted receipt is durable must be retried by
        # the provider. Previously persisted items are idempotent, so a retried
        # batch cannot process them twice.
        log_intake_error(route_channel, e)
        head :service_unavailable
      end

      def log_intake_error(route_channel, error)
        Rails.logger.error("[Infobip chat webhook channel=#{route_channel}] #{error.class}")
      end

      def accept_deliveries(route_channel)
        # Disabled channels are intentionally inert and acknowledged. Resolve
        # the tenant only after this gate so an unopened channel cannot cause a
        # retry storm because of incomplete launch configuration.
        return unless channel_configured?(route_channel)

        organization = DecidimApp::Bijeljina::Concierge.organization

        messages(route_channel).each do |message|
          next unless acceptable_message?(message, route_channel)

          delivery = Decidim::Bih::Viber::InboundDelivery.accept!(organization:, message:)
          enqueue_delivery(delivery)
        end
      end

      def messages(route_channel)
        Decidim::Bih::Infobip::InboundMessage.parse_all(payload, route_channel:)
      end

      def acceptable_message?(message, route_channel)
        return false unless message.channel.to_s == route_channel
        return false if message.sender.blank?

        configured_recipient = configured_sender(route_channel)
        message.recipient.present? && message.recipient.to_s == configured_recipient.to_s
      end

      def channel_configured?(route_channel)
        Decidim::Bih::Infobip::Client.new.chat_channel_configured?(route_channel)
      end

      def configured_sender(route_channel)
        Decidim::Bih::Config.infobip[:"#{route_channel}_sender"]
      end

      def enqueue_delivery(delivery)
        return unless delivery.enqueueable?

        DecidimApp::Infobip::ProcessInboundDeliveryJob.perform_later(delivery.id)
      rescue StandardError => e
        # The encrypted receipt is already durable. The shared recovery sweep
        # will enqueue the channel-correct processor after a queue interruption.
        Rails.logger.error("[Infobip chat webhook enqueue] #{e.class}")
      end

      def authorized?(route_channel)
        secret = webhook_secret(route_channel)
        return !Rails.env.production? if secret.blank?
        return false if secret.bytesize < MIN_WEBHOOK_SECRET_BYTES

        ActiveSupport::SecurityUtils.secure_compare(provided_secret, secret)
      end

      def webhook_secret(route_channel)
        channel_secret = ENV.fetch(CHANNEL_SECRET_KEYS.fetch(route_channel), nil).to_s
        return channel_secret if channel_secret.bytesize >= MIN_WEBHOOK_SECRET_BYTES

        ENV.fetch(SHARED_SECRET_KEY, nil).presence || channel_secret.presence
      end

      # Header only. Query parameters are deliberately ignored because URLs are
      # routinely retained in proxy and access logs.
      def provided_secret
        request.headers["X-Webhook-Secret"].to_s
      end

      def payload
        parsed = request.request_parameters
        return parsed if parsed.present?

        JSON.parse(request.raw_post)
      rescue JSON::ParserError, ActionDispatch::Http::Parameters::ParseError
        {}
      end
    end
  end
end
