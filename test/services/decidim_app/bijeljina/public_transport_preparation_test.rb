# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/synthetic_event_source_registry"

module DecidimApp
  module Bijeljina
    class PublicTransportPreparationTest < ActiveSupport::TestCase
      include SyntheticEventSourceRegistry
      setup do
        DecidimApp::CityServiceSourceSnapshot.delete_all
        @now = Time.utc(2026, 9, 9, 9)
        @notice = CityServiceNoticeCollector::Notice.new(source_key: "public_transport", source_label: "Transport", provider: "City",
                                                         title: "P1 Izmišljeni centar-Izmišljeni vrt", url: URI.join(CityServiceSources.fetch("public_transport").fetch(:source_url), "/authored-p1.pdf").to_s,
                                                         fetched_at: @now, fingerprint: "route-1")
        @body = timetable_text("7:30")
        @calls = 0
        @store = CityServiceSourceCheckStore.new(clock: -> { @now })
        @writer = PublicTransportTimetable.new(fetcher: lambda { |_url|
          @calls += 1
          @body
        }, text_extractor: ->(body) { body },
                                               clock: -> { @now }, snapshot_store: @store, prepared_only: true, stop_registry: [], cache: false)
      end

      test "cold ordinary matrix and structured reads perform zero external fetches" do
        assert_empty @writer.matrix(notices: [@notice])
        result = @writer.query(origin: "Izmišljeni centar", destination: "Izmišljeni vrt", notices: [@notice], requested_at: @now)
        assert_equal :unavailable, result.status
        assert_equal 0, @calls
      end

      test "background materialization is reusable by a fresh reader without PDF parsing" do
        assert_equal :ok, @writer.prepare(notices: [@notice]).first.fetch(:status)
        reader = PublicTransportTimetable.new(clock: -> { @now }, snapshot_store: @store, stop_registry: [], cache: false)
        routes = reader.matrix(notices: [@notice])

        assert_equal 1, routes.size
        assert_equal "7:30", routes.first.directions.first.stops.first.times.first
        assert_equal 1, @calls
      end

      test "changed content at unchanged URL invalidates prepared rows" do
        @writer.prepare(notices: [@notice])
        old_hash = @store.snapshot(source_key: @writer.send(:document_key, @notice)).content_hash
        assert_equal "7:30", @writer.matrix(notices: [@notice]).first.directions.first.stops.first.times.first
        @body = timetable_text("8:30")
        @now += 60
        @writer.prepare(notices: [@notice])

        assert_not_equal old_hash, @store.snapshot(source_key: @writer.send(:document_key, @notice)).content_hash
        assert_equal "8:30", @writer.matrix(notices: [@notice]).first.directions.first.stops.first.times.first
      end

      test "malformed replacement cannot overwrite last-good matrix and is not silently served" do
        @writer.prepare(notices: [@notice])
        before = @store.snapshot(source_key: @writer.send(:document_key, @notice)).last_good_payload
        @body = "navigation or truncated PDF"
        @now += 60
        assert_equal :unavailable, @writer.prepare(notices: [@notice]).first.fetch(:status)
        row = @store.snapshot(source_key: @writer.send(:document_key, @notice))

        assert_equal before, row.last_good_payload
        assert_equal "unavailable", row.check_payload["status"]
        assert_empty @writer.matrix(notices: [@notice])
      end

      test "expired timetable cannot produce a current route without refresh" do
        @writer.prepare(notices: [@notice])
        @now += 15.days
        assert_empty @writer.matrix(notices: [@notice])
        assert_equal 1, @calls
      end

      test "changed stop registry invalidates derived rows even with unchanged URL" do
        @writer.prepare(notices: [@notice])
        @writer.stub(:stop_registry_fingerprint, "new-reviewed-coordinates") do
          assert_empty @writer.matrix(notices: [@notice])
        end
        assert_equal 1, @calls
      end

      test "deadline failures preserve good snapshot without changing health" do
        @writer.prepare(notices: [@notice])
        @writer.stub(:call_fetcher, ->(*) { raise CityServiceNoticeCollector::DeadlineExceeded }) do
          assert_raises(CityServiceNoticeCollector::DeadlineExceeded) { @writer.prepare(notices: [@notice]) }
        end
        assert_equal 1, @writer.matrix(notices: [@notice]).size
      end

      test "unchanged PDF reuses validated text and matrices without parsing" do
        @writer.prepare(notices: [@notice])
        @writer.instance_variable_set(:@text_extractor, ->(*) { raise "unchanged PDF must not be parsed" })
        @now += 60
        result = @writer.prepare(notices: [@notice]).first
        assert_equal :ok, result.fetch(:status)
        assert_equal false, result.fetch(:parsed)
        assert_equal 2, @calls
      end

      test "Friday last trip cannot become an invented Saturday trip" do
        @writer.prepare(notices: [@notice])
        result = @writer.query(origin: "Izmišljeni centar", destination: "Izmišljeni vrt", notices: [@notice], requested_at: Time.utc(2026, 9, 11, 21))
        assert_not_equal :ok, result.status
      end

      test "named Sunday rows are retained separately from workday departures" do
        @body += "\nNedjelja\nIzmišljeni centar (NAS) 2,13 16:00\nIzmišljeni vrt (CSP) 3,24 16:13\n"
        assert_equal :ok, @writer.prepare(notices: [@notice]).first.fetch(:status)
        row = @store.snapshot(source_key: @writer.send(:document_key, @notice))
        assert_equal(%w(workday sunday), row.last_good_payload.fetch("calendars").map { |entry| entry.fetch("kind") })
        assert_not_includes @writer.matrix(notices: [@notice]).first.directions.first.stops.first.times, "16:00"
        result = @writer.query(origin: "Izmišljeni centar (NAS)", destination: "Izmišljeni vrt", notices: [@notice], requested_at: Time.utc(2026, 9, 13, 12))
        assert_equal :ok, result.status
        assert_equal "sunday", result.itinerary.legs.first.calendar.fetch("kind")
        assert_equal "16:00", result.itinerary.legs.first.departure_at.in_time_zone("Europe/Sarajevo").strftime("%H:%M")
      end

      test "invalid timetable hours cannot replace validated rows" do
        @writer.prepare(notices: [@notice])
        @body = timetable_text("27:30")
        assert_equal :unavailable, @writer.prepare(notices: [@notice]).first.fetch(:status)
        assert_empty @writer.matrix(notices: [@notice])
      end

      test "whole legacy timetable answer respects an expired caller budget without reading documents" do
        deadline = Decidim::Bih::Concierge::Dialogue::TurnBudget.new(timeout: 0.001)
        deadline.stub(:expired?, true) do
          assert_raises(CityServiceNoticeCollector::DeadlineExceeded) do
            @writer.answer(text: "kada ide sljedeći autobus za Izmišljeni vrt", notices: [@notice], deadline:)
          end
        end
        assert_equal 0, @calls
      end

      test "legacy exceptional-day question cannot silently receive an ordinary weekday trip" do
        reply = @writer.answer(text: "kada ide autobus za Izmišljeni vrt za praznike", notices: [@notice])
        assert_includes reply, "nemam provjeren kalendar datuma"
        assert_equal 0, @calls
      end

      private

      def timetable_text(departure)
        <<~TEXT
          P1 Izmišljeni centar-Izmišljeni vrt
          Radni dan
          Izmišljeni centar (NAS) 2,13 #{departure} 11:30
          Izmišljeni vrt (CSP) 3,24 7:43 11:43
        TEXT
      end
    end
  end
end
