# frozen_string_literal: true

module DecidimApp
  module Viber
    # Receives Infobip Viber Bot webhook callbacks for "Mi pre(d)uzimamo!"
    # and hands them to the Bijeljina concierge. Inherits straight from
    # ActionController::Base (NOT the app's ApplicationController) so the
    # `allow_browser` modern-UA gate doesn't 406 a server-to-server POST.
    #
    # Poison callbacks and disabled-channel traffic are acknowledged so they
    # cannot create a retry storm. An active-channel tenant or storage failure
    # before a receipt exists returns 503 so the provider can retry; once a
    # receipt exists, queue recovery owns delivery.
    #
    # AUTH: when ENV["VIBER_WEBHOOK_SECRET"] is set we require a matching
    # `X-Webhook-Secret` header. A query-string secret is deliberately ignored
    # because URLs commonly land in proxy/access logs. Production also rejects
    # when the environment secret is unset; dev/test accept unsigned requests for
    # local convenience.
    class WebhookController < ActionController::Base # rubocop:disable Rails/ApplicationController
      include DecidimApp::BoundedWebhookBody

      MIN_WEBHOOK_SECRET_BYTES = 16
      ReceiptPersistenceError = Class.new(StandardError)

      skip_forgery_protection

      def create
        return head(:unauthorized) unless authorized?
        return if reject_oversized_webhook

        accept_deliveries(payload)
        head :ok
      rescue StandardError => e
        # Parsing filters poison/unsupported items without raising. Receipt,
        # tenant, and other internal failures on an authenticated, configured
        # intake path happen before every item is proven durable, so request a
        # provider retry.
        log_intake_error(e)
        head :service_unavailable
      end

      private

      def accept_deliveries(payload_hash)
        # A disabled Bot endpoint stays inert. Only resolve the tenant after the
        # provider/channel configuration proves this is an active intake path.
        return unless viber_channel_configured?

        organization = DecidimApp::Bijeljina::Concierge.organization

        Decidim::Bih::Viber::InboundMessage.parse_all(payload_hash).each do |message|
          next unless acceptable_message?(message)

          delivery = accept_delivery!(organization:, message:)
          enqueue_delivery(delivery)
        end
      end

      def accept_delivery!(organization:, message:)
        Decidim::Bih::Viber::InboundDelivery.accept!(organization:, message:)
      rescue StandardError
        raise ReceiptPersistenceError, "durable receipt persistence failed", cause: nil
      end

      def acceptable_message?(message)
        return false if message.sender.blank? || message.message_id.blank?
        return false unless message.respond_to?(:channel) && message.channel.to_s == "viber"

        message.recipient.present? && message.recipient.to_s == configured_viber_sender.to_s
      end

      # The Viber Bot is a separately-billed product and is switched off by
      # default (Decidim::Bih::Config.viber_bot_enabled?). While it is off this
      # endpoint authenticates as usual but accepts nothing, so the route stays
      # mounted and inert rather than becoming a 404 the provider retries.
      def viber_channel_configured?
        Decidim::Bih::Infobip::Client.new.viber_bot_active?
      end

      def configured_viber_sender
        Decidim::Bih::Config.infobip[:viber_bot_sender]
      end

      def log_intake_error(error)
        Rails.logger.error("[Viber webhook] #{error.class}")
      end

      def enqueue_delivery(delivery)
        return unless delivery.enqueueable?

        DecidimApp::Viber::ProcessInboundDeliveryJob.perform_later(delivery.id)
      rescue StandardError => e
        # Receipt is already durable. A recovery sweep can enqueue this pending
        # row later, so acknowledge the provider without losing the message.
        Rails.logger.error("[Viber webhook enqueue] #{e.class}")
      end

      def authorized?
        secret = ENV.fetch("VIBER_WEBHOOK_SECRET", nil)
        # Fail CLOSED in production: this endpoint is public and message.sender
        # is fed to the outbound Viber send, so an unset secret must reject there.
        # In dev/test a blank secret is accepted for convenience.
        return !Rails.env.production? if secret.blank?
        return false if secret.bytesize < MIN_WEBHOOK_SECRET_BYTES

        ActiveSupport::SecurityUtils.secure_compare(provided_secret, secret)
      end

      # Header only — never read the secret from the query string (it would land
      # in access/proxy logs).
      def provided_secret
        request.headers["X-Webhook-Secret"].to_s
      end

      # Infobip posts JSON; Rails parses it into request_parameters. Fall back to
      # parsing the raw body defensively.
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
