# frozen_string_literal: true

require "test_helper"

module DecidimApp
  module Bijeljina
    module Milica
      class ReadMetricsTest < ActiveSupport::TestCase
        # ActiveSupport::Cache::RedisCacheStore#increment writes the counter
        # through Redis INCRBY, so the value is a raw string with no marshalled
        # entry around it. A read without raw: true finds nothing. MemoryStore
        # does not behave this way, which is why this fake exists.
        class RawCounterCache
          def initialize = @data = {}

          def increment(key, amount = 1, **_options)
            @data[key] = (@data.fetch(key, "0").to_i + amount).to_s
          end

          def read_multi(*keys, **options)
            return {} unless options[:raw] == true

            keys.each_with_object({}) { |key, found| found[key] = @data[key] if @data.has_key?(key) }
          end
        end

        test "read and stage counters survive the raw Redis-style round trip" do
          now = Time.utc(2026, 9, 9, 12)
          Rails.stub(:cache, RawCounterCache.new) do
            ReadMetrics.record(topic: "waste", action: "ask_information", status: "ok", elapsed_ms: 8, now:)
            ReadMetrics.record_stage(stage: "understanding", status: "completed", duration_ms: 900, now:)
            reads = ReadMetrics.snapshot(now:, hours: 2)
            stages = ReadMetrics.stage_snapshot(now:, hours: 2)
            assert reads.any? { |_topic, statuses| statuses.any? { |_status, buckets| buckets.values.sum.positive? } }, reads.inspect
            assert stages.any? { |_stage, statuses| statuses.any? { |_status, buckets| buckets.values.sum.positive? } }, stages.inspect
          end
        end

        test "stage instrumentation aggregates only allowed dimensions across UTC hours" do
          cache = ActiveSupport::Cache::MemoryStore.new
          now = Time.utc(2026, 9, 9, 12, 15)
          Rails.stub(:cache, cache) do
            ReadMetrics.record_stage(stage: "understanding", status: "completed", duration_ms: 120, now:)
            ReadMetrics.record_stage(stage: "understanding", status: "completed", duration_ms: 180, now: now - 1.hour)
            ReadMetrics.record_stage(stage: "rendering", status: "failed", duration_ms: 11, now:)
            ReadMetrics.record_stage(stage: "private query", status: "completed", duration_ms: 12, now:)
            ReadMetrics.record_stage(stage: "rendering", status: "private identity", duration_ms: 12, now:)
            ReadMetrics.record_stage(stage: "rendering", status: "completed", duration_ms: Float::NAN, now:)
            ReadMetrics.record_stage(stage: "rendering", status: "completed", duration_ms: -1, now:)

            values = ReadMetrics.stage_snapshot(now:, hours: 2)
            assert_equal 2, values.dig("understanding", "completed", "250")
            assert_equal 1, values.dig("rendering", "failed", "25")
            assert_equal(3, values.values.sum { |statuses| statuses.values.sum { |buckets| buckets.values.sum } })
            assert_equal 1, ReadMetrics.stage_snapshot(now:, hours: 1).dig("understanding", "completed", "250")
            assert_raises(ArgumentError) { ReadMetrics.stage_snapshot(now:, hours: 49) }
          end
        end

        test "engine stage notification reaches host counters" do
          cache = ActiveSupport::Cache::MemoryStore.new
          Rails.stub(:cache, cache) do
            ActiveSupport::Notifications.instrument("milica.dialogue_stage", stage: "rendering", status: "completed", duration_ms: 9)
            assert_equal 1, ReadMetrics.stage_snapshot(hours: 1).dig("rendering", "completed", "10")
          end
        end

        test "records bounded counters without citizen text and isolates cache failure" do
          keys = []
          cache = Object.new
          cache.define_singleton_method(:increment) { |key, _amount, **_options| keys << key }
          Rails.stub(:cache, cache) do
            ReadMetrics.record(topic: "water", action: "ask_information", status: "ok", elapsed_ms: 90.0)
            ReadMetrics.record(topic: "private citizen text", action: "ask_information", status: "ok", elapsed_ms: 90.0)
          end
          assert_equal 1, keys.size
          assert_match %r{/water/ok/100\z}, keys.first

          cache.define_singleton_method(:increment) { |*_, **_| raise IOError, "cache offline" }
          value = Struct.new(:status).new("ok")
          Rails.stub(:cache, cache) do
            assert_same value, ReadMetrics.measure(topic: "water", action: "ask_information") { value }
          end
        end
      end
    end
  end
end
