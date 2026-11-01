# frozen_string_literal: true

require "openssl"
require "uri"

module DecidimApp
  module Bijeljina
    # Handles the small, explicit registration handoff conversation on external
    # chat channels. It deliberately stops before the general concierge so a
    # phone number or handoff URL never enters the LLM context, transcript cache,
    # or usage aggregates.
    # TODO(D): the citizen-facing replies below are hardcoded Serbian rather
    # than I18n keys, so a citizen reading the platform in bs/hr/sr-Cyrl gets
    # Serbian Latin here. Deliberately left as-is for delivery A: this feature
    # is default-off (MI_SOCIAL_REGISTRATION_ENABLED) and the copy, including
    # which locale a chat channel should answer in, is owned by delivery D.
    class SocialRegistrationIntake
      CHANNELS = %w(messenger instagram).freeze
      STATE_AWAITING_PHONE = "awaiting_phone"
      STATE_TTL = 15.minutes
      REPLY_TTL = 10.minutes
      PHONE_INPUT = /\A\s*\+?[\d\s().-]{8,28}\s*\z/
      REGISTRATION_INTENT = /(?:registr|sign\s*up|signup|open\s+(?:an?\s+)?account|create\s+(?:an?\s+)?account|otvori(?:m|s|š|ti)?\s+nalog|novi\s+nalog|napravi\s+nalog)/i
      CANCEL_INTENT = /\A\s*(?:cancel|stop|odustani|prekini|ne\s+zelim|ne\s+želim)\b/i
      RESTART_INTENT = /(?:registr|sign\s*up|signup|otvori(?:m|s|š|ti)?\s+nalog|novi\s+nalog|napravi\s+nalog)/i

      IntakeReply = Struct.new(:text, :answer_intent, :request_phone, :expires_at, keyword_init: true)

      class << self
        def call(organization:, message:, cache: Rails.cache, handoff: nil)
          new(organization:, message:, cache:, handoff:).call
        end

        def available?
          handoff = handoff_class
          enabled? && handoff && handoff.respond_to?(:available?) && handoff.available?
        rescue StandardError
          false
        end

        def enabled?
          ActiveModel::Type::Boolean.new.cast(ENV.fetch("MI_SOCIAL_REGISTRATION_ENABLED", "false"))
        end

        private

        def handoff_class
          "DecidimApp::Bijeljina::SocialRegistrationHandoff".safe_constantize
        rescue StandardError
          nil
        end
      end

      def initialize(organization:, message:, cache: Rails.cache, handoff: nil)
        @organization = organization
        @message = message
        @handoff = handoff || self.class.send(:handoff_class)
        @state = StateStore.new(
          organization:,
          channel: message.channel,
          sender: message.sender,
          cache:
        )
      end

      def call
        return unless self.class.enabled?
        return unless CHANNELS.include?(message.channel.to_s)
        return if message.sender.blank?

        return handle_existing_state if state.get == STATE_AWAITING_PHONE

        unless registration_intent?
          return expired_phone_reply if normalize_phone(message.text)

          return
        end

        return unavailable_reply unless handoff_available?

        state.put(STATE_AWAITING_PHONE)
        shared_phone = normalized_shared_phone
        return accepted_phone(shared_phone) if shared_phone

        ask_for_phone
      end

      private

      attr_reader :organization, :message, :state, :handoff

      def handle_existing_state
        return unavailable_reply unless handoff_available?

        handle_pending
      end

      def handoff_available?
        handoff && handoff.respond_to?(:available?) && handoff.available?
      end

      def handle_pending
        if cancel_intent?
          state.clear
          return reply("U redu, prekinula sam registraciju. Ako se predomisliš, napiši da želiš da otvoriš nalog.")
        end

        if restart_intent?
          state.put(STATE_AWAITING_PHONE)
          return ask_for_phone
        end

        phone = normalized_shared_phone || normalize_phone(message.text)
        return accepted_phone(phone) if phone

        state.put(STATE_AWAITING_PHONE)
        reply("Broj nije prepoznat. Pošalji broj mobilnog telefona u formatu +387 6X XXX XXX ili odustani.")
      end

      def registration_intent?
        message.text.to_s.match?(REGISTRATION_INTENT)
      end

      def expired_phone_reply
        reply("Ova registracija je istekla. Ponovo napiši da želiš da otvoriš nalog, pa ću zatražiti broj mobilnog telefona.")
      end

      def cancel_intent?
        message.text.to_s.match?(CANCEL_INTENT)
      end

      def restart_intent?
        message.text.to_s.match?(RESTART_INTENT)
      end

      def ask_for_phone
        reply(
          "Za otvaranje naloga pošalji broj mobilnog telefona. Na taj broj ćemo poslati potvrdu. Možeš razgovarati s Milicom ovdje — samo odgovori na poruku.",
          request_phone: message.channel.to_s == "messenger"
        )
      end

      def unavailable_reply
        reply("Registracija trenutno nije dostupna. Pokušaj ponovo kasnije.")
      end

      def accepted_phone(phone)
        url = handoff.issue(
          organization:,
          channel: message.channel.to_s,
          sender: message.sender.to_s,
          phone:
        )
        raise ArgumentError, "social registration handoff URL is not absolute" unless absolute_url?(url)

        state.clear
        reply("Nastavi registraciju ovdje: #{url}")
      rescue StandardError => e
        Rails.logger.warn(
          "[SocialRegistrationIntake] handoff failed " \
          "(#{e.class}: #{Decidim::Bih::LogRedactor.error_message(e)})"
        )
        reply("Trenutno ne mogu pokrenuti registraciju. Pokušaj ponovo za nekoliko minuta.")
      end

      def normalized_shared_phone
        return unless message.respond_to?(:shared_phone)

        normalize_phone(message.shared_phone)
      end

      def normalize_phone(value)
        raw = value.to_s
        return unless raw.match?(PHONE_INPUT)

        phone = Decidim::Bih::SmsAuthorization.normalize(raw)
        phone = "+387#{phone.delete_prefix("0")}" if phone.match?(/\A0\d{8,9}\z/)
        phone = "+#{phone}" if phone.match?(/\A387\d{8,12}\z/)
        phone if phone.match?(/\A\+\d{8,15}\z/)
      end

      def absolute_url?(value)
        uri = URI.parse(value.to_s)
        uri.absolute? && uri.host.present?
      rescue URI::InvalidURIError
        false
      end

      def reply(text, request_phone: false)
        IntakeReply.new(
          text:,
          answer_intent: "registration_intake",
          request_phone:,
          expires_at: REPLY_TTL.from_now
        )
      end

      # Purpose-specific, organization/channel scoped state. Only the HMAC of
      # the provider sender appears in the cache key; the sender and phone are
      # never used as a raw key or persisted in the conversation transcript.
      class StateStore
        PURPOSE = "social-registration-intake"

        def initialize(organization:, channel:, sender:, cache:)
          @organization = organization
          @channel = channel.to_s
          @sender = sender.to_s
          @cache = cache
        end

        def get
          cache.read(cache_key)
        end

        def put(value)
          write(value)
        end

        def clear
          write(nil)
        end

        private

        attr_reader :organization, :channel, :sender, :cache

        def write(value)
          Decidim::Bih::DurableEffects.cache_write(cache_key, value, cache:, expires_in: SocialRegistrationIntake::STATE_TTL)
        end

        def cache_key
          digest = OpenSSL::HMAC.hexdigest(
            "SHA256",
            Rails.application.secret_key_base.to_s,
            [PURPOSE, organization.id, channel, sender].join("\0")
          )
          "decidim-bih/social-registration-intake/#{organization.id}/#{channel}/#{digest}"
        end
      end

      private_constant :StateStore
    end
  end
end
