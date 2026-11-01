# frozen_string_literal: true

require "test_helper"

module DecidimApp
  module Bijeljina
    class LegacyMeasurementPolicyTest < ActiveSupport::TestCase
      include ActiveSupport::Testing::TimeHelpers

      test "legacy fresh fetch cannot make an old source measurement current" do
        travel_to Time.utc(2026, 9, 9, 12) do
          notice = observation("2026-09-07T10:00:00+02:00")
          reply = LiveServiceAnswers.new.send(:air_quality_answer, [notice])
          assert_includes reply, "zastarjelo"
          assert_not_includes reply, "13 µg/m³"
          assert_not_includes reply, "Trenutno očitanje"
        end
      end

      test "unknown source time and community scope are visible in legacy answer" do
        reply = LiveServiceAnswers.new.send(:air_quality_answer, [observation(nil)])
        assert_includes reply, "13 µg/m³"
        assert_includes reply, "Vrijeme mjerenja nije pouzdano navedeno"
        assert_includes reply, "nije službeno mjerenje"
        assert_includes reply, "niti opis stanja u svakom komšiluku"
      end

      test "numeric water station values require centimetres and source time remains distinct" do
        metadata = { "kind" => "water_level_observation", "station" => "Radalj", "value" => 245, "unit" => "cm" }
        row = SourceMeasurement.call(metadata:, source_key: "water_levels", now: Time.current)
        assert_equal "river_station", row.fetch("coverage").fetch("scope")
        assert_includes row.fetch("warning_codes"), "measurement_time_unknown"
        assert_includes row.fetch("text"), "nije procjena opasnosti od poplave"
        assert_nil SourceMeasurement.call(metadata: metadata.merge("unit" => "µg/m³"), source_key: "water_levels", now: Time.current)
      end

      test "unstructured legacy body is never promoted to a reliable measurement" do
        notice = observation(nil)
        notice.metadata = nil
        notice.body = "Trenutno 99 µg/m³"
        reply = LiveServiceAnswers.new.send(:air_quality_answer, [notice])
        assert_includes reply, "Nemam pouzdano izdvojeno mjerenje"
        assert_not_includes reply, "99"
      end

      private

      def observation(observed_at)
        CityServiceNoticeCollector::Notice.new(
          source_key: "air_quality_realtime", provider: "Klimerko", title: "Javni prikaz PM2.5", fetched_at: Time.current,
          metadata: { "kind" => "air_quality_observation", "value" => 13, "unit" => "µg/m³", "pollutant" => "PM2.5", "observed_at" => observed_at }
        )
      end
    end
  end
end
