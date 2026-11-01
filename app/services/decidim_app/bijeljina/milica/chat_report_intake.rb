# frozen_string_literal: true

require "openssl"

module DecidimApp
  module Bijeljina
    module Milica
      # Owns the per-channel switch and the trusted conversation scope that let
      # an EXTERNAL chat channel use the same report boundary the web uses.
      #
      # The web builds its TrustedContext from a signed session cookie
      # (Decidim::Bih::Concierge::WebChatController#trusted_dialogue_context).
      # An external channel has no cookie: the only stable handle is the
      # provider's sender id, so the conversation key is an HMAC over
      # (purpose, organization, channel, sender) — the same construction
      # ExternalChatSessionStore already uses for its cache key. The raw sender
      # is never stored or logged. This legacy fallback carries no citizen
      # identity; authenticated adapters use ChannelConversationContext to bind
      # a verified report actor to an isolated scope. Contact consent remains
      # an independent choice in the confirmed report preview.
      #
      # Channel separation is part of the key, so the same phone number writing
      # on Viber and on WhatsApp holds two independent drafts, and two senders
      # on one channel can never reach each other's draft.
      module ChatReportIntake
        # The per-channel flag. Empty (the default) means no external channel
        # may file a report and every channel keeps its guidance-only
        # behaviour. It only ADDS channels to the existing master switch; it
        # can never turn report intake on by itself.
        FLAG = "MI_CHAT_REPORT_INTAKE_CHANNELS"
        MASTER_FLAG = "MILICA_REPORT_CHAT_SUBMISSION_ENABLED"
        # Channels that MAY be listed. Anything else in the list is ignored.
        SUPPORTED_CHANNELS = %w(viber_bm whatsapp messenger instagram).freeze
        # Domain separation: this digest must never equal a session digest or
        # the external-chat conversation-memory key for the same sender.
        KEY_PURPOSE = "milica-chat-report-conversation:v1"
        # A chat report is anonymous and reads nothing private.
        CAPABILITIES = %w(public_reads report_guidance).freeze

        module_function

        # The configured channels, sanitized against SUPPORTED_CHANNELS.
        def channels(env: ENV)
          env.fetch(FLAG, nil).to_s.split(",").filter_map do |value|
            token = value.strip.downcase
            token if SUPPORTED_CHANNELS.include?(token)
          end.uniq
        end

        def enabled?(channel, env: ENV)
          env[MASTER_FLAG] == "true" && channels(env:).include?(channel.to_s)
        end

        # The trusted scope for this (organization, channel, sender), or nil
        # when the channel is not enabled or the sender is unusable. A nil
        # context keeps the caller on its existing guidance-only path.
        def context(organization:, channel:, sender:, now: Time.current, env: ENV)
          return unless organization.respond_to?(:id) && organization.id.is_a?(Integer)
          return unless enabled?(channel, env:)
          return if sender.to_s.strip.empty?

          Decidim::Bih::Concierge::Dialogue::Contracts::TrustedContext.new(
            organization_id: organization.id,
            conversation_key: conversation_key(organization:, channel:, sender:),
            actor_id: nil,
            account_state: "anonymous",
            capabilities: CAPABILITIES,
            now:
          )
        end

        def conversation_key(organization:, channel:, sender:)
          identity = [KEY_PURPOSE, organization.id, channel.to_s, sender.to_s].join("\0")
          OpenSSL::HMAC.hexdigest("SHA256", Rails.application.secret_key_base.to_s, identity)
        end
      end
    end
  end
end
