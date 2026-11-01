# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/synthetic_event_source_registry"

module DecidimApp
  module Bijeljina
    class SourceMeasurementMetadataTest < ActiveSupport::TestCase
      include SyntheticEventSourceRegistry
      test "public measurements retain stable station and datum identity without cross-station conflicts" do
        metadata = { "station" => "Shared station label", "station_id" => "station-a", "kind" => "water_level_observation",
                     "value" => -12, "unit" => "cm", "source_clock" => "UTC+1", "datum" => "station_gauge_zero",
                     "vertical_datum" => "unknown", "observed_at" => "2026-09-15T08:00:00+01:00" }
        fact = SourceMeasurement.call(metadata:, source_key: "water_levels", now: Time.utc(2026, 9, 15, 8))
        assert_equal "station-a", fact["station_id"]
        assert_equal "UTC+1", fact["source_clock"]
        assert_equal "station_gauge_zero", fact["datum"]
        assert_empty SourceMeasurement.conflicting_observations([fact, fact.merge("station_id" => "station-b", "value" => 55)])
        assert_empty SourceMeasurement.conflicting_observations([fact, fact.merge("datum" => "absolute_elevation", "value" => 55)])
        assert_equal 2, SourceMeasurement.conflicting_observations([fact, fact.merge("value" => 55)]).size
      end

      test "measurement date requires a complete unambiguous source civil timestamp" do
        parser = CityServiceNoticeCollector
        assert_nil parser.send(:source_measurement_time, "30. juna u 06:54")
        assert_nil parser.send(:source_measurement_time, "29.03.2026 02:30")
        assert_nil parser.send(:source_measurement_time, "25.10.2026 02:30")
        assert_nil parser.send(:source_measurement_time, "31.02.2026 09:00")
        assert_equal "2026-09-09T08:00:00+02:00", parser.send(:source_measurement_time, "Poslednji podatak: 09.09.2026 08:00h")
      end

      test "RHMZ Serbia fixed UTC plus one remains stable through summer winter and DST boundaries" do
        parser = CityServiceNoticeCollector
        %w(09.09.2026 09.01.2026 29.03.2026 25.10.2026).each do |date|
          day, month, year = date.split(".").map(&:to_i)
          assert_equal Time.new(year, month, day, 2, 30, 0, "+01:00").iso8601,
                       parser.send(:source_measurement_time, "#{date} 02:30", source_clock: "UTC+1")
        end
        assert_nil parser.send(:source_measurement_time, "09.09.2026 08:00", source_clock: "unknown")
        assert_nil parser.send(:source_measurement_time, "31.02.2026 08:00", source_clock: "UTC+1")
      end

      test "aggregated river observations use reviewed station clocks and retain negative gauge values" do
        html = [
          ["Rijeka Drina (Radalj)", "-12"], ["Rijeka Sava (Jamena)", "123,9"], ["Unknown station", "45"]
        ].map do |station, level|
          "<div class='okvircijena'>Poslednji podatak: 15.09.2026 08:00h <span class='nazivartikla'>#{station}</span> " \
            "<span class='cijenaKM'>Vodostaj: #{level}cm</span></div>"
        end.join
        source = CityServiceSources.fetch("water_levels")
        notice = CityServiceNoticeCollector.send(:water_level_notices, source, Nokogiri::HTML(html), source[:source_url], now: Time.utc(2026, 9, 15, 8)).first
        rows = notice.metadata.fetch("readings")
        assert_equal(["RS45882", "RS45084", nil], rows.map { |row| row["station_id"] })
        assert_equal([-12, 123.9, 45], rows.map { |row| row["value"] })
        assert_equal "2026-09-15T08:00:00+01:00", rows[0]["observed_at"]
        assert_equal "UTC+1", rows[0]["source_clock"]
        assert_nil rows[2]["observed_at"]
        assert_includes rows[2]["quality_flags"], "unknown_station_and_clock"
      end

      test "water station metadata survives public snapshot serialization" do
        now = Time.utc(2026, 9, 9, 12)
        metadata = { "kind" => "water_level_observation", "readings" => [{ "station" => "Radalj", "value" => 32,
                                                                           "unit" => "cm", "observed_at" => "2026-09-09T08:00:00+02:00" }] }
        notice = CityServiceNoticeCollector::Notice.new(source_key: "water_levels", title: "Radalj", body: "32 cm",
                                                        url: CityServiceSources.fetch("water_levels")[:source_url], metadata:, fingerprint: "station", fetched_at: now)
        check = CityServiceNoticeCollector::SourceCheckResult.new(source_key: "water_levels", status: :ok, notices: [notice], checked_at: now)
        store = CityServiceSourceCheckStore.new(clock: -> { now })
        store.record(check:)
        prepared = store.check(keys: ["water_levels"]).first.notices.first
        assert_equal metadata, prepared.metadata
        assert_equal "2026-09-09T08:00:00+02:00", prepared.metadata["readings"].first["observed_at"]
      end
    end
  end
end
