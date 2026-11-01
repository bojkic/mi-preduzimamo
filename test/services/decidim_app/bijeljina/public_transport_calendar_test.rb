# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/public_reference_source_registry"

module DecidimApp
  module Bijeljina
    class PublicTransportCalendarTest < ActiveSupport::TestCase
      include PublicReferenceSourceRegistry

      # Authored text tables only: no captured provider documents or local data.
      SYNTHETIC_ROUTES = %w(g1 p2 p12).freeze

      setup do
        DecidimApp::CityServiceSourceSnapshot.delete_all
        @now = Time.utc(2026, 9, 9, 10)
        @store = CityServiceSourceCheckStore.new(clock: -> { @now })
      end

      test "authored documents preserve named section and empty Sunday evidence" do
        SYNTHETIC_ROUTES.map { |code| synthetic_source(code) }.each do |source|
          sections = PublicTransportCalendar.sections(synthetic_document(source.fetch("fixture")), source_url: source.fetch("url"))
          assert_equal %w(workday saturday sunday), sections.map { |section| section.fetch("kind") }, source.fetch("fixture")
          assert_equal "available", sections[1].fetch("status")
          assert_equal "no_departures_published", sections[2].fetch("status")
          assert_equal(source.fetch("school_symbol_unexplained") ? "unreviewed" : "available", sections.first.fetch("status"))
          assert_equal 1, sections.first.fetch("source_page")
        end
      end

      test "synthetic G1 Saturday selects its own departures and Sunday stays explicitly empty" do
        notice, reader = prepare_route("g1")
        saturday = reader.query(origin: "Bijeljina (NAS)", destination: "Primjerpark", notices: [notice], requested_at: Time.utc(2026, 9, 12, 12))
        assert_equal :ok, saturday.status
        assert_equal "saturday", saturday.itinerary.legs.first.calendar.fetch("kind")
        assert_equal "Subota", saturday.itinerary.legs.first.calendar.fetch("source_heading")
        assert_equal "14:25", saturday.itinerary.legs.first.departure_at.in_time_zone("Europe/Sarajevo").strftime("%H:%M")
        sunday = reader.query(origin: "Bijeljina (NAS)", destination: "Primjerpark", notices: [notice], requested_at: Time.utc(2026, 9, 13, 10))
        assert_equal :empty, sunday.status
        assert_includes sunday.warnings, "no_departures_published_for_service_day"
      end

      test "synthetic P12 unexplained school mark blocks weekday inference while Saturday remains prepared" do
        notice, reader = prepare_route("p12")
        result = reader.query(origin: "Bijeljina (NAS)", destination: "Primjerpolje (centar)", notices: [notice], requested_at: @now)
        assert_equal :unreviewed, result.status
        assert_includes result.warnings, "service_calendar_requires_review"
        saturday = reader.query(origin: "Bijeljina (NAS)", destination: "Primjerpolje (centar)", notices: [notice], requested_at: Time.utc(2026, 9, 12, 8))
        assert_equal :ok, saturday.status
        assert_equal "saturday", saturday.itinerary.legs.first.calendar.fetch("kind")
        assert_equal "Bijeljina (NAS)", saturday.itinerary.legs.first.origin_label
        assert_equal "Primjerpolje (centar)", saturday.itinerary.legs.last.destination_label
      end

      test "named holiday and school sections do not invent a calendar of exceptional dates" do
        text = "P1\nRadni dan\nA 1,10 7:00\nB 1,10 7:15\nPraznici\nA 1,10 9:00\nB 1,10 9:15\nŠkolski dan\nA 1,10 6:00\nB 1,10 6:15\n"
        sections = PublicTransportCalendar.sections(text, source_url: "https://community.example.invalid/synthetic/calendar.pdf")
        assert_equal(%w(workday holiday school_day), sections.map { |section| section.fetch("kind") })
        assert_not PublicTransportCalendar.supports_date?(sections[1], @now)
        assert_not PublicTransportCalendar.supports_date?(sections[2], @now)
        assert PublicTransportCalendar.supports_date?(sections[1].merge("requested_service_date" => "2026-09-09"), @now)
      end

      test "a Sunday with no published departures rolls to Monday only when asked, and says so" do
        notice, reader = prepare_route("g1")
        sunday = Time.utc(2026, 9, 13, 10)
        plain = reader.query(origin: "Bijeljina (NAS)", destination: "Primjerpark", notices: [notice], requested_at: sunday)
        rolled = reader.query(origin: "Bijeljina (NAS)", destination: "Primjerpark", notices: [notice], requested_at: sunday, roll_over: true)

        assert_equal :empty, plain.status
        assert_equal :ok, rolled.status
        assert_equal true, rolled.rolled_over
        assert_equal "2026-09-13", rolled.requested_service_date
        assert_equal "2026-09-14", rolled.service_date
        assert_equal "workday", rolled.itinerary.legs.first.calendar.fetch("kind")
        assert_includes rolled.warnings, "no_departures_published_for_service_day"
      end

      test "the weekday calendar gate follows the routes that serve the destination" do
        g1_notice, = prepare_route("g1")
        p2_notice, reader = prepare_route("p2")
        wednesday = Time.utc(2026, 9, 9, 10)

        primjerpolje = reader.query(origin: "Bijeljina (NAS)", destination: "Primjerpolje", notices: [g1_notice, p2_notice], requested_at: wednesday)
        assert_equal :unreviewed, primjerpolje.status, "a reviewed G1 must not vouch for the unreviewed P2 weekday section"
        assert_includes primjerpolje.warnings, "service_calendar_requires_review"

        primjerpark = reader.query(origin: "Bijeljina (NAS)", destination: "Primjerpark", notices: [g1_notice, p2_notice], requested_at: wednesday)
        assert_equal :ok, primjerpark.status

        # A settlement does not identify a boarding stop; narrow it before
        # applying the calendar gate to the line serving that actual stop.
        broad_origin = reader.query(origin: "Primjerpolje", destination: "Bijeljina", notices: [g1_notice, p2_notice], requested_at: wednesday, roll_over: true)
        assert_equal :ambiguous, broad_origin.status
        assert_includes broad_origin.warnings, "transport_origin_ambiguous"
        assert_empty broad_origin.options

        # Every line reaches Bijeljina; only the unreviewed P2 leaves this stop.
        ["Primjerpolje (centar)", "primjerpolje centar", "Примјерпоље (центар)"].each do |origin|
          from_primjerpolje = reader.query(origin:, destination: "Bijeljina", notices: [g1_notice, p2_notice], requested_at: wednesday, roll_over: true)
          assert_equal :unreviewed, from_primjerpolje.status, origin
          assert_includes from_primjerpolje.warnings, "service_calendar_requires_review"
          assert_empty from_primjerpolje.options
        end

        missing = reader.query(origin: "Nepoznatovac (centar)", destination: "Primjerpark", notices: [g1_notice, p2_notice], requested_at: wednesday)
        assert_equal :empty, missing.status
        assert_includes missing.warnings, "origin_not_in_reviewed_timetable"
        assert_empty missing.options
      end

      test "exact printed stop without parentheses cannot borrow another routes calendar" do
        source = synthetic_source("p2")
        # Only typography changes: retain the authored synthetic rows and calendar.
        body = synthetic_document("p2").gsub("Primjerpolje (centar)", "Primjerpolje centar  ")
        notice = CityServiceNoticeCollector::Notice.new(source_key: "public_transport", title: source.fetch("title"), url: source.fetch("url"))
        writer = PublicTransportTimetable.new(fetcher: ->(*) { body }, text_extractor: ->(text) { text }, clock: -> { @now },
                                              snapshot_store: @store, prepared_only: true, stop_registry: [], cache: false)
        assert_equal :ok, writer.prepare(notices: [notice]).first.fetch(:status)
        g1_notice, reader = prepare_route("g1")
        result = reader.query(origin: "Primjerpolje centar", destination: "Bijeljina", notices: [g1_notice, notice], requested_at: @now, roll_over: true)
        assert_equal :unreviewed, result.status
        assert_includes result.warnings, "service_calendar_requires_review"
        assert_empty result.options

        %w(Bijeljina centar).each do |destination|
          saturday = reader.query(origin: "Primjerpolje centar", destination:, notices: [g1_notice, notice], requested_at: Time.utc(2026, 9, 12, 10))
          assert_equal :ok, saturday.status, destination
          assert_equal "Primjerpolje centar", saturday.itinerary.legs.first.origin_label
          assert saturday.itinerary.legs.last.destination_label.start_with?("Bijeljina"), destination
          assert_equal "12:15", saturday.itinerary.legs.first.departure_at.in_time_zone("Europe/Sarajevo").strftime("%H:%M")
        end
      end

      test "empty forward cells cannot move reverse departures into the forward direction" do
        notice = CityServiceNoticeCollector::Notice.new(source_key: "public_transport", title: "P1 route", url: "https://community.example.invalid/synthetic/calendar.pdf")
        text = [
          "#{"Radni dan Smjer A".ljust(60)}Smjer B",
          "#{"Start 1,10 / /".ljust(60)}End 1,10 9:00 11:00",
          "#{"Mid 1,10 8:00 10:00".ljust(60)}Mid 1,10 9:10 11:10",
          "#{"End 1,10 8:10 10:10".ljust(60)}Start 1,10 9:20 11:20"
        ].join("\n")
        reader = PublicTransportTimetable.new(stop_registry: [], cache: false)
        directions = reader.send(:route_directions_from_text, text, notice, calendar: { "kind" => "workday" })
        forward = directions.find { |direction| direction.name == "A" }
        reverse = directions.find { |direction| direction.name == "B" }
        assert_not_includes forward.stops.flat_map(&:times), "9:00"
        assert_includes reverse.stops.flat_map(&:times), "9:00"
      end

      private

      def synthetic_source(code)
        { "fixture" => code, "title" => "#{code.upcase} — IZMIŠLJENI TEST",
          "url" => "https://community.example.invalid/synthetic/#{code}.pdf",
          "school_symbol_unexplained" => code != "g1" }
      end

      def synthetic_document(code)
        destination = code == "g1" ? "Primjerpark" : "Primjerpolje (centar)"
        last = code == "g1" ? "Primjerlivada" : "Primjerpolje (škola)"
        mark = code == "g1" ? "" : " (Š)"
        # Two aligned directions exercise the PDF-column parser, with wholly
        # invented trips. The school mark intentionally has no explanatory key.
        rows = [
          ["Radni dan Smjer A#{mark}", "Smjer B#{mark}"],
          ["Bijeljina (NAS)  1,10  06:25 13:25", "#{last}  1,10  07:20 14:20"],
          ["#{destination}  1,10  06:35 13:35", "#{destination}  1,10  07:25 14:25"],
          ["#{last}  1,10  06:40 13:40", "Bijeljina (NAS)  1,10  07:40 14:40"],
          ["Subota Smjer A", "Smjer B"],
          ["Bijeljina (NAS)  1,10  10:45 14:25", "#{last}  1,10  12:10 15:10"],
          ["#{destination}  1,10  10:55 14:35", "#{destination}  1,10  12:15 15:15"],
          ["#{last}  1,10  11:00 14:40", "Bijeljina (NAS)  1,10  12:30 15:30"],
          ["Nedjelja Smjer A", "Smjer B"],
          ["Bijeljina (NAS)  1,10", "#{last}  1,10"],
          ["#{destination}  1,10", "#{destination}  1,10"],
          ["#{last}  1,10", "Bijeljina (NAS)  1,10"]
        ]
        ["#{code.upcase} — IZMIŠLJENI TEST", *rows.map { |left, right| left.ljust(80) + right }].join("\n")
      end

      def prepare_route(code)
        source = synthetic_source(code)
        notice = CityServiceNoticeCollector::Notice.new(source_key: "public_transport", title: source.fetch("title"), url: source.fetch("url"))
        body = synthetic_document(code)
        writer = PublicTransportTimetable.new(fetcher: ->(*) { body }, text_extractor: ->(text) { text }, clock: lambda {
          @now
        }, snapshot_store: @store, prepared_only: true, stop_registry: [], cache: false)
        assert_equal :ok, writer.prepare(notices: [notice]).first.fetch(:status)
        reader = PublicTransportTimetable.new(clock: -> { @now }, snapshot_store: @store, stop_registry: [], cache: false)
        [notice, reader]
      end
    end
  end
end
