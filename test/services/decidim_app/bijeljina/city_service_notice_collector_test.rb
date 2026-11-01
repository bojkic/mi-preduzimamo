# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/public_reference_source_registry"
require_relative "../../../support/synthetic_weather_region"

# Invented page bodies and measurements. Named city/station identifiers below
# exercise the reference adapter mappings, not real contacts or observations.

module DecidimApp
  module Bijeljina
    class CityServiceNoticeCollectorTest < ActiveSupport::TestCase
      include PublicReferenceSourceRegistry
      include SyntheticWeatherRegion

      setup do
        install_synthetic_weather_region
        write_synthetic_weather_region(source_url: CityServiceSources.fetch("weather_warnings").fetch(:source_url),
          reviewed_on: "2026-01-01", valid_until: "2026-12-31")
      end
      teardown { restore_synthetic_weather_region if @synthetic_weather_region_root }
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

      class RecordingDeadline
        attr_reader :calls

        def initialize(values)
          @values = values
          @calls = []
        end

        def remaining_seconds
          value = @values.shift || @calls.last
          @calls << value
          value
        end

        def expired?
          false
        end

        def deadline
          123.0
        end

        def within(_max_seconds)
          self
        end
      end

      test "filtered feeds reject navigation vacancies and expired campaigns without a title fallback" do
        cases = {
          "road_conditions" => "Управљајте опцијама",
          "civil_protection" => "ЈАВНИ КОНКУРС ЗА ПРИЈЕМ ПРИПРАВНИКА",
          "bulky_waste" => "ОДВОЖЕЊЕ КАБАСТОГ ОТПАДА У АПРИЛУ 2026.",
          "weather_warnings" => "MeteoAlarm"
        }
        cases.each do |key, title|
          html = "<html><title>#{title}</title><body><article><a href='/item'>#{title}</a></article></body></html>"
          check = CityServiceNoticeCollector.check(keys: [key], fetcher: fake_fetcher(body: html), now: Time.zone.parse("2026-09-09 12:00")).first
          assert_empty check.notices, key
          assert_equal(key == "weather_warnings" ? :malformed : :unreviewed, check.status, key)
          assert_equal :no_relevant_content, check.error_code, key unless key == "weather_warnings"
        end
      end

      test "regional response news and routine waste programs do not enter alert-specific feeds" do
        cases = {
          "civil_protection" => ["AKTIVNI POŽARI NA PODRUČJU TREBINJA", "Sastanak o zaštiti od požara u Vlasenici"],
          "bulky_waste" => ["Програм одвоза отпада за зону 2, Рејон 10"]
        }
        cases.each do |key, titles|
          html = titles.map.with_index { |title, i| "<article><a href='/item/#{i}'>#{title}</a></article>" }.join
          notices = CityServiceNoticeCollector.call(keys: [key], fetcher: fake_fetcher(body: html))
          assert_empty notices, key
        end
      end

      test "topic filtering occurs before limits and retains candidates for review only" do
        jobs = (1..25).map { |i| "<a href='/job/#{i}'>Javni konkurs za prijem pripravnika #{i}</a>" }.join
        html = "<article>#{jobs}<a href='/warning'>Upozorenje na poplave u Bijeljini</a></article>"
        notices = CityServiceNoticeCollector.call(keys: ["civil_protection"], fetcher: fake_fetcher(body: html), max_items: 1)
        assert_equal 1, notices.size
        assert_equal "Upozorenje na poplave u Bijeljini", notices.first.title
        assert_equal "review_candidate", notices.first.metadata["content_role"]
        assert_equal "unverified", notices.first.metadata["temporal_status"]
      end

      test "road paragraph extraction keeps local road evidence and drops consent text" do
        html = <<~HTML
          <article><p>Na putu Bijeljina–Rača saobraćaj je obustavljen zbog radova.</p></article>
          <div class='cookie-notice'><p>Upravljajte opcijama saobraćaj Bijeljina</p></div>
        HTML
        notices = CityServiceNoticeCollector.call(keys: ["road_conditions"], fetcher: fake_fetcher(body: html))
        assert_equal 1, notices.size
        assert_includes notices.first.body, "obustavljen"
        assert_not_includes notices.first.body, "Upravljajte"
      end

      test "collects normalized notice candidates from official html links" do
        html = <<~HTML
          <html>
            <body>
              <nav>
                <a href="/">VRATI ME NA SAJT</a>
              </nav>
              <article>
                <a href="/notice/1">Planirano iskljucenje struje u Izmišljenom vrtu</a>
                <p>Izmišljeni vrt, 20. juni od 09:00 do 12:00.</p>
              </article>
              <article>
                <a href="https://example.test/notice/2">Upozorenje na nevrijeme za Bijeljinu</a>
              </article>
            </body>
          </html>
        HTML

        notices = CityServiceNoticeCollector.call(
          keys: ["electricity_outages"],
          fetcher: fake_fetcher(body: html, final_url: "https://example.test/index.html"),
          now: Time.zone.parse("2026-06-19 12:00:00")
        )

        assert_equal 2, notices.size
        first = notices.first

        assert_equal "electricity_outages", first.source_key
        assert_equal "Planirano iskljucenje struje u Izmišljenom vrtu", first.title
        assert_equal "https://example.test/notice/1", first.url
        assert_match(/\A[a-f0-9]{24}\z/, first.fingerprint)
        assert_equal Time.zone.parse("2026-06-19 12:00:00"), first.fetched_at
      end

      test "returns fallback document notice for non-html sources" do
        notices = CityServiceNoticeCollector.call(
          keys: ["waste_schedule"],
          fetcher: fake_fetcher(body: "%PDF-1.7", content_type: "application/pdf")
        )

        assert_equal 1, notices.size
        assert_equal "Izmišljeni izvor waste_schedule", notices.first.title
        assert_includes notices.first.body, "source-specific parser"
      end

      test "returns no notices when source collection fails" do
        fetcher = lambda do |source:, timeout:, max_bytes:, user_agent:|
          raise "timeout #{source.fetch(:key)} #{timeout} #{max_bytes} #{user_agent}"
        end

        assert_equal [], CityServiceNoticeCollector.call(keys: ["water_service"], fetcher:)
      end

      test "check returns one immutable typed result per source while call stays an array" do
        checked_at = Time.zone.parse("2026-06-19 12:00:00")
        html = '<html><article><a href="/g1.pdf">G1 Bijeljina</a></article></html>'
        fetcher = fake_fetcher(body: html)

        result = CityServiceNoticeCollector.check(keys: ["public_transport"], fetcher:, now: checked_at).first

        assert_equal [:source_key, :status, :notices, :checked_at, :error_code], result.members
        assert_equal "public_transport", result.source_key
        assert_equal :ok, result.status
        assert_equal checked_at, result.checked_at
        assert_nil result.error_code
        assert result.frozen?
        assert result.notices.frozen?
        assert_kind_of Array, CityServiceNoticeCollector.call(keys: ["public_transport"], fetcher:, now: checked_at)
      end

      test "check distinguishes reviewed empty extraction from unreviewed generic collection" do
        checked_at = Time.zone.parse("2026-06-19 12:00:00")
        reviewed_empty = CityServiceNoticeCollector.check(
          keys: ["public_transport"],
          fetcher: fake_fetcher(body: "<html><h1>Red vožnje javnog prevoza</h1></html>"),
          now: checked_at
        ).first
        unreviewed = CityServiceNoticeCollector.check(
          keys: ["city_official_notices"],
          fetcher: fake_fetcher(body: '<html><article><a href="/news">Obavještenje</a></article></html>'),
          now: checked_at
        ).first

        assert_equal :empty, reviewed_empty.status
        assert_empty reviewed_empty.notices
        assert_equal checked_at, reviewed_empty.checked_at
        assert_equal :unreviewed, unreviewed.status
        assert_equal 1, unreviewed.notices.size
      end

      test "unrecognized reviewed-source layout is malformed rather than successful empty" do
        result = CityServiceNoticeCollector.check(
          keys: ["water_levels"],
          fetcher: fake_fetcher(body: "<html><h1>Unrelated replacement page</h1></html>"),
          now: Time.zone.parse("2026-06-19 12:00:00")
        ).first

        assert_equal :malformed, result.status
        assert_equal :parser_error, result.error_code
        assert_nil result.checked_at
      end

      test "failed and malformed checks never fabricate a verified check time" do
        failed = CityServiceNoticeCollector.check(
          keys: ["water_service"],
          fetcher: ->(**) { raise Net::ReadTimeout, "timed out" },
          now: Time.zone.parse("2026-06-19 12:00:00")
        ).first
        malformed = CityServiceNoticeCollector.check(
          keys: ["water_levels"],
          fetcher: fake_fetcher(body: ""),
          now: Time.zone.parse("2026-06-19 12:00:00")
        ).first

        assert_equal :unavailable, failed.status
        assert_equal :fetch_error, failed.error_code
        assert_nil failed.checked_at
        assert_equal :malformed, malformed.status
        assert_equal :empty_body, malformed.error_code
        assert_nil malformed.checked_at
      end

      test "check rejects an expired deadline before invoking the fetcher" do
        calls = 0
        result = CityServiceNoticeCollector.check(
          keys: ["water_levels"],
          deadline: TestDeadline.new(0),
          fetcher: ->(**) { calls += 1 }
        ).first

        assert_equal 0, calls
        assert_equal :unavailable, result.status
        assert_equal :deadline_exceeded, result.error_code
        assert_nil result.checked_at
      end

      test "check rejects numeric deadlines instead of treating monotonic absolutes as durations" do
        calls = 0
        result = CityServiceNoticeCollector.check(
          keys: ["water_levels"],
          deadline: 12_345.0,
          fetcher: ->(**) { calls += 1 }
        ).first

        assert_equal 0, calls
        assert_equal :unavailable, result.status
        assert_equal :invalid_deadline, result.error_code
      end

      test "whole source fetch is bounded by remaining deadline" do
        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result = CityServiceNoticeCollector.check(
          keys: ["water_levels"],
          deadline: TestDeadline.new(0.05),
          timeout: 1,
          fetcher: ->(**) { sleep 0.2 }
        ).first
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

        assert_operator elapsed, :<, 0.18
        assert_equal :unavailable, result.status
        assert_equal :deadline_exceeded, result.error_code
        assert_nil result.checked_at
      end

      test "redirects recompute the remaining deadline for network timeouts" do
        deadline = RecordingDeadline.new([2, 2, 2, 1.5, 1.0])
        redirect = Net::HTTPFound.new("1.1", "302", "Found")
        redirect["location"] = "/final"
        success = Net::HTTPOK.new("1.1", "200", "OK")
        success["content-type"] = "text/html"
        success.define_singleton_method(:read_body) { |&block| block.call('<html><a href="/g1.pdf">G1 Bijeljina</a></html>') }
        responses = [redirect, success]
        timeouts = []
        starter = lambda do |_host, _port, **options, &block|
          timeouts << options.fetch(:read_timeout)
          response = responses.shift
          http = Object.new
          http.define_singleton_method(:request) { |_request, &response_block| response_block.call(response) }
          block.call(http)
        end

        policy = Object.new
        policy.define_singleton_method(:before_request) { |_, timeout:| timeout }
        policy.define_singleton_method(:observe_response) { |_, _| nil }
        result = CitySourceRequestPolicy.stub(:default, policy) do
          Net::HTTP.stub(:start, starter) do
            CityServiceNoticeCollector.check(
              keys: ["public_transport"],
              deadline:,
              clock: -> { Time.zone.parse("2026-06-19 12:00") }
            ).first
          end
        end

        assert_equal :ok, result.status
        assert_equal [1.5, 1.0], timeouts
        assert_operator deadline.calls.size, :>=, 5
      end

      test "a redirect to the provider's own error page is source_unreachable, not a layout failure" do
        redirect = Net::HTTPFound.new("1.1", "302", "Found")
        redirect["location"] = "/PhpLogin/access-error.php"
        requested = []
        starter = lambda do |_host, _port, **_options, &block|
          http = Object.new
          http.define_singleton_method(:request) do |request, &response_block|
            requested << request.path
            response_block.call(redirect)
          end
          block.call(http)
        end
        policy = Object.new
        policy.define_singleton_method(:before_request) { |_, timeout:| timeout }
        policy.define_singleton_method(:observe_response) { |_, _| nil }
        check = CitySourceRequestPolicy.stub(:default, policy) do
          Net::HTTP.stub(:start, starter) do
            CityServiceNoticeCollector.check(keys: ["road_conditions"]).first
          end
        end

        assert_equal :unavailable, check.status
        assert_equal :source_unreachable, check.error_code
        assert_equal 1, requested.size, "the error page itself is not fetched"
      end

      test "source policy refusal is a failed fetch with its own reason not an empty feed" do
        fetcher = ->(**) { raise CitySourceRequestPolicy::PolicyError, :robots_disallowed }
        check = CityServiceNoticeCollector.check(keys: ["water_levels"], fetcher:).first
        assert_equal :unavailable, check.status
        assert_equal :robots_disallowed, check.error_code
        assert_nil check.checked_at
        assert_empty check.notices
      end

      test "future source observation is malformed rather than fresh evidence" do
        now = Time.zone.parse("2026-06-19 12:00:00")
        result = CityServiceNoticeCollector.check(
          keys: ["public_transport"],
          fetcher: fake_fetcher(body: '<html><a href="/g1.pdf">G1 Bijeljina</a></html>', checked_at: now + 1.second),
          clock: -> { now }
        ).first

        assert_equal :malformed, result.status
        assert_equal :invalid_checked_at, result.error_code
        assert_nil result.checked_at
      end

      test "typed result rejects an invalid successful check time" do
        assert_raises(ArgumentError, match: /typed checked_at/) do
          CityServiceNoticeCollector::SourceCheckResult.new(
            source_key: "water_levels",
            status: :empty,
            notices: [],
            checked_at: "not-a-time",
            error_code: nil
          )
        end
      end

      test "extracts current Drina and Sava water-level readings" do
        html = <<~HTML
          <html>
            <body>
              <nav><a href="/news">Najnovije vijesti koje nisu vodostaji</a></nav>
              <div class="okvircijena">
                Poslednji podatak: 30.06.2026 06:00h
                <h1 class="nazivartikla">Rijeka Drina (Radalj)</h1>
                <span class="cijenaKM">Vodostaj: 17cm <div class="vodkorekcija"><span class="malivodostaj">-1cm/1h</span></div></span>
                <div class="dodatnipodatak">Kota redovne odbrane od poplava: 700cm</div>
              </div>
              <div class="okvircijena">
                Poslednji podatak: 30.06.2026 06:00h
                <h1 class="nazivartikla">Rijeka Sava (Jamena)</h1>
                <span class="cijenaKM">Vodostaj: 271cm <div class="vodkorekcija"><span class="malivodostaj">0cm/1h</span></div></span>
                <div class="dodatnipodatak">Kota redovne odbrane od poplava: 1100cm</div>
              </div>
            </body>
          </html>
        HTML

        notices = CityServiceNoticeCollector.call(keys: ["water_levels"], fetcher: fake_fetcher(body: html))

        assert_equal 1, notices.size
        assert_includes notices.first.title, "Drina (Radalj) 17cm"
        assert_includes notices.first.title, "Sava (Jamena) 271cm"
        assert_includes notices.first.body, "Kota redovne odbrane od poplava: 700cm"
        assert_not_includes notices.first.body, "Najnovije vijesti"
      end

      test "extracts air-quality PDF reports instead of unrelated city links" do
        html = <<~HTML
          <html>
            <body>
              <nav><a href="/lat/1963.dnevni-red-sjednica-gik.html">Dnevni red sjednica GIK</a></nav>
              <article>
                <h1 class="single-post__entry-title">Podaci o kvalitetu vazduha u Gradu Bijeljina</h1>
                <a href="/UcitaneSlike/admin/Dokumenti/bn-26-28.06.26.pdf">26-28.6.2026.</a>
                <a href="/UcitaneSlike/admin/Dokumenti/bn-25.06.26.pdf">25.6.2026.</a>
              </article>
            </body>
          </html>
        HTML

        notices = CityServiceNoticeCollector.call(
          keys: ["air_quality"],
          fetcher: fake_fetcher(body: html, final_url: "https://www.gradbijeljina.org/lat/source.html")
        )

        assert_equal 2, notices.size
        assert_equal "Kvalitet vazduha: 26-28.6.2026.", notices.first.title
        assert_equal "https://www.gradbijeljina.org/UcitaneSlike/admin/Dokumenti/bn-26-28.06.26.pdf", notices.first.url
        assert_not_includes notices.map(&:title).join(" "), "Dnevni red"
      end

      test "extracts realtime Bijeljina air-quality value from Klimerko map data" do
        html = <<~HTML
          <html>
            <body>
              <p class="updated-at">Ažurirano 30. juna u 06:54</p>
              <script>
                kit.start(app, element, {
                  data: [{markers:{cities:new Map([
                    ["165",{id:"165",name:"Bijeljina",country:"Bosna i Hercegovina",value:14,aqiIndex:1,location:{latitude:0.1,longitude:0.2}}],
                    ["166",{id:"166",name:"Izmišljeni inostrani grad",country:"Srbija",value:7,aqiIndex:0,location:{latitude:0.1,longitude:0.2}}]
                  ])}}]
                });
              </script>
            </body>
          </html>
        HTML

        notices = CityServiceNoticeCollector.call(
          keys: ["air_quality_realtime"],
          fetcher: fake_fetcher(
            body: html,
            final_url: "https://klimerko.org/map?pollutant=pm2&range=latest&zoom=15&latitude=0.1&longitude=0.2"
          )
        )

        assert_equal 1, notices.size
        assert_equal "Kvalitet vazduha uživo: Bijeljina PM2.5 14 µg/m³ (dobro)", notices.first.title
        assert_includes notices.first.body, "Ažurirano 30. juna u 06:54"
        assert_includes notices.first.body, "koordinate: 0.1, 0.2"
        assert_not_includes notices.first.body, "Izmišljeni inostrani grad"
      end

      test "extracts public-transport route PDFs from the official article" do
        html = <<~HTML
          <html>
            <body>
              <article>
                <h1 class="single-post__entry-title">Raspored stajališta i red vožnje novog sistema javnog gradskog prevoza</h1>
                <a href="/synthetic/g1-example.pdf">G1 Izmišljeni vrt-Izmišljeno polje-Centar-Škola</a>
                <a href="/synthetic/p1-example.pdf">P1 Izmišljeni terminal-Centar-Izmišljeni vrt</a>
                <a href="/sr/news/novosti/7129.pocela-zetva-psenice.html">Počela žetva pšenice u Semberiji</a>
              </article>
            </body>
          </html>
        HTML

        notices = CityServiceNoticeCollector.call(
          keys: ["public_transport"],
          fetcher: fake_fetcher(body: html, final_url: "https://www.gradbijeljina.org/lat/source.html")
        )

        assert_equal 2, notices.size
        assert_equal "Javni prevoz: G1 Izmišljeni vrt-Izmišljeno polje-Centar-Škola", notices.first.title
        assert_includes notices.second.title, "P1 Izmišljeni terminal"
        assert_not_includes notices.map(&:title).join(" "), "žetva"
      end

      test "summarizes Sistem 48 public archive filters without raw citizen reports" do
        html = <<~HTML
          <html>
            <body>
              <form>
                <select name="tip_zahteva">
                  <option>-- SVE --</option>
                  <option>Komunalni problemi</option>
                  <option>Rasvjeta</option>
                </select>
                <select name="zahtevi_status">
                  <option>-- SVE --</option>
                  <option>Zahtjevi u obradi</option>
                  <option>Riješeni zahtjevi</option>
                </select>
                <select name="datum">
                  <option>Danas</option>
                  <option>Poslednjih 7 dana</option>
                </select>
              </form>
              <div class="prijava">Moja ulica ima problem ispred kuće.</div>
            </body>
          </html>
        HTML

        notices = CityServiceNoticeCollector.call(keys: ["sistem48_public_archive"], fetcher: fake_fetcher(body: html))

        assert_equal 1, notices.size
        assert_equal "Sistem 48 javni pregled: 2 vrsta problema", notices.first.title
        assert_includes notices.first.body, "Komunalni problemi"
        assert_includes notices.first.body, "Riješeni zahtjevi"
        assert_not_includes notices.first.body, "Moja ulica"
      end

      test "extracts PU Bijeljina contacts and actionable MUP service links" do
        html = <<~HTML
          <html>
            <body>
              <table>
                <tr><th>Naziv</th><th>Adresa</th><th>Grad</th><th>Telefon</th><th>Faks</th><th>E-mail</th></tr>
                <tr><td>PS BIJELjINA 1</td><td>Izmišljena adresa jedan</td><td>00000 Bijeljina</td><td>000/000-001</td><td></td><td>one@community.example.invalid</td></tr>
                <tr><td>PS JANjA</td><td>Izmišljena adresa dva</td><td>00000 Janja</td><td>000/000-002</td><td></td><td>two@community.example.invalid</td></tr>
                <tr><td>PS LOPARE</td><td>Izmišljena adresa tri</td><td>00000 Lopare</td><td>000/000-003</td><td></td><td>three@community.example.invalid</td></tr>
              </table>
              <a href="https://e-servisi-mup.vladars.rs/">eUsluge</a>
              <a href="https://mup.vladars.rs/lat/mup-servisi/provjera-dokumenata">Provjera nevažećih dokumenata</a>
              <a href="https://mup.vladars.rs/lat/mup-servisi/kamera">PU B.Luka izdavanje ličnih dokumenata</a>
            </body>
          </html>
        HTML

        notices = CityServiceNoticeCollector.call(keys: ["police_service_information"], fetcher: fake_fetcher(body: html))

        assert_equal 3, notices.size
        assert_equal "PU Bijeljina: policijske stanice i kontakti", notices.first.title
        assert_includes notices.first.body, "PS BIJELjINA 1"
        assert_includes notices.first.body, "PS JANjA"
        assert_not_includes notices.first.body, "PS LOPARE"
        assert_includes notices.map(&:title), "MUP RS servis: eUsluge"
        assert_not_includes notices.map(&:title).join(" "), "B.Luka"
      end

      test "identifies the civic collector honestly on official sources" do
        assert_equal CitySourceRequestPolicy::USER_AGENT, CityServiceNoticeCollector::DEFAULT_USER_AGENT
        assert_includes CityServiceNoticeCollector::DEFAULT_USER_AGENT, "MilicaSourceCollector/"
        assert_not_includes CityServiceNoticeCollector::DEFAULT_USER_AGENT, "Mozilla/"
        assert_nil CityServiceNoticeCollector::DEFAULT_CONTACT_EMAIL
        assert_nil CitySourceRequestPolicy.contact_email({})
      end

      test "does not parse non-success HTTP response bodies" do
        html = "<html><title>Error page that looks like news</title><a href=\"/notice\">False notice</a></html>"

        notices = CityServiceNoticeCollector.call(
          keys: ["city_official_notices"],
          fetcher: fake_fetcher(body: html, content_type: "text/html", http_status: 500)
        )

        assert_equal [], notices
      end

      private

      def fake_fetcher(body:, final_url: "https://example.test/source", content_type: "text/html", http_status: 200, checked_at: nil)
        lambda do |source:, timeout:, max_bytes:, user_agent:|
          assert source.fetch(:key).present?
          assert_operator timeout, :>, 0
          assert_operator max_bytes, :>, 0
          assert user_agent.present?

          result = {
            http_status:,
            final_url:,
            content_type:,
            body:
          }
          result[:checked_at] = checked_at if checked_at
          result
        end
      end
    end
  end
end
