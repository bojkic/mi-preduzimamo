# frozen_string_literal: true

require "test_helper"

module DecidimApp
  module Bijeljina
    module Milica
      class AnswerMetricsTest < ActiveSupport::TestCase
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

        test "counters written by increment are read back from a raw Redis-style store" do
          now = Time.utc(2026, 9, 9, 12)
          Rails.stub(:cache, RawCounterCache.new) do
            AnswerMetrics.record(topic: "water", outcome: "answered", now:)
            AnswerMetrics.record(topic: "water", outcome: "answered", now:)
            AnswerMetrics.record(topic: "parking", outcome: "fallback", now: now - 1.hour)
            rows = AnswerMetrics.snapshot(now:, hours: 2).fetch(:rows).index_by { |row| row.fetch(:topic) }
            assert_equal 2, rows.fetch("water").fetch(:outcomes).fetch("answered")
            assert_equal 1, rows.fetch("parking").fetch(:unmet_demand_proxy_count)
          end
        end

        test "allowlisted answer outcomes aggregate across hours while clarification stays separate from unmet demand" do
          now = Time.utc(2026, 9, 9, 12)
          Rails.stub(:cache, ActiveSupport::Cache::MemoryStore.new) do
            AnswerMetrics.record(topic: "water", outcome: "source_unavailable", now:)
            AnswerMetrics.record(topic: "water", outcome: "clarification", now: now - 1.hour)
            AnswerMetrics.record(topic: "unknown", outcome: "fallback", now:)
            AnswerMetrics.record(topic: "Private street", outcome: "fallback", now:)
            AnswerMetrics.record(topic: "water", outcome: "Private reply", now:)
            rows = AnswerMetrics.snapshot(now:, hours: 2).fetch(:rows).index_by { |row| row.fetch(:topic) }
            assert_equal 2, rows.fetch("water").fetch(:recorded_answers)
            assert_equal 1, rows.fetch("water").fetch(:unmet_demand_proxy_count)
            assert_equal 1, rows.fetch("unknown").fetch(:unmet_demand_proxy_count)
            assert_equal %w(unknown water), rows.keys.sort
            assert_raises(ArgumentError) { AnswerMetrics.snapshot(hours: 49) }
          end
        end

        test "answer boundary recorder emits fixed labels without needing ReadPort and before usage database failure" do
          organization = create_organization
          recorder_class = Decidim::Bih::Concierge::UsageAggregateRecorder
          recorder = recorder_class.new(organization:, channel: "web_chat", outcome: "success", answer_intent: "service", topic: "water",
                                        outcome_dimensions: recorder_class.outcome_dimensions(resolution: "clarification"))
          events = []
          callback = ->(*arguments) { events << arguments.last }
          recorder.define_singleton_method(:find_or_create_aggregate) { raise IOError, "Synthetic aggregate DB failure" }
          Rails.stub(:cache, ActiveSupport::Cache::MemoryStore.new) do
            ActiveSupport::Notifications.subscribed(callback, "milica.answer_outcome") do
              assert_raises(IOError) { recorder.call }
            end
            assert_equal [{ topic: "water", outcome: "clarification" }], events
            assert_equal 1, AnswerMetrics.snapshot(hours: 1).fetch(:rows).first.fetch(:recorded_answers)
          end
        end

        test "dimension event contains only bounded classification and an internal tenant partition" do
          events = []
          callback = ->(*arguments) { events << arguments.last }
          ActiveSupport::Notifications.subscribed(callback, "milica.answer_dimensions") do
            Decidim::Bih::Concierge::AnswerOutcome.record_dimensions(
              organization_id: 7, topic: "water", answer_intent: "service", outcome: "success", resolution: "answered", facet: "private text"
            )
          end
          assert_equal [{ organization_id: 7, topic: "water", outcome: "answered", facet: "unknown" }], events
        end

        test "counter writes expire after 48 hours and failure cannot affect outcome recording" do
          writes = []
          cache = Object.new
          cache.define_singleton_method(:increment) { |key, count, **options| writes << [key, count, options] }
          Rails.stub(:cache, cache) { AnswerMetrics.record(topic: "unknown", outcome: "fallback") }
          assert_equal 48.hours, writes.first.last.fetch(:expires_in)
          assert_match %r{\Amilica/answer-metrics/v1/\d{10}/unknown/fallback\z}, writes.first.first
          cache.define_singleton_method(:increment) { |*_, **_| raise IOError, "Synthetic cache failure" }
          Rails.stub(:cache, cache) { assert_nil AnswerMetrics.record(topic: "water", outcome: "answered") }
        end
      end
    end
  end
end
