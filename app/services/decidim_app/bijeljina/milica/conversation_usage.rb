# frozen_string_literal: true

require "English"
require "redis"
require "decidim/bih/redis_endpoint"

module DecidimApp
  module Bijeljina
    module Milica
      # Aggregate provider accounting, never citizen text or identity. Unknown
      # provider usage retains its reservation; a failure cannot grant a retry.
      class ConversationUsage
        class Limit < StandardError; end
        MICRO_USD = 1_000_000
        CALL_CEILING = 50_000
        RESERVE = <<~LUA
          local current = tonumber(redis.call('HGET', KEYS[1], 'committed_micro_usd') or '0')
          if current + tonumber(ARGV[1]) > tonumber(ARGV[2]) then return 0 end
          redis.call('HINCRBY', KEYS[1], 'committed_micro_usd', ARGV[1])
          redis.call('HINCRBY', KEYS[1], 'reserved_calls', 1)
          redis.call('EXPIRE', KEYS[1], 172800)
          return 1
        LUA
        SETTLE = <<~LUA
          redis.call('HINCRBY', KEYS[1], 'committed_micro_usd', tonumber(ARGV[1])-tonumber(ARGV[2]))
          redis.call('HINCRBY', KEYS[1], 'settled_micro_usd', ARGV[1])
          redis.call('HINCRBY', KEYS[1], 'settled_calls', 1)
          redis.call('HINCRBY', KEYS[1], 'input_tokens', ARGV[3])
          redis.call('HINCRBY', KEYS[1], 'output_tokens', ARGV[4])
          return 1
        LUA

        attr_reader :receipts, :attempts

        # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity, Metrics/ParameterLists -- each bounded spend argument is validated explicitly; keyword seams keep tests off Redis and the clock
        def initialize(organization_id:, model:, redis: nil, day: Time.now.utc.strftime("%Y%m%d"), daily_ceiling_usd: 20, max_attempts: 8, turn_ceiling_micro_usd: 250_000,
                       observer: nil, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
          raise ArgumentError, "Measured model pricing required" unless model == "gemini-3.5-flash-lite"
          raise ArgumentError, "Organization required" unless organization_id.is_a?(Integer) && organization_id.positive?
          raise ArgumentError, "Bounded daily ceiling required" unless daily_ceiling_usd.is_a?(Numeric) && daily_ceiling_usd.positive? && daily_ceiling_usd <= 1000

          raise ArgumentError, "Bounded turn attempts required" unless max_attempts.is_a?(Integer) && max_attempts.between?(2, 8)
          raise ArgumentError, "Bounded turn spend required" unless turn_ceiling_micro_usd.is_a?(Integer) && turn_ceiling_micro_usd.between?(CALL_CEILING, 500_000)

          @max_attempts = max_attempts
          @turn_ceiling = turn_ceiling_micro_usd
          @turn_committed = 0
          @key = "decidim-bih:milica:model-led:usage:v1:#{organization_id}:#{day}"
          @ceiling = (daily_ceiling_usd * MICRO_USD).ceil
          # Spend counters historically defaulted to db0 (not the engine's db1)
          # when REDIS_URL is unset in production; keep that, never under test.
          @redis = redis || Redis.new(url: Decidim::Bih::RedisEndpoint.url(fallback: Decidim::Bih::RedisEndpoint::LOCAL_DB0_FALLBACK_URL),
                                      connect_timeout: 0.2, read_timeout: 0.2, write_timeout: 0.2)
          @receipts = []
          @attempts = 0
          @observer = observer
          @clock = clock
        end
        # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity, Metrics/ParameterLists

        # rubocop:disable Metrics/CyclomaticComplexity -- reserve, yield, settle and ensure-accounting must stay in one method so every path is accounted
        def call(component:, deadline:)
          started = @clock.call if @observer
          receipts_before = @receipts.length
          reserved = false
          raise Limit, "Model turn limit" if @attempts >= @max_attempts || deadline.expired?
          raise Limit, "Model turn spend limit" if @turn_committed + CALL_CEILING > @turn_ceiling
          raise Limit, "Model spend limit" unless @redis.eval(RESERVE, keys: [@key], argv: [CALL_CEILING, @ceiling]) == 1

          reserved = true
          @turn_committed += CALL_CEILING
          @attempts += 1
          result = yield
          settle(result.usage, component:)
          result
        rescue GeminiConversationClient::Error => e
          settle(e.usage, component:) if e.usage.is_a?(Hash) && e.usage.any?
          raise
        ensure
          if started
            emit_accounting(component:, started:, reserved:, settled: @receipts.length > receipts_before,
                            error: $ERROR_INFO)
          end
        end
        # rubocop:enable Metrics/CyclomaticComplexity

        # Leave room for one continuation plus a final answer. Missing usage
        # retains its full reservation, including in this local turn budget.
        def can_continue?
          @attempts + 2 <= @max_attempts && @turn_committed + (2 * CALL_CEILING) <= @turn_ceiling
        end

        private

        # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity -- flat mapping of every outcome to one metadata-only event
        def emit_accounting(component:, started:, reserved:, settled:, error:)
          phase = %w(planner continuation composer finalization).include?(component.to_s) ? component.to_s : "other"
          status = if error.is_a?(Limit) then "limited"
                   elsif error.is_a?(GeminiConversationClient::Error) then "provider_error"
                   elsif error then "error"
                   else
                     "ok"
                   end
          receipt = settled ? @receipts.last : nil
          event = { phase: "accounting", component: phase, status: status,
                    duration_ms: [((@clock.call - started) * 1000).round(3), 0].max,
                    attempts: @attempts, reserved: reserved, settled: settled,
                    usage_unknown: reserved && !settled }
          event[:input_tokens] = receipt.fetch("input_tokens") if receipt
          event[:output_tokens] = receipt.fetch("output_tokens") if receipt
          event[:cached_input_tokens] = receipt.fetch("cached_input_tokens") if receipt&.has_key?("cached_input_tokens")
          event[:estimated_cost_micro_usd] = receipt.fetch("cost_micro_usd") if receipt
          @observer.call(**event.freeze)
        rescue StandardError
          nil
        end
        # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

        # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity -- provider usage fields are validated one by one before any spend is settled
        def settle(usage, component:)
          return unless usage.is_a?(Hash) && usage["promptTokenCount"].is_a?(Integer) && usage["candidatesTokenCount"].is_a?(Integer)

          input = usage.fetch("promptTokenCount")
          output = usage.fetch("candidatesTokenCount") + usage.fetch("thoughtsTokenCount", 0)
          return unless input >= 0 && output.is_a?(Integer) && output >= 0

          cost = ((input * 0.3) + (output * 2.5)).ceil
          @redis.eval(SETTLE, keys: [@key], argv: [cost, CALL_CEILING, input, output])
          @turn_committed += cost - CALL_CEILING
          cached = usage["cachedContentTokenCount"]
          cached = nil unless cached.is_a?(Integer) && cached.between?(0, input)
          receipt = { "phase" => component.to_s, "input_tokens" => input, "output_tokens" => output, "cost_micro_usd" => cost }
          receipt["cached_input_tokens"] = cached unless cached.nil?
          @receipts << receipt
          raise Limit, "Model call exceeded reserved cost" if cost > CALL_CEILING
        end
        # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
      end
    end
  end
end
