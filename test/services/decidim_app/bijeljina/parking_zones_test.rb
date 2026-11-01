# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/synthetic_service_directory"

module DecidimApp
  module Bijeljina
    class ParkingZonesTest < ActiveSupport::TestCase
      include SyntheticServiceDirectory

      setup do
        install_synthetic_service_directory
        rows = ParkingZones::BUNDLED_STREET_ROWS.map(&:deep_dup)
        blue = rows.find { |row| row.fetch(:zone) == "blue" }
        blue.merge!(street_name: "Primjerava", normalized_street_name: "primjerava", aliases: ["primjerava"])
        rows << { street_name: "Primjerova", normalized_street_name: "primjerova", aliases: ["primjerova"],
                  zone: "red", segment_note: "Izmišljeni segment D." }
        swap_service_constant(ParkingZones, :BUNDLED_STREET_ROWS, rows.map(&:freeze).freeze)
        ParkingZones.reset!
        ParkingZoneStreet.delete_all if ParkingZones.table_available?
      end

      teardown do
        ParkingZones.reset!
        restore_synthetic_service_directory
      end

      test "uses the authored reviewed overview when the table is empty" do
        assert_equal 4, ParkingZones.street_count
        assert_includes ParkingZones.coverage_detail, "streets=4"
        assert_includes ParkingZones.coverage_detail, "red=2"
        assert_includes ParkingZones.coverage_detail, "blue=1"
      end

      test "can seed the table with the authored parking zone street rows" do
        assert_difference -> { ParkingZoneStreet.count }, 4 do
          assert_equal true, ParkingZones.seed_defaults!
        end

        row = ParkingZoneStreet.find_by!(normalized_street_name: "primjerava")
        assert_equal "Primjerava", row.street_name
        assert_equal "blue", row.zone
        assert_equal ParkingZones.source_url, row.source_url
      end

      test "looks up Primjerava as blue zone and Izmišljena breza as red zone" do
        nu = ParkingZones.default.lookup("kako da platim parking za ulicu primjerava?")
        kneginje = ParkingZones.default.lookup("koja je parking zona u ulici izmisljena breza?")

        assert_equal "blue", nu.fetch(:zone)
        assert_equal "Primjerava", nu.fetch(:street_name)
        assert_equal "red", kneginje.fetch(:zone)
        assert_equal "Izmišljena breza", kneginje.fetch(:street_name)
      end

      test "answers a street parking question with zone price and SMS" do
        answer = ParkingZones.default.answer(text: "kako da platim parking za ulicu primjerava?", locale: "sr")

        assert_includes answer, "Primjerava"
        assert_includes answer, "plava / II zona"
        assert_includes answer, "TEST-B"
        assert_includes answer, "0,95 KM/h"
        assert_includes answer, "TEST-D"
        assert_includes answer, "provjereno 14.09.2040"
      end

      test "answers a tariff question with every zone tariff" do
        answer = ParkingZones.default.answer(text: "koliko košta parking?", locale: "sr")

        assert_includes answer, "bijela / zona centar"
        assert_includes answer, "TEST-W"
        assert_includes answer, "crvena / I zona"
        assert_includes answer, "TEST-R"
        assert_includes answer, "plava / II zona"
        assert_includes answer, "TEST-B"
      end

      test "asks for street or zone sign when parking is requested for coordinates only" do
        answer = ParkingZones.default.answer(
          text: "kako da platim parking za ovu lokaciju?",
          locale: "sr",
          location: { latitude: 0.5001, longitude: 0.5021 }
        )

        assert_includes answer, "ne mogu pouzdano odrediti parking zonu samo iz koordinata"
        assert_includes answer, "Pošalji naziv ulice"
        assert_includes answer, "TEST-W"
        assert_includes answer, "TEST-R"
        assert_includes answer, "TEST-B"
      end

      test "asks for street or zone sign for current parking zone questions" do
        answer = ParkingZones.default.answer(
          text: "U kojoj sam parking zoni?",
          locale: "sr",
          location: { latitude: 0.5001, longitude: 0.5021 }
        )

        assert_includes answer, "ne mogu pouzdano odrediti parking zonu samo iz koordinata"
        assert_includes answer, "Pošalji naziv ulice"
        assert_not_includes answer, "Imam strukturirani pregled parking zona"
      end

      test "resolves a declined street name to its reviewed row" do
        lookup = ParkingZones.default

        assert_equal "Primjerova", lookup.lookup_named("Primjerove").fetch(:street_name)
        assert_equal "Primjerava", lookup.lookup_named("Primjeravoj").fetch(:street_name)
        assert_equal "Izmišljena breza", lookup.lookup_named("izmisljena breza").fetch(:street_name)
        assert_nil lookup.lookup_named("Nepoznata")
        assert_equal %w(primjerove primjerova), ParkingZones.name_forms("Primjerove").first(2)
        assert_empty ParkingZones.name_forms("")
      end

      test "the street summary carries the zone facts without the source sentence" do
        street = ParkingZones.default.lookup("primjerava")
        summary = ParkingZones.default.street_summary(street)

        assert_includes summary, "Primjerava"
        assert_includes summary, "plava / II zona"
        assert_includes summary, "TEST-B"
        assert_includes summary, "provjeri znak zone"
        assert_not_includes summary, "Izvor:"
        assert_not_includes summary, "http"
        assert_equal "#{summary} #{ParkingZones.default.send(:source_sentence, street)}", ParkingZones.default.send(:street_answer, street)
      end

      test "localizes parking answers to Cyrillic" do
        answer = ParkingZones.default.answer(text: "parking zona primjerava", locale: "sr-Cyrl")

        assert_match(/\p{Cyrillic}/, answer)
        assert_includes answer, "Примјерава"
      end

      # --- Wave 2 F: the typed read port resolves a zone from a street name ---

      test "the read port answers a named street with its zone, SMS number and price" do
        result = parking_read({ "query" => "koja je parking zona u ulici Primjerava" })

        assert_equal "ok", result.status
        fact = result.facts.fetch(0)
        assert_equal "parking_zone", fact.fetch("kind")
        assert_includes fact.fetch("text"), "Primjerava"
        assert_includes fact.fetch("text"), "plava / II zona"
        assert_includes fact.fetch("text"), "TEST-B"
        assert_not_includes fact.fetch("text"), "http"
        assert_equal ParkingZones::SOURCE_URL, fact.fetch("source_url")
        assert_equal "blue", result.coverage.fetch("zone")
        assert_equal false, result.validity.fetch("live_status")
      end

      test "a declined street name in the area slot resolves through the reviewed rows" do
        result = parking_read({ "area_query" => "Primjerove", "query" => "u kojoj zoni je ta ulica" })

        assert_equal "ok", result.status
        assert_equal "red", result.coverage.fetch("zone")
        assert_includes result.facts.fetch(0).fetch("text"), "crvena / I zona"
        assert_includes result.facts.fetch(0).fetch("text"), "TEST-R"
      end

      test "an unknown street is asked for by name first and the sign colour second" do
        first = parking_read({ "query" => "koja je parking zona u ulici Nepoznata" })
        second = parking_read({ "area_query" => "Nepoznata", "query" => "koja je parking zona u ulici Nepoznata" })

        assert_equal "ambiguous", first.status
        assert_equal ["parking_street_not_in_reviewed_catalog"], first.warnings
        assert_equal "ambiguous", second.status
        assert_equal ["parking_street_not_in_reviewed_catalog"], second.warnings
      end

      test "location-only and colour questions keep their existing answers" do
        location = { latitude: 0.5001, longitude: 0.5021, accuracy: 20, consent: true, purpose: "current_location", provenance: "browser_geolocation" }
        located = parking_read({ "query" => "U kojoj sam parking zoni?" }, location:)
        blue = parking_read({ "query" => "koliko kosta parking u plavoj zoni na ulici" })

        assert_equal ["parking_zone_required"], located.warnings
        assert_equal "ok", blue.status
        assert_equal "service_directory", blue.facts.fetch(0).fetch("kind")
      end

      test "a cyrillic street question gets a cyrillic zone answer" do
        result = parking_read({ "query" => "Која је зона у улици Примјерава" }, locale: "sr-Cyrl")

        assert_equal "ok", result.status
        assert_match(/\p{Cyrillic}/, result.facts.fetch(0).fetch("text"))
        assert_includes result.facts.fetch(0).fetch("text"), "Примјерава"
      end

      private

      def parking_read(entities, location: nil, locale: "sr")
        @organization ||= create_organization
        port = Milica::ReadPort.new(organization: @organization)
        context = Decidim::Bih::Concierge::Dialogue::Contracts::TrustedContext.new(
          organization_id: @organization.id, conversation_key: "b" * 64, now: Time.utc(2040, 9, 16, 10), capabilities: ["public_reads"]
        )
        port.call(action: "ask_information", topic: "parking", entities:, context:, locale:, location:)
      end
    end
  end
end
