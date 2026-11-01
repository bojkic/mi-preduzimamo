# frozen_string_literal: true

require "digest"
require "json"
require "redis"
require "decidim/bih/redis_endpoint"
require "securerandom"
require "active_support/message_encryptor"

module DecidimApp
  module Bijeljina
    module Milica
      # Separate from model-visible semantic state: drafts may contain a report
      # address/GPS. Only authenticated ciphertext is retained, for 15 minutes.
      class ReportConversationStore
        TTL = 900
        PREFIX = "bijeljina:milica:report-draft:v1"
        ACQUIRE = "if redis.call('EXISTS', KEYS[2]) == 1 then return -1 end if redis.call('SET', KEYS[1], ARGV[1], 'NX', 'EX', 20) then return 1 end return 0"
        RELEASE = "if redis.call('GET', KEYS[1]) == ARGV[1] then return redis.call('DEL', KEYS[1]) end return 0"
        WRITE = "if redis.call('EXISTS', KEYS[3]) == 1 or redis.call('GET', KEYS[1]) ~= ARGV[1] then return 0 end redis.call('SET', KEYS[2], ARGV[2], 'EX', ARGV[3]) return 1"
        CLEAR = "if redis.call('EXISTS', KEYS[3]) == 1 or redis.call('GET', KEYS[1]) ~= ARGV[1] then return 0 end redis.call('DEL', KEYS[2]) return 1"
        REVOKE = "redis.call('SET', KEYS[3], '1', 'EX', ARGV[1]) redis.call('DEL', KEYS[1], KEYS[2]) return 1"
        Lease = Data.define(:key, :token)
        Busy = Class.new(StandardError)
        LeaseLost = Class.new(StandardError)
        Revoked = Class.new(StandardError)

        def initialize(redis: nil, encryptor: nil)
          @redis = redis
          @encryptor = encryptor
        end

        def synchronize(context:)
          storage_key = key(context)
          lock = "#{storage_key}:lock"
          token = SecureRandom.hex(16)
          acquired = redis.eval(ACQUIRE, keys: [lock, "#{storage_key}:revoked"], argv: [token])
          raise Revoked if acquired == -1
          raise Busy unless acquired == 1

          begin
            yield Lease.new(key: lock, token:)
          ensure
            redis.eval(RELEASE, keys: [lock], argv: [token])
          end
        end

        def read(context:)
          return if redis.get("#{key(context)}:revoked")

          raw = redis.get(key(context))
          return unless raw
          raise ArgumentError, "Invalid report draft envelope" unless raw.is_a?(String) && raw.bytesize <= 24_000

          draft = encryptor.decrypt_and_verify(raw, purpose: key(context))
          return unless draft.is_a?(Hash) && draft["expires_at"].is_a?(Numeric) && draft["expires_at"] > context.now.to_f

          draft
        end

        def write(context:, draft:, lease:)
          ttl = [(draft.fetch("expires_at") - context.now.to_f).ceil, TTL].min
          raise ArgumentError, "Expired report draft" unless ttl.positive?

          encrypted = encryptor.encrypt_and_sign(draft, purpose: key(context))
          raise ArgumentError, "Report draft too large" if encrypted.bytesize > 24_000

          keys = lease_keys(context, lease)
          raise LeaseLost unless redis.eval(WRITE, keys:, argv: [lease.token, encrypted, ttl]) == 1

          draft
        end

        def clear(context:, lease:)
          raise LeaseLost unless redis.eval(CLEAR, keys: lease_keys(context, lease), argv: [lease.token]) == 1
        end

        # Rotation must revoke old signed-cookie replays, not only hide their
        # draft from the new session. No report content is kept in this marker.
        def revoke(context:)
          storage_key = key(context)
          redis.eval(REVOKE, keys: [storage_key, "#{storage_key}:lock", "#{storage_key}:revoked"], argv: [TTL])
        end

        private

        def lease_keys(context, lease)
          storage_key = key(context)
          raise LeaseLost unless lease.is_a?(Lease) && lease.key == "#{storage_key}:lock"

          [lease.key, storage_key, "#{storage_key}:revoked"]
        end

        def key(context)
          klass = Decidim::Bih::Concierge::Dialogue::Contracts::TrustedContext
          raise ArgumentError, "Trusted conversation required" unless context.is_a?(klass)

          scope = [context.organization_id, context.actor_id || "anonymous", context.conversation_key].join(":")
          "#{PREFIX}:#{Digest::SHA256.hexdigest(scope)}"
        end

        def redis
          @redis ||= Redis.new(url: Decidim::Bih::RedisEndpoint.url,
                               connect_timeout: 0.2, read_timeout: 0.2, write_timeout: 0.2, reconnect_attempts: 0)
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
