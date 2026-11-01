# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module City
      # Unit-tests the shared text-matching primitives extracted from the four
      # City content services (Budget, GazetteIndex, ServiceDirectory,
      # WasteSchedule). The module mixes in PRIVATE instance methods, so a tiny
      # host class exposes them for direct assertion.
      class MatchingTest < ActiveSupport::TestCase
        # Minimal consumer that surfaces the private helpers publicly for testing.
        class Host
          include Decidim::Bih::City::Matching

          public :normalize, :tokenize
        end

        setup { @matching = Host.new }

        # ---- #normalize (must equal Decidim::Bih::Text.fold exactly) ----------

        test "normalize folds Cyrillic to lowercase ASCII Latin" do
          assert_equal "dvorovi", @matching.normalize("Дворови")
        end

        test "normalize folds Serbian Latin diacritics to ASCII" do
          assert_equal "carsijska pijaca", @matching.normalize("Čaršijska pijaca")
        end

        test "normalize is the shared Decidim::Bih::Text.fold" do
          ["Дворови", "Čaršija", "socijalni rad", "DVOROVI", "Đorđe"].each do |value|
            assert_equal Decidim::Bih::Text.fold(value), @matching.normalize(value)
          end
        end

        test "normalize maps nil and blank to empty string" do
          assert_equal "", @matching.normalize(nil)
          assert_equal "", @matching.normalize("")
        end

        # ---- #tokenize (must match the old Gazette/ServiceDirectory tokenizer) -

        test "tokenize splits a normalized string into word tokens" do
          assert_equal %w(javne nabavke), @matching.tokenize("Javne nabavke")
        end

        test "tokenize discards sub-two-character tokens" do
          # "u" and "i" are single-character connectives and must be dropped.
          assert_equal %w(odluka parking), @matching.tokenize("Odluka u i parking")
        end

        test "tokenize splits on non-alphanumerics and is script-insensitive" do
          assert_equal @matching.tokenize("паркинг зона"), @matching.tokenize("parking zona")
          assert_equal %w(parking zona), @matching.tokenize("парКинг, зона!")
        end

        test "tokenize keeps digit tokens (issue numbers)" do
          assert_equal %w(02 2026), @matching.tokenize("02/2026")
        end

        test "tokenize of a blank or nil string is empty" do
          assert_empty @matching.tokenize("")
          assert_empty @matching.tokenize(nil)
        end
      end
    end
  end
end
