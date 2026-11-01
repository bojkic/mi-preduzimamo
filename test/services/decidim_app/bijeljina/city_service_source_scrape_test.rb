# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/public_reference_source_registry"
require_relative "../../../support/synthetic_weather_region"

# Invented page bodies and measurements. Named city/station identifiers below
# exercise the reference adapter mappings, not real contacts or observations.

module DecidimApp
  module Bijeljina
    class CityServiceSourceScrapeTest < ActiveSupport::TestCase
      include PublicReferenceSourceRegistry
      include SyntheticWeatherRegion
      include ActiveSupport::Testing::TimeHelpers

      setup do
        @organization = create_organization
        install_synthetic_weather_region
        write_synthetic_weather_region(organization_host: @organization.host,
          source_url: CityServiceSources.fetch("weather_warnings").fetch(:source_url),
          reviewed_on: "2026-01-01", valid_until: "2026-12-31",
          region_label: "Autorski region", community_label: "Autorska zajednica")
        @mz = Decidim::Bih::LocalArea.create!(
          organization: @organization,
          kind: "mz",
          slug: "mz-izmisljeni-vrt",
          name: { "sr" => "Izmišljeni vrt" }
        )
        Decidim::Bih::LocalArea.create!(
          organization: @organization,
          kind: "komsiluk",
          slug: "komsiluk-izmisljeni-vrt",
          name: { "sr" => "Izmišljeni vrt 1" },
          parent: @mz,
          primary_mz_slug: "mz-izmisljeni-vrt",
          overlapping_mz_slugs: ["mz-izmisljeni-vrt"]
        )
      end

      teardown do
        restore_synthetic_weather_region if @synthetic_weather_region_root
        travel_back
      end

      test "parser-backed scrape creates pending-review city-service events" do
        travel_to Time.zone.local(2026, 6, 29, 8, 0, 0) do
          results = scrape(keys: ["electricity_outages"], fetcher: fake_fetcher(electricity_html))

          assert_equal 1, results.size
          result = results.first
          assert_equal "electricity_outages", result.source_key
          assert_equal "ok", result.status, result.detail
          assert_equal "deterministic_event_parser", result.parser
          assert_equal 1, result.created
          assert_equal 1, CityServiceEvent.pending_review.count

          event = CityServiceEvent.last
          assert_equal @organization, event.organization
          assert_equal "planned_outage", event.event_type
          assert_includes event.affected_area_slugs, "mz-izmisljeni-vrt"
          assert_not_includes event.attributes.to_json, "<table>"
        end
      end

      test "collection-only scrape fetches unsupported sources without persisting events" do
        results = scrape(keys: ["public_transport"], fetcher: fake_fetcher(generic_links_html))

        assert_equal 1, results.size
        result = results.first
        assert_equal "public_transport", result.source_key
        assert_equal "ok", result.status
        assert_equal "collection_only", result.parser
        assert_equal 1, result.collected_count
        assert_equal 0, result.created
        assert_equal 0, CityServiceEvent.count
        assert_includes result.detail, "collection_only_notices=1"
        assert_includes result.detail, "sample=Javni prevoz: G1 Izmišljeni vrt-Izmišljeno polje-Centar-Škola"
      end

      test "transport preparation failure records bounded class diagnostics without asset URL" do
        url = "https://www.gradbijeljina.org/route.png?private=example"
        notice = Struct.new(:url).new(url)
        check = CityServiceNoticeCollector::SourceCheckResult.new(source_key: "public_transport", status: :ok,
                                                                  notices: [notice], checked_at: Time.current)
        timetable = Struct.new(:results) do
          def prepare(**)
            results
          end
        end.new([{ source_url: url, status: :unavailable, error_code: "Net::OpenTimeout" }])
        scraper = CityServiceSourceScrape.new(organization: @organization, fetcher: fake_fetcher(generic_links_html))

        PublicTransportTimetable.stub(:new, timetable) do
          partial = scraper.send(:prepare_transport_check, { key: "public_transport" }, check)
          diagnostics = scraper.instance_variable_get(:@transport_diagnostics)
          detail = scraper.send(:collection_only_detail, partial.notices, check: partial)

          assert_equal :timetable_preparation_failed, partial.error_code
          assert_equal "Net::OpenTimeout", diagnostics.dig("failures", 0, "error_class")
          assert_includes detail, Digest::SHA256.hexdigest(url)[0, 12]
          assert_not_includes detail, url
          assert_not_includes diagnostics.to_json, url
        end
      end

      test "generic collection is unreviewed rather than successful source health" do
        results = scrape(keys: ["waste_schedule"], fetcher: fake_fetcher("%PDF-1.7", content_type: "application/pdf"))
        result = results.first

        assert_equal "unreviewed", result.status
        assert_equal "collection_only", result.parser
        assert_equal 1, result.collected_count
        assert_not_nil result.checked_at
        assert_nil result.error_code
        assert_equal 0, CityServiceEvent.count
      end

      test "malformed collection-only content is not reported as successful empty collection" do
        result = scrape(keys: ["public_transport"], fetcher: fake_fetcher("")).first

        assert_equal "malformed", result.status
        assert_equal "empty_body", result.error_code
        assert_nil result.checked_at
        assert_equal 0, result.collected_count
        assert_equal 0, CityServiceEvent.count
      end

      test "provider error page redirect is recorded as source_unreachable" do
        fetcher = ->(**) { raise CityServiceNoticeCollector::ProviderErrorPage, "provider error page" }
        result = scrape(keys: ["road_conditions"], fetcher:, cadence: "hourly").first

        assert_equal "fail", result.status
        assert_equal "source_unreachable", result.error_code
      end

      test "scheduled scrape skips a muted source until muted_until, then fetches it again" do
        fetched = []
        recording = lambda do |source:, **|
          fetched << source.fetch(:key)
          { http_status: 200, final_url: source.fetch(:source_url), content_type: "text/html", body: "<html></html>" }
        end

        travel_to Time.zone.local(2026, 10, 21, 9) do
          scrape(keys: [], cadence: "hourly", fetcher: recording)
        end
        assert_not_includes fetched, "civil_protection"
        assert_includes fetched, "road_conditions"

        fetched.clear
        travel_to Time.zone.local(2026, 11, 22, 9) do
          scrape(keys: [], cadence: "hourly", fetcher: recording)
        end
        assert_includes fetched, "civil_protection"

        fetched.clear
        travel_to Time.zone.local(2026, 10, 21, 9) do
          scrape(keys: ["civil_protection"], cadence: "hourly", fetcher: recording)
        end
        assert_equal ["civil_protection"], fetched, "an explicit probe still reaches a muted source"
      end

      test "four-hourly scrape covers realtime air-quality source" do
        results = scrape(keys: [], cadence: "four_hourly", fetcher: fake_fetcher(klimerko_html))

        assert_equal 1, results.size
        result = results.first
        assert_equal "air_quality_realtime", result.source_key
        assert_equal "four_hourly", result.cadence
        assert_equal "collection_only", result.parser
        assert_equal 1, result.collected_count
        assert_includes result.detail, "Kvalitet vazduha uživo: Bijeljina PM2.5 14 µg/m³"
      end

      test "non-success source responses are isolated to a failed result" do
        results = scrape(
          keys: ["water_service"],
          fetcher: fake_fetcher("service unavailable", http_status: 503)
        )

        assert_equal 1, results.size
        assert_equal "fail", results.first.status
        assert_equal 503, results.first.http_status
        assert_nil results.first.checked_at
        assert_equal "http_error", results.first.error_code
        assert_equal 0, CityServiceEvent.count
      end

      # komunalacbn.com cuts Cyrillic excerpts at a byte count, so the page
      # carries a half character before "..." (live since 2026-09-20).
      test "parser-backed source survives a page with a truncated multibyte character" do
        truncated = "<html><div class='categoryBlog'><h2><a href='/a'>Одвожење кабастог отпада</a></h2>" \
                    "<p>Обавјештење о давању у закуп \xD1...</p></div></html>".dup.force_encoding(Encoding::UTF_8)

        result = scrape(keys: ["bulky_waste"], fetcher: fake_fetcher(truncated)).first

        assert_not_equal "scrape_error", result.error_code, result.detail
        assert_no_match(/Encoding/, result.detail.to_s)
      end

      test "formatted output is tab-separated and bounded" do
        results = scrape(keys: ["public_transport"], fetcher: fake_fetcher(generic_links_html))
        output = CityServiceSourceScrape.format(results)

        assert_includes output, "source\tcadence\tstatus\thttp_status\tparser"
        assert_includes output, "public_transport\tweekly\tok\t200\tcollection_only"
        assert_not_includes output, "<html>"
      end

      test "policy failures preserve durable reasons and backoff without retrying forbidden access" do
        calls = 0
        retry_at = Time.current + 60
        fetcher = lambda do |**|
          calls += 1
          raise CitySourceRequestPolicy::PolicyError.new(:source_host_backoff, retry_at:)
        end
        result = scrape(keys: ["electricity_outages"], fetcher:).first
        assert_equal 1, calls
        assert_equal "deferred", result.status
        assert_equal "source_host_backoff", result.error_code
        assert_not result.healthy?
        payload = DecidimApp::CityServiceSourceSnapshot.find_by!(source_key: "electricity_outages").check_payload
        assert_equal "source_host_backoff", payload["error_code"]
        assert_equal "deferred", payload.dig("collection", "outcome")
        assert_equal retry_at.iso8601, payload.dig("collection", "retry_at")
      end

      test "a provider blocking the collector is reported as blocked and does not fail the run" do
        fetcher = ->(**) { raise CitySourceRequestPolicy::PolicyError.new(:source_provider_blocked, retry_at: 1.day.from_now) }
        result = scrape(keys: ["sistem48_public_archive"], fetcher:).first

        assert_equal "blocked", result.status
        assert_equal "source_provider_blocked", result.error_code
        assert_not result.healthy?
        assert_not result.fails_run?
        assert CityServiceSourceScrape::Result.new(status: "fail", error_code: "scrape_error").fails_run?
      end

      test "healthy empty and awaiting review are successful collection but partial is not" do
        %w(ok empty unreviewed).each do |status|
          assert CityServiceSourceScrape::Result.new(status:).healthy?
          assert_not CityServiceSourceScrape::Result.new(status:, error_code: "partial_source_coverage").healthy?
        end
      end

      test "pacing contention retries within a bounded attempt count" do
        calls = 0
        fetcher = lambda do |**|
          calls += 1
          raise CitySourceRequestPolicy::PolicyError.new(:source_host_busy, retry_at: Time.current) if calls < 3

          { http_status: 200, body: electricity_html }
        end
        result = scrape(keys: ["electricity_outages"], fetcher:).first
        assert_equal 3, calls
        assert_nil result.error_code
      end

      # 2026-10-20 09:15 UTC: a yellow MeteoAlarm warning gave the typed reader
      # a notice but the board parser no event, and the combined check raised
      # "empty source check cannot have notices" every hour.
      test "a yellow-only weather feed refreshes answer evidence without a board event" do
        travel_to Time.zone.parse("2026-10-20T09:15:00Z") do
          result = scrape(keys: ["weather_warnings"], cadence: "hourly", fetcher: weather_fetcher(weather_alert(severity: "Moderate"))).first

          assert_nil result.error_code, result.detail
          assert_equal "empty", result.status
          assert result.healthy?
          assert_equal 0, result.collected_count
          assert_equal 0, CityServiceEvent.count
          snapshot = DecidimApp::CityServiceSourceSnapshot.find_by!(source_key: "weather_warnings")
          assert_equal "ok", snapshot.check_payload["status"]
          assert_equal "healthy", snapshot.check_payload.dig("collection", "outcome")
          assert_equal(["Moderate"], snapshot.check_payload["notices"].map { |notice| notice.dig("metadata", "provider_severity") })
          assert_equal Time.current.to_i, snapshot.last_success_at.to_i

          # Milica reads the prepared snapshot, not the scrape result.
          prepared = CityServiceSourceCheckStore.new.check(keys: ["weather_warnings"]).sole
          assert_equal :ok, prepared.status
          assert_nil prepared.error_code
          assert_equal "Moderate", prepared.notices.sole.metadata["provider_severity"]

          answer = Milica::SourceRead.new(source_checker: CityServiceSourceCheckStore.new, organization: @organization)
                                     .call(topic: "weather", context: milica_context, locale: "sr", entities: {})
          assert_equal "ok", answer[:status]
          fact = answer[:facts].sole
          assert_equal "Moderate", fact["provider_severity"]
          assert_equal "TEST-REGION-A", fact["provider_area_code"]
          assert_equal "Autorski region (Autorska zajednica)", fact["verified_region_label"]
          assert_equal CityServiceWeatherParser::BOARD_SEVERITIES, fact.dig("board_publication_policy", "eligible_severities")
        end
      end

      # The typed reader only trusts AMS paragraphs inside "article-container";
      # elsewhere its road notices are review candidates, not verified facts.
      test "road_conditions without a board event keeps unverified typed notices as unreviewed" do
        travel_to Time.zone.parse("2026-10-20T09:15:00Z") do
          result = scrape(keys: ["road_conditions"], cadence: "hourly", fetcher: fake_fetcher(quiet_roads_html)).first

          assert_nil result.error_code, result.detail
          assert_equal "empty", result.status
          assert_equal 0, CityServiceEvent.count
          snapshot = DecidimApp::CityServiceSourceSnapshot.find_by!(source_key: "road_conditions")
          assert_equal "unreviewed", snapshot.check_payload["status"]
          assert_nil snapshot.check_payload["error_code"]
          assert_equal "awaiting_review", snapshot.check_payload.dig("collection", "outcome")
          assert_match(/Bijeljine/, snapshot.check_payload["notices"].sole["body"])
          assert_equal Time.current.to_i, snapshot.last_success_at.to_i
        end
      end

      test "an orange warning still becomes one pending-review event while yellow stays answer evidence only" do
        travel_to Time.zone.parse("2026-10-20T09:15:00Z") do
          feed = [weather_alert(identifier: "yellow", severity: "Moderate"), weather_alert(identifier: "orange", severity: "Severe")]
          result = scrape(keys: ["weather_warnings"], cadence: "hourly", fetcher: weather_fetcher(*feed)).first

          assert_nil result.error_code, result.detail
          assert_equal "ok", result.status
          event = CityServiceEvent.sole
          assert event.pending_review?
          assert_equal "safety", event.severity
          snapshot = DecidimApp::CityServiceSourceSnapshot.find_by!(source_key: "weather_warnings")
          assert_equal "ok", snapshot.check_payload["status"]
          assert_equal %w(Moderate Severe), snapshot.check_payload["notices"].map { |notice| notice.dig("metadata", "provider_severity") }.sort
        end
      end

      test "a genuinely quiet weather feed is a healthy empty snapshot" do
        travel_to Time.zone.parse("2026-10-20T09:15:00Z") do
          result = scrape(keys: ["weather_warnings"], cadence: "hourly", fetcher: weather_fetcher).first

          assert_nil result.error_code, result.detail
          assert_equal "empty", result.status
          snapshot = DecidimApp::CityServiceSourceSnapshot.find_by!(source_key: "weather_warnings")
          assert_equal "empty", snapshot.check_payload["status"]
          assert_empty Array(snapshot.check_payload["notices"])
          assert_equal Time.current.to_i, snapshot.last_success_at.to_i
          assert_equal 0, CityServiceEvent.count
        end
      end

      test "a malformed weather feed fails without advancing the last good snapshot" do
        travel_to Time.zone.parse("2026-10-20T09:15:00Z") do
          scrape(keys: ["weather_warnings"], cadence: "hourly", fetcher: weather_fetcher(weather_alert(severity: "Moderate")))
        end
        travel_to Time.zone.parse("2026-10-20T10:15:00Z") do
          result = scrape(keys: ["weather_warnings"], cadence: "hourly", fetcher: fake_fetcher("{", content_type: "application/json")).first

          assert_equal "fail", result.status
          assert_not result.healthy?
          snapshot = DecidimApp::CityServiceSourceSnapshot.find_by!(source_key: "weather_warnings")
          assert_equal Time.zone.parse("2026-10-20T09:15:00Z").to_i, snapshot.last_success_at.to_i
          assert_equal(["Moderate"], snapshot.last_good_payload["notices"].map { |notice| notice.dig("metadata", "provider_severity") })
        end
      end

      %w(road_conditions civil_protection weather_warnings).each do |key|
        test "#{key}: typed notices without board events keep the typed notices and their status" do
          typed_notice = typed_notice(key, "typed")
          [:ok, :unreviewed].each do |typed_status|
            typed = check_result(key, typed_status, [typed_notice])
            check = typed_check(key, typed:, fallback: check_result(key, :empty, []))

            assert_equal typed_status, check.status
            assert_equal [typed_notice], check.notices
            assert_nil check.error_code
          end
        end

        test "#{key}: genuinely empty typed and board input stays empty" do
          check = typed_check(key, typed: check_result(key, :empty, []), fallback: check_result(key, :empty, []))

          assert_equal :empty, check.status
          assert_empty check.notices
          assert_nil check.error_code
        end

        test "#{key}: board events keep a healthy status with typed or event notices" do
          event_notice = typed_notice(key, "event")
          typed_notice = typed_notice(key, "typed")
          fallback = check_result(key, :ok, [event_notice])

          with_typed = typed_check(key, typed: check_result(key, :ok, [typed_notice]), fallback:)
          assert_equal :ok, with_typed.status
          assert_equal [typed_notice], with_typed.notices

          without_typed = typed_check(key, typed: check_result(key, :empty, []), fallback:)
          assert_equal :ok, without_typed.status
          assert_equal [event_notice], without_typed.notices
        end

        test "#{key}: partial extraction keeps typed evidence but stays partial" do
          typed_notice = typed_notice(key, "typed")
          fallback = check_result(key, :unreviewed, [], error_code: :partial_source_coverage)
          check = typed_check(key, typed: check_result(key, :ok, [typed_notice]), fallback:)

          assert_equal :unreviewed, check.status
          assert_equal :partial_source_coverage, check.error_code
          assert_equal [typed_notice], check.notices
        end

        test "#{key}: a typed reader error is reported rather than hidden by board health" do
          failed = check_result(key, :malformed, [], error_code: :parser_error)
          [check_result(key, :empty, []), check_result(key, :unreviewed, [], error_code: :partial_source_coverage)].each do |fallback|
            assert_equal failed, typed_check(key, typed: failed, fallback:)
          end
        end
      end

      test "bulky_waste: a complete empty listing stays empty without consulting the typed reader" do
        fallback = check_result("bulky_waste", :empty, [])
        scraper = CityServiceSourceScrape.new(organization: @organization, now: Time.current)
        check = CityServiceNoticeCollector.stub(:check, ->(**) { flunk "typed reader must not run" }) do
          scraper.send(:typed_source_check, CityServiceSources.fetch("bulky_waste"), response: { body: "", http_status: 200 }, fallback:)
        end

        assert_same fallback, check
      end

      test "bulky_waste: board events still take typed answer evidence" do
        typed_notice = typed_notice("bulky_waste", "typed")
        check = typed_check("bulky_waste", typed: check_result("bulky_waste", :ok, [typed_notice]),
                                           fallback: check_result("bulky_waste", :ok, [typed_notice("bulky_waste", "event")]))

        assert_equal :ok, check.status
        assert_equal [typed_notice], check.notices
      end

      private

      def typed_check(key, typed:, fallback:)
        scraper = CityServiceSourceScrape.new(organization: @organization, now: Time.current)
        result = CityServiceNoticeCollector.stub(:check, [typed]) do
          scraper.send(:typed_source_check, CityServiceSources.fetch(key), response: { body: "document", http_status: 200 }, fallback:)
        end
        assert_equal typed.weather_region_review_id, result.weather_region_review_id if key == "weather_warnings"
        result
      end

      def check_result(key, status, notices, error_code: nil)
        failed = [:unavailable, :malformed, :stale].include?(status)
        provenance = key == "weather_warnings" && !failed ? { weather_region_review_id: synthetic_scrape_weather_review.identity } : {}
        CityServiceNoticeCollector::SourceCheckResult.new(source_key: key, status:, notices:, error_code:,
                                                          checked_at: (Time.current unless failed), **provenance)
      end

      def typed_notice(key, fingerprint)
        source = CityServiceSources.fetch(key)
        CityServiceNoticeCollector::Notice.new(source_key: key, source_label: source.fetch(:label), provider: source.fetch(:provider),
                                               title: "Upozorenje #{fingerprint}", body: "Tekst #{fingerprint}", url: source.fetch(:source_url),
                                               fingerprint:, fetched_at: Time.current,
                                               metadata: { "kind" => "official_warning" }.merge(key == "weather_warnings" ? synthetic_scrape_weather_review.metadata : {}))
      end

      def synthetic_scrape_weather_review
        WeatherRegionConfiguration.for_source(source_url: CityServiceSources.fetch("weather_warnings").fetch(:source_url),
          day: Time.current.in_time_zone("Europe/Sarajevo").to_date)
      end

      def milica_context
        Struct.new(:now, :organization_id, :deadline, keyword_init: true) do
          def allows?(capability) = capability == "public_reads"
        end.new(now: Time.current, organization_id: @organization.id)
      end

      def quiet_roads_html
        <<~HTML
          <html>
            <body>
              <article>
                <h1>Stanje na putevima</h1>
                <p>Na putevima oko Bijeljine kolovoz je suv, a saobraćaj se odvija bez zastoja i prohodan je u svim pravcima.</p>
              </article>
            </body>
          </html>
        HTML
      end

      def weather_fetcher(*alerts)
        fake_fetcher(JSON.generate("warnings" => alerts.map { |alert| { "alert" => alert } }), content_type: "application/json")
      end

      def weather_alert(severity:, identifier: "warning-1")
        colour = severity == "Moderate" ? "žuto" : "narandžasto"
        { "identifier" => identifier, "sender" => "weather-authority.example.invalid", "sent" => "2026-10-20T06:00:00Z",
          "status" => "Actual", "scope" => "Public", "msgType" => "Alert",
          "info" => [{ "language" => "bs", "event" => "Vjetar #{colour} Upozorenje", "headline" => "Autorsko upozorenje za testni region",
                       "description" => "Jak vjetar.", "instruction" => "Budite pažljivi.", "severity" => severity,
                       "senderName" => "Reviewed meteorological authority", "effective" => "2026-10-20T06:00:00Z",
                       "onset" => "2026-10-20T08:00:00Z", "expires" => "2026-10-20T20:00:00Z",
                       "area" => [{ "areaDesc" => "Autorski provider region", "geocode" => [{ "valueName" => "EMMA_ID", "value" => "TEST-REGION-A" }] }] }] }
      end

      def scrape(keys:, fetcher:, cadence: "weekly")
        preparation = Object.new
        preparation.define_singleton_method(:prepare) do |notices:, deadline:|
          raise "preparation requires the shared background deadline" unless deadline

          notices.map { |notice| { source_url: notice.url, status: :ok } }
        end
        PublicTransportTimetable.stub(:new, preparation) do
          CityServiceSourceScrape.new(organization: @organization, fetcher:, now: Time.current)
                                 .call(cadence:, keys:)
        end
      end

      def fake_fetcher(body, http_status: 200, content_type: "text/html")
        lambda do |source:, timeout:, max_bytes:, user_agent:|
          assert source.fetch(:key).present?
          assert_operator timeout, :positive?
          assert_operator max_bytes, :positive?
          assert user_agent.present?

          {
            http_status:,
            final_url: source.fetch(:source_url),
            content_type:,
            body:
          }
        end
      end

      def electricity_html
        <<~HTML
          <html>
            <body>
              <p>29.06.2026.</p>
              <table>
                <tr>
                  <th>TJ</th><th>Objekat</th><th>Područje</th><th>Razlog</th><th>Početak</th><th>Završetak</th>
                </tr>
                <tr>
                  <td>Bijeljina</td>
                  <td>TS Izmišljeni vrt 1</td>
                  <td>Izmišljeni vrt, izlaz prema školi</td>
                  <td>Radovi</td>
                  <td>09:00</td>
                  <td>12:00</td>
                </tr>
              </table>
            </body>
          </html>
        HTML
      end

      def generic_links_html
        <<~HTML
          <html>
            <body>
              <article>
                <h1 class="single-post__entry-title">Raspored stajališta i red vožnje javnog gradskog prevoza</h1>
                <a href="/synthetic/g1-example.pdf">
                  G1 Izmišljeni vrt-Izmišljeno polje-Centar-Škola
                </a>
              </article>
            </body>
          </html>
        HTML
      end

      def klimerko_html
        <<~HTML
          <html>
            <body>
              <p class="updated-at">Ažurirano 30. juna u 06:54</p>
              <script>
                data: [{markers:{cities:new Map([
                  ["165",{id:"165",name:"Bijeljina",country:"Bosna i Hercegovina",value:14,aqiIndex:1,location:{latitude:0.1,longitude:0.2}}]
                ])}}]
              </script>
            </body>
          </html>
        HTML
      end
    end
  end
end
