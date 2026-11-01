# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/synthetic_waste_schedule"

module DecidimApp
  module Bijeljina
    class WasteRouteRegistryTest < ActiveSupport::TestCase
      include SyntheticWasteSchedule
      setup { install_synthetic_waste_schedule }
      teardown { restore_synthetic_waste_schedule }

      test "urban household source rows have exact weekday and page provenance" do
        lookup = WasteSchedule.default
        result = lookup.resolution_for("Rejon 2 Izmišljena breza", on: Date.new(2040, 9, 16))
        assert_equal :ok, result[:status]
        assert_equal ["ponedjeljak"], result[:days]
        assert_equal [3], result[:rows].map { |row| row.fetch("source_pdf_page") }.uniq
        assert_equal ["četvrtak"], lookup.collection_days_for("Rejon 3 Izmišljeni javor")
        assert_equal ["srijeda"], lookup.collection_days_for("Rejon 4 Izmišljeni bor")
      end

      test "same named street across districts requests route clarification instead of union" do
        result = WasteSchedule.default.resolution_for("Измишљени багрем")
        assert_equal :ambiguous, result[:status]
        assert_nil WasteSchedule.default.collection_days_for("Измишљени багрем")
        assert_equal ["ponedjeljak"], WasteSchedule.default.collection_days_for("Rejon 2 Izmišljeni bagrem")
        assert_equal ["srijeda"], WasteSchedule.default.collection_days_for("Rejon 3 Izmišljeni bagrem")
      end

      test "unknown routes and dates outside programme validity cannot use current schedule" do
        assert_equal :unknown, WasteSchedule.default.resolution_for("nepostojeća ulica")[:status]
        assert_equal :unavailable, WasteSchedule.default.resolution_for("Izmišljena breza", on: Date.new(2041, 1, 1))[:status]
      end

      test "container rows and unverified holiday changes never join household facts" do
        registry = JSON.parse(File.read(WasteSchedule::ROUTE_REGISTRY_PATH))
        assert_equal 8, registry.fetch("rows").size
        assert_equal [1, 2, 3, 4, 5], registry.fetch("rows").map { |row| row.fetch("district") }.uniq.sort
        assert(registry.fetch("rows").all? { |row| row.fetch("route_kind") == "household" })
        assert_empty registry.fetch("exceptions")
        assert_includes WasteSchedule.default.resolution_for("Izmišljena breza")[:warnings], "regular_schedule_exceptions_not_verified"
      end

      test "Izmišljeno polje settlement and named street rows remain separate" do
        assert_equal ["ponedjeljak"], WasteSchedule.default.collection_days_for("Измишљено поље")
        assert_equal ["utorak"], WasteSchedule.default.collection_days_for("Измишљено поље, Измишљени храст")
      end
    end
  end
end
