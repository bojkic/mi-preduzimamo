# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/synthetic_public_catalogs"
require_relative "../../../support/synthetic_waste_schedule"

module DecidimApp
  module Bijeljina
    class CityDataPreviewTest < ActiveSupport::TestCase
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
      test "returns admin preview rows for waste, parking and budget data" do
        previews = CityDataPreview.previews(
          organization: nil,
          waste_query: "Izmišljeno polje",
          parking_query: "Izmišljeni javor",
          budget_query: "centar"
        )
        by_key = previews.index_by { |preview| preview.fetch(:key) }

        assert_includes by_key.keys, "waste_schedule"
        assert_includes by_key.keys, "parking_zones"
        assert_includes by_key.keys, "budget_snapshot"
        assert_equal "city_waste_query", by_key.fetch("waste_schedule").fetch(:query_param)
        assert_equal "city_parking_query", by_key.fetch("parking_zones").fetch(:query_param)
        assert_equal "city_budget_query", by_key.fetch("budget_snapshot").fetch(:query_param)
        assert_equal "Raspored odvoza otpada", by_key.fetch("waste_schedule").fetch(:label)
        assert_equal "Parking zone", by_key.fetch("parking_zones").fetch(:label)
        assert_equal "Pregled budžeta", by_key.fetch("budget_snapshot").fetch(:label)
        assert by_key.fetch("waste_schedule").fetch(:rows).any?
        assert_equal "Izmišljeni javor", by_key.fetch("parking_zones").fetch(:rows).first.fetch(:label)
        assert_includes by_key.fetch("parking_zones").fetch(:rows).first.fetch(:value), "plava / II zona"
        assert by_key.fetch("budget_snapshot").fetch(:rows).any?
      end

      test "renders budget preview in Latin for Latin locales" do
        preview = CityDataPreview.previews(organization: nil, budget_query: "centar", locale: :sr)
                                 .find { |row| row.fetch(:key) == "budget_snapshot" }

        labels = preview.fetch(:rows).map { |row| row.fetch(:label) }
        assert(labels.any? { |label| label.include?("centar") || label.include?("Centar") })
        assert(labels.none? { |label| label.include?("центар") })
      end

      test "unresolved waste entries retain a nonempty preview without inventing collection days" do
        schedule = Object.new
        schedule.define_singleton_method(:areas) { ["Synthetic ambiguous street"] }
        schedule.define_singleton_method(:collection_days_for) { |_| nil }
        schedule.define_singleton_method(:registry) { { "rows" => [] } }
        WasteSchedule.stub(:default, schedule) do
          preview = CityDataPreview.previews(organization: nil).find { |row| row.fetch(:key) == "waste_schedule" }
          row = preview.fetch(:rows).first
          assert_equal "Synthetic ambiguous street", row.fetch(:label)
          assert_equal I18n.t("decidim_app.city_data_preview.waste.unresolved", default: "Schedule unresolved; specify district or street segment"), row.fetch(:value)
        end
      end
    end
  end
end
