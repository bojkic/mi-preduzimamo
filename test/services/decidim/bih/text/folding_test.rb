# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module Text
      # Unit tests for the single shared text-folding helper used by the
      # concierge Responder and every City content service (Budget,
      # GazetteIndex, WasteSchedule, ServiceDirectory) for script- and
      # accent-insensitive keyword/lookup matching.
      class FoldingTest < ActiveSupport::TestCase
        test "Latin ASCII text passes through unchanged" do
          assert_equal "voda", Decidim::Bih::Text.fold("voda")
          assert_equal "socijalni rad", Decidim::Bih::Text.fold("socijalni rad")
        end

        test "downcases the input" do
          assert_equal "dvorovi", Decidim::Bih::Text.fold("DVOROVI")
          assert_equal "novi dvorovi", Decidim::Bih::Text.fold("Novi Dvorovi")
        end

        test "folds Serbian Latin diacritics to their ASCII base" do
          assert_equal "cesma", Decidim::Bih::Text.fold("česma")
          assert_equal "smece", Decidim::Bih::Text.fold("smeće")
          assert_equal "zelja", Decidim::Bih::Text.fold("žElja")
          assert_equal "djordje", Decidim::Bih::Text.fold("Đorđe")
        end

        test "transliterates Cyrillic to Latin" do
          assert_equal "voda", Decidim::Bih::Text.fold("вода")
          assert_equal "otpad", Decidim::Bih::Text.fold("отпад")
          assert_equal "dvorovi", Decidim::Bih::Text.fold("Дворови")
        end

        test "a Cyrillic query folds to the same key as its Latin spelling" do
          assert_equal Decidim::Bih::Text.fold("smece"), Decidim::Bih::Text.fold("смеће")
          assert_equal Decidim::Bih::Text.fold("socijalni rad"),
                       Decidim::Bih::Text.fold("Социјални рад")
        end

        test "folds mixed Cyrillic/Latin and accents together" do
          assert_equal "djubre i otpad", Decidim::Bih::Text.fold("Ђубре i отпад")
        end

        test "replaces punctuation with a space and collapses whitespace" do
          assert_equal "br 2026 0001", Decidim::Bih::Text.fold("BR-2026-0001")
          assert_equal "voda vodovod", Decidim::Bih::Text.fold("  voda,  vodovod!  ")
          assert_equal "07 2026", Decidim::Bih::Text.fold("07/2026")
        end

        test "keeps single spaces between words" do
          assert_equal "centar za socijalni rad",
                       Decidim::Bih::Text.fold("Centar za socijalni rad")
        end

        test "keeps digits" do
          assert_equal "rejon 3", Decidim::Bih::Text.fold("Рејон 3")
        end

        test "nil and blank input fold to an empty string" do
          assert_equal "", Decidim::Bih::Text.fold(nil)
          assert_equal "", Decidim::Bih::Text.fold("")
          assert_equal "", Decidim::Bih::Text.fold("   ")
          assert_equal "", Decidim::Bih::Text.fold("!?-.")
        end

        test "folds a decomposed (NFD) diacritic like a composed one" do
          composed = "č".unicode_normalize(:nfc) # single codepoint
          decomposed = "č".unicode_normalize(:nfd) # c + combining caron

          assert_operator decomposed.length, :>, composed.length, "fixture must be decomposed"
          assert_equal "c", Decidim::Bih::Text.fold(composed)
          assert_equal Decidim::Bih::Text.fold(composed), Decidim::Bih::Text.fold(decomposed)
        end
      end
    end
  end
end
