# frozen_string_literal: true
require "test_helper"

class UnconfiguredSourcesTest < ActiveSupport::TestCase
  Sources = DecidimApp::Bijeljina::CityServiceSources
  Collector = DecidimApp::Bijeljina::CityServiceNoticeCollector

  def with_sources(rows)
    original = Sources::SOURCES
    Sources.send(:remove_const, :SOURCES)
    Sources.const_set(:SOURCES, rows.freeze)
    yield
  ensure
    Sources.send(:remove_const, :SOURCES)
    Sources.const_set(:SOURCES, original)
  end

  test "empty public configuration has no scheduled or on demand requests" do
    with_sources([]) do
      assert_empty Sources.all
      [Sources.hourly_sources, Sources.four_hourly_sources, Sources.daily_sources, Sources.weekly_sources, Sources.alert_candidates].each { |rows| assert_empty rows }
      assert_empty Collector.check(fetcher: ->(**) { flunk "unconfigured sources must not fetch" })
    end
  end

  test "a disabled source cannot be fetched even when its key is explicitly requested" do
    source = { key: "synthetic_disabled", source_url: "https://community.example.invalid/", enabled: false }
    with_sources([source]) do
      fetcher = ->(**) { flunk "disabled sources must not fetch" }
      assert_empty Collector.check(fetcher:)
      assert_empty Collector.check(keys: ["synthetic_disabled"], fetcher:)
    end
  end

  test "only explicitly enabled configuration reaches the bounded collector" do
    source = { key: "synthetic_enabled", source_url: "https://community.example.invalid/", enabled: true }
    calls = []
    with_sources([source]) do
      results = Collector.check(fetcher: ->(**options) { calls << options.fetch(:source).fetch(:key); raise "synthetic refusal" })
      assert_equal ["synthetic_enabled"], calls
      assert_equal 1, results.size
      assert_equal :unavailable, results.first.status
    end
  end
end
