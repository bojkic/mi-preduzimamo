# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/synthetic_event_source_registry"
require_relative "../../../support/synthetic_weather_region"

module DecidimApp
  module Bijeljina
    class CityServiceEvidenceParserTest < ActiveSupport::TestCase
      include SyntheticEventSourceRegistry
      include SyntheticWeatherRegion
      setup do
        @now = Time.find_zone!("Europe/Sarajevo").parse("2040-09-09 17:00:00")
        install_synthetic_weather_region
        write_synthetic_weather_region(source_url: CityServiceSources.fetch("weather_warnings").fetch(:source_url),
          reviewed_on: "2040-09-01", valid_until: "2041-08-31")
      end

      teardown { restore_synthetic_weather_region if @synthetic_weather_region_root }

      test "waste programme is verified only for the reviewed PDF checksum and current coverage year" do
        pdf = "%PDF-1.7 reviewed fixture"
        registry = { "source_sha256" => Digest::SHA256.hexdigest(pdf), "source_url" => CityServiceSources.fetch("waste_schedule").fetch(:source_url),
                     "valid_from" => "2040-01-01", "valid_until" => "2040-12-31", "coverage" => { "districts" => [2, 3, 4], "container_routes_included" => false } }
        CityServiceEvidenceParser.stub(:waste_program_registry, registry) do
          check = collect("waste_schedule", pdf)
          assert_equal :ok, check.status
          assert_equal false, check.notices.first.metadata["exceptions_verified"]
          assert_equal [2, 3, 4], check.notices.first.metadata.dig("coverage", "districts")
          assert_equal true, check.notices.first.metadata["review_required"]
          assert_equal :unreviewed, collect("waste_schedule", "#{pdf} changed").status
          assert_equal :unreviewed, collect("waste_schedule", pdf, now: @now + 1.year).status
        end
      end

      test "civil feed supplies explicit inclusive window and regional evidence without old warnings" do
        html = civil_feed("ЛОКАЦИЈА: ЦИЈЕЛА РЕПУБЛИКА СРПСКА ВРИЈЕМЕ: од 03.09. до 09.09.2040.")
        check = collect("civil_protection", html)
        assert_equal :ok, check.status
        metadata = check.notices.first.metadata
        assert_equal "2040-09-03T00:00:00+02:00", metadata["starts_at"]
        assert_equal "2040-09-10T00:00:00+02:00", metadata["ends_at"]
        assert_equal "ЦИЈЕЛА РЕПУБЛИКА СРПСКА", metadata["affected_area_text"]
        assert_equal true, metadata["review_required"]
        assert_equal :empty, collect("civil_protection", html, now: @now + 1.day).status
      end

      test "civil feed recognizes the explicitly labelled single day across inline formatting" do
        html = civil_feed("ЛОКАЦИЈА: ЦИЈЕЛА РЕПУБЛИКА СРПСКА ВРИЈЕМЕ: <strong>11.09.</strong>2040. Ујутру облачно.")
        check = collect("civil_protection", html)
        assert_equal :ok, check.status
        assert_equal "2040-09-11T00:00:00+02:00", check.notices.first.metadata["starts_at"]
        assert_equal "2040-09-12T00:00:00+02:00", check.notices.first.metadata["ends_at"]
        assert_equal "upcoming", check.notices.first.metadata["temporal_status"]
        assert_equal true, check.notices.first.metadata["review_required"]
      end

      test "civil single-day parsing does not truncate unsupported ranges or infer a date from prose" do
        ["11.09.2040. - 12.09.2040.", "11.09.2040. од 10 до 12 часова", "31.09.2040.", "наредних дана; објављено 11.09.2040."].each do |value|
          check = collect("civil_protection", civil_feed("ЛОКАЦИЈА: ЦИЈЕЛА РЕПУБЛИКА СРПСКА ВРИЈЕМЕ: #{value}"))
          assert_equal :unreviewed, check.status, value
          assert_equal "unknown", check.notices.first.metadata["temporal_status"], value
        end
      end

      test "civil warnings with unsupported clocks remain unreviewed and regional unrelated warnings are excluded" do
        check = collect("civil_protection", civil_feed("ЛОКАЦИЈА: ЦИЈЕЛА РЕПУБЛИКА СРПСКА ВРИЈЕМЕ: наредних дана"))
        assert_equal :unreviewed, check.status
        assert_equal "unknown", check.notices.first.metadata["temporal_status"]
        other = collect("civil_protection", civil_feed("ЛОКАЦИЈА: ТРЕБИЊЕ ВРИЈЕМЕ: од 03.09. до 09.09.2040."))
        assert_equal :empty, other.status
      end

      test "embedded road report extracts current local paragraphs and rejects stale reports" do
        html = <<~HTML
          <html><article><header><h2>ИЗВЈЕШТАЈ О СТАЊУ НА ПУТЕВИМА 09.09.2040 16:28:12</h2></header>
          <div id='article-container'><p>Измијењен је режим саобраћаја на путу <strong>Бијељина–Измишљени мост</strong> због радова.</p>
          <p>Измијењен је режим саобраћаја на путу Неповезано измишљено мјесто због радова.</p></div></article></html>
        HTML
        check = collect("road_conditions", html)
        assert_equal :ok, check.status
        assert_equal 1, check.notices.size
        assert_equal "2040-09-09T16:28:12+02:00", check.notices.first.metadata["source_published_at"]
        assert_equal "Бијељина–Измишљени мост", check.notices.first.metadata["affected_area_text"]
        assert_equal :malformed, collect("road_conditions", html, now: @now + 3.days).status
      end

      test "a completed bulky campaign produces listing status without claiming a current campaign" do
        html = <<~HTML
          <html><section class='blog'><article><div class='categoryBlog'><h2><a href='/action'>ОДВОЖЕЊЕ КАБАСТОГ ОТПАДА У АПРИЛУ 2040.</a></h2>
          <div class='categoryIntro'>08.04.2040. | 03:41 ИЗМИШЉЕНА СЛУЖБА од 15.04. до 30.04.2040. године.</div></div></article></section></html>
        HTML
        check = collect("bulky_waste", html)
        assert_equal :ok, check.status
        metadata = check.notices.first.metadata
        assert_equal "no_current_campaign_listed", metadata["temporal_status"]
        assert_equal "2040-05-01T00:00:00+02:00", metadata["last_campaign_ends_at"]
        assert_nil metadata["starts_at"]
        assert_nil metadata["ends_at"]
        assert_equal :ok, collect("bulky_waste", html.sub("</html>", "<!--\xFF--></html>")).status
      end

      test "weather feed selects only the configured reviewed region and preserves its provider name" do
        check = collect("weather_warnings", weather_feed)
        assert_equal :ok, check.status
        assert_equal 1, check.notices.size
        metadata = check.notices.first.metadata
        assert_equal "Izmišljena regija", metadata["affected_area_text"]
        assert_equal "TEST-REGION-A", metadata["provider_area_code"]
        assert_equal "operator_reviewed_region_coverage", metadata["coverage_status"]
        configured = WeatherRegionConfiguration.for_source(source_url: CityServiceSources.fetch("weather_warnings").fetch(:source_url), day: @now.to_date)
        assert_equal configured.identity, check.weather_region_review_id
        assert_equal configured.identity, metadata["weather_region_review_id"]
        assert_equal configured.evidence_url, metadata["area_evidence_url"]
        assert_equal "upcoming", metadata["temporal_status"]
        assert_equal :empty, collect("weather_warnings", weather_feed.gsub("TEST-REGION-A", "TEST-REGION-B").gsub("Izmišljena regija", "Druga izmišljena regija")).status
      end

      test "weather expired test and cancelled entries cannot become current warnings" do
        assert_equal :empty, collect("weather_warnings", weather_feed, now: @now + 25.hours).status
        assert_equal :empty, collect("weather_warnings", weather_feed.sub("Actual", "Test")).status
        assert_equal :empty, collect("weather_warnings", weather_feed.sub(">Alert<", ">Cancel<")).status
        assert_equal :malformed, collect("weather_warnings", weather_feed.sub("2040-09-10T16:00:00Z", "bad-date")).status
      end

      test "malformed or externally declared XML is not silently parsed as a healthy empty feed" do
        assert_equal :malformed, collect("civil_protection", "<rss><channel>").status
        assert_equal :malformed, collect("civil_protection", "<!DOCTYPE rss SYSTEM 'file:///etc/passwd'>#{civil_feed("")} ").status
        assert_equal :malformed, collect("weather_warnings", weather_feed.sub(%r{<entry>.*</entry>}m, "")).status
        assert_equal :malformed, collect("weather_warnings", weather_feed.sub("2040-09-09T08:00:00Z", "2040-09-11T08:00:00Z")).status
        assert_equal :malformed,
                     collect("road_conditions", "<html><article><header><h2>09.09.2040 16:28:12</h2></header><div id='article-container'></div></article></html>").status
      end

      test "weather validates publication before filtering future effective or expired warnings" do
        future_effective = weather_feed.sub("</cap:sent>", "</cap:sent><cap:effective>2040-09-10T08:00:00Z</cap:effective>")
        assert_equal :empty, collect("weather_warnings", future_effective).status

        future_publication = future_effective.sub("2040-09-09T08:00:00Z", "2040-09-11T08:00:00Z")
        assert_equal :malformed, collect("weather_warnings", future_publication).status
        assert_equal :malformed, collect("weather_warnings", future_publication, now: @now + 25.hours).status
        assert_equal :malformed, collect("weather_warnings", "<!DOCTYPE feed SYSTEM 'file:///etc/passwd'>#{weather_feed}").status
      end

      test "weather identical reissues keep the latest publication without merging changed warnings or other windows" do
        original = weather_feed.match(%r{<entry>.*</entry>}m)[0]
        older = original.sub("2040-09-09T08:00:00Z", "2040-09-08T08:00:00Z").sub("example-warning", "older-warning")
        changed = original.sub("Moderate", "Severe").sub("example-warning", "severe-warning")
        next_window = original.sub("2040-09-10T11:00:00Z", "2040-09-11T11:00:00Z")
                              .sub("2040-09-10T16:00:00Z", "2040-09-11T16:00:00Z").sub("example-warning", "next-window")
        check = collect("weather_warnings", weather_feed.sub(original, [older, original, changed, next_window].join))
        assert_equal :ok, check.status
        assert_equal 3, check.notices.size
        identifiers = check.notices.map { |notice| notice.metadata.fetch("provider_identifier") }
        assert_includes identifiers, "example-warning"
        assert_not_includes identifiers, "older-warning"
        assert_includes identifiers, "severe-warning"
        assert_includes identifiers, "next-window"
      end

      test "legacy Atom cancellation suppresses its referenced alert" do
        original = weather_feed.match(%r{<entry>.*</entry>}m)[0]
        cancellation = original.sub(">Alert<", ">Cancel<").sub("example-warning", "cancellation")
                               .sub("</entry>", "<cap:references>authority,example-warning,2040-09-09T08:00:00Z</cap:references></entry>")
        assert_equal :empty, collect("weather_warnings", weather_feed.sub(original, original + cancellation)).status
      end

      test "an old weather feed is stale rather than malformed and cannot provide warnings" do
        result = collect("weather_warnings", weather_feed, now: @now + 3.days)
        assert_equal :stale, result.status
        assert_equal :source_feed_stale, result.error_code
        assert_nil result.checked_at
        assert_empty result.notices
      end

      test "a civil feed rebuilt only on publication keeps windowed warnings current and drops undated old ones" do
        windowed = civil_feed("LOKACIJA: BIJELJINA VRIJEME: 15.09.2040.")
        check = collect("civil_protection", windowed, now: @now + 3.days)
        assert_equal :ok, check.status
        assert_equal "upcoming", check.notices.first.metadata["temporal_status"]
        assert_equal "2040-09-09T10:00:00+00:00", check.notices.first.metadata["source_published_at"]

        undated = collect("civil_protection", civil_feed("LOKACIJA: BIJELJINA VRIJEME: naredna tri dana"), now: @now + 3.days)
        assert_equal :empty, undated.status
        assert_equal :unreviewed, collect("civil_protection", civil_feed("LOKACIJA: BIJELJINA VRIJEME: naredna tri dana"), now: @now + 1.day).status

        abandoned = collect("civil_protection", windowed, now: @now + 31.days)
        assert_equal :stale, abandoned.status
        assert_equal :source_feed_stale, abandoned.error_code
        assert_nil abandoned.checked_at
        assert_empty abandoned.notices
      end

      test "unrecognized reference feed identities are rejected before source facts are accepted" do
        civil = civil_feed("LOKACIJA: BIJELJINA VRIJEME: 15.09.2040.")
        assert_equal :malformed, collect("civil_protection", civil.sub("<link>https://ruczrs.org</link>", "<link>https://untrusted.example.invalid</link>")).status
        assert_equal :malformed, collect("weather_warnings", weather_feed.sub("tag:meteoalarm.org,2021-02-19:BA", "tag:untrusted.example.invalid,2040-01-01:TEST")).status
      end

      private

      def collect(key, body, now: @now)
        fetcher = ->(**) { { body:, http_status: 200, content_type: "text/html" } }
        CityServiceNoticeCollector.check(keys: [key], fetcher:, now:).first
      end

      # Canonical identifiers are the reference adapter grammar, not a fetched
      # feed. Dates, bodies, item URLs and alert narratives below are invented.
      def civil_feed(body)
        <<~XML
          <rss xmlns:content="http://purl.org/rss/1.0/modules/content/"><channel><link>https://ruczrs.org</link><lastBuildDate>Sun, 09 Sep 2040 12:00:00 +0000</lastBuildDate>
          <item><title>УПОЗОРЕЊЕ — ИЗМИШЉЕНИ ТЕСТ</title>
          <link>https://civil-protection.example.invalid/2040/09/09/warning/</link><pubDate>Sun, 09 Sep 2040 10:00:00 +0000</pubDate>
          <content:encoded><![CDATA[<p>#{body}</p>]]></content:encoded></item></channel></rss>
        XML
      end

      def weather_feed
        <<~XML
          <feed xmlns="http://www.w3.org/2005/Atom" xmlns:cap="urn:oasis:names:tc:emergency:cap:1.2">
          <id>tag:meteoalarm.org,2021-02-19:BA</id><updated>2040-09-09T12:00:00Z</updated><entry><title>Yellow Thunderstorm Warning Izmišljena regija</title>
          <cap:areaDesc>Izmišljena regija</cap:areaDesc><cap:geocode><valueName>EMMA_ID</valueName><value>TEST-REGION-A</value></cap:geocode>
          <cap:event>Thunderstorm Yellow Warning</cap:event><cap:sent>2040-09-09T08:00:00Z</cap:sent>
          <cap:onset>2040-09-10T11:00:00Z</cap:onset><cap:expires>2040-09-10T16:00:00Z</cap:expires>
          <cap:status>Actual</cap:status><cap:scope>Public</cap:scope><cap:message_type>Alert</cap:message_type>
          <cap:identifier>example-warning</cap:identifier><cap:severity>Moderate</cap:severity></entry></feed>
        XML
      end
    end
  end
end
