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
      # A browser return ticket, never an authentication credential. Only an
      # actual backend-success hook may bind its authenticated actor. Every
      # transition also requires the original committed task to be unchanged.
      class RegistrationHandoffStore
        TTL = 600
        PREFIX = "bijeljina:milica:registration-return:v1"
        ENTRY_KEYS = %w(token organization_id actor_id conversation_key).freeze
        TASKS = %w(ask_information report_problem report_status neighborhood_information neighborhood_post choose_area).freeze
        ISSUE = "if redis.call('EXISTS', KEYS[2]) == 1 then return 0 end redis.call('SET', KEYS[1], ARGV[1], 'EX', ARGV[2]) return 1"
        REPLACE = <<~LUA
          if redis.call('EXISTS', KEYS[2]) == 1 or redis.call('GET', KEYS[1]) ~= ARGV[1] then return 0 end
          local ok, state = pcall(cjson.decode, redis.call('GET', KEYS[3]) or '')
          if not ok or type(state) ~= 'table' or state.version ~= tonumber(ARGV[3]) then return 0 end
          redis.call('SET', KEYS[1], ARGV[2], 'KEEPTTL')
          return 1
        LUA
        CLAIM = <<~LUA
          if redis.call('EXISTS', KEYS[2]) == 1 or redis.call('GET', KEYS[1]) ~= ARGV[1] then return 0 end
          local ok, state = pcall(cjson.decode, redis.call('GET', KEYS[3]) or '')
          if not ok or type(state) ~= 'table' or state.version ~= tonumber(ARGV[2]) then return 0 end
          redis.call('SET', KEYS[2], '1', 'EX', ARGV[3])
          redis.call('DEL', KEYS[1])
          return 1
        LUA
        REVOKE = "redis.call('SET', KEYS[2], '1', 'EX', ARGV[1]) redis.call('DEL', KEYS[1]) return 1"
        Ticket = Data.define(:entry, :expires_at)

        def initialize(redis: nil, encryptor: nil, state_store: nil, report_store: nil, clock: -> { Time.now.utc })
          @redis = redis
          @encryptor = encryptor
          @state_store = state_store
          @report_store = report_store
          @clock = clock
        end

        def issue(context:, state:, destination:)
          state = state_store.validate(context:, state:)
          return unless state["version"].positive? && state == state_store.read(context:)

          task = resumable_task(state, context:)
          return unless task

          now = @clock.call
          expires_at = [now.to_f + TTL, state.fetch("expires_at")].min
          ttl = (expires_at - now.to_f).floor
          return unless ttl.positive?

          entry = { "token" => SecureRandom.hex(24), "organization_id" => context.organization_id,
                    "actor_id" => context.actor_id, "conversation_key" => context.conversation_key }
          payload = { "token_digest" => Digest::SHA256.hexdigest(entry.fetch("token")), "state_version" => state.fetch("version"),
                      "state_digest" => state_digest(state), "task" => task, "destination" => destination,
                      "expires_at" => expires_at, "phase" => "issued", "authenticated_actor_id" => nil }
          return unless redis.eval(ISSUE, keys: keys(context), argv: [encrypt(payload, context), ttl]) == 1

          Ticket.new(entry: contracts.snapshot(entry), expires_at: Time.at(expires_at).utc)
        end

        # Read-only authorization of the clean handoff URL, followed by a CAS
        # phase marker. GET does not consume a ticket or authenticate anyone.
        def start(entry:, context:)
          decoded = read_entry(entry)
          return unless decoded

          payload, raw, origin = decoded
          return unless same_scope?(origin, context) && %w(issued started).include?(payload["phase"])
          return unless current_state?(payload, origin)
          return unless replace(payload.merge("phase" => "started"), raw, origin)

          payload.fetch("destination")
        end

        # Called only after the existing backend granted/claimed proof and the
        # controller observes that same real, active user signed in.
        # rubocop:disable Metrics/CyclomaticComplexity -- fail-closed guard list; each condition is an independent refusal
        def authenticated(entry:, user:, organization_id:)
          decoded = read_entry(entry)
          return false unless decoded

          payload, raw, origin = decoded
          return false unless valid_user?(user, organization_id) && origin.organization_id == organization_id
          return false unless origin.actor_id.nil? || origin.actor_id == user.id
          return false unless %w(started authenticated).include?(payload["phase"])
          return false if payload["authenticated_actor_id"] && payload["authenticated_actor_id"] != user.id
          return false unless current_state?(payload, origin)

          replace(payload.merge("phase" => "authenticated", "authenticated_actor_id" => user.id), raw, origin)
        end
        # rubocop:enable Metrics/CyclomaticComplexity

        # Claim before normal actor-scope rotation, then let the controller CAS
        # install this task into a fresh scope. A failed installation is not a
        # reason to replay a consumed ticket or overwrite a newer conversation.
        # rubocop:disable Metrics/CyclomaticComplexity -- fail-closed guard list; each condition is an independent refusal
        def consume(entry:, context:, user:)
          decoded = read_entry(entry)
          return unless decoded

          payload, raw, origin = decoded
          return unless valid_user?(user, context.organization_id) && context.actor_id == user.id
          return unless origin.organization_id == context.organization_id && payload["phase"] == "authenticated"
          return unless payload["authenticated_actor_id"] == user.id && current_state?(payload, origin)
          return unless redis.eval(CLAIM, keys: revision_keys(origin), argv: [raw, payload.fetch("state_version"), TTL]) == 1
          # Phone authentication may have reset the session, so the chat
          # controller no longer knows this old scope. Retire its report code
          # before returning any task; failed revocation cannot undo login but
          # must prevent task restoration.
          return unless report_store.revoke(context: origin) == 1

          contracts.snapshot(payload.fetch("task"))
        end
        # rubocop:enable Metrics/CyclomaticComplexity

        def revoke(context:)
          redis.eval(REVOKE, keys: keys(context), argv: [TTL])
        end

        # Phone authentication may have removed the original chat scope from
        # the session. A cancelled return must still revoke that saved origin,
        # not merely the new authenticated conversation's unrelated key.
        def revoke_entry(entry:)
          decoded = read_entry(entry)
          revoke(context: decoded.last) if decoded
        end

        private

        def resumable_task(state, context:)
          suspended = state["suspended_task"]
          # A prior sign-in detour cannot hide the current explicit own-read.
          # Keep supported suspended work (especially reports) in its old order.
          suspended = nil if suspended && !TASKS.include?(suspended["active_task"]) && !suspended["draft"] && active_own_report?(state) # rubocop:disable Rails/NegateInclude -- loads without ActiveSupport core extensions
          task = (suspended || state).slice(*state_store.class::TASK_KEYS)
          return unless TASKS.include?(task["active_task"])

          # Carry citizen-supplied semantics, not old-account profile data,
          # retrieved private facts, GPS, draft handles or submission authority.
          provenance = task.fetch("entity_provenance").select { |_key, value| %w(citizen corrected).include?(value) }
          task = task.merge("entities" => task.fetch("entities").slice(*provenance.keys), "entity_provenance" => provenance,
                            "draft" => nil, "report_handoff_offered" => false, "clarification_count" => 0)
          state_store.validate(context:, state: state_store.empty_state(context).merge(task))
          task
        end

        def active_own_report?(state)
          return false unless state.values_at("active_task", "topic") == %w(report_status report)
          return false if state["draft"] || state.fetch("entities")["reference"]
          return false unless %w(citizen corrected).include?(state.fetch("entity_provenance")["query"])

          Decidim::Bih::Concierge::Dialogue::OwnReportQuestion.limit(state.fetch("entities")["query"])
        end

        # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity -- fail-closed validation of an untrusted entry before decryption
        def read_entry(entry)
          return unless entry.is_a?(Hash) && entry.keys.sort == ENTRY_KEYS.sort
          return unless entry["token"].is_a?(String) && entry["token"].match?(/\A[0-9a-f]{48}\z/)

          origin = contracts::TrustedContext.new(**entry.slice("organization_id", "actor_id", "conversation_key").transform_keys(&:to_sym), now: @clock.call)
          storage_key, revoked_key = keys(origin)
          return if redis.get(revoked_key)

          raw = redis.get(storage_key)
          return unless raw.is_a?(String) && raw.bytesize <= 24_000

          payload = encryptor.decrypt_and_verify(raw, purpose: storage_key)
          return unless payload.is_a?(Hash) && payload["expires_at"].is_a?(Numeric) && payload["expires_at"] > @clock.call.to_f
          return unless payload["token_digest"] == Digest::SHA256.hexdigest(entry.fetch("token"))

          [payload, raw, origin]
        rescue contracts::Invalid, ActiveSupport::MessageEncryptor::InvalidMessage, JSON::ParserError
          nil
        end
        # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

        def current_state?(payload, origin)
          state = state_store.read(context: origin)
          state && state["version"] == payload["state_version"] && state_digest(state) == payload["state_digest"]
        end

        def same_scope?(left, right)
          right.is_a?(contracts::TrustedContext) &&
            [left.organization_id, left.actor_id, left.conversation_key] == [right.organization_id, right.actor_id, right.conversation_key]
        end

        def valid_user?(user, organization_id)
          user.is_a?(Decidim::User) && user.persisted? && user.organization.id == organization_id &&
            user.active_for_authentication? && !user.blocked? && !user.deleted?
        end

        def replace(payload, raw, context)
          redis.eval(REPLACE, keys: revision_keys(context), argv: [raw, encrypt(payload, context), payload.fetch("state_version")]) == 1
        end

        def revision_keys(context)
          keys(context) + [state_store.revision_key(context:)]
        end

        def encrypt(payload, context)
          encrypted = encryptor.encrypt_and_sign(payload, purpose: keys(context).first)
          raise contracts::Invalid, "Registration return too large" if encrypted.bytesize > 24_000

          encrypted
        end

        def state_digest(value)
          Digest::SHA256.hexdigest(JSON.generate(canonical(value)))
        end

        def canonical(value)
          return value.keys.sort.to_h { |key| [key, canonical(value.fetch(key))] } if value.is_a?(Hash) # rubocop:disable Rails/IndexWith -- loads without ActiveSupport core extensions
          return value.map { |item| canonical(item) } if value.is_a?(Array)

          value
        end

        def keys(context)
          raise contracts::Invalid, "Trusted context required" unless context.is_a?(contracts::TrustedContext)

          scope = [context.organization_id, context.actor_id || "anonymous", context.conversation_key].join(":")
          key = "#{PREFIX}:#{Digest::SHA256.hexdigest(scope)}"
          [key, "#{key}:revoked"]
        end

        def state_store = @state_store ||= Decidim::Bih::Concierge::Dialogue::StateStore.new

        def report_store = @report_store ||= ReportConversationStore.new

        def contracts = Decidim::Bih::Concierge::Dialogue::Contracts

        def redis
          @redis ||= Redis.new(url: Decidim::Bih::RedisEndpoint.url,
                               connect_timeout: 0.2, read_timeout: 0.2, write_timeout: 0.2, reconnect_attempts: 0)
        end

        def encryptor
          @encryptor ||= ActiveSupport::MessageEncryptor.new(Rails.application.key_generator.generate_key(PREFIX, 32),
                                                             cipher: "aes-256-gcm", serializer: JSON)
        end
      end
    end
  end
end
