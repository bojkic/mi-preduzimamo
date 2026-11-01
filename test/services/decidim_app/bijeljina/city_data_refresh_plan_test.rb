# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/synthetic_public_catalogs"
require_relative "../../../support/synthetic_waste_schedule"

module DecidimApp
  module Bijeljina
    class CityDataRefreshPlanTest < ActiveSupport::TestCase
      include SyntheticPublicCatalogs
      include SyntheticWasteSchedule

      setup do
        install_synthetic_public_catalogs
        install_synthetic_waste_schedule
      end

      teardown do
        restore_synthetic_waste_schedule
        restore_synthetic_public_catalogs
      end
      test "returns source-specific readiness rows for every city-data dataset" do
        rows = CityDataRefreshPlan.rows
        by_key = rows.index_by { |row| row.fetch(:key) }

        assert_equal %w(waste_schedule parking_zones budget_snapshot gazette_index service_directory service_alert_sources local_areas), by_key.keys

        waste = by_key.fetch("waste_schedule")
        assert_equal "Raspored odvoza otpada", waste.fetch(:label)
        assert_equal "ok", waste.fetch(:status)
        assert_equal true, waste.fetch(:source_file_present)
        assert_match(%r{schedule\.txt\z}, waste.fetch(:source_file))
        assert_match(%r{\Ahttps://}, waste.fetch(:source_url))
        assert_equal "2040-09-14", waste.fetch(:metadata_date)
        assert_operator waste.fetch(:count), :>, 0
        assert_includes CityDataRefreshPlan.validation_command(waste), "waste_schedule_test.rb"

        parking = by_key.fetch("parking_zones")
        assert_equal "ok", parking.fetch(:status)
        assert_equal true, parking.fetch(:source_file_present)
        assert_match(%r{app/services/decidim_app/bijeljina/parking_zones\.rb\z}, parking.fetch(:source_file))
        assert_match(%r{\Ahttps://}, parking.fetch(:source_url))
        assert_equal "2040-09-14", parking.fetch(:metadata_date)
        assert_equal 3, parking.fetch(:count)
        assert_includes CityDataRefreshPlan.validation_command(parking), "parking_zones_test.rb"

        budget = by_key.fetch("budget_snapshot")
        assert_equal "Pregled budžeta", budget.fetch(:label)
        assert_equal "ok", budget.fetch(:status)
        assert_equal true, budget.fetch(:source_file_present)
        assert_match(%r{budget\.txt\z}, budget.fetch(:source_file))
        assert_equal "2040-09-14", budget.fetch(:metadata_date)
        assert_equal 5, budget.fetch(:count)

        assert_equal "https://community.example.invalid/authored-gazette", by_key.fetch("gazette_index").fetch(:source_url)
        assert_nil by_key.fetch("service_directory").fetch(:source_url)
        assert_nil by_key.fetch("service_alert_sources").fetch(:source_url)

        local_areas = by_key.fetch("local_areas")
        assert_equal "warn", local_areas.fetch(:status), "without an organization, local-area readiness should stay read-only and cautious"
        assert_equal true, local_areas.fetch(:source_file_present)
        assert_nil local_areas.fetch(:source_url)
        assert_includes CityDataRefreshPlan.validation_command(local_areas), "synthetic_community_import_test.rb"

        alert_sources = by_key.fetch("service_alert_sources")
        assert_equal "ok", alert_sources.fetch(:status)
        assert_equal true, alert_sources.fetch(:source_file_present)
        assert_equal "2040-09-14", alert_sources.fetch(:metadata_date)
        assert_operator alert_sources.fetch(:count), :>=, 10
        assert_includes alert_sources.fetch(:detail), "viber_alerts=disabled"
        assert_includes CityDataRefreshPlan.validation_command(alert_sources), "city_service_sources_test.rb"
        assert_includes CityDataRefreshPlan.validation_command(alert_sources), "city_service_source_probe_test.rb"
        assert(alert_sources.fetch(:checklist).any? { |item| item.include?("mi_city_service_viber_readiness_smoke") })
      end

      test "rows include operator checklists and exact validation test paths" do
        rows = CityDataRefreshPlan.rows

        rows.each do |row|
          assert row.fetch(:checklist).all?(&:present?), "#{row.fetch(:key)} checklist should be actionable"
          assert row.fetch(:validation_tests).all? { |path| path.start_with?("test/") },
                 "#{row.fetch(:key)} validation tests should be repo-relative"
          assert_includes CityDataRefreshPlan.validation_command(row), "bin/rails test"
          row.fetch(:validation_tests).each { |path| assert_path_exists Rails.root.join(path), "#{row.fetch(:key)} missing public test #{path}" }
        end
      end
    end
  end
end
