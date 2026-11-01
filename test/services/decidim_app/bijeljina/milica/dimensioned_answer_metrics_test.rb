# frozen_string_literal: true

require "test_helper"

module DecidimApp
  module Bijeljina
    module Milica
      class DimensionedAnswerMetricsTest < ActiveSupport::TestCase
        class RedisFake
          attr_reader :hashes, :writes

          def initialize
            @hashes = Hash.new { |hash, key| hash[key] = {} }
            @writes = []
          end

          def eval(_script, keys:, argv:)
            key = keys.first
            field = argv.first
            @writes << [keys, argv]
            @hashes[key][field] = (@hashes[key].fetch(field, "0").to_i + 1).to_s
          end

          def hgetall(key) = @hashes[key]
        end

        setup do
          @redis = RedisFake.new
          @cache = Struct.new(:redis).new(@redis)
          @now = Time.utc(2026, 9, 15, 10)
          @traffic = ENV.fetch("MILICA_METRICS_TRAFFIC_KIND", nil)
          ENV.delete("MILICA_METRICS_TRAFFIC_KIND")
          DimensionedAnswerMetrics.configure(release_sha: "a" * 40, prompt_version: 1)
        end

        teardown do
          @traffic.nil? ? ENV.delete("MILICA_METRICS_TRAFFIC_KIND") : ENV["MILICA_METRICS_TRAFFIC_KIND"] = @traffic
          DimensionedAnswerMetrics.configure(release_sha: MetricRollup.release_sha, prompt_version: Decidim::Bih::Concierge::Dialogue::Contracts::VERSION)
        end

        def record(**attributes)
          DimensionedAnswerMetrics.record(organization_id: 1, topic: "water", outcome: "answered", facet: "status", now: @now, **attributes)
        end

        def snapshot(**attributes)
          DimensionedAnswerMetrics.snapshot(organization_id: 1, now: @now, hours: 2, **attributes)
        end

        test "tenant hour facet traffic and capture release remain independent" do
          Rails.stub(:cache, @cache) do
            3.times { record }
            record(now: @now - 1.hour)
            record(organization_id: 2)
            record(now: @now - 3.hours)
            ENV["MILICA_METRICS_TRAFFIC_KIND"] = "synthetic"
            record(facet: "fee")
            DimensionedAnswerMetrics.configure(release_sha: "b" * 40, prompt_version: 2)
            record(facet: "fee")
            rows = snapshot
            assert_equal(6, rows.sum { |row| row[:count] })
            assert_equal 4, rows.find { |row| row[:traffic_kind] == "unclassified" }[:count]
            assert_equal ["a" * 40, "b" * 40], rows.select { |row| row[:traffic_kind] == "synthetic" }.map { |row| row[:release_sha] }.sort
            assert(rows.all? { |row| row.keys.sort == [:count, :facet, :label, :prompt_version, :release_sha, :topic, :traffic_kind] })
            assert_equal 1, snapshot(organization_id: 2).first[:count]
          end
          assert(@redis.writes.all? { |_keys, arguments| arguments[1] == 48.hours.to_i })
        end

        test "unknown dimensions and forged traffic never persist arbitrary text" do
          Rails.stub(:cache, @cache) do
            record(topic: "private address")
            record(facet: "private phone")
            record(outcome: "private reply")
            record(organization_id: "1/private")
            assert_empty @redis.writes
            ENV["MILICA_METRICS_TRAFFIC_KIND"] = "citizen supplied"
            record
            assert_equal "unclassified", snapshot.first[:traffic_kind]
            assert_not_includes @redis.hashes.to_s, "private"
            assert_not_includes @redis.hashes.to_s, "citizen supplied"
          end
        end

        test "malformed cache fields are rejected and capture failure cannot change an answer" do
          Rails.stub(:cache, @cache) do
            @redis.hashes[DimensionedAnswerMetrics.cache_key(1, @now)]["private-not-json"] = "5"
            @redis.hashes[DimensionedAnswerMetrics.cache_key(1, @now)][JSON.generate(["water", "answered", "private", "unclassified", nil, 1])] = "5"
            assert_empty snapshot
            @redis.define_singleton_method(:eval) { |*_, **_| raise IOError }
            assert_nil record
          end
          assert_raises(ArgumentError) { snapshot(hours: 49) }
        end
      end
    end
  end
end
