# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/synthetic_event_source_registry"

module DecidimApp
  module Bijeljina
    class CityServiceSourceProbeTest < ActiveSupport::TestCase
      include SyntheticEventSourceRegistry
      TestDeadline = Struct.new(:remaining_seconds) do
        def expired?
          remaining_seconds <= 0
        end

        def deadline
          123.0
        end

        def within(max_seconds)
          self.class.new([remaining_seconds, max_seconds].min)
        end
      end

      test "probes selected sources through an injected fetcher without returning raw bodies" do
        rows = CityServiceSourceProbe.call(
          keys: ["electricity_outages"],
          fetcher: fake_fetcher(http_status: "200", content_type: "text/html", bytes_sampled: 512)
        )

        assert_equal 1, rows.size
        row = rows.first

        assert_equal "electricity_outages", row.fetch(:source_key)
        assert_equal "reachability_only", row.fetch(:check_scope)
        assert_equal "ok", row.fetch(:status)
        assert_not_nil row.fetch(:checked_at)
        assert_nil row.fetch(:error_code)
        assert_equal 200, row.fetch(:http_status)
        assert_equal "text/html", row.fetch(:content_type)
        assert_equal 512, row.fetch(:bytes_sampled)
        assert_includes row.fetch(:detail), "bytes_sampled=512"
        assert_not_includes row.to_s, "raw source body"
      end

      test "maps blocked but reachable source responses to warning" do
        rows = CityServiceSourceProbe.call(
          keys: ["water_service"],
          fetcher: fake_fetcher(http_status: "403", content_type: "text/html", bytes_sampled: 0)
        )

        assert_equal "warn", rows.first.fetch(:status)
        assert_equal "access_restricted", rows.first.fetch(:error_code)
        assert_equal 403, rows.first.fetch(:http_status)
      end

      test "maps missing source responses to failure" do
        rows = CityServiceSourceProbe.call(
          keys: ["water_service"],
          fetcher: fake_fetcher(http_status: "404", content_type: "text/html", bytes_sampled: 0)
        )

        assert_equal "fail", rows.first.fetch(:status)
        assert_equal "http_error", rows.first.fetch(:error_code)
      end

      test "returns a sanitized failure row when collection raises" do
        fetcher = lambda do |source:, timeout:, max_bytes:, user_agent:|
          raise "network timeout for #{source.fetch(:key)} #{timeout} #{max_bytes} #{user_agent}"
        end

        rows = CityServiceSourceProbe.call(keys: ["water_service"], fetcher:)

        assert_equal "fail", rows.first.fetch(:status)
        assert_nil rows.first.fetch(:http_status)
        assert_nil rows.first.fetch(:checked_at)
        assert_equal "probe_error", rows.first.fetch(:error_code)
        assert_includes rows.first.fetch(:detail), "RuntimeError"
        assert_includes rows.first.fetch(:detail), "water_service"
      end

      test "uses the same browser-compatible HTTP identity as the scraper" do
        assert_equal CityServiceNoticeCollector::DEFAULT_USER_AGENT, CityServiceSourceProbe::DEFAULT_USER_AGENT
        assert_equal CityServiceNoticeCollector::DEFAULT_CONTACT_EMAIL, CityServiceSourceProbe::DEFAULT_CONTACT_EMAIL
      end

      test "owner disabled heating cannot be probed even with an explicit key" do
        calls = 0
        fetcher = ->(**) { calls += 1; raise "disabled source was fetched" }
        assert_raises(ArgumentError) { CityServiceSourceProbe.call(keys: ["heating_service"], fetcher:) }
        assert_equal 0, calls
      end

      test "rejects unknown selected source keys" do
        assert_raises(KeyError) do
          CityServiceSourceProbe.call(keys: ["missing_source"], fetcher: fake_fetcher)
        end
      end

      test "honors an expired remaining deadline without fetching" do
        calls = 0
        row = CityServiceSourceProbe.call(
          keys: ["water_service"],
          deadline: TestDeadline.new(0),
          fetcher: ->(**) { calls += 1 }
        ).first

        assert_equal 0, calls
        assert_equal "fail", row.fetch(:status)
        assert_equal "deadline_exceeded", row.fetch(:error_code)
        assert_nil row.fetch(:checked_at)
      end

      test "rejects numeric deadlines without fetching" do
        calls = 0
        row = CityServiceSourceProbe.call(
          keys: ["water_service"],
          deadline: 12_345.0,
          fetcher: ->(**) { calls += 1 }
        ).first

        assert_equal 0, calls
        assert_equal "fail", row.fetch(:status)
        assert_equal "invalid_deadline", row.fetch(:error_code)
      end

      private

      def fake_fetcher(http_status: "200", content_type: "text/html", bytes_sampled: 128)
        lambda do |source:, timeout:, max_bytes:, user_agent:|
          assert source.fetch(:key).present?
          assert_operator timeout, :>, 0
          assert_operator max_bytes, :>, 0
          assert user_agent.present?

          {
            http_status:,
            final_url: source.fetch(:source_url),
            content_type:,
            bytes_sampled:
          }
        end
      end
    end
  end
end
