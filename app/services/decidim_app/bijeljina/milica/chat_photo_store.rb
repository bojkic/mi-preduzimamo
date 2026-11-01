# frozen_string_literal: true

require "base64"
require "digest"
require "json"
require "redis"
require "decidim/bih/redis_endpoint"
require "active_support/message_encryptor"
require_relative "report_conversation_store"

module DecidimApp
  module Bijeljina
    module Milica
      # Holds the bytes of ONE unconfirmed chat photo for exactly as long as the
      # report draft it belongs to.
      #
      # The photo is a citizen's own picture of their street, so it is stored the
      # way the draft is: only authenticated ciphertext, in Redis, under a key
      # derived from the same conversation scope, with a Redis TTL that can never
      # exceed ReportConversationStore::TTL. Nothing survives the draft — there is
      # no sweeper to forget to run, and an abandoned conversation leaves no image
      # behind on disk.
      #
      # EXIF/GPS is already gone before anything reaches here: the fetcher runs
      # Decidim::Bih::Media::ImageNormalizer, so the stored bytes carry no device
      # metadata even for the 15 minutes they live.
      class ChatPhotoStore
        TTL = ReportConversationStore::TTL
        PREFIX = "bijeljina:milica:report-photo:v1"
        # Ciphertext ceiling: 5MB of bytes becomes ~6.7MB of Base64, then JSON
        # and AES-GCM/Base64 framing. A payload past this is refused rather than
        # written, so one conversation can never park an unbounded blob.
        MAX_ENVELOPE_BYTES = 10_000_000

        def initialize(redis: nil, encryptor: nil)
          @redis = redis
          @encryptor = encryptor
        end

        # Returns { "content_type", "filename", "data" (raw bytes), "draft_id",
        # "expires_at" } or nil. An envelope whose own deadline has passed is
        # treated as absent even if Redis still holds it.
        def read(context:)
          raw = redis.get(key(context))
          return unless raw.is_a?(String) && !raw.empty?
          return unless raw.bytesize <= MAX_ENVELOPE_BYTES

          envelope = encryptor.decrypt_and_verify(raw, purpose: key(context))
          return unless envelope.is_a?(Hash)
          return unless envelope["expires_at"].is_a?(Numeric) && envelope["expires_at"] > context.now.to_f

          decoded = Base64.strict_decode64(envelope["data"].to_s)
          return if decoded.empty?

          envelope.merge("data" => decoded)
        rescue StandardError
          # A tampered, truncated or undecodable envelope is simply "no photo".
          # Never raise into a citizen's conversation over a cache read.
          nil
        end

        # Writes (replacing any earlier pending photo for this conversation) with
        # a TTL bounded by the draft lifetime. Returns true on success.
        def write(context:, bytes:, content_type:, filename:, draft_id: nil, expires_at: nil) # rubocop:disable Metrics/ParameterLists
          deadline = [expires_at || (context.now.to_f + TTL), context.now.to_f + TTL].min
          ttl = (deadline - context.now.to_f).ceil
          return false unless ttl.positive?

          envelope = encryptor.encrypt_and_sign(
            { "content_type" => content_type.to_s, "filename" => filename.to_s,
              "data" => Base64.strict_encode64(bytes.to_s), "draft_id" => draft_id&.to_s,
              "expires_at" => deadline },
            purpose: key(context)
          )
          return false if envelope.bytesize > MAX_ENVELOPE_BYTES

          redis.set(key(context), envelope, ex: [ttl, TTL].min)
          true
        rescue StandardError
          false
        end

        # Moves a pending photo onto a newly built draft without rewriting the
        # bytes' deadline: a corrected preview keeps the photo, it does not buy
        # it more time.
        def rebind(context:, draft_id:)
          envelope = read(context:)
          return false unless envelope

          write(context:, bytes: envelope.fetch("data"), content_type: envelope.fetch("content_type"),
                filename: envelope["filename"], draft_id:, expires_at: envelope["expires_at"])
        end

        def clear(context:)
          redis.del(key(context))
          true
        rescue StandardError
          false
        end

        private

        # Same scope as the report draft, so a photo can only ever be read back
        # into the conversation that sent it.
        def key(context)
          klass = Decidim::Bih::Concierge::Dialogue::Contracts::TrustedContext
          raise ArgumentError, "Trusted conversation required" unless context.is_a?(klass)

          scope = [context.organization_id, context.actor_id || "anonymous", context.conversation_key].join(":")
          "#{PREFIX}:#{Digest::SHA256.hexdigest(scope)}"
        end

        def redis
          @redis ||= Redis.new(url: Decidim::Bih::RedisEndpoint.url,
                               connect_timeout: 0.2, read_timeout: 1.0, write_timeout: 1.0, reconnect_attempts: 0)
        end

        def encryptor
          @encryptor ||= begin
            secret = Rails.application.key_generator.generate_key(PREFIX, 32)
            ActiveSupport::MessageEncryptor.new(secret, cipher: "aes-256-gcm", serializer: JSON)
          end
        end
      end
    end
  end
end
