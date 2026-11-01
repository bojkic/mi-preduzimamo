# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/synthetic_weather_region"

module DecidimApp
  module Bijeljina
    class CityServiceWeatherParserTest < ActiveSupport::TestCase
      include SyntheticWeatherRegion
      setup do
        @organization = create_organization
        @now = Time.utc(2040, 9, 15, 12)
        install_synthetic_weather_region
        write_synthetic_weather_region(organization_host: @organization.host)
        @source = { key: "weather_warnings", source_url: SyntheticWeatherRegion::SOURCE_URL,
                    label: "Autorski testni izvor", provider: "Autorski testni pružalac" }
        @parser = CityServiceWeatherParser.new(organization: @organization, source: @source)
      end
      teardown { restore_synthetic_weather_region }

      def body(severity: "Severe")
        info = { language: "sr", event: "IZMIŠLJENI TESTNI DOGAĐAJ", headline: "IZMIŠLJENA NAJAVA",
                 severity:, onset: "2040-09-16T00:00:00Z", expires: "2040-09-16T08:00:00Z",
                 instruction: "IZMIŠLJENO UPUTSTVO.",
                 area: [{ areaDesc: "Izmišljeni provider region", geocode: [{ valueName: "EMMA_ID", value: "TEST-REGION-A" }] }] }
        JSON.generate(warnings: [{ alert: { sender: "weather-authority.example.invalid", identifier: "authored-warning-a",
          sent: "2040-09-15T06:00:00Z", status: "Actual", scope: "Public", msgType: "Alert", info: [info] } }])
      end

      def parse(severity: "Severe", source_url: SyntheticWeatherRegion::SOURCE_URL)
        @parser.call(html: body(severity:), fetched_at: @now, source_url:)
      end

      test "board weather preserves reviewed region source and unknown targeting without a local place fallback" do
        event = parse.sole
        assert_equal "Izmišljena pregledana regija (Izmišljena zajednica)", event.affected_text
        assert_includes event.title, "Izmišljena pregledana regija"
        assert_includes event.title, "Izmišljena zajednica"
        assert_equal "unknown", event.targeting_level
        assert_empty event.affected_area_slugs
        assert_equal true, event.extraction_metadata.fetch("requires_human_review")
        assert_equal "operator_reviewed_region_coverage", event.extraction_metadata.fetch("coverage_status")
        assert_equal "2040-09-13", event.extraction_metadata.fetch("area_evidence_checked_on")
        assert_not_includes event.title, "Bijeljina"
        assert_equal "scheduled", event.lifecycle
        assert_equal Time.iso8601("2040-09-16T00:00:00Z"), event.starts_at
      end

      test "yellow stays readable from CAP while board candidates retain the configured severity policy" do
        assert_empty parse(severity: "Moderate")
        notices = WeatherCapFeed.call(body: body(severity: "Moderate"), url: SyntheticWeatherRegion::SOURCE_URL, now: @now)
        assert_equal 1, notices.size
        assert_equal "Moderate", notices.sole.fetch(:metadata).fetch("provider_severity")
        assert_equal "safety", parse(severity: "Severe").sole.severity
        assert_equal "emergency", parse(severity: "Extreme").sole.severity
      end

      test "board refuses another organization and another source even for a quiet feed" do
        other = CityServiceWeatherParser.new(organization: Struct.new(:host).new("other.example.invalid"), source: @source)
        assert_raises(CityServiceNoticeCollector::ParserError) { other.call(html: '{"warnings":[]}', fetched_at: @now) }
        assert_raises(CityServiceNoticeCollector::ParserError) { parse(source_url: "https://other-weather.example.invalid/feed") }
      end

      test "missing malformed and expired review cannot become a quiet board weather result" do
        ENV.delete("MI_WEATHER_REGION_CONFIG_PATH")
        assert_raises(CityServiceNoticeCollector::ParserError) { @parser.call(html: '{"warnings":[]}', fetched_at: @now) }
        ENV["MI_WEATHER_REGION_CONFIG_PATH"] = @synthetic_weather_region_path
        File.write(@synthetic_weather_region_path, "{SYNTHETIC_PRIVATE_MARKER")
        error = assert_raises(CityServiceNoticeCollector::ParserError) { parse }
        assert_not_includes error.message, "SYNTHETIC_PRIVATE_MARKER"
        assert_nil error.cause
        write_synthetic_weather_region(organization_host: @organization.host, valid_until: "2040-09-14")
        assert_raises(CityServiceNoticeCollector::ParserError) { parse }
      end

      test "same review is idempotent and changed review creates a distinct human review candidate" do
        first = parse.sole
        same = parse.sole
        assert_equal first.source_fingerprint, same.source_fingerprint
        assert_equal first.content_version, same.content_version
        write_synthetic_weather_region(organization_host: @organization.host, region_label: "Druga autorska pregledana regija")
        changed = parse.sole
        assert_not_equal first.source_fingerprint, changed.source_fingerprint
        assert_not_equal first.source_occurrence_id, changed.source_occurrence_id
        assert_not_equal first.content_version, changed.content_version
        assert_equal true, changed.extraction_metadata.fetch("requires_human_review")
        assert_equal "unknown", changed.targeting_level
        assert_empty changed.affected_area_slugs
      end

      test "board and CAP share the selected immutable review and recheck current identity" do
        reviews = []
        original = WeatherRegionConfiguration.method(:for_source)
        loader = ->(**options) { reviews << original.call(**options); reviews.last }
        feed = WeatherCapFeed.method(:call)
        received = nil
        parser = ->(**options) { received = options.fetch(:region); feed.call(**options) }
        WeatherRegionConfiguration.stub(:for_source, loader) do
          WeatherCapFeed.stub(:call, parser) { assert_equal 1, parse.size }
        end
        assert_equal 2, reviews.size
        assert_same reviews.first, received
        assert_equal reviews.first.identity, reviews.last.identity
      end

      test "an explicitly passed CAP review is still checked against source and current day" do
        review = WeatherRegionConfiguration.load(day: @now.in_time_zone("Europe/Sarajevo").to_date)
        assert_raises(CityServiceNoticeCollector::ParserError) do
          WeatherCapFeed.call(body: body, url: "https://other-weather.example.invalid/feed", now: @now, region: review)
        end
        assert_raises(CityServiceNoticeCollector::ParserError) do
          WeatherCapFeed.call(body: body, url: SyntheticWeatherRegion::SOURCE_URL, now: Time.utc(2042, 1, 1), region: review)
        end
        assert_raises(CityServiceNoticeCollector::ParserError) do
          WeatherCapFeed.call(body: body, url: SyntheticWeatherRegion::SOURCE_URL, now: @now, region: Object.new)
        end
      end
    end
  end
end
