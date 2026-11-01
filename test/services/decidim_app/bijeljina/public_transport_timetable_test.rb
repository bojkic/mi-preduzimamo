# frozen_string_literal: true

require "test_helper"

module DecidimApp
  module Bijeljina
    class PublicTransportTimetableTest < ActiveSupport::TestCase
      class DeadlineCountingTimetable < PublicTransportTimetable
        attr_reader :deadline_entries

        def initialize(...)
          @deadline_entries = 0
          super
        end

        private

        def within_deadline(...)
          @deadline_entries += 1
          super
        end
      end

      setup { Rails.cache.clear }

      test "answers a public transport journey from Janja to Dvorovi with transfer guidance" do
        timetable = PublicTransportTimetable.new(
          fetcher: ->(url) { url },
          text_extractor: ->(url) { { "https://source.example/p1.pdf" => p1_text, "https://source.example/p2.pdf" => p2_text }.fetch(url, "") },
          clock: -> { Time.zone.local(2026, 6, 30, 10, 0) },
          cache: false
        )

        answer = timetable.answer(
          text: "kako da javnim prevozom stignem od janje do dvorova",
          notices: [
            notice("P1", "P1 Nova AS-Centar-SŠC-Dvorovi-Trnjaci"),
            notice("P2", "P2 Nova AS-(SŠC)-Centar-Janja-Novo Naselje Janja")
          ]
        )

        assert_includes answer, "Najranija veza s presjedanjem"
        assert_includes answer, "P2"
        assert_includes answer, "presjed"
        assert_includes answer, "P1"
        assert_includes answer, "Janja (škola) u 12:35"
        assert_includes answer, "Bijeljina (NAS) oko 13:06"
        assert_includes answer, "Bijeljina (NAS) u 13:15"
        assert_includes answer, "Dvorovi"
        assert_includes answer, "Prema zvaničnim PDF redovima vožnje"
      end

      test "answers a public transport journey from Batkovići to Glavičice using the timetable matrix" do
        texts = {
          "https://source.example/p9.pdf" => p9_text,
          "https://source.example/p13.pdf" => p13_text
        }
        timetable = PublicTransportTimetable.new(
          fetcher: ->(url) { url },
          text_extractor: ->(url) { texts.fetch(url) },
          clock: -> { Time.zone.local(2026, 6, 30, 17, 31) },
          cache: false
        )

        answer = timetable.answer(
          text: "kako gradskim prevozom od batkovića do glavičica",
          notices: [
            notice("P9", "P9 Nova AS-Centar-SŠC-Batković-Ostojićevo-Klis"),
            notice("P13", "P13 Nova AS-(SŠC)-Centar-Janja-Glavičice-Bjeloševac-Kacevac-Banjica-Tavna")
          ]
        )

        assert_includes answer, "Najranija veza s presjedanjem"
        assert_includes answer, "P9"
        assert_includes answer, "Batković (Klis - prodavnica) u sutra 09:45"
        assert_includes answer, "Bijeljina (NAS) oko sutra 10:11"
        assert_includes answer, "P13"
        assert_includes answer, "Bijeljina (NAS) u sutra 10:50"
        assert_includes answer, "Glavičice (Ristić) oko sutra 11:32"
        assert_includes answer, "Presjedanje: Bijeljina (NAS)"
      end

      test "answers Ljeljenca to Janja tomorrow morning with transfer timing" do
        texts = {
          "https://source.example/p10.pdf" => p10_text,
          "https://source.example/p2.pdf" => p2_text,
          "https://source.example/p12.pdf" => p12_text
        }
        timetable = PublicTransportTimetable.new(
          fetcher: ->(url) { url },
          text_extractor: ->(url) { texts.fetch(url) },
          clock: -> { Time.zone.local(2026, 6, 30, 20, 49) },
          cache: false
        )

        answer = timetable.answer(
          text: "kako da dođem gradskim prevozom od ljeljenče do janje sutra ujutro",
          notices: [
            notice("P10", "P10 Nova AS-SŠC-ATC-Ljeljenča-S. Čađavica-G. Čađavica-Zabrđe"),
            notice("P2", "P2 Nova AS-(SŠC)-Centar-Janja-Novo Naselje Janja"),
            notice("P12", "P12 Nova AS-(SŠC)-Centar-Janja-Janjarska Obrijež-Čengić-Johovac")
          ]
        )

        assert_includes answer, "Najranija veza s presjedanjem"
        assert_includes answer, "P10"
        assert_includes answer, "Ljeljenča (izlaz) u sutra 06:37"
        assert_includes answer, "Bijeljina (NAS) oko sutra 07:05"
        assert_includes answer, "P2"
        assert_includes answer, "Bijeljina (NAS) u sutra 07:10"
        assert_includes answer, "Janja (centar) oko sutra 07:33"
        assert_includes answer, "Presjedanje: Bijeljina (NAS)"
        assert_not_includes answer, "Čađavica Srednja (škola)."
        assert_not_includes answer, "Našao sam"
      end

      test "morning journey cutoff uses Sarajevo when the application zone is UTC" do
        Time.use_zone("UTC") do
          texts = { "https://source.example/p10.pdf" => p10_text, "https://source.example/p2.pdf" => p2_text }
          timetable = PublicTransportTimetable.new(
            fetcher: ->(url) { url }, text_extractor: ->(url) { texts.fetch(url) },
            clock: -> { Time.utc(2026, 6, 30, 18, 49) }, cache: false
          )
          answer = timetable.answer(
            text: "kako da dođem gradskim prevozom od ljeljenče do janje sutra ujutro",
            notices: [
              notice("P10", "P10 Nova AS-SŠC-ATC-Ljeljenča-S. Čađavica-G. Čađavica-Zabrđe"),
              notice("P2", "P2 Nova AS-(SŠC)-Centar-Janja-Novo Naselje Janja")
            ]
          )

          assert_includes answer, "Ljeljenča (izlaz) u sutra 06:37"
          assert_includes answer, "Bijeljina (NAS) oko sutra 07:05"
          assert_includes answer, "Bijeljina (NAS) u sutra 07:10"
          assert_includes answer, "Janja (centar) oko sutra 07:33"
        end
      end

      test "answers next city transport from Janja to Ljeljenca as an origin-destination journey" do
        texts = {
          "https://source.example/p2.pdf" => p2_text,
          "https://source.example/p10.pdf" => p10_text
        }
        timetable = PublicTransportTimetable.new(
          fetcher: ->(url) { url },
          text_extractor: ->(url) { texts.fetch(url) },
          clock: -> { Time.zone.local(2026, 6, 30, 21, 45) },
          cache: false
        )

        answer = timetable.answer(
          text: "kada imam sljedeći gradski prevoz od janje do ljeljenče",
          notices: [
            notice("P2", "P2 Nova AS-(SŠC)-Centar-Janja-Novo Naselje Janja"),
            notice("P10", "P10 Nova AS-SŠC-ATC-Ljeljenča-S. Čađavica-G. Čađavica-Zabrđe")
          ]
        )

        assert_includes answer, "Najranija veza s presjedanjem"
        assert_includes answer, "P2"
        assert_includes answer, "Janja (škola) u sutra 07:55"
        assert_includes answer, "Bijeljina (NAS) oko sutra 08:19"
        assert_includes answer, "P10"
        assert_includes answer, "Bijeljina (NAS) u sutra 11:20"
        assert_includes answer, "Ljeljenča (ulaz) oko sutra 11:34"
        assert_includes answer, "Presjedanje: Bijeljina (NAS)"
        assert_not_includes answer, "Vučko"
        assert_not_includes answer, "P12"
        assert_not_includes answer, "P12 Bijeljina (NAS) u 4:40"
        assert_not_includes answer, "Našao sam ove redove vožnje/linije"
      end

      test "answers direct journey questions without the route inventory fallback" do
        timetable = PublicTransportTimetable.new(
          fetcher: ->(_url) { "p1" },
          text_extractor: ->(_body) { p1_text },
          clock: -> { Time.zone.local(2026, 6, 30, 10, 0) },
          cache: false
        )

        answer = timetable.answer(
          text: "kako da autobusom stignem iz centra do dvorova",
          notices: [
            notice("P1", "P1 Nova AS-Centar-SŠC-Dvorovi-Trnjaci"),
            notice("P2", "P2 Nova AS-(SŠC)-Centar-Janja-Novo Naselje Janja")
          ]
        )

        assert_includes answer, "Najranija direktna veza"
        assert_includes answer, "P1"
        assert_includes answer, "Bijeljina"
        assert_includes answer, "Dvorovi"
      end

      test "answers odavde journey questions by resolving the nearest timetable stop" do
        timetable = PublicTransportTimetable.new(
          fetcher: ->(_url) { "p1" },
          text_extractor: ->(_body) { p1_text },
          clock: -> { Time.zone.local(2026, 6, 30, 10, 0) },
          cache: false,
          stop_registry: precise_stop_registry
        )

        answer = timetable.answer(
          text: "kako odavde do dvorova javnim prevozom",
          notices: [notice("P1", "P1 Nova AS-Centar-SŠC-Dvorovi-Trnjaci")],
          location: { latitude: 44.7561, longitude: 19.2144 }
        )

        assert_includes answer, "Koristim najbliže stajalište: Bijeljina (Saborna crkva)"
        assert_includes answer, "Najranija direktna veza"
        assert_includes answer, "smjer prema Dvorovi (CSP)"
        assert_includes answer, "Bijeljina (Saborna crkva) u 11:34"
        assert_includes answer, "Dvorovi"
        assert_not_includes answer, "google.com/maps"
        assert_walking_maps_chip(
          answer.quick_replies,
          origin: "44.756100,19.214400",
          destination: "44.756100,19.214400"
        )
      end

      test "uses precise stop coordinates instead of rough central anchors" do
        timetable = PublicTransportTimetable.new(
          fetcher: ->(_url) { "p8" },
          text_extractor: ->(_body) { p8_text },
          clock: -> { Time.zone.local(2026, 6, 30, 10, 0) },
          cache: false,
          stop_registry: precise_stop_registry
        )

        answer = timetable.answer(
          text: "kako odavde do dvorova gradskim prevozom",
          notices: [notice("P8", "P8 Nova AS-Centar-SŠC-Dvorovi-Triješnica")],
          location: { latitude: 44.7594446, longitude: 19.2157649 }
        )

        assert_includes answer, "Koristim najbliže stajalište: Bijeljina (sud)"
        assert_includes answer, "P8"
        assert_includes answer, "Bijeljina (sud) u 11:32"
        assert_not_includes answer, "Bijeljina (SŠC)"
      end

      test "builds a route matrix with verified stop coordinates when registry is present" do
        timetable = PublicTransportTimetable.new(
          fetcher: ->(_url) { "p8" },
          text_extractor: ->(_body) { p8_text },
          clock: -> { Time.zone.local(2026, 6, 30, 10, 0) },
          cache: false,
          stop_registry: precise_stop_registry
        )

        route = timetable.matrix(notices: [notice("P8", "P8 Nova AS-Centar-SŠC-Dvorovi-Triješnica")]).first
        stop = route.directions.first.stops.find { |row| row.label == "Bijeljina (sud)" }

        assert_equal "P8", route.code
        assert_equal %w(5:32 7:42 11:32 13:12 15:32 19:12), stop.times
        assert_equal 44.7594446, stop.latitude
        assert_equal 19.2157649, stop.longitude
        assert_equal "test verified registry", stop.coordinates_source
        assert_equal "verified", stop.coordinates_accuracy
      end

      test "marks current-location routing with assumed coordinates as estimated" do
        timetable = PublicTransportTimetable.new(
          fetcher: ->(_url) { "p8" },
          text_extractor: ->(_body) { p8_text },
          clock: -> { Time.zone.local(2026, 6, 30, 10, 0) },
          cache: false,
          stop_registry: assumed_stop_registry
        )

        answer = timetable.answer(
          text: "kako odavde do dvorova gradskim prevozom",
          notices: [notice("P8", "P8 Nova AS-Centar-SŠC-Dvorovi-Triješnica")],
          location: { latitude: 44.7594446, longitude: 19.2157649 }
        )

        assert_includes answer, "Koristim najbliže procijenjeno stajalište: Bijeljina (sud)"
        assert_includes answer, "procijenjeno oko"
        assert_includes answer, "Najranija direktna veza"
      end

      test "marks user-provided current-location coordinates as mapped" do
        timetable = PublicTransportTimetable.new(
          fetcher: ->(_url) { "p8" },
          text_extractor: ->(_body) { p8_text },
          clock: -> { Time.zone.local(2026, 6, 30, 10, 0) },
          cache: false,
          stop_registry: provided_stop_registry
        )

        answer = timetable.answer(
          text: "kako odavde do dvorova gradskim prevozom",
          notices: [notice("P8", "P8 Nova AS-Centar-SŠC-Dvorovi-Triješnica")],
          location: { latitude: 44.7594446, longitude: 19.2157649 }
        )

        assert_includes answer, "Koristim najbliže mapirano stajalište: Bijeljina (sud)"
        assert_not_includes answer, "procijenjeno oko"
        assert_includes answer, "Najranija direktna veza"
      end

      test "prefers the nearby stop with the better actual itinerary" do
        timetable = PublicTransportTimetable.new(
          fetcher: ->(_url) { "p8" },
          text_extractor: ->(_body) { p8_with_spomenik_transfer_text },
          clock: -> { Time.zone.local(2026, 6, 30, 5, 0) },
          cache: false,
          stop_registry: provided_stop_registry
        )

        answer = timetable.answer(
          text: "kako odavde do dvorova gradskim prevozom",
          notices: [notice("P8", "P8 Nova AS-Centar-SŠC-Dvorovi-Triješnica")],
          location: { latitude: 44.7594446, longitude: 19.2157649 }
        )

        assert_includes answer, "Koristim najbliže mapirano stajalište: Bijeljina (sud)"
        assert_includes answer, "Najranija direktna veza"
        assert_includes answer, "Bijeljina (sud) u 05:32"
        assert_not_includes answer, "Presjedanje: Bijeljina (NAS)"
      end

      test "cleans fare and vehicle prefixes from parsed PDF stop labels" do
        timetable = PublicTransportTimetable.new(
          fetcher: ->(_url) { "pdf" },
          text_extractor: ->(_body) { parser_artifact_text },
          clock: -> { Time.zone.local(2026, 6, 30, 10, 0) },
          cache: false
        )

        labels = timetable.matrix(notices: [notice("P2", "P2 Nova AS-(SŠC)-Centar-Janja")])
                          .first
                          .directions
                          .flat_map { |direction| direction.stops.map(&:label) }

        assert_includes labels, "Bijeljina (NAS)"
        assert_includes labels, "Bijeljina (PiM škola)"
        assert_includes labels, "Koviljuše (škola)"
        assert_not(labels.any? { |label| label.start_with?("16,60") })
        assert_not(labels.any? { |label| label.start_with?("2 vozila") })
        assert_not(labels.any? { |label| label.start_with?("MINI ") })
      end

      test "asks for a named stop when no verified coordinate registry is available" do
        timetable = PublicTransportTimetable.new(
          fetcher: ->(_url) { raise "should not fetch route PDFs without verified coordinates" },
          text_extractor: ->(_body) { "" },
          clock: -> { Time.zone.local(2026, 6, 30, 10, 0) },
          cache: false,
          stop_registry: []
        )

        answer = timetable.answer(
          text: "kako odavde do dvorova gradskim prevozom",
          notices: [notice("P8", "P8 Nova AS-Centar-SŠC-Dvorovi-Triješnica")],
          location: { latitude: 44.7594446, longitude: 19.2157649 }
        )

        assert_includes answer, "Nemam provjerene koordinate stajališta"
        assert_includes answer, "najbliže stajalište"
        assert_not_includes answer, "Najranija direktna veza"
      end

      test "asks for location before answering odavde journey questions" do
        timetable = PublicTransportTimetable.new(
          fetcher: ->(_url) { raise "should not fetch without location" },
          text_extractor: ->(_body) { "" },
          clock: -> { Time.zone.local(2026, 6, 30, 10, 0) },
          cache: false
        )

        answer = timetable.answer(
          text: "kako odavde do dvorova javnim prevozom",
          notices: [notice("P1", "P1 Nova AS-Centar-SŠC-Dvorovi-Trnjaci")]
        )

        assert_includes answer, "treba mi lokacija"
        assert_includes answer, "najbliže stajalište"
      end

      test "asks for location for flexible odavde journey wording" do
        timetable = PublicTransportTimetable.new(
          fetcher: ->(_url) { raise "should not fetch without location" },
          text_extractor: ->(_body) { "" },
          clock: -> { Time.zone.local(2026, 6, 30, 10, 0) },
          cache: false
        )

        answer = timetable.answer(
          text: "Kako da odavde dođem gradskim prevozom do dvorova",
          notices: [notice("P1", "P1 Nova AS-Centar-SŠC-Dvorovi-Trnjaci")]
        )

        assert_includes answer, "treba mi lokacija"
        assert_includes answer, "najbliže stajalište"
        assert_not_includes answer, "Našao sam ove redove vožnje/linije"
      end

      test "answers flexible odavde journey wording when location is present" do
        timetable = PublicTransportTimetable.new(
          fetcher: ->(_url) { "p1" },
          text_extractor: ->(_body) { p1_text },
          clock: -> { Time.zone.local(2026, 6, 30, 10, 0) },
          cache: false,
          stop_registry: precise_stop_registry
        )

        answer = timetable.answer(
          text: "Kako da odavde dođem gradski prevozom do dvorova",
          notices: [notice("P1", "P1 Nova AS-Centar-SŠC-Dvorovi-Trnjaci")],
          location: { latitude: 44.7561, longitude: 19.2144 }
        )

        assert_includes answer, "Koristim najbliže stajalište: Bijeljina (Saborna crkva)"
        assert_includes answer, "Najranija direktna veza"
        assert_includes answer, "Dvorovi"
        assert_not_includes answer, "Našao sam ove redove vožnje/linije"
      end

      test "answers current-location starting stop questions without route inventory" do
        timetable = PublicTransportTimetable.new(
          fetcher: ->(_url) { raise "should not fetch route PDFs for nearest-stop lookup" },
          text_extractor: ->(_body) { "" },
          clock: -> { Time.zone.local(2026, 6, 30, 10, 0) },
          cache: false,
          stop_registry: precise_stop_registry
        )

        answer = timetable.answer(
          text: "Koristi moju lokaciju da predlozis pocetnu stanicu",
          notices: [notice("P1", "P1 Nova AS-Centar-SŠC-Dvorovi-Trnjaci")],
          location: { latitude: 44.7594446, longitude: 19.2157649 }
        )

        assert_includes answer, "Najbliže stajalište"
        assert_includes answer, "Bijeljina (sud)"
        assert_includes answer, "Smjer zavisi od odredišta"
        assert_includes answer, "kako odavde do Dvorova"
        assert_not_includes answer, "Našao sam ove redove vožnje/linije"
        assert_not_includes answer, "google.com/maps"
        assert_walking_maps_chip(
          answer.quick_replies,
          origin: "44.759445,19.215765",
          destination: "44.759445,19.215765"
        )
      end

      test "prefers a practical boarding stop over a marginally closer stop in the same cluster" do
        timetable = PublicTransportTimetable.new(
          fetcher: ->(_url) { raise "should not fetch route PDFs for nearest-stop lookup" },
          text_extractor: ->(_body) { "" },
          clock: -> { Time.zone.local(2026, 6, 30, 10, 0) },
          cache: false,
          stop_registry: [
            { label: "Bijeljina (spomenik)", latitude: 44.75699894318762, longitude: 19.216623648405786, accuracy: "provided" },
            { label: "Bijeljina (sud)", latitude: 44.756535187193094, longitude: 19.21607674029993, accuracy: "provided", nearest_priority: 10 }
          ]
        )

        answer = timetable.answer(
          text: "Koja je najbliža stanica za moju lokaciju?",
          notices: [notice("P1", "P1 Nova AS-Centar-SŠC-Dvorovi-Trnjaci")],
          location: { latitude: 44.7594446, longitude: 19.2157649 }
        )

        assert_includes answer, "Bijeljina (sud)"
        assert_not_includes answer, "Bijeljina (spomenik)"
        assert_walking_maps_chip(
          answer.quick_replies,
          origin: "44.759445,19.215765",
          destination: "44.756535,19.216077"
        )
      end

      test "asks for location before answering starting stop questions" do
        timetable = PublicTransportTimetable.new(
          fetcher: ->(_url) { raise "should not fetch without location" },
          text_extractor: ->(_body) { "" },
          clock: -> { Time.zone.local(2026, 6, 30, 10, 0) },
          cache: false
        )

        answer = timetable.answer(
          text: "Koja je najbliza pocetna stanica za moju lokaciju?",
          notices: [notice("P1", "P1 Nova AS-Centar-SŠC-Dvorovi-Trnjaci")]
        )

        assert_includes answer, "treba mi lokacija"
        assert_includes answer, "najbliže stajalište"
      end

      test "answers the next route-code departure from a center stop" do
        timetable = PublicTransportTimetable.new(
          fetcher: ->(_url) { "pdf" },
          text_extractor: ->(_body) { p2_text },
          clock: -> { Time.zone.local(2026, 6, 30, 12, 0) }
        )

        answer = timetable.answer(text: "P2 sljeddeći autobus iz centra za Janju", notices: [notice("P2", "P2 Nova AS-(SŠC)-Centar-Janja")])

        assert_includes answer, "P2"
        assert_includes answer, "Bijeljina (spomenik) u 13:23"
        assert_includes answer, "Janja (centar) oko"
        assert_includes answer, "naredni: 19:23"
        assert_includes answer, "odjeljku za traženi dan"
        assert_includes answer, "izuzeci za praznike i školski kalendar nisu provjereni"
      end

      test "infers a route from origin and destination and includes arrival when readable" do
        timetable = PublicTransportTimetable.new(
          fetcher: ->(_url) { "pdf" },
          text_extractor: ->(_body) { p1_text },
          clock: -> { Time.zone.local(2026, 6, 30, 10, 0) }
        )

        answer = timetable.answer(
          text: "kada ide sljedeći autobus iz centra grada za dvorove",
          notices: [notice("P1", "P1 Nova AS-Centar-SŠC-Dvorovi-Trnjaci")]
        )

        assert_includes answer, "P1"
        assert_includes answer, "Bijeljina (Saborna crkva) u 11:34"
        assert_includes answer, "Dvorovi (CSP) oko 11:43"
      end

      test "destination questions skip unrelated routes and already passed departures" do
        texts = {
          "https://source.example/p4.pdf" => p4_without_dvorovi_text,
          "https://source.example/p8.pdf" => p8_text,
          "https://source.example/p1.pdf" => p1_text
        }
        timetable = PublicTransportTimetable.new(
          fetcher: ->(url) { url },
          text_extractor: ->(url) { texts.fetch(url) },
          clock: -> { Time.zone.local(2026, 6, 30, 13, 20) }
        )

        answer = timetable.answer(
          text: "kada je sledeći prevoz iz Bijeljine u Dvorove",
          notices: [
            notice("P4", "P4 Bijeljina-Novo Selo"),
            notice("P8", "P8 Bijeljina-Dvorovi"),
            notice("P1", "P1 Nova AS-Centar-SŠC-Dvorovi-Trnjaci")
          ]
        )

        assert_includes answer, "P1 Bijeljina (NAS) u 15:15"
        assert_includes answer, "P8 Bijeljina (NAS) u 15:30"
        assert_not_includes answer, "P4"
        assert_not_includes answer, "13:10"
        assert_not_includes answer, "13:15"
      end

      test "returns nil for a broad route-list question" do
        timetable = PublicTransportTimetable.new(
          fetcher: ->(_url) { raise "should not fetch broad list" },
          text_extractor: ->(_body) { "" },
          clock: -> { Time.zone.local(2026, 6, 30, 10, 0) }
        )

        assert_nil timetable.answer(text: "gdje je red voznje javnog prevoza", notices: [notice("P1", "P1 Centar-Dvorovi")])
      end

      test "returns nil when a route PDF cannot be read" do
        timetable = PublicTransportTimetable.new(
          fetcher: ->(_url) { "not a pdf" },
          text_extractor: ->(_body) { raise PDF::Reader::MalformedPDFError, "bad pdf" },
          clock: -> { Time.zone.local(2026, 6, 30, 10, 0) }
        )

        assert_nil timetable.answer(text: "P1 sljedeci autobus iz centra", notices: [notice("P1", "P1 Centar-Dvorovi")])
      end

      test "returns a structured route with direction destination service time and source" do
        timetable = PublicTransportTimetable.new(
          fetcher: ->(_url) { "p1" },
          text_extractor: ->(_body) { p1_text },
          clock: -> { Time.zone.local(2026, 6, 30, 10, 0) },
          cache: false
        )

        result = timetable.query(
          origin: "Bijeljina (NAS)",
          destination: "Dvorovi",
          requested_at: Time.zone.local(2026, 6, 30, 10, 0),
          route_code: "P1",
          notices: [notice("P1", "P1 Nova AS-Centar-SŠC-Dvorovi-Trnjaci")]
        )

        assert_equal :ok, result.status
        assert_equal ["https://source.example/p1.pdf"], result.sources
        assert_equal "P1", result.itinerary.legs.first.route_code
        assert_equal "Bijeljina (NAS)", result.itinerary.legs.first.origin_label
        assert_equal "Dvorovi (CSP)", result.itinerary.legs.first.destination_label
        assert_equal "11:30", result.itinerary.legs.first.departure_at.strftime("%H:%M")
        assert_includes result.itinerary.legs.first.direction_label, "Dvorovi"
        assert_includes result.warnings, "timetable_not_live_vehicle_status"
      end

      test "does not apply the workday section to a Sarajevo weekend date" do
        timetable = PublicTransportTimetable.new(
          fetcher: ->(_url) { "fixture" },
          text_extractor: ->(_body) { p1_text },
          clock: -> { Time.zone.local(2026, 9, 5, 10, 0) },
          cache: false
        )

        result = timetable.query(
          origin: "Bijeljina (NAS)",
          destination: "Dvorovi",
          requested_at: Time.zone.local(2026, 9, 6, 10, 0),
          route_code: "P1",
          notices: [notice("P1", "P1 Nova AS-Centar-SŠC-Dvorovi-Trnjaci")]
        )

        assert_equal :unavailable, result.status
        assert_includes result.warnings, "unsupported_service_day"
      end

      test "does not turn a timed-out route fetch into an empty matrix" do
        timetable = PublicTransportTimetable.new(
          fetcher: lambda do |_url|
            sleep 0.1
            "p1"
          end,
          text_extractor: ->(_body) { p1_text },
          clock: -> { Time.zone.local(2026, 9, 5, 10, 0) },
          cache: false
        )
        notices = [notice("P1", "P1 Nova AS-Centar-SŠC-Dvorovi-Trnjaci")]
        deadline = Decidim::Bih::Concierge::Dialogue::TurnBudget.new(timeout: 0.02)
        result = :not_returned

        assert_raises(CityServiceNoticeCollector::DeadlineExceeded) do
          result = timetable.query(
            origin: "Bijeljina (NAS)",
            destination: "Dvorovi",
            requested_at: Time.zone.local(2026, 9, 4, 10, 0),
            route_code: "P1",
            notices:,
            deadline:
          )
        end
        assert_equal :not_returned, result
      end

      test "bounds one complete public matrix operation across multiple routes and parsing" do
        parsed = []
        timetable = PublicTransportTimetable.new(
          fetcher: ->(url) { url },
          text_extractor: lambda do |url|
            parsed << url
            sleep 0.5 if url.end_with?("/p2.pdf")
            url.end_with?("/p1.pdf") ? p1_text : p2_text
          end,
          clock: -> { Time.zone.local(2026, 9, 5, 10, 0) },
          cache: false
        )
        notices = [
          notice("P1", "P1 Nova AS-Centar-SŠC-Dvorovi-Trnjaci"),
          notice("P2", "P2 Nova AS-(SŠC)-Centar-Janja-Novo Naselje Janja")
        ]
        deadline = Decidim::Bih::Concierge::Dialogue::TurnBudget.new(timeout: 0.2)
        result = :not_returned

        assert_raises(CityServiceNoticeCollector::DeadlineExceeded) do
          result = timetable.matrix(notices:, deadline:)
        end
        assert_equal :not_returned, result
        assert_equal %w(https://source.example/p1.pdf https://source.example/p2.pdf), parsed
      end

      test "enters the deadline guard once per public matrix and query operation" do
        notices = [
          notice("P1", "P1 Nova AS-Centar-SŠC-Dvorovi-Trnjaci"),
          notice("P2", "P2 Nova AS-(SŠC)-Centar-Janja-Novo Naselje Janja")
        ]
        texts = {
          "https://source.example/p1.pdf" => p1_text,
          "https://source.example/p2.pdf" => p2_text
        }
        matrix_timetable = DeadlineCountingTimetable.new(
          fetcher: ->(url) { url }, text_extractor: ->(url) { texts.fetch(url) }, cache: false
        )
        matrix_deadline = Decidim::Bih::Concierge::Dialogue::TurnBudget.new(timeout: 1.0)

        assert_equal 2, matrix_timetable.matrix(notices:, deadline: matrix_deadline).length
        assert_equal 1, matrix_timetable.deadline_entries

        query_timetable = DeadlineCountingTimetable.new(
          fetcher: ->(_url) { "p1" }, text_extractor: ->(_body) { p1_text }, cache: false
        )
        query_deadline = Decidim::Bih::Concierge::Dialogue::TurnBudget.new(timeout: 1.0)
        query = query_timetable.query(
          origin: "Bijeljina (NAS)", destination: "Dvorovi",
          requested_at: Time.zone.local(2026, 9, 4, 10, 0), route_code: "P1",
          notices: notices.first(1), deadline: query_deadline
        )

        assert_equal :ok, query.status
        assert_equal 1, query_timetable.deadline_entries
      end

      test "marks current-location stop selection and assumed coordinates as uncertain" do
        timetable = PublicTransportTimetable.new(
          fetcher: ->(_url) { "p8" },
          text_extractor: ->(_body) { p8_text },
          clock: -> { Time.zone.local(2026, 6, 30, 10, 0) },
          cache: false,
          stop_registry: assumed_stop_registry
        )

        result = timetable.query(
          origin: nil,
          destination: "Dvorovi",
          requested_at: Time.zone.local(2026, 6, 30, 10, 0),
          route_code: "P8",
          notices: [notice("P8", "P8 Nova AS-Centar-SŠC-Dvorovi-Triješnica")],
          location: { latitude: 44.7565387, longitude: 19.2164754 }
        )

        assert_equal :ok, result.status
        assert_equal "Bijeljina (sud)", result.origin
        assert_includes result.warnings, "walking_distance_is_approximate"
        assert_includes result.warnings, "assumed_stop_coordinates"
        assert_equal "assumed", result.candidates.first.fetch("coverage").fetch("coordinate_accuracy")
        assert_includes result.candidates.first.fetch("warning_codes"), "assumed_stop_coordinates"
      end

      test "may choose a farther current-location stop for an earlier arrival" do
        timetable = PublicTransportTimetable.new(
          fetcher: ->(_url) { "p8" },
          text_extractor: ->(_body) { p8_choice_text },
          clock: -> { Time.zone.local(2026, 6, 30, 8, 0) },
          cache: false,
          stop_registry: [
            { label: "Bijeljina (bliže)", latitude: 44.7565387, longitude: 19.2164754, accuracy: "assumed" },
            { label: "Bijeljina (brža veza)", latitude: 44.7605, longitude: 19.2205, accuracy: "assumed" }
          ]
        )

        result = timetable.query(
          origin: nil,
          destination: "Dvorovi",
          requested_at: Time.zone.local(2026, 6, 30, 8, 0),
          route_code: "P8",
          notices: [notice("P8", "P8 Nova AS-Centar-SŠC-Dvorovi-Triješnica")],
          location: { latitude: 44.7565387, longitude: 19.2164754 }
        )

        assert_equal :ok, result.status
        assert_equal "Bijeljina (brža veza)", result.origin
        assert_equal "10:00", result.itinerary.legs.first.arrival_at.strftime("%H:%M")
      end

      test "requires an explicit destination and does not parse one from arbitrary text" do
        timetable = PublicTransportTimetable.new(
          fetcher: ->(_url) { raise "must not fetch without a destination" },
          cache: false
        )

        result = timetable.query(
          origin: "Centar",
          destination: nil,
          requested_at: Time.zone.local(2026, 6, 30, 10, 0),
          notices: [notice("P1", "P1 Nova AS-Centar-SŠC-Dvorovi-Trnjaci")]
        )

        assert_equal :ambiguous, result.status
        assert_equal ["transport_destination_required"], result.warnings
      end

      test "passes the shared budget object to deadline-aware timetable fetchers" do
        budget = Object.new
        budget.define_singleton_method(:deadline) { 1.0 }
        budget.define_singleton_method(:remaining_seconds) { 2.0 }
        budget.define_singleton_method(:expired?) { false }
        budget.define_singleton_method(:within) { |_seconds| budget }
        received = []
        timetable = PublicTransportTimetable.new(
          fetcher: lambda do |_url, deadline:|
            received << deadline
            "p1"
          end,
          text_extractor: ->(_body) { p1_text },
          clock: -> { Time.zone.local(2026, 6, 30, 10, 0) },
          cache: false
        )

        result = timetable.query(
          origin: "Bijeljina (NAS)",
          destination: "Dvorovi",
          notices: [notice("P1", "P1 Nova AS-Centar-SŠC-Dvorovi-Trnjaci")],
          deadline: budget
        )

        assert_equal :ok, result.status
        assert_equal [budget], received
      end

      # --- Wave 2 F: journey semantics on top of the structured query -------

      SARAJEVO = ActiveSupport::TimeZone["Europe/Sarajevo"]

      test "a strict structured query never returns the departure leaving this very minute" do
        at = SARAJEVO.local(2026, 6, 30, 7, 30)
        lenient = journey_timetable(p1_text, at).query(origin: "Bijeljina (NAS)", destination: "Dvorovi", requested_at: at, notices: [notice("P1", "P1 Nova AS-Dvorovi")])
        strict = journey_timetable(p1_text, at).query(origin: "Bijeljina (NAS)", destination: "Dvorovi", requested_at: at, notices: [notice("P1", "P1 Nova AS-Dvorovi")],
                                                      strict: true)

        assert_equal "07:30", lenient.itinerary.legs.first.departure_at.in_time_zone(SARAJEVO).strftime("%H:%M")
        assert_equal "11:30", strict.itinerary.legs.first.departure_at.in_time_zone(SARAJEVO).strftime("%H:%M")
        assert_equal false, strict.rolled_over
        assert_equal "2026-06-30", strict.service_date
        assert_equal "2026-06-30", strict.requested_service_date
      end

      test "a next-departure query returns at most two distinct options in departure order" do
        at = SARAJEVO.local(2026, 6, 30, 10, 0)
        result = journey_timetable(p1_text, at).query(origin: "Bijeljina (NAS)", destination: "Dvorovi", requested_at: at,
                                                      notices: [notice("P1", "P1 Nova AS-Dvorovi")], options: 5)

        assert_equal :ok, result.status
        assert_equal(%w(11:30 13:15), result.options.map { |option| option.legs.first.departure_at.in_time_zone(SARAJEVO).strftime("%H:%M") })
        assert_equal 1, result.alternatives.size
        single = journey_timetable(p1_text, at).query(origin: "Bijeljina (NAS)", destination: "Dvorovi", requested_at: at, notices: [notice("P1", "P1 Nova AS-Dvorovi")])
        assert_empty single.alternatives
      end

      test "the last-departure mode picks the latest departure still on the requested day" do
        at = SARAJEVO.local(2026, 6, 30, 10, 0)
        result = journey_timetable(p1_text, at).query(origin: "Bijeljina (NAS)", destination: "Dvorovi", requested_at: at,
                                                      notices: [notice("P1", "P1 Nova AS-Dvorovi")], mode: :last)

        assert_equal :ok, result.status
        assert_equal "19:15", result.itinerary.legs.first.departure_at.in_time_zone(SARAJEVO).strftime("%H:%M")
        assert_equal false, result.rolled_over
        assert_empty result.alternatives
      end

      test "rolls to the next service day when nothing is left today and says so" do
        at = SARAJEVO.local(2026, 6, 30, 21, 0) # Tuesday evening, last P1 left 19:15
        rolled = journey_timetable(p1_text, at).query(origin: "Bijeljina (NAS)", destination: "Dvorovi", requested_at: at,
                                                      notices: [notice("P1", "P1 Nova AS-Dvorovi")], roll_over: true, mode: :last)

        assert_equal :ok, rolled.status
        assert_equal "2026-07-01 05:30", rolled.itinerary.legs.first.departure_at.in_time_zone(SARAJEVO).strftime("%Y-%m-%d %H:%M")
        assert_equal true, rolled.rolled_over
        assert_equal "2026-06-30", rolled.requested_service_date
        assert_equal "2026-07-01", rolled.service_date
      end

      test "a Friday evening request rolls past an unsupported weekend day only when asked to" do
        at = SARAJEVO.local(2026, 7, 3, 22, 0) # Friday; the injected fixture has a workday section only
        plain = journey_timetable(p1_text, at).query(origin: "Bijeljina (NAS)", destination: "Dvorovi", requested_at: at, notices: [notice("P1", "P1 Nova AS-Dvorovi")])
        rolled = journey_timetable(p1_text, at).query(origin: "Bijeljina (NAS)", destination: "Dvorovi", requested_at: at, notices: [notice("P1", "P1 Nova AS-Dvorovi")],
                                                      roll_over: true)

        assert_equal :empty, plain.status
        # An injected fixture publishes no weekend section at all, so the rolled
        # request reports the unsupported day instead of pretending emptiness.
        assert_equal :unavailable, rolled.status
        assert_equal ["unsupported_service_day"], rolled.warnings
      end

      test "names the place that no reviewed stop label supports" do
        at = SARAJEVO.local(2026, 6, 30, 10, 0)
        timetable = journey_timetable(p1_text, at)
        notices = [notice("P1", "P1 Nova AS-Dvorovi")]

        origin = timetable.query(origin: "Karađorđeva", destination: "Dvorovi", requested_at: at, notices:)
        assert_equal :empty, origin.status
        assert_equal ["origin"], origin.unmatched
        assert_includes origin.warnings, "origin_not_in_reviewed_timetable"

        destination = timetable.query(origin: "Bijeljina (NAS)", destination: "Neprovjereno Mjesto", requested_at: at, notices:)
        assert_equal :empty, destination.status
        assert_equal ["destination"], destination.unmatched
        assert_includes destination.warnings, "destination_not_in_reviewed_timetable"
      end

      test "a street origin resolved to coordinates boards at the nearest reviewed stop with navigation" do
        at = SARAJEVO.local(2026, 6, 30, 10, 0)
        timetable = journey_timetable(p8_text, at, stop_registry: [
                                        { label: "Bijeljina (sud)", latitude: 44.756535, longitude: 19.216077, accuracy: "provided", source: "Reviewed registry" },
                                        { label: "Bijeljina (NAS)", latitude: 44.765175, longitude: 19.212140, accuracy: "provided", source: "Reviewed registry" }
                                      ])
        result = timetable.query(origin: nil, destination: "Bijeljina (SŠC)", requested_at: at, notices: [notice("P8", "P8 Nova AS-Dvorovi")],
                                 location: { "latitude" => 44.7571886, "longitude" => 19.2173723 }, options: 2)

        assert_equal :ok, result.status
        assert_equal "Bijeljina (sud)", result.origin
        assert_equal "Bijeljina (sud)", result.boarding_stop.fetch("text")
        assert_includes result.boarding_stop.fetch("destination"), "google.com/maps"
        assert_equal(%w(11:32 13:12), result.options.map { |option| option.legs.first.departure_at.in_time_zone(SARAJEVO).strftime("%H:%M") })
      end

      private

      def journey_timetable(text, at, stop_registry: nil)
        options = { fetcher: ->(_url) { text }, text_extractor: ->(body) { body }, clock: -> { at }, cache: false }
        options[:stop_registry] = stop_registry if stop_registry
        PublicTransportTimetable.new(**options)
      end

      def notice(code, title)
        CityServiceNoticeCollector::Notice.new(
          source_key: "public_transport",
          source_label: "Public transport",
          provider: "Grad Bijeljina",
          title: "Javni prevoz: #{title}",
          body: "",
          url: "https://source.example/#{code.downcase}.pdf",
          fingerprint: code,
          fetched_at: Time.current
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

      def p1_text
        <<~TEXT
          P1 NAS-Centar-SŠC-Dvorovi-Trnjaci
          Bijeljina (NAS)           1,10    5:30    7:30   11:30   13:15   15:15   19:15
          Bijeljina (Saborna crkva)  1,10    5:34    7:34   11:34   13:19   15:19   19:19            Brodac (Suvara) 2,00 6:26 8:26
          Dvorovi (CSP)             1,40    5:43    7:43   11:43   13:28   15:28   19:28            Trnjaci (centar) 1,10 6:42
        TEXT
      end

      def p8_text
        <<~TEXT
          P8 Bijeljina-Dvorovi
          Bijeljina (NAS)           1,00    5:30    7:40   11:30   13:10   15:30   19:10
          Bijeljina (sud)           1,05    5:32    7:42   11:32   13:12   15:32   19:12
          Bijeljina (Saborna crkva) 1,10    5:34    7:44   11:34   13:14   15:34   19:14
          Bijeljina (SŠC)           0,50    5:36    7:46   11:36   13:16   15:36   19:16
          Dvorovi (CSP)             1,40    5:43    7:53   11:43   13:23   15:43   19:23
        TEXT
      end

      def p8_choice_text
        <<~TEXT
          P8 Bijeljina-Dvorovi
          Bijeljina (bliže)       1,00    10:00    12:00
          Bijeljina (brža veza)   1,00    8:00     9:00
          Dvorovi (CSP)           1,40    11:00    10:00
        TEXT
      end

      def p8_with_spomenik_transfer_text
        <<~TEXT
          P8 Bijeljina-Dvorovi
          Radni dan                    Smjer A                        1       3                         Smjer B                    2       4
          Bijeljina (NAS)           1,00    5:30    7:30                   Dvorovi (CSP)             1,40    6:50    8:50
          Bijeljina (sud)           1,05    5:32    7:32                   Bijeljina (spomenik)      0,85    7:04    9:04
          Dvorovi (CSP)             1,40    5:43    7:43                   Bijeljina (NAS)           1,00    7:06    9:06
          Subota
        TEXT
      end

      def parser_artifact_text
        <<~TEXT
          P2 NAS-(SŠC)-Centar-Janja-Novo Naselje Janja
          Radni dan                    Smjer A                        1       3                         Smjer B                    2       4
                                                                 16,60   16,60                                           Bijeljina (NAS)         17,39    6:59   12:59
          2 vozila Bijeljina (PiM škola)       1,20    6:01    12:01                                              Bijeljina (centar)      1,20     7:09   13:09
          MINI Koviljuše (škola)               1,10    6:21    12:21
          Subota
        TEXT
      end

      def precise_stop_registry
        [
          { label: "Bijeljina (NAS)", latitude: 44.7615, longitude: 19.2195, source: "test verified registry" },
          { label: "Bijeljina (sud)", latitude: 44.7594446, longitude: 19.2157649, source: "test verified registry" },
          { label: "Bijeljina (Saborna crkva)", latitude: 44.7561, longitude: 19.2144, source: "test verified registry" },
          { label: "Bijeljina (SŠC)", latitude: 44.7602, longitude: 19.214, source: "test verified registry" },
          { label: "Bijeljina (spomenik)", latitude: 44.757, longitude: 19.2125, source: "test verified registry" },
          { label: "Bijeljina (bolnica)", latitude: 44.763, longitude: 19.2105, source: "test verified registry" }
        ]
      end

      def assumed_stop_registry
        [
          { label: "Bijeljina (NAS)", latitude: 44.7615, longitude: 19.2195, accuracy: "assumed", confidence: "low" },
          { label: "Bijeljina (sud)", latitude: 44.7565387, longitude: 19.2164754, accuracy: "assumed", confidence: "medium" },
          { label: "Bijeljina (Saborna crkva)", latitude: 44.7561, longitude: 19.2144, accuracy: "assumed", confidence: "medium" },
          { label: "Bijeljina (SŠC)", latitude: 44.7699884, longitude: 19.2260232, accuracy: "assumed", confidence: "medium" }
        ]
      end

      def provided_stop_registry
        [
          { label: "Bijeljina (spomenik)", latitude: 44.75699894318762, longitude: 19.216623648405786, accuracy: "provided", confidence: "high" },
          { label: "Bijeljina (sud)", latitude: 44.7565387, longitude: 19.2164754, accuracy: "provided", confidence: "high" },
          { label: "Bijeljina (Saborna crkva)", latitude: 44.7561, longitude: 19.2144, accuracy: "provided", confidence: "high" },
          { label: "Bijeljina (SŠC)", latitude: 44.7690556, longitude: 19.2254444, accuracy: "provided", confidence: "high" }
        ]
      end

      def p4_without_dvorovi_text
        <<~TEXT
          P4 Bijeljina-Novo Selo
          Bijeljina (NAS)           1,10    6:20   12:20   15:20   18:20
          Novo Selo                 1,10    6:45   12:45   15:45   18:45
        TEXT
      end

      def p2_text
        <<~TEXT
          P2 NAS-(SŠC)-Centar-Janja-Novo Naselje Janja
          Radni dan                    Smjer A                        1       3       5       7       9       11       13                 Smjer B                    2       4       6       8       10       12       14
          Bijeljina (NAS)             1,70    5:50    7:10   11:50   13:20   15:15   18:00   19:20                   Janja (centar)           1,50    6:36   7:56    12:36   14:06   16:01  18:46   20:06
          Bijeljina (spomenik)        0,85      /       /       /    13:23      /      /     19:23                   Janja (škola)            0,60    6:35   7:55    12:35   14:05   16:00  18:45   20:05
          Bijeljina (bolnica)         0,85    5:53    7:13   11:53   13:25   15:18   18:03   19:25                   Bijeljina (Vučko)        0,60    6:56   8:17    12:56   14:26   16:22  19:07   20:27
          Janja (centar)              0,70    6:13    7:33   12:13   13:44   15:38   18:23   19:44                   Bijeljina (NAS)         20,79    7:06   8:19    13:06   14:29   16:24  19:09   20:29
          Subota
        TEXT
      end

      def p10_text
        <<~TEXT
          P10 NAS-SŠC-ATC-Ljeljenča-S. Čađavica-G. Čađavica-Zabrđe
          Radni dan                    Smjer A                        1       3                         Smjer B                    2       4
          Bijeljina (NAS)             1,00    5:20    11:20                   Ljeljenča (izlaz)         1,30    6:37   12:37
          Ljeljenča (ulaz)            1,30    5:34    11:34                   Bijeljina (NAS)           1,00    7:05   13:05
          Čađavica Srednja (škola)    1,30    5:51    11:51
          Subota
        TEXT
      end

      def p12_text
        <<~TEXT
          P12 NAS-(SŠC)-Centar-Janja-Janjarska Obrijež-Čengić-Johovac
          Radni dan                    Smjer A                        1       3                         Smjer B                    2       4
          Bijeljina (NAS)             1,70    4:40    6:40                    Janja (škola)             0,60    6:02   8:07
          Janja (centar)              0,70    5:03    7:03                    Janja (centar)            0,60    6:03   8:08
          Subota
        TEXT
      end

      def p9_text
        <<~TEXT
          P9 NAS-Centar-SŠC-Batković-Ostojićevo-Klis
          Radni dan                    Smjer A                        1       3       5       7       9      11                         Smjer B                           2       4       6       8       10      12
          Bijeljina (NAS)          1,00    5:55    9:00   11:50   13:15   15:30   19:15             Batković (Klis - prodavnica)       1,60    6:40    9:45   12:35   14:00   16:15   20:00
          Bijeljina (SŠC)          0,55    6:01    9:06   11:56   13:21   15:36   19:21                   Batković (škola)             1,50    6:46    9:51   12:41   14:06   16:21   20:06
          Batković (škola)         2,10    6:15    9:20   12:10   13:35   15:50   19:35                    Bijeljina (SŠC)             1,80    7:00   10:05   12:55   14:20   16:35   20:20
          Batković (Klis - prodavnica)   19,60    6:34    9:39   12:29   13:54   16:09   19:54             Bijeljina (NAS)            13,20    7:06   10:11   13:01   14:26   16:41   20:26
          Subota
        TEXT
      end

      def p13_text
        <<~TEXT
          P13 NAS-(SŠC)-Centar-Janja-Glavičice-Bjeloševac-Kacevac-Banjica-Tavna
          Radni dan                    Smjer A (Š)                       1       3       5       7       9                      Smjer B (Š)                       2       4       6       8      10
          Bijeljina (NAS)           1,90    4:50   10:50   13:10   15:30   19:10                  Kacevac (izlaz)           2,10    5:55    11:55   14:20   16:35   20:20
          Janja (centar)            1,60    5:13   11:13   13:39   15:53   19:39                  Janja (centar)            1,50    6:36    12:36   15:01   17:16   21:01
          Glavičice (Ristić)         0,70    5:32   11:32   13:59   16:12   19:59                 Bijeljina (NAS)           38,60   7:06    13:06   15:24   17:39   21:24
          Subota
        TEXT
      end
    end
  end
end
