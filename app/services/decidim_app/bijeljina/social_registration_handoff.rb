# frozen_string_literal: true

require "active_support/key_generator"
require "active_support/message_encryptor"
require "active_support/core_ext/numeric/time"
require "active_support/core_ext/string/inflections"
require "json"
require "openssl"
require "redis"
require "decidim/bih/redis_endpoint"
require "securerandom"
require "time"

module DecidimApp
  module Bijeljina
    # Transfers an unverified phone candidate from Instagram or Messenger to
    # delivery D's browser registration form. It creates no user, identity,
    # authorization or OTP. The random URL credential is single-use and its
    # Redis payload is encrypted independently of the opaque HMAC store key.
    class SocialRegistrationHandoff
      Error = Class.new(StandardError)
      Unavailable = Class.new(Error)

      CHANNELS = %w(instagram messenger).freeze
      TTL = 10.minutes
      KEY_PREFIX = "mi:social-registration-handoff"
      STORE_KEY_SALT = "mi-social-registration-handoff-store-key"
      SENDER_KEY_SALT = "mi-social-registration-handoff-sender-key"
      ENCRYPTION_KEY_SALT = "mi-social-registration-handoff-payload"
      TOKEN_PATTERN = /\A[A-Za-z0-9_-]{40,64}\z/
      CLAIM_SCRIPT = <<~LUA
        local current = redis.call("GET", KEYS[1])
        if not current or current ~= ARGV[1] then return nil end
        redis.call("DEL", KEYS[1])
        return current
      LUA

      class << self
        def issue(...) = new.issue(...)

        def peek(...) = new.peek(...)

        def claim(...) = new.claim(...)

        # This is an intake/configuration gate only. Redis is checked by the
        # actual write so every issue fails closed without a network probe on
        # every inbound social message.
        def available?(routes: Rails.application.routes)
          return false unless enabled?
          return false unless Decidim::Bih.registration_path == "/registracija"
          return false unless registration_components_available?

          destination = routes.recognize_path("/registracija", method: :get)
          destination[:controller] == "decidim/bih/registrations" && destination[:action] == "new"
        rescue ActionController::RoutingError, NameError
          false
        end

        private

        def enabled?
          ENV.fetch("MI_SOCIAL_REGISTRATION_ENABLED", "false").match?(/\A(?:1|true|yes)\z/i)
        end

        def registration_components_available?
          controller = "Decidim::Bih::RegistrationsController".safe_constantize
          form = "Decidim::Bih::PhoneRegistrationForm".safe_constantize
          prefill = "Decidim::Bih::SocialRegistrationPrefill".safe_constantize
          controller && form && prefill && controller.ancestors.include?(prefill)
        end
      end

      def initialize(redis: nil, secret: nil, clock: -> { Time.current }, url_builder: nil)
        @redis = redis
        @secret = secret
        @clock = clock
        @url_builder = url_builder
      end

      def issue(organization:, channel:, sender:, phone:)
        raise Unavailable, "social registration handoff is unavailable" unless self.class.available?

        channel = normalize_channel(channel)
        phone = normalize_phone(phone)
        expires_at = clock.call + TTL
        raw_token = SecureRandom.urlsafe_base64(32)
        ciphertext = encrypt(
          "version" => 1,
          "organization_id" => Integer(organization.id),
          "channel" => channel,
          "sender_digest" => sender_digest(organization.id, channel, sender),
          "phone" => phone,
          "expires_at" => expires_at.iso8601(6)
        )
        stored = Decidim::Bih::DurableEffects.redis_set(
          redis:,
          key: store_key(raw_token),
          value: ciphertext,
          ex: TTL.to_i,
          nx: true
        )
        raise Unavailable, "social registration handoff could not be stored" unless
          [true, "OK", :deferred].include?(stored)

        build_url(organization, raw_token)
      rescue Redis::BaseError => e
        Rails.logger.warn("[SocialRegistrationHandoff] issue failed: #{e.class}") if defined?(Rails.logger)
        raise Unavailable, "social registration handoff could not be stored"
      end

      # GET previews call this read-only path. A wrong organization cannot burn
      # the credential that belongs to the intended tenant.
      def peek(token:, organization:)
        token = normalize_token(token)
        return unless token

        decode_for_organization(redis.get(store_key(token)), organization)
      rescue Redis::BaseError, ActiveSupport::MessageEncryptor::InvalidMessage, JSON::ParserError
        nil
      end

      # Validate tenancy from a read-only peek first, then compare-and-delete
      # the exact ciphertext atomically. A concurrent winner or replacement
      # makes the comparison fail, preserving strict one-use behavior.
      def claim(token:, organization:)
        token = normalize_token(token)
        return unless token

        key = store_key(token)
        ciphertext = redis.get(key)
        payload = decode_for_organization(ciphertext, organization)
        return unless payload

        claimed = redis.eval(CLAIM_SCRIPT, keys: [key], argv: [ciphertext])
        claimed ? payload : nil
      rescue Redis::BaseError, ActiveSupport::MessageEncryptor::InvalidMessage, JSON::ParserError
        nil
      end

      private

      attr_reader :clock

      def redis
        @redis ||= Redis.new(url: Decidim::Bih::RedisEndpoint.url)
      end

      def normalize_channel(channel)
        channel = channel.to_s
        raise ArgumentError, "unsupported social handoff channel" unless CHANNELS.include?(channel)

        channel
      end

      def normalize_phone(phone)
        phone = Decidim::Bih::SmsAuthorization.normalize(phone)
        phone = "+387#{phone.delete_prefix("0")}" if phone.match?(/\A0\d{8,9}\z/)
        phone = "+#{phone}" if phone.match?(/\A387\d{8,12}\z/)
        raise ArgumentError, "social handoff phone is invalid" unless phone.match?(/\A\+\d{8,15}\z/)

        phone
      end

      def normalize_token(token)
        value = token.to_s
        value if value.match?(TOKEN_PATTERN)
      end

      def sender_digest(organization_id, channel, sender)
        sender = sender.to_s
        raise ArgumentError, "social handoff sender is invalid" if sender.blank? || sender.bytesize > 255

        OpenSSL::HMAC.hexdigest("SHA256", sender_key, [organization_id, channel, sender].join("\0"))
      end

      def store_key(raw_token)
        digest = OpenSSL::HMAC.hexdigest("SHA256", store_key_secret, raw_token)
        "#{KEY_PREFIX}:#{digest}"
      end

      def decode_for_organization(ciphertext, organization)
        return unless ciphertext

        payload = decrypt(ciphertext)
        return unless payload.is_a?(Hash)
        return unless valid_payload?(payload, organization)

        payload
      rescue ArgumentError, KeyError, TypeError
        nil
      end

      def valid_payload?(payload, organization)
        [
          payload["version"] == 1,
          payload["organization_id"].to_i == organization.id,
          CHANNELS.include?(payload["channel"]),
          payload["sender_digest"].to_s.match?(/\A[0-9a-f]{64}\z/),
          payload["phone"].to_s.match?(/\A\+\d{8,15}\z/),
          Time.iso8601(payload.fetch("expires_at")) > clock.call
        ].all?
      end

      def encrypt(payload)
        encryptor.encrypt_and_sign(payload)
      end

      def decrypt(ciphertext)
        encryptor.decrypt_and_verify(ciphertext)
      end

      def encryptor
        @encryptor ||= ActiveSupport::MessageEncryptor.new(
          derived_key(ENCRYPTION_KEY_SALT),
          cipher: "aes-256-gcm",
          serializer: JSON
        )
      end

      def store_key_secret = @store_key_secret ||= derived_key(STORE_KEY_SALT)

      def sender_key = @sender_key ||= derived_key(SENDER_KEY_SALT)

      def derived_key(salt)
        ActiveSupport::KeyGenerator.new(secret).generate_key(salt, 32)
      end

      def secret
        value = (@secret || Rails.application.secret_key_base).to_s
        raise ArgumentError, "secret_key_base is required for social handoff" if value.empty?

        value
      end

      def build_url(organization, raw_token)
        return @url_builder.call(organization, raw_token) if @url_builder

        Rails.application.routes.url_helpers.social_registration_handoff_url(
          social_handoff: raw_token,
          host: organization.host,
          protocol: "https"
        )
      end
    end
  end
end
