# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    module Milica
      # Low-cardinality aggregate timing only. No query, location, identity,
      # conversation, source body or provider payload enters these counters.
      module ReadMetrics
        VERSION = 1
        BUCKETS_MS = [10, 25, 50, 100, 250, 500, 1_000, 2_500, 5_000, 10_000, 30_000].freeze
        RETENTION = 48.hours
        STAGES = %w(understanding rendering).freeze
        STAGE_STATUSES = %w(completed failed).freeze

        module_function

        def measure(topic:, action:)
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          value = yield
          value
        ensure
          elapsed = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1_000).round(2)
          record(topic:, action:, status: value&.status || "unavailable", elapsed_ms: elapsed)
        end

        def record(topic:, action:, status:, elapsed_ms:, now: Time.current)
          contracts = Decidim::Bih::Concierge::Dialogue::Contracts
          return unless contracts::TOPICS.include?(topic) && contracts::ACTIONS.include?(action) && contracts::READ_STATUSES.include?(status)
          return unless elapsed_ms.finite? && elapsed_ms >= 0

          bucket = BUCKETS_MS.find { |bound| elapsed_ms <= bound } || "overflow"
          key = cache_key(now, topic, status, bucket)
          Rails.cache.increment(key, 1, expires_in: RETENTION)
          ActiveSupport::Notifications.instrument("read_measured.milica", topic:, action:, status:, duration_ms: elapsed_ms)
        rescue StandardError
          # Metrics failure cannot change a citizen answer or trigger retry.
          nil
        end

        def snapshot(now: Time.current, hours: 24)
          raise ArgumentError, "hours must be 1..48" unless (1..48).cover?(hours)

          contracts = Decidim::Bih::Concierge::Dialogue::Contracts
          contracts::TOPICS.to_h do |topic|
            keys = contracts::READ_STATUSES.flat_map do |status|
              (BUCKETS_MS + ["overflow"]).flat_map do |bucket|
                hours.times.map { |offset| cache_key(now - offset.hours, topic, status, bucket) }
              end
            end
            # Rails.cache.increment writes the counter as a raw integer, so a
            # read without raw: true deserializes nothing and every bucket reads
            # as absent. Keep these two in step.
            values = Rails.cache.read_multi(*keys, raw: true)
            counts = contracts::READ_STATUSES.to_h do |status|
              buckets = (BUCKETS_MS + ["overflow"]).to_h do |bucket|
                total = hours.times.sum { |offset| values.fetch(cache_key(now - offset.hours, topic, status, bucket), 0).to_i }
                [bucket.to_s, total]
              end
              [status, buckets]
            end
            [topic, counts]
          end
        end

        def record_stage(stage:, status:, duration_ms:, now: Time.current)
          return unless STAGES.include?(stage.to_s) && STAGE_STATUSES.include?(status.to_s)

          elapsed = Float(duration_ms)
          return unless elapsed.finite? && elapsed >= 0

          bucket = BUCKETS_MS.find { |bound| elapsed <= bound } || "overflow"
          Rails.cache.increment(stage_key(now, stage, status, bucket), 1, expires_in: RETENTION)
        rescue StandardError
          nil
        end

        def stage_snapshot(now: Time.current, hours: 24)
          raise ArgumentError, "hours must be 1..48" unless (1..48).cover?(hours)

          STAGES.to_h do |stage|
            keys = STAGE_STATUSES.flat_map do |status|
              (BUCKETS_MS + ["overflow"]).flat_map { |bucket| hours.times.map { |offset| stage_key(now - offset.hours, stage, status, bucket) } }
            end
            values = Rails.cache.read_multi(*keys, raw: true)
            statuses = STAGE_STATUSES.index_with do |status|
              (BUCKETS_MS + ["overflow"]).to_h do |bucket|
                [bucket.to_s, hours.times.sum { |offset| values.fetch(stage_key(now - offset.hours, stage, status, bucket), 0).to_i }]
              end
            end
            [stage, statuses]
          end
        end

        def stage_key(now, stage, status, bucket)
          "milica/read-metrics/v#{VERSION}/stages/#{now.getutc.strftime("%Y%m%d%H")}/#{stage}/#{status}/#{bucket}"
        end

        def cache_key(now, topic, status, bucket)
          "milica/read-metrics/v#{VERSION}/#{now.getutc.strftime("%Y%m%d%H")}/#{topic}/#{status}/#{bucket}"
        end
      end
    end
  end
end
