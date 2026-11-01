# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/synthetic_public_catalogs"

module DecidimApp
  module Bijeljina
    # Real parser over an independent authored two-block fiscal example.
    class BudgetTest < ActiveSupport::TestCase
      include SyntheticPublicCatalogs
      setup { install_synthetic_public_catalogs }
      teardown { restore_synthetic_public_catalogs }
      test "default builds a parsed budget from the authored snapshot" do
        assert_instance_of Decidim::Bih::City::Budget, Budget.default
        assert_not_empty Budget.default.line_items
      end

      test "memoizes the parsed default budget" do
        assert_same Budget.default, Budget.default
      end

      test "parses both Korisnici budzeta tables into clean line items" do
        # Two authored rows in the first block + three in the second.
        assert_equal 5, Budget.default.line_items.size
        Budget.default.line_items.each do |item|
          assert_not_empty item[:category]
          assert_operator item[:amount], :>, 0
        end
      end

      test "answers amount_for a authored budget user (Измишљени центар)" do
        assert_equal 12_345, Budget.default.amount_for("Измишљени центар")
      end

      test "answers amount_for a authored department (Измишљено одјељење)" do
        assert_equal 34_567, Budget.default.amount_for("Измишљено одјељење")
      end

      test "amount_for is script-insensitive for a Latin query" do
        assert_equal Budget.default.amount_for("Измишљена заштита"),
                     Budget.default.amount_for("izmisljena zastita")
        assert_equal 45_678, Budget.default.amount_for("izmisljena zastita")
      end

      test "amount_for does diacritic-insensitive partial matching" do
        # "vrtic" (no diacritics) resolves the authored Измишљени вртић row.
        assert_equal 23_456, Budget.default.amount_for("vrtic")
        assert_equal 56_789, Budget.default.amount_for("muzej")
      end

      test "amount_for an unknown category returns nil" do
        assert_nil Budget.default.amount_for("свемирски програм")
        assert_nil Budget.default.amount_for("")
      end

      test "total is the document's stated grand total" do
        assert_equal 999_999, Budget.default.total
      end

      test "parses the fiscal year" do
        assert_equal 2040, Budget.default.year
        assert_equal 2040, Budget::YEAR
      end

      test "exposes the env-overridable community budget source url" do
        assert_equal(
          "https://community.example.invalid/authored-budget.pdf",
          Budget::DEFAULT_SOURCE_URL
        )
        assert_equal Budget::DEFAULT_SOURCE_URL, Budget.source_url
      end

      test "honours MI_BUDGET_SOURCE_URL override" do
        ENV["MI_BUDGET_SOURCE_URL"] = "https://example.test/new-budget.pdf"
        assert_equal "https://example.test/new-budget.pdf", Budget.source_url
      ensure
        ENV.delete("MI_BUDGET_SOURCE_URL")
      end
      test "missing configured budget text fails closed despite a cached parse" do
        Budget.default
        swap_service_constant(Budget, :BUNDLED_TEXT_PATH, File.join(@synthetic_service_root, "absent-budget.txt"))
        assert_raises(Decidim::Bih::City::BudgetError) { Budget.default }
      end

      test "source metadata requires a public https url without credentials or alternate port" do
        ["", "http://community.example.invalid/budget.pdf", "https://reader:secret@community.example.invalid/budget.pdf",
         "https://community.example.invalid:8443/budget.pdf", "not a url"].each do |url|
          ENV["MI_BUDGET_SOURCE_URL"] = url
          refute Budget.configured?, url
          assert_raises(Decidim::Bih::City::BudgetError) { Budget.default }
        end
      end

      test "headline requires explicit reviewed metadata and preserves a real zero" do
        ENV.delete("MI_BUDGET_HEADLINE_TOTAL")
        assert_nil Budget.headline_total
        ENV["MI_BUDGET_HEADLINE_TOTAL"] = "0.00"
        assert_equal BigDecimal("0"), Budget.headline_total
        ENV["MI_BUDGET_HEADLINE_TOTAL"] = "12345.67"
        assert_equal BigDecimal("12345.67"), Budget.headline_total
        %w(-1 NaN Infinity 1e9 12,34 123.456).each do |value|
          ENV["MI_BUDGET_HEADLINE_TOTAL"] = value
          assert_nil Budget.headline_total, value
        end
      end

      test "page provenance is optional positive reviewed metadata" do
        ENV.delete("MI_BUDGET_TABLE_PAGE")
        assert_nil Budget.table_page
        ENV["MI_BUDGET_TABLE_PAGE"] = "8"
        assert_equal 8, Budget.table_page
        %w(0 -1 1.5 01 10000 unknown).each do |value|
          ENV["MI_BUDGET_TABLE_PAGE"] = value
          assert_nil Budget.table_page, value
        end
      end

      test "reviewed fiscal year must match the parsed document even after memoization" do
        Budget.default
        swap_service_constant(Budget, :YEAR, 2041)
        assert_raises(Decidim::Bih::City::BudgetError) { Budget.default }
      end
    end
  end
end
