# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/synthetic_waste_schedule"

module DecidimApp
  module Bijeljina
    # Real reference adapter with authored text and household rows.
    class WasteScheduleTest < ActiveSupport::TestCase
      include SyntheticWasteSchedule
      setup { install_synthetic_waste_schedule }
      teardown { restore_synthetic_waste_schedule }

      test "adds Bijeljina-only structural labels at the host layer" do
        assert_includes WasteSchedule::STRUCTURAL_LABELS, "Бијељина"
        assert_not_includes Decidim::Bih::City::WasteSchedule::STRUCTURAL_LABELS, "Бијељина"
      end

      test "default builds a parsed schedule from the authored snapshot" do
        assert_instance_of WasteSchedule::Lookup, WasteSchedule.default
        assert_instance_of Decidim::Bih::City::WasteSchedule, WasteSchedule.default.legacy
        assert_not_empty WasteSchedule.default.areas
      end

      test "memoizes the parsed default schedule" do
        assert_same WasteSchedule.default, WasteSchedule.default
      end

      test "answers collection_days_for a known village (Измишљено поље)" do
        days = WasteSchedule.default.collection_days_for("Измишљено поље")

        assert_not_nil days
        assert_includes days, "ponedjeljak"
      end

      test "a street listed in two source districts requires the district" do
        resolution = WasteSchedule.default.resolution_for("Izmišljena lipa")

        assert_equal :ambiguous, resolution[:status]
        assert_equal [1, 3], resolution[:candidates].map { |row| row.fetch(:district) }.sort
        assert_equal ["utorak"], WasteSchedule.default.collection_days_for("Rejon 1 Izmišljena lipa")
        assert_equal ["srijeda"], WasteSchedule.default.collection_days_for("Rejon 3 Izmišljena lipa")
      end

      test "answers collection_days_for a known village (Измишљена ливада)" do
        days = WasteSchedule.default.collection_days_for("Измишљена ливада")

        assert_not_nil days
        assert_includes days, "petak"
      end

      test "lookup is script-insensitive for a Latin query" do
        assert_equal WasteSchedule.default.collection_days_for("Измишљено поље"),
                     WasteSchedule.default.collection_days_for("izmisljeno polje")
      end

      test "central household routes carry reviewed page evidence instead of the former district gap" do
        assert_nil WasteSchedule.default.partial_coverage_gap_for("Rejon 2 Bijeljina")
        result = WasteSchedule.default.resolution_for("Rejon 2 Izmišljena breza")
        assert_equal :ok, result.fetch(:status)
        assert_equal [3], result.fetch(:rows).map { |row| row.fetch("source_pdf_page") }.uniq
        assert_equal WasteSchedule.schedule_url, result.fetch(:source_url)
      end

      test "does not mark mapped villages as partial coverage gaps" do
        assert_nil WasteSchedule.default.partial_coverage_gap_for("Izmišljeno polje")
      end

      test "a place that explains only part of the query asks instead of answering for it" do
        result = WasteSchedule.default.resolution_for("Nepoznatopolis, Izmišljeno polje")

        assert_equal :ambiguous, result.fetch(:status)
        assert_equal "place_in_query_not_confirmed", result.fetch(:warning)
        assert_equal ["nepoznatopolis"], result.fetch(:unexplained)
        assert_nil result[:days]
        assert_nil WasteSchedule.default.collection_days_for("Nepoznatopolis, Izmišljeno polje")
        assert_equal [{ place: "Измишљено поље" }], result.fetch(:candidates)
      end

      test "the reviewed municipal suffix and bare qualifiers still leave a confident answer" do
        ["Izmišljeno polje, Bijeljina", "ulica Izmišljeno polje", "Izmišljeno polje"].each do |query|
          result = WasteSchedule.default.resolution_for(query)

          assert_equal :ok, result.fetch(:status), query
          assert_includes result.fetch(:days), "ponedjeljak", query
        end
      end

      test "a name the schedule holds nothing for stays unknown rather than borrowing a neighbour" do
        result = WasteSchedule.default.resolution_for("dsnica")

        assert_equal :unknown, result.fetch(:status)
        assert_nil WasteSchedule.default.collection_days_for("dsnica")
      end

      test "a confident resolution names the place as the schedule spells it" do
        assert_equal ["Измишљено поље"], WasteSchedule.default.resolution_for("izmisljeno polje").fetch(:places)
        assert_equal ["Измишљена бреза"], WasteSchedule.default.resolution_for("ulica Izmišljena breza").fetch(:places)
      end

      test "exposes the env-overridable community source url" do
        assert_equal(
          "https://community.example.invalid/authored-waste.pdf",
          WasteSchedule::DEFAULT_SCHEDULE_URL
        )
        assert_equal WasteSchedule::DEFAULT_SCHEDULE_URL, WasteSchedule.schedule_url
      end
      test "coverage detail describes configured rows instead of excluded municipal counts" do
        detail = WasteSchedule.coverage_detail
        assert_includes detail, "source_year=2040"
        assert_includes detail, "household_districts=1,2,3,4,5"
        assert_includes detail, "structured_household_rows=8"
        assert_not_includes detail, "195"
      end

      test "missing community text fails closed even after a cached lookup" do
        WasteSchedule.default
        original = WasteSchedule::BUNDLED_TEXT_PATH
        WasteSchedule.send(:remove_const, :BUNDLED_TEXT_PATH)
        WasteSchedule.const_set(:BUNDLED_TEXT_PATH, File.join(@synthetic_waste_root, "absent.txt"))
        assert_raises(Decidim::Bih::City::WasteScheduleError) { WasteSchedule.default }
      ensure
        WasteSchedule.send(:remove_const, :BUNDLED_TEXT_PATH)
        WasteSchedule.const_set(:BUNDLED_TEXT_PATH, original)
      end

      test "authored fixture restores its own files constants and exact cached lookup" do
        old_cache = @synthetic_waste_cache.dup
        old_constants = @synthetic_waste_constants.dup
        fixture_root = @synthetic_waste_root
        WasteSchedule.default
        restore_synthetic_waste_schedule
        assert_not File.exist?(fixture_root)
        old_constants.each { |name, prior| assert_same prior, WasteSchedule.const_get(name, false) }
        assert_equal old_cache.first, WasteSchedule.instance_variable_defined?(:@default)
        assert_same old_cache.last, WasteSchedule.instance_variable_get(:@default) if old_cache.first
      end

    end
  end
end
