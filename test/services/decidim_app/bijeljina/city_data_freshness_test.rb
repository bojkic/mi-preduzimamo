# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/synthetic_public_catalogs"
require_relative "../../../support/synthetic_waste_schedule"

module DecidimApp
  module Bijeljina
    class CityDataFreshnessTest < ActiveSupport::TestCase
      include ActiveSupport::Testing::TimeHelpers
      include SyntheticPublicCatalogs
      include SyntheticWasteSchedule

      setup do
        install_synthetic_public_catalogs
        install_synthetic_waste_schedule
        # Static metadata captures dates at boot; the fixture supplies all
        # sources explicitly while the real counters/health logic still run.
        rows = CityDataFreshness::STATIC_SOURCES.map { |source| source.merge(last_updated_on: Date.new(2040, 9, 14)).freeze }
        swap_service_constant(CityDataFreshness, :STATIC_SOURCES, rows.freeze)
        @organization = create_organization
      end

      teardown do
        travel_back
        restore_synthetic_waste_schedule
        restore_synthetic_public_catalogs
      end

      test "returns healthy explicitly configured sources while missing prepared source checks remain unavailable" do
        travel_to Time.zone.local(2040, 9, 16, 12, 0, 0)
        create_healthy_local_areas!

        rows = CityDataFreshness.statuses(organization: @organization)
        by_key = rows.index_by { |row| row.fetch(:key) }

        assert_equal %w(waste_schedule parking_zones budget_snapshot gazette_index service_directory service_alert_sources),
                     by_key.keys.first(6)
        assert_includes by_key.keys, "service_source.electricity_outages"
        assert_includes by_key.keys, "service_source.waste_schedule"
        assert_equal "local_areas", by_key.keys.last
        assert_equal "2040-09-14", by_key.fetch("waste_schedule").fetch(:last_updated_on)
        assert_equal "Raspored odvoza otpada", by_key.fetch("waste_schedule").fetch(:label)
        assert_equal "ok", by_key.fetch("waste_schedule").fetch(:status)
        assert_includes by_key.fetch("waste_schedule").fetch(:detail), "household_districts=1,2,3,4,5"
        assert_includes by_key.fetch("waste_schedule").fetch(:detail), "structured_household_rows=8"
        assert_includes by_key.fetch("waste_schedule").fetch(:detail), "container_routes=not_indexed"
        assert_equal "ok", by_key.fetch("parking_zones").fetch(:status)
        assert_includes by_key.fetch("parking_zones").fetch(:detail), "streets=3"
        assert_equal "ok", by_key.fetch("budget_snapshot").fetch(:status)
        assert_equal "ok", by_key.fetch("gazette_index").fetch(:status)
        assert_equal "ok", by_key.fetch("service_directory").fetch(:status)
        assert_includes by_key.fetch("service_directory").fetch(:detail), "scope=expanded_static_faq_plus_reviewed_source_topics"
        assert_equal "ok", by_key.fetch("service_alert_sources").fetch(:status)
        assert_equal "ok", by_key.fetch("local_areas").fetch(:status)
        assert_equal "Lokalna područja", by_key.fetch("local_areas").fetch(:label)
        rows.each { |row| assert row.fetch(:refresh_command).present? unless row.fetch(:status) == "disabled" }
        assert_equal "script/mi_city_data_refresh_readiness waste_schedule", by_key.fetch("waste_schedule").fetch(:refresh_command)
        assert_equal "script/mi_city_data_refresh_readiness parking_zones", by_key.fetch("parking_zones").fetch(:refresh_command)
        assert_equal "script/mi_city_data_refresh_readiness budget_snapshot", by_key.fetch("budget_snapshot").fetch(:refresh_command)
        assert_equal "script/mi_city_data_refresh_readiness gazette_index", by_key.fetch("gazette_index").fetch(:refresh_command)
        assert_equal "script/mi_city_data_refresh_readiness service_directory", by_key.fetch("service_directory").fetch(:refresh_command)
        assert_equal "script/mi_city_data_refresh_readiness service_alert_sources", by_key.fetch("service_alert_sources").fetch(:refresh_command)
        assert_includes by_key.fetch("local_areas").fetch(:refresh_command), "script/mi_city_data_refresh_readiness local_areas"
        assert_includes by_key.fetch("local_areas").fetch(:refresh_command), "decidim_bih:geo:import_areas"
        assert_equal "2040-09-14", by_key.fetch("budget_snapshot").fetch(:last_updated_on)
        assert_includes by_key.fetch("budget_snapshot").fetch(:detail), "source_year=2040"
        assert_includes by_key.fetch("service_alert_sources").fetch(:detail), "viber_candidates="
        assert_includes by_key.fetch("service_alert_sources").fetch(:detail), "viber_alerts=disabled"
        assert_includes by_key.fetch("service_alert_sources").fetch(:detail), "runtime_health=reported_separately"
        assert_equal "script/mi_city_service_source_probe electricity_outages",
                     by_key.fetch("service_source.electricity_outages").fetch(:refresh_command)
        assert_equal "fail", by_key.fetch("service_source.electricity_outages").fetch(:status)
        assert_nil by_key.fetch("service_source.electricity_outages").fetch(:last_updated_on)
        assert_includes by_key.fetch("service_source.electricity_outages").fetch(:detail), "runtime_health=unavailable"
        assert_includes by_key.fetch("service_source.electricity_outages").fetch(:detail), "delivery=viber_alert_candidate"
        assert_includes by_key.fetch("local_areas").fetch(:detail), "mz=1"
        assert_includes by_key.fetch("local_areas").fetch(:detail), "missing_contact=0"
        assert_includes by_key.fetch("local_areas").fetch(:detail), "integrity_issues=0"
      end
      test "propagates explicit successful source checks without treating catalogue presence as health" do
        travel_to Time.zone.local(2040, 9, 16, 12, 0, 0)
        check = CityServiceNoticeCollector::SourceCheckResult.new(
          source_key: "electricity_outages",
          status: :empty,
          notices: [],
          checked_at: Time.zone.local(2040, 9, 16, 11, 30),
          error_code: nil
        )

        row = CityDataFreshness.statuses(organization: @organization, source_checks: [check])
                               .find { |candidate| candidate.fetch(:key) == "service_source.electricity_outages" }

        assert_equal "ok", row.fetch(:status)
        assert_equal "2040-09-16", row.fetch(:last_updated_on)
        assert_includes row.fetch(:detail), "runtime_health=empty"
      end

      test "published electricity does not create review work but pending unknown water does" do
        now = Time.zone.local(2040, 9, 29, 12)
        travel_to now
        CityServiceEvent.create!(organization: @organization, source_key: "electricity_outages", source_fingerprint: "published-area",
                                 parser_version: "test", event_type: "planned_outage", severity: "service_outage",
                                 title: "Published", summary: "Reviewed area", targeting_level: "komsiluk",
                                 state: "board_published", starts_at: now - 1.hour, ends_at: now + 2.hours)
        CityServiceEvent.create!(organization: @organization, source_key: "water_service", source_fingerprint: "pending-area",
                                 parser_version: "test", event_type: "planned_outage", severity: "service_outage",
                                 title: "Pending", summary: "Area missing", targeting_level: "unknown",
                                 state: "pending_review", starts_at: now - 1.hour, ends_at: now + 2.hours)

        rows = CityDataFreshness.statuses(organization: @organization, source_checks: [], now:).index_by { |row| row.fetch(:key) }
        assert_equal "ok", rows.fetch("service_data_quality").fetch(:status)
        assert_equal "warn", rows.fetch("service_review.water_service").fetch(:status)
        assert_equal 1, rows.fetch("service_review.water_service").fetch(:review_count)
        assert_not rows.key?("service_review.electricity_outages")
      end

      test "warns when MZ contact data is incomplete" do
        travel_to Time.zone.local(2040, 9, 16, 12, 0, 0)
        mz_boundary = square(0.500, 0.500, 0.510, 0.510)
        mz_point = Decidim::Bih::Geo::AreaLocator.representative_point(mz_boundary)
        Decidim::Bih::LocalArea.create!(
          organization: @organization,
          kind: "mz",
          slug: "mz-missing-contact",
          name: { "sr" => "Missing Contact MZ" },
          boundary: mz_boundary,
          centroid_lat: mz_point[0],
          centroid_lon: mz_point[1]
        )

        local_area = CityDataFreshness.statuses(organization: @organization)
                                      .find { |row| row.fetch(:key) == "local_areas" }

        assert_equal "warn", local_area.fetch(:status)
        assert_includes local_area.fetch(:detail), "missing_president=1"
        assert_includes local_area.fetch(:detail), "missing_phone=1"
        assert_includes local_area.fetch(:detail), "missing_contact=1"
      end

      test "does not fail only because Komsiluk polygons are not imported yet" do
        travel_to Time.zone.local(2040, 9, 16, 12, 0, 0)
        mz_boundary = square(0.500, 0.500, 0.510, 0.510)
        mz_point = Decidim::Bih::Geo::AreaLocator.representative_point(mz_boundary)
        Decidim::Bih::LocalArea.create!(
          organization: @organization,
          kind: "mz",
          slug: "mz-only",
          name: { "sr" => "MZ Only" },
          predsjednik: "IZMIŠLJENI PREDSTAVNIK",
          telefon: "TEST-PHONE",
          boundary: mz_boundary,
          centroid_lat: mz_point[0],
          centroid_lon: mz_point[1]
        )

        local_area = CityDataFreshness.statuses(organization: @organization)
                                      .find { |row| row.fetch(:key) == "local_areas" }

        assert_equal "ok", local_area.fetch(:status)
        assert_includes local_area.fetch(:detail), "mz=1"
        assert_includes local_area.fetch(:detail), "komsiluk=0"
        assert_includes local_area.fetch(:detail), "integrity_issues=0"
      end

      test "warns when local-area integrity check finds issues" do
        travel_to Time.zone.local(2040, 9, 16, 12, 0, 0)
        Decidim::Bih::LocalArea.create!(
          organization: @organization,
          kind: "komsiluk",
          slug: "broken-komsiluk",
          name: { "sr" => "Broken" }
        )

        local_area = CityDataFreshness.statuses(organization: @organization)
                                      .find { |row| row.fetch(:key) == "local_areas" }

        assert_equal "warn", local_area.fetch(:status)
        assert_match(/integrity_issues=[1-9]/, local_area.fetch(:detail))
      end

      test "warns when no organization is available for local-area checks" do
        local_area = CityDataFreshness.statuses(organization: nil)
                                      .find { |row| row.fetch(:key) == "local_areas" }

        assert_equal "warn", local_area.fetch(:status)
        assert_equal "organization missing", local_area.fetch(:detail)
      end

      private

      def create_healthy_local_areas!
        mz_boundary = square(0.500, 0.500, 0.510, 0.510)
        mz_point = Decidim::Bih::Geo::AreaLocator.representative_point(mz_boundary)
        Decidim::Bih::LocalArea.create!(
          organization: @organization,
          kind: "mz",
          slug: "mz-freshness",
          name: { "sr" => "Freshness MZ" },
          predsjednik: "IZMIŠLJENI PREDSTAVNIK",
          telefon: "TEST-PHONE",
          boundary: mz_boundary,
          centroid_lat: mz_point[0],
          centroid_lon: mz_point[1]
        )

        komsiluk_boundary = square(0.502, 0.502, 0.508, 0.508)
        komsiluk_point = Decidim::Bih::Geo::AreaLocator.representative_point(komsiluk_boundary)
        Decidim::Bih::LocalArea.create!(
          organization: @organization,
          kind: "komsiluk",
          slug: "komsiluk-freshness",
          name: { "sr" => "Freshness Komšiluk" },
          boundary: komsiluk_boundary,
          primary_mz_slug: "mz-freshness",
          overlapping_mz_slugs: %w(mz-freshness),
          centroid_lat: komsiluk_point[0],
          centroid_lon: komsiluk_point[1]
        )
      end

      def square(lon_min, lat_min, lon_max, lat_max)
        {
          "type" => "Polygon",
          "coordinates" => [
            [
              [lon_min, lat_min],
              [lon_max, lat_min],
              [lon_max, lat_max],
              [lon_min, lat_max],
              [lon_min, lat_min]
            ]
          ]
        }
      end
    end
  end
end
