# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/synthetic_event_source_registry"
require_relative "../../../support/synthetic_weather_region"

module DecidimApp
  module Bijeljina
    class WeatherAcquisitionTest < ActiveSupport::TestCase
      include SyntheticEventSourceRegistry
      include SyntheticWeatherRegion

      Context = Struct.new(:now, :organization_id, :deadline, keyword_init: true) do
        def allows?(capability) = capability == "public_reads"
      end

      setup do
        @now = Time.utc(2040, 9, 19, 8)
        travel_to @now
        @organization = create_organization
        @source = CityServiceSources.fetch("weather_warnings")
        install_synthetic_weather_region
        write_review
        @store = CityServiceSourceCheckStore.new(clock: -> { Time.current })
        DecidimApp::CityServiceSourceSnapshot.where(source_key: "weather_warnings").delete_all
      end
      teardown do
        restore_synthetic_weather_region if @synthetic_weather_region_root
        travel_back
      end

      def write_review(**changes)
        write_synthetic_weather_region(**{ organization_host: @organization.host, source_url: @source.fetch(:source_url) }.merge(changes))
      end

      def review
        WeatherRegionConfiguration.for_source(source_url: @source.fetch(:source_url), day: Time.current.in_time_zone("Europe/Sarajevo").to_date)
      end

      def feed(severity: nil)
        rows = if severity
                 [{ alert: { sender: "authority.example.invalid", identifier: "authored-acquisition-a",
                   sent: (@now - 1.hour).iso8601, status: "Actual", scope: "Public", msgType: "Alert",
                   info: [{ language: "sr", event: "AUTORSKO TESTNO UPOZORENJE", severity:,
                     onset: @now.iso8601, expires: (@now + 4.hours).iso8601,
                     area: [{ areaDesc: "Autorska regija", geocode: [{ valueName: "EMMA_ID", value: "TEST-REGION-A" }] }] }] } }]
               else
                 []
               end
        JSON.generate(warnings: rows)
      end

      def response(body = feed)
        { body:, http_status: 200, content_type: "application/json", final_url: @source.fetch(:source_url), fetched_at: @now }
      end

      def collect(body: feed, **options)
        CityServiceNoticeCollector.check(keys: ["weather_warnings"], fetcher: ->(**) { response(body) }, now: @now, **options).sole
      end

      def refresh(body: feed, fetcher: nil)
        @store.refresh(keys: ["weather_warnings"], fetcher: fetcher || ->(**) { response(body) }).sole
      end

      def read_weather(checker = @store)
        context = Context.new(now: Time.current, organization_id: @organization.id)
        Milica::SourceRead.new(source_checker: checker, organization: @organization).call(topic: "weather", context:, locale: "sr", entities: {})
      end

      def scrape(fetcher: ->(**) { response })
        CityServiceSourceScrape.new(organization: @organization, source_store: @store, fetcher:, now: @now)
                              .call(keys: ["weather_warnings"], cadence: "hourly").sole
      end

      test "empty acquisition records its review identity and remains scoped in a real prepared read" do
        acquired = review.identity
        result = refresh
        assert_equal :empty, result.status
        assert_equal acquired, result.weather_region_review_id
        snapshot = @store.snapshot(source_key: "weather_warnings")
        assert_equal acquired, snapshot.check_payload.fetch("weather_region_review_id")
        assert_equal acquired, @store.check(keys: ["weather_warnings"]).sole.coverage.fetch("weather_region_review_id")
        answer = read_weather
        assert_equal "empty", answer.fetch(:status)
        assert_empty answer.fetch(:facts)
        assert_equal acquired, answer.fetch(:coverage).fetch("reviewed_region_scope").fetch("review_id")
        assert_equal false, answer.fetch(:coverage).fetch("reviewed_region_scope").fetch("live_warning_status")
      end

      test "weather acquisition keeps the established five field check shape" do
        result = collect
        assert_equal [:source_key, :status, :notices, :checked_at, :error_code], result.members
        assert_equal result.members, result.to_h.keys
        assert_predicate result, :frozen?
        assert_predicate result.weather_region_review_id, :frozen?
      end

      test "missing or expired review prevents network acquisition" do
        [-> { ENV.delete("MI_WEATHER_REGION_CONFIG_PATH") },
         -> { ENV["MI_WEATHER_REGION_CONFIG_PATH"] = @synthetic_weather_region_path; write_review(valid_until: "2040-09-18") }].each do |invalidate|
          invalidate.call
          calls = 0
          result = refresh(fetcher: ->(**) { calls += 1; response })
          assert_equal 0, calls
          assert_includes [:unavailable, :malformed], result.status
          assert_nil @store.snapshot(source_key: "weather_warnings").last_success_at
        end
      end

      test "review changed by the fetcher cannot promote old empty data under the new review" do
        captured = review.identity
        result = refresh(fetcher: ->(**) { write_review(region_label: "Druga autorska regija"); response })
        assert_not_equal captured, review.identity
        assert_includes [:unavailable, :malformed], result.status
        assert_nil @store.snapshot(source_key: "weather_warnings").last_success_at
        assert_equal "unavailable", read_weather.fetch(:status)
      end

      test "review expiry during HTTP acquisition rejects the returned feed" do
        write_review(valid_until: "2040-09-19")
        result = refresh(fetcher: ->(**) { travel_to(@now + 2.days); response })
        assert_includes [:unavailable, :malformed], result.status
        assert_nil @store.snapshot(source_key: "weather_warnings").last_success_at
      end

      test "an explicitly supplied stale review is rejected before calling the fetcher" do
        captured = review
        write_review(region_label: "Druga autorska regija")
        calls = 0
        result = CityServiceNoticeCollector.check(keys: ["weather_warnings"], weather_region: captured,
          fetcher: ->(**) { calls += 1; response }, now: @now).sole
        assert_equal 0, calls
        assert_includes [:unavailable, :malformed], result.status
        assert_nil result.weather_region_review_id
      end

      test "record rejects review changes after collection and preserves last good evidence as historical" do
        refresh
        snapshot = @store.snapshot(source_key: "weather_warnings")
        retained = snapshot.attributes.slice("source_version", "last_good_payload", "last_success_at", "content_hash")
        check = collect
        write_review(region_label: "Druga autorska regija")
        result = @store.record(check:, source: @source, response: response)
        assert_equal :unavailable, result.status
        assert_equal :weather_acquisition_review_changed, result.error_code
        assert_equal retained, snapshot.reload.attributes.slice("source_version", "last_good_payload", "last_success_at", "content_hash")
        prepared = @store.check(keys: ["weather_warnings"]).sole
        assert_equal :unavailable, prepared.status
        assert_empty prepared.notices
        assert_equal "retained_for_review_not_current_answer_evidence", prepared.last_good_evidence.fetch("usage")
      end

      test "an unbound empty manual record cannot borrow the current review" do
        check = CityServiceNoticeCollector::SourceCheckResult.new(source_key: "weather_warnings", status: :empty, notices: [], checked_at: @now)
        result = @store.record(check:, source: @source)
        assert_equal :weather_acquisition_review_changed, result.error_code
        assert_nil @store.snapshot(source_key: "weather_warnings").last_success_at
        fake = Object.new
        fake.define_singleton_method(:check) { |**| [check] }
        answer = read_weather(fake)
        assert_equal "unavailable", answer.fetch(:status)
        assert_includes answer.fetch(:warnings), "weather_empty_snapshot_not_region_bound"
      end

      test "a notice cannot borrow the acquired identity from other retained data" do
        check = collect(body: feed(severity: "Moderate"))
        assert_equal :ok, check.status
        changed = CityServiceNoticeCollector::Notice.new(**check.notices.sole.to_h,
          metadata: check.notices.sole.metadata.merge("weather_region_review_id" => "f" * 64))
        forged = CityServiceNoticeCollector::SourceCheckResult.new(**check.to_h, notices: [changed], weather_region_review_id: check.weather_region_review_id)
        result = @store.record(check: forged, source: @source)
        assert_equal :weather_acquisition_review_changed, result.error_code
        assert_nil @store.snapshot(source_key: "weather_warnings").last_success_at
      end

      test "byte identical empty bodies get a new prepared version after a reviewed region change" do
        refresh
        original = @store.snapshot(source_key: "weather_warnings")
        old_version, old_hash = original.source_version, original.content_hash
        write_review(region_label: "Druga autorska regija")
        assert_equal :prepared_source_version_changed, @store.check(keys: ["weather_warnings"]).sole.error_code
        assert_equal :empty, refresh.status
        assert_not_equal old_version, original.reload.source_version
        assert_equal old_hash, original.content_hash
        assert_equal review.identity, original.check_payload.fetch("weather_region_review_id")
      end

      test "scraper captures the organization review before HTTP and refuses a changed review before event writes" do
        result = scrape(fetcher: ->(**) { write_review(region_label: "Druga autorska regija"); response(feed(severity: "Severe")) })
        assert_not result.healthy?
        assert_equal 0, CityServiceEvent.where(organization: @organization, source_key: "weather_warnings").count
        assert_nil @store.snapshot(source_key: "weather_warnings").last_success_at
      end

      test "scraper refuses the wrong organization before calling HTTP" do
        write_review(organization_host: "other.example.invalid")
        calls = 0
        result = scrape(fetcher: ->(**) { calls += 1; response })
        assert_equal 0, calls
        assert_not result.healthy?
        assert_nil @store.snapshot(source_key: "weather_warnings").last_success_at
      end

      test "quiet scraper results retain the same identity through its typed clone and record" do
        result = scrape
        assert result.healthy?, result.error_code.to_s
        assert_equal "empty", result.status
        assert_equal review.identity, @store.snapshot(source_key: "weather_warnings").check_payload.fetch("weather_region_review_id")
        assert_equal "empty", read_weather.fetch(:status)
      end

      test "non weather version and manually recorded empty checks keep their previous contract" do
        source = CityServiceSources.fetch("public_transport")
        expected = Digest::SHA256.hexdigest(JSON.generate([CityServiceSourceCheckStore::PARSER_VERSION, source]))
        assert_equal expected, @store.version_for(source)
        check = CityServiceNoticeCollector::SourceCheckResult.new(source_key: "public_transport", status: :empty, notices: [], checked_at: @now)
        assert_same check, @store.record(check:, source:)
        assert_equal :empty, @store.check(keys: ["public_transport"]).sole.status
        assert_not @store.snapshot(source_key: "public_transport").check_payload.key?("weather_region_review_id")
      end
    end
  end
end
