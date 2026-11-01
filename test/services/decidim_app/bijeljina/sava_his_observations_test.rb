# frozen_string_literal: true

# This adapter needs no Rails or database; keep its bounded fetch/parse contract
# runnable while the serialized application gate is occupied.
require "minitest/autorun"
require_relative "../../../../app/services/decidim_app/bijeljina/sava_his_observations"

module DecidimApp
  module Bijeljina
    class SavaHisObservationsTest < Minitest::Test
      NOW = Time.utc(2026, 9, 15, 8)

      def setup
        @pilot = SavaHisObservations.new(clock: -> { NOW })
      end

      def test_retains_negative_gauge_levels_and_distinct_station_identity
        result = parse(feature("BARHMZRS102", waterlevel: -191), feature("RS45882", waterlevel: 35.9))
        levels = result["readings"].select { |row| row["parameter"] == "waterlevel" }
        assert_equal([-191, 35.9], levels.map { |row| row["value"] })
        assert_equal(%w(Rača Radalj), levels.map { |row| row["station"] })
        assert_equal(%w(Sava Drina), levels.map { |row| row["river"] })
        assert_equal "cm", levels.first["unit"]
        assert_includes levels.first["quality_flags"], "gauge_zero_unknown"
        assert_equal false, result["public_answer_ready"]
      end

      def test_each_parameter_uses_its_own_explicit_timestamp
        rows = parse(feature("RS45084", waterlevel_time: "2026-09-15T07:00:00Z", flow_time: "2026-09-13T07:00:00Z", temperature_time: nil))["readings"]
        assert_equal "2026-09-15T07:00:00Z", rows[0]["observed_at"]
        assert_includes rows[1]["quality_flags"], "stale_measurement"
        assert_nil rows[2]["observed_at"]
        assert_includes rows[2]["quality_flags"], "unknown_measurement_time"
        assert_equal "°C", rows[2]["unit"]
        assert_equal "Normal state", rows[1]["source_flood_defence"]
      end

      def test_missing_or_unzoned_measurements_never_borrow_overall_time
        [nil, "2026-09-15T07:00:00", "15 September at seven", "2026-02-30T07:00:00Z"].each do |stamp|
          row = parse(feature("RS45084", waterlevel_time: stamp))["readings"].first
          assert_nil row["observed_at"]
          stamp.nil? ? assert_nil(row["observation_time_text"]) : assert_equal(stamp, row["observation_time_text"])
        end
      end

      def test_explicit_offsets_are_normalized_and_original_preserved
        row = parse(feature("RS45084", waterlevel_time: "2026-09-15T08:00:00+01:00"))["readings"].first
        assert_equal "2026-09-15T07:00:00Z", row["observed_at"]
        assert_equal "2026-09-15T08:00:00+01:00", row["observation_time_text"]
      end

      def test_future_non_numeric_and_duplicate_readings_are_flagged
        item = feature("RS45084", waterlevel: "NaN", waterlevel_time: "2026-09-16T08:00:00Z")
        row = parse(item, item)["readings"].first
        assert_nil row["value"]
        assert_equal "NaN", row["source_value"]
        assert_includes row["quality_flags"], "missing_or_invalid_value"
        assert_includes row["quality_flags"], "future_measurement"
        assert_includes row["quality_flags"], "duplicate_station_parameter"
      end

      def test_station_identity_changes_require_review_and_unknown_codes_are_excluded
        result = parse(feature("RS45084", station_name: "Rača"), feature("UNKNOWN"))
        assert_equal 3, result["readings"].size
        assert_includes result["readings"].first["quality_flags"], "station_identity_mismatch"
        assert_includes result["missing_station_ids"], "BARHMZRS102"
      end

      def test_extreme_gauge_levels_are_not_rejected_using_generic_range
        row = parse(feature("RS45084", waterlevel: 1265))["readings"].first
        assert_equal 1265, row["value"]
      end

      def test_empty_collection_reports_missing_station_coverage
        result = parse
        assert_empty result["readings"]
        assert_equal SavaHisObservations::STATIONS.keys.sort, result["missing_station_ids"].sort
      end

      def test_byte_shape_and_feature_limits_reject_malformed_responses
        ["{}", "[]", "<html>maintenance</html>", "x" * (SavaHisObservations::MAX_BYTES + 1),
         JSON.generate(type: "FeatureCollection", features: [nil]),
         JSON.generate(type: "FeatureCollection", features: Array.new(301, {}))].each do |body|
          assert_raises(SavaHisObservations::InvalidResponse) { @pilot.parse(body) }
        end
      end

      def test_fetch_pipeline_has_fixed_endpoint_and_no_side_effects
        urls = []
        pilot = SavaHisObservations.new(fetcher: lambda { |url|
          urls << url
          JSON.generate(type: "FeatureCollection", features: [feature("RS45084")])
        }, clock: -> { NOW })
        result = pilot.call
        assert_equal [SavaHisObservations::ENDPOINT], urls
        assert_equal "2026-09-15T08:00:00Z", result["checked_at"]
        assert_equal "internal_comparison", result["mode"]
      end

      private

      def parse(*features)
        @pilot.parse(JSON.generate(type: "FeatureCollection", features:))
      end

      def feature(code, **overrides)
        name, river, authority = SavaHisObservations::STATIONS.fetch(code, %w(Unknown Unknown Unknown))
        {
          type: "Feature", id: "generated-id-not-stable", properties: {
            european_wgst_code: code, station_name: name, river:, authority:,
            waterlevel: 123.9, waterlevel_time: "2026-09-15T07:00:00Z",
            flow: 221, flow_time: "2026-09-15T06:00:00Z", temperature: 21, temperature_time: "2026-09-15T05:00:00Z",
            time_of_measurement: "2026-09-15T08:00:00Z", gauge_zero: nil, flood_defence: "Normal state"
          }.merge(overrides)
        }
      end
    end
  end
end
