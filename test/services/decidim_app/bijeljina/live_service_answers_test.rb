# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/synthetic_service_directory"

module DecidimApp
  module Bijeljina
    class LiveServiceAnswersTest < ActiveSupport::TestCase
      include SyntheticServiceDirectory
      include ActiveSupport::Testing::TimeHelpers

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

      class FakeCollector
        attr_reader :calls

        def initialize(notices, status: :ok, error_code: nil, checked_at: nil)
          @notices = notices
          @status = status
          @error_code = error_code
          @checked_at = checked_at
          @calls = []
        end

        def check(**options)
          @calls << options
          options.fetch(:keys).map do |source_key|
            matching = @notices.select { |notice| notice.source_key == source_key }
            status = @status == :ok && matching.empty? ? :empty : @status
            checked_at = @checked_at || @notices.filter_map(&:fetched_at).max
            CityServiceNoticeCollector::SourceCheckResult.new(
              source_key:,
              status:,
              notices: matching,
              checked_at: [:unavailable, :malformed, :stale].include?(status) ? nil : checked_at,
              error_code: @error_code
            )
          end
        end
      end

      class FakeTransportTimetable
        attr_reader :calls

        def initialize(answer, error: nil)
          @answer = answer
          @error = error
          @calls = []
        end

        def answer(text:, notices:, location: nil)
          @calls << { text:, notices:, location: }
          raise @error if @error

          @answer
        end
      end

      setup { Rails.cache.clear }

      test "answers air-quality questions with the realtime value, not just a link" do
        collector = FakeCollector.new(
          [
            notice(
              source_key: "air_quality_realtime",
              provider: "Klimerko",
              title: "Kvalitet vazduha uživo: Bijeljina PM2.5 13 µg/m³ (dobro)",
              body: "Klimerko PM2.5 za Bijeljinu: 13 µg/m³; kategorija: dobro",
              metadata: { "kind" => "air_quality_observation", "value" => 13, "unit" => "µg/m³", "pollutant" => "PM2.5" }
            ),
            notice(
              source_key: "air_quality",
              provider: "Grad Bijeljina",
              title: "Kvalitet vazduha: 26-28.6.2026.",
              url: "https://grad.example/report.pdf"
            )
          ]
        )

        answer = LiveServiceAnswers.new(collector:).answer(text: "kakav je kvalitet vazduha u Bijeljini?", locale: "sr")

        assert_includes answer, "Vrijeme mjerenja nije pouzdano navedeno"
        assert_includes answer, "PM2.5: 13 µg/m³"
        assert_includes answer, "Gradski izvještaji: 26-28.6.2026."
        assert_includes answer, "Izvor podataka: Klimerko; Grad Bijeljina; provjereno 30.06.2026. u 10:00."
        assert_not_includes answer, "https://"
        assert_equal %w(air_quality_realtime air_quality), collector.calls.first.fetch(:keys)
      end

      test "answers transport questions with route names instead of only the source URL" do
        collector = FakeCollector.new(
          [
            notice(source_key: "public_transport", title: "Javni prevoz: G1 Koviljuše-Intergaj-Centar-SŠC"),
            notice(source_key: "public_transport", title: "Javni prevoz: P1 Nova AS-Centar-Dvorovi")
          ]
        )

        answer = LiveServiceAnswers.new(collector:).answer(text: "gdje je red voznje javnog prevoza", locale: "sr")

        assert_includes answer, "G1 Koviljuše"
        assert_includes answer, "P1 Nova AS"
        assert_includes answer, "npr. G1 ili P1"
        assert_includes answer, "provjereno 30.06.2026. u 10:00"
        assert_not_includes answer, "https://"
      end

      test "answers public transport price questions without falling into the route list" do
        collector = FakeCollector.new([])

        answer = LiveServiceAnswers.new(collector:).answer(text: "koliko košta javni prevoz?", locale: "sr")

        assert_includes answer, "1,00 KM"
        assert_includes answer, "2,00 KM"
        assert_includes answer, "2,50 KM"
        assert_includes answer, "24 do 90 KM"
        assert_not_includes answer, "Našao sam ove redove vožnje/linije"
        assert_empty collector.calls
      end

      test "ignores previous unversioned public transport cache entries" do
        Rails.cache.write(
          "bijeljina/live-service-answers/public_transport/public_transport",
          [notice(source_key: "public_transport", title: "Javni prevoz: P1 Nova AS-Centar-Dvorovi")]
        )
        collector = FakeCollector.new(
          [
            notice(source_key: "public_transport", title: "Javni prevoz: P10 Nova AS-SŠC-ATC-Ljeljenča-S. Čađavica-G. Čađavica-Zabrđe", url: "https://source.example/p10.pdf"),
            notice(source_key: "public_transport", title: "Javni prevoz: P2 Nova AS-(SŠC)-Centar-Janja-Novo Naselje Janja", url: "https://source.example/p2.pdf")
          ]
        )
        timetable = FakeTransportTimetable.new("Najranija veza s presjedanjem koju čitam: P10; zatim P2.")

        answer = LiveServiceAnswers.new(collector:, transport_timetable: timetable).answer(
          text: "kako da dođem gradskim prevozom od ljeljenče do janje sutra ujutro",
          locale: "sr"
        )

        assert_includes answer, "P10; zatim P2"
        assert_not_includes answer, "Našao sam ove redove vožnje/linije"
        assert_equal 1, collector.calls.size
        assert_equal 30, collector.calls.first.fetch(:max_items)
        assert_equal 2, timetable.calls.first.fetch(:notices).size
      end

      test "answers public transport origin-destination questions with transfer guidance" do
        collector = FakeCollector.new(
          [
            notice(source_key: "public_transport", title: "Javni prevoz: P1 Nova AS-Centar-SŠC-Dvorovi-Trnjaci", url: "https://source.example/p1.pdf"),
            notice(source_key: "public_transport", title: "Javni prevoz: P2 Nova AS-(SŠC)-Centar-Janja-Novo Naselje Janja", url: "https://source.example/p2.pdf"),
            notice(source_key: "public_transport", title: "Javni prevoz: P8 Nova AS-Centar-SŠC-Dvorovi-Triješnica", url: "https://source.example/p8.pdf")
          ]
        )
        timetable = PublicTransportTimetable.new(
          fetcher: ->(url) { url },
          text_extractor: ->(url) { route_text_for(url) },
          clock: -> { Time.zone.local(2026, 6, 30, 10, 0) },
          cache: false
        )

        answer = LiveServiceAnswers.new(collector:, transport_timetable: timetable).answer(
          text: "kako da javnim prevozom stignem od janje do dvorova",
          locale: "sr"
        )

        assert_includes answer, "Najranija veza s presjedanjem"
        assert_includes answer, "P2"
        assert_includes answer, "presjed"
        assert_includes answer, "P1"
        assert_not_includes answer, "Našao sam ove redove vožnje/linije"
        assert_equal %w(public_transport), collector.calls.first.fetch(:keys)
      end

      test "passes transient location to the public transport timetable" do
        collector = FakeCollector.new(
          [
            notice(source_key: "public_transport", title: "Javni prevoz: P1 Nova AS-Centar-Dvorovi", url: "https://source.example/p1.pdf")
          ]
        )
        timetable = FakeTransportTimetable.new("Koristim najbliže stajalište: Bijeljina (Saborna crkva).")
        location = { latitude: 0.512345, longitude: 0.756789 }

        answer = LiveServiceAnswers.new(collector:, transport_timetable: timetable).answer(
          text: "kako odavde do dvorova javnim prevozom",
          locale: "sr",
          location:
        )

        assert_includes answer, "Bijeljina (Saborna crkva)"
        assert_equal location, timetable.calls.first.fetch(:location)
      end

      test "preserves walking maps quick reply for current-location transport answers" do
        collector = FakeCollector.new(
          [
            notice(source_key: "public_transport", title: "Javni prevoz: P1 Nova AS-Centar-Dvorovi", url: "https://source.example/p1.pdf")
          ]
        )
        timetable = PublicTransportTimetable.new(
          fetcher: ->(url) { url },
          text_extractor: ->(url) { route_text_for(url) },
          clock: -> { Time.zone.local(2026, 6, 30, 10, 0) },
          cache: false,
          stop_registry: [
            { label: "Bijeljina (NAS)", latitude: 44.76517465445327, longitude: 19.212139760636862, source: "test registry" }
          ]
        )

        answer = LiveServiceAnswers.new(collector:, transport_timetable: timetable).answer(
          text: "kako odavde do dvorova javnim prevozom",
          locale: "sr",
          location: { latitude: 44.76517465445327, longitude: 19.212139760636862 }
        )

        assert_includes answer, "Najranija direktna veza"
        assert_includes answer, "Izvor podataka: Grad Bijeljina"
        assert_not_includes answer, "google.com/maps"
        assert_walking_maps_chip(
          answer.quick_replies,
          origin: "44.765175,19.212140",
          destination: "44.765175,19.212140"
        )
      end

      test "routes current-location starting stop requests to the transport timetable" do
        collector = FakeCollector.new(
          [
            notice(source_key: "public_transport", title: "Javni prevoz: P1 Nova AS-Centar-Dvorovi", url: "https://source.example/p1.pdf")
          ]
        )
        timetable = FakeTransportTimetable.new("Najbliže stajalište koje trenutno mogu koristiti u redu vožnje je Bijeljina (SŠC).")
        location = { latitude: 44.7594446, longitude: 19.2157649 }

        answer = LiveServiceAnswers.new(collector:, transport_timetable: timetable).answer(
          text: "Koristi moju lokaciju da predložis početnu stanicu",
          locale: "sr",
          location:
        )

        assert_includes answer, "Bijeljina (SŠC)"
        assert_not_includes answer, "Našao sam ove redove vožnje/linije"
        assert_equal location, timetable.calls.first.fetch(:location)
      end

      test "answers Batkovici to Glavicice questions through the timetable matrix" do
        collector = FakeCollector.new(
          [
            notice(source_key: "public_transport", title: "Javni prevoz: P9 Nova AS-Centar-SŠC-Batković-Ostojićevo-Klis", url: "https://source.example/p9.pdf"),
            notice(source_key: "public_transport", title: "Javni prevoz: P13 Nova AS-(SŠC)-Centar-Janja-Glavičice-Bjeloševac-Kacevac-Banjica-Tavna", url: "https://source.example/p13.pdf")
          ]
        )
        timetable = PublicTransportTimetable.new(
          fetcher: ->(url) { url },
          text_extractor: ->(url) { route_text_for(url) },
          clock: -> { Time.zone.local(2026, 6, 30, 17, 31) },
          cache: false
        )

        answer = LiveServiceAnswers.new(collector:, transport_timetable: timetable).answer(
          text: "kako gradskim prevozom od batkovića do glavičica",
          locale: "sr"
        )

        assert_includes answer, "Najranija veza s presjedanjem"
        assert_includes answer, "P9"
        assert_includes answer, "Batković"
        assert_includes answer, "P13"
        assert_includes answer, "Glavičice"
        assert_not_includes answer, "Našao sam ove redove vožnje/linije"
      end

      test "answers Ljeljenca to Janja tomorrow morning through the timetable matrix" do
        collector = FakeCollector.new(
          [
            notice(source_key: "public_transport", title: "Javni prevoz: P10 Nova AS-SŠC-ATC-Ljeljenča-S. Čađavica-G. Čađavica-Zabrđe", url: "https://source.example/p10.pdf"),
            notice(source_key: "public_transport", title: "Javni prevoz: P2 Nova AS-(SŠC)-Centar-Janja-Novo Naselje Janja", url: "https://source.example/p2.pdf")
          ]
        )
        timetable = PublicTransportTimetable.new(
          fetcher: ->(url) { url },
          text_extractor: ->(url) { route_text_for(url) },
          clock: -> { Time.zone.local(2026, 6, 30, 20, 49) },
          cache: false
        )

        answer = LiveServiceAnswers.new(collector:, transport_timetable: timetable).answer(
          text: "kako da dođem gradskim prevozom od ljeljenče do janje sutra ujutro",
          locale: "sr"
        )

        assert_includes answer, "Najranija veza s presjedanjem"
        assert_includes answer, "P10"
        assert_includes answer, "Ljeljenča"
        assert_includes answer, "P2"
        assert_includes answer, "Janja"
        assert_includes answer, "sutra 07:10"
        assert_not_includes answer, "Našao sam ove redove vožnje/linije"
      end

      test "answers next city transport from Janja to Ljeljenca through the timetable matrix" do
        collector = FakeCollector.new(
          [
            notice(source_key: "public_transport", title: "Javni prevoz: P2 Nova AS-(SŠC)-Centar-Janja-Novo Naselje Janja", url: "https://source.example/p2.pdf"),
            notice(source_key: "public_transport", title: "Javni prevoz: P10 Nova AS-SŠC-ATC-Ljeljenča-S. Čađavica-G. Čađavica-Zabrđe", url: "https://source.example/p10.pdf")
          ]
        )
        timetable = PublicTransportTimetable.new(
          fetcher: ->(url) { url },
          text_extractor: ->(url) { route_text_for(url) },
          clock: -> { Time.zone.local(2026, 6, 30, 21, 45) },
          cache: false
        )

        answer = LiveServiceAnswers.new(collector:, transport_timetable: timetable).answer(
          text: "kada imam sljedeći gradski prevoz od janje do ljeljenče",
          locale: "sr"
        )

        assert_includes answer, "Najranija veza s presjedanjem"
        assert_includes answer, "P2"
        assert_includes answer, "Janja (centar) u sutra 07:56"
        assert_includes answer, "P10"
        assert_includes answer, "Ljeljenča"
        assert_not_includes answer, "Bijeljina (NAS) u 4:40, Janja"
        assert_not_includes answer, "Našao sam ove redove vožnje/linije"
      end

      test "answers parking street questions from the structured parking-zone overview" do
        install_synthetic_service_directory
        collector = FakeCollector.new([])

        answer = LiveServiceAnswers.new(collector:).answer(text: "kako da platim parking za ulicu izmišljeni javor?", locale: "sr")

        assert_includes answer, "Izmišljeni javor"
        assert_includes answer, "plava / II zona"
        assert_includes answer, "TEST-B"
        assert_includes answer, "0,95 KM/h"
        assert_empty collector.calls
      ensure
        restore_synthetic_service_directory
      end

      test "answers parking location questions with a bounded street/sign clarification" do
        install_synthetic_service_directory
        collector = FakeCollector.new([])

        answer = LiveServiceAnswers.new(collector:).answer(
          text: "kako da platim parking za ovu lokaciju?",
          locale: "sr",
          location: { latitude: 0.512345, longitude: 0.756789 }
        )

        assert_includes answer, "ne mogu pouzdano odrediti parking zonu samo iz koordinata"
        assert_includes answer, "Pošalji naziv ulice"
        assert_empty collector.calls
      ensure
        restore_synthetic_service_directory
      end

      test "answers current parking zone questions with a bounded street/sign clarification" do
        install_synthetic_service_directory
        collector = FakeCollector.new([])

        answer = LiveServiceAnswers.new(collector:).answer(
          text: "U kojoj sam parking zoni?",
          locale: "sr",
          location: { latitude: 0.512345, longitude: 0.756789 }
        )

        assert_includes answer, "ne mogu pouzdano odrediti parking zonu samo iz koordinata"
        assert_includes answer, "Pošalji naziv ulice"
        assert_empty collector.calls
      ensure
        restore_synthetic_service_directory
      end

      test "treats route-code follow-ups as transport questions" do
        collector = FakeCollector.new(
          [
            notice(source_key: "public_transport", title: "Javni prevoz: P2 Nova AS-(SŠC)-Centar-Janja")
          ]
        )
        timetable = FakeTransportTimetable.new("P2 Bijeljina (spomenik) u 13:23.")

        answer = LiveServiceAnswers.new(collector:, transport_timetable: timetable).answer(
          text: "P2 sljeddeći autobus iz centra",
          locale: "sr"
        )

        assert_includes answer, "P2 Bijeljina"
        assert_equal "P2 sljeddeći autobus iz centra", timetable.calls.first.fetch(:text)
        assert_equal %w(public_transport), collector.calls.first.fetch(:keys)
      end

      test "falls back to the transport route list when timetable parsing fails" do
        collector = FakeCollector.new(
          [
            notice(source_key: "public_transport", title: "Javni prevoz: P1 Nova AS-Centar-Dvorovi"),
            notice(source_key: "public_transport", title: "Javni prevoz: P2 Nova AS-Centar-Janja")
          ]
        )
        timetable = FakeTransportTimetable.new(nil, error: PDF::Reader::MalformedPDFError.new("bad pdf"))

        answer = LiveServiceAnswers.new(collector:, transport_timetable: timetable).answer(
          text: "P1 sljedeci autobus iz centra",
          locale: "sr"
        )

        assert_includes answer, "Našao sam ove redove vožnje/linije"
        assert_includes answer, "P1 Nova AS-Centar-Dvorovi"
        assert_includes answer, "P2 Nova AS-Centar-Janja"
        assert_includes answer, "provjereno 30.06.2026. u 10:00"
      end

      test "answers police questions with contacts and emergency guidance" do
        collector = FakeCollector.new(
          [
            notice(
              source_key: "police_service_information",
              provider: "MUP RS / PU Bijeljina",
              title: "PU Bijeljina: policijske stanice i kontakti",
              body: "Kontakti sa zvanične stranice PU Bijeljina: " \
                    "PS BIJELjINA 1, Neznanih junaka br. 73, 76300 Bijeljina, tel. 055/235-179 | " \
                    "PS JANjA, Karađorđeva br. 50, 76316 Janja, tel. 055/544-153"
            ),
            notice(source_key: "police_service_information", title: "MUP RS servis: eUsluge")
          ]
        )

        answer = LiveServiceAnswers.new(collector:).answer(text: "koji je telefon policijske stanice", locale: "sr")

        assert_includes answer, "PS BIJELjINA 1"
        assert_includes answer, "055/235-179"
        assert_includes answer, "Dostupni servisi: eUsluge."
        assert_includes answer, "Za hitne slučajeve zovi 122."
        assert_includes answer, "provjereno 30.06.2026. u 10:00"
      end

      test "localizes live answers to Cyrillic when the citizen writes Cyrillic" do
        collector = FakeCollector.new(
          [
            notice(
              source_key: "air_quality_realtime",
              provider: "Klimerko",
              title: "Kvalitet vazduha uživo: Bijeljina PM2.5 13 µg/m³ (dobro)",
              metadata: { "kind" => "air_quality_observation", "value" => 13, "unit" => "µg/m³", "pollutant" => "PM2.5" }
            )
          ]
        )

        answer = LiveServiceAnswers.new(collector:).answer(text: "какав је квалитет ваздуха", locale: "sr-Cyrl")

        assert_match(/\p{Cyrillic}/, answer)
        assert_includes answer, "Бијељина"
      end

      test "returns nil for unrelated questions so the normal directory can answer" do
        collector = FakeCollector.new([])

        assert_nil LiveServiceAnswers.new(collector:).answer(text: "izvod iz matične knjige", locale: "sr")
        assert_empty collector.calls
      end

      test "does not expose collector-internal fallback notices" do
        collector = FakeCollector.new(
          [
            notice(
              source_key: "sistem48_public_archive",
              title: "Sistem 48 public reports",
              body: "Source document requires a source-specific parser before automatic publication."
            )
          ]
        )

        answer = LiveServiceAnswers.new(collector:).answer(text: "šta ima u sistem 48", locale: "sr")

        assert_includes answer, "nemam odgovarajući javni pregled Sistema 48"
        assert_not_includes answer, "source-specific parser"
      end

      test "distinguishes reviewed empty results from source failure" do
        empty = FakeCollector.new([], status: :empty, checked_at: Time.zone.parse("2026-06-30 10:00"))
        failed = FakeCollector.new([], status: :unavailable, error_code: :fetch_error)

        empty_answer = LiveServiceAnswers.new(collector: empty).answer(text: "kakav je kvalitet vazduha", locale: "sr")
        failed_answer = LiveServiceAnswers.new(collector: failed).answer(text: "kakav je kvalitet vazduha", locale: "sr")

        assert_includes empty_answer, "nemam odgovarajući objavljeni podatak"
        assert_includes empty_answer, "nije potvrda"
        assert_not_includes empty_answer, "ne mogu dohvatiti"
        assert_includes failed_answer, "ne mogu dohvatiti"
      end

      test "stale evidence cannot be described as a reviewed empty result" do
        collector = FakeCollector.new([], status: :stale, error_code: :source_feed_stale)
        answer = LiveServiceAnswers.new(collector:).answer(text: "kakav je kvalitet vazduha", locale: "sr")
        assert_includes answer, "ne mogu dohvatiti"
        assert_not_includes answer, "nemam odgovarajući objavljeni podatak"
      end

      test "does not present unreviewed generic extraction as a source-backed answer" do
        collector = FakeCollector.new(
          [notice(source_key: "public_transport", title: "Javni prevoz: neprovjeren nacrt")],
          status: :unreviewed,
          checked_at: Time.zone.parse("2026-06-30 10:00")
        )

        answer = LiveServiceAnswers.new(collector:).answer(text: "red voznje javnog prevoza", locale: "sr")

        assert_includes answer, "još nemam u pouzdano pregledanom obliku"
        assert_not_includes answer, "neprovjeren nacrt"
      end

      test "passes the remaining deadline to source checks" do
        collector = FakeCollector.new([], status: :empty, checked_at: Time.zone.parse("2026-06-30 10:00"))
        deadline = TestDeadline.new(1.5)

        LiveServiceAnswers.new(collector:).answer(text: "vodostaj drine", locale: "sr", deadline:)

        assert_same deadline, collector.calls.first.fetch(:deadline)
      end

      test "numeric deadline is rejected without a source check" do
        collector = FakeCollector.new([], status: :empty, checked_at: Time.zone.parse("2026-06-30 10:00"))

        answer = LiveServiceAnswers.new(collector:).answer(text: "vodostaj drine", locale: "sr", deadline: 12_345.0)

        assert_includes answer, "ne mogu dohvatiti vodostaje"
        assert_empty collector.calls
      end

      test "future notice timestamp is not rendered as a successful check" do
        travel_to Time.zone.local(2026, 9, 5, 12, 0) do
          future_notice = notice(source_key: "water_levels", title: "Vodostaji: Drina 30cm")
          future_notice.fetched_at = 1.hour.from_now
          collector = FakeCollector.new([future_notice])

          answer = LiveServiceAnswers.new(collector:).answer(text: "vodostaj drine", locale: "sr")

          assert_not_includes answer, "provjereno 05.09.2026. u 13:00"
          assert_includes answer, "Izvor podataka: Grad Bijeljina."
        end
      end

      private

      def notice(source_key:, title:, provider: "Grad Bijeljina", body: "", url: "https://source.example", metadata: nil) # rubocop:disable Metrics/ParameterLists -- explicit contract fixture fields
        CityServiceNoticeCollector::Notice.new(
          source_key:,
          source_label: source_key,
          metadata:,
          provider:,
          title:,
          body:,
          url:,
          fingerprint: "abc123",
          fetched_at: Time.zone.parse("2026-06-30 10:00:00")
        )
      end

      def assert_walking_maps_chip(quick_replies, origin:, destination:)
        chip = Array(quick_replies).find do |reply|
          (reply[:label] || reply["label"]) == "Pješke do stajališta"
        end

        assert_not_nil chip, "expected a Google Maps walking quick reply"
        uri = URI.parse(chip[:url] || chip["url"])
        assert_equal "www.google.com", uri.host
        assert_equal "/maps/dir/", uri.path

        query = URI.decode_www_form(uri.query).to_h
        assert_equal "1", query.fetch("api")
        assert_equal origin, query.fetch("origin")
        assert_equal destination, query.fetch("destination")
        assert_equal "walking", query.fetch("travelmode")
      end

      def route_text_for(url)
        case url
        when %r{/p1\.pdf\z}
          <<~TEXT
            P1 NAS-Centar-SŠC-Dvorovi-Trnjaci
            Radni dan Smjer A 1 3 Smjer B 2 4
            Bijeljina (NAS) 1,00 11:30 15:15 Dvorovi (CSP) 1,50 12:53 16:38
            Dvorovi (CSP) 1,40 11:43 15:28 Bijeljina (NAS) 23,40 13:06 16:51
            Subota
          TEXT
        when %r{/p2\.pdf\z}
          <<~TEXT
            P2 NAS-(SŠC)-Centar-Janja-Novo Naselje Janja
            Radni dan Smjer A 1 3 Smjer B 2 4
            Bijeljina (NAS) 1,70 7:10 11:50 15:15 Janja (centar) 1,50 6:36 7:56 12:36 16:01
            Janja (centar) 0,70 7:33 12:13 15:38 Bijeljina (NAS) 20,79 7:06 8:19 13:06 16:24
            Subota
          TEXT
        when %r{/p10\.pdf\z}
          <<~TEXT
            P10 NAS-SŠC-ATC-Ljeljenča-S. Čađavica-G. Čađavica-Zabrđe
            Radni dan Smjer A 1 3 Smjer B 2 4
            Bijeljina (NAS) 1,00 5:20 11:20 Ljeljenča (izlaz) 1,30 6:37 12:37
            Ljeljenča (ulaz) 1,30 5:34 11:34 Bijeljina (NAS) 1,00 7:05 13:05
            Subota
          TEXT
        when %r{/p9\.pdf\z}
          <<~TEXT
            P9 NAS-Centar-SŠC-Batković-Ostojićevo-Klis
            Radni dan Smjer A 1 3 5 7 9 11 Smjer B 2 4 6 8 10 12
            Bijeljina (NAS) 1,00 5:55 9:00 11:50 13:15 15:30 19:15 Batković (Klis - prodavnica) 1,60 6:40 9:45 12:35 14:00 16:15 20:00
            Batković (Klis - prodavnica) 19,60 6:34 9:39 12:29 13:54 16:09 19:54 Bijeljina (NAS) 13,20 7:06 10:11 13:01 14:26 16:41 20:26
            Subota
          TEXT
        when %r{/p13\.pdf\z}
          <<~TEXT
            P13 NAS-(SŠC)-Centar-Janja-Glavičice-Bjeloševac-Kacevac-Banjica-Tavna
            Radni dan Smjer A 1 3 5 7 9 Smjer B 2 4 6 8 10
            Bijeljina (NAS) 1,90 4:50 10:50 13:10 15:30 19:10 Kacevac (izlaz) 2,10 5:55 11:55 14:20 16:35 20:20
            Glavičice (Ristić) 0,70 5:32 11:32 13:59 16:12 19:59 Bijeljina (NAS) 38,60 7:06 13:06 15:24 17:39 21:24
            Subota
          TEXT
        else
          ""
        end
      end
    end
  end
end
