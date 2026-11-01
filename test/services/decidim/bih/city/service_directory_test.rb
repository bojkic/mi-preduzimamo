# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module City
      # Exercises the GENERIC ranked-search machinery with a small synthetic
      # directory — no Bijeljina data here (that lives in the host app and is
      # tested in DecidimApp::Bijeljina::CityDirectoryTest).
      class ServiceDirectoryTest < ActiveSupport::TestCase
        ENTRIES = [
          {
            key: :voda,
            title: "Vodosnabdijevanje",
            keywords: %w(voda vodovod česma kvar prijava),
            answer: "Kvar na vodovodu prijavite vodovodnom preduzeću.",
            source_url: "https://example.test/voda"
          },
          {
            key: :struja,
            title: "Električna energija",
            keywords: %w(struja elektro nestanak kvar prijava),
            answer: "Nestanak struje prijavite elektrodistribuciji.",
            source_url: "https://example.test/struja"
          },
          {
            key: :groblje,
            title: "Gradska groblja",
            keywords: %w(groblje sahrana grobno mjesto),
            answer: "Za grobna mjesta obratite se upravi groblja.",
            source_url: "https://example.test/groblje"
          }
        ].freeze

        def directory
          ServiceDirectory.new(ENTRIES)
        end

        test "all returns a frozen entries array" do
          all = directory.all

          assert all.frozen?
          assert_equal 3, all.size
          all.each do |entry|
            assert entry.frozen?
            assert_kind_of Symbol, entry[:key]
            assert entry[:title].present?
            assert entry[:keywords].present?
            assert entry[:answer].present?
            assert_match(%r{\Ahttps?://}, entry[:source_url])
          end
        end

        test "a returned entry's keywords array is deep-frozen" do
          entry = directory.all.first # rubocop:disable Rails/RedundantActiveRecordAllMethod

          assert entry[:keywords].frozen?, "nested :keywords array must be frozen"
          assert_raises(FrozenError) { entry[:keywords] << "mutated" }
        end

        test "the directory does not share state with the source array" do
          source = ENTRIES.map(&:dup)
          built = ServiceDirectory.new(source)
          source.clear

          assert_equal 3, built.all.size
        end

        test "search returns the most relevant entry first" do
          results = directory.search("voda")

          assert_equal :voda, results.first[:key]
        end

        test "search ranks an exact keyword hit above a substring hit" do
          results = directory.search("nestanak struje")

          assert_equal :struja, results.first[:key]
        end

        test "search is diacritic-insensitive" do
          with_diacritics = directory.search("česma")
          without_diacritics = directory.search("cesma")

          assert_equal :voda, with_diacritics.first[:key]
          assert_equal(with_diacritics.map { |e| e[:key] },
                       without_diacritics.map { |e| e[:key] })
        end

        # Regression: a Cyrillic (sr-Cyrl) query must reach the same Latin
        # keyword vectors as the equivalent Latin query. Before the shared
        # Decidim::Bih::Text.fold helper, the directory only folded diacritics
        # (no Cyrillic), so "вода"/"отпад" never matched the Latin keywords.
        test "search is script-insensitive (a Cyrillic query matches Latin keywords)" do
          latin = directory.search("voda")
          cyrillic = directory.search("вода")

          assert_equal :voda, cyrillic.first[:key]
          assert_equal(latin.map { |entry| entry[:key] },
                       cyrillic.map { |entry| entry[:key] })
        end

        test "search matches a Cyrillic query against a multi-keyword Latin entry" do
          # "струја" (Cyrillic) -> "struja" must hit the :struja entry exactly
          # as the Latin "struja" does, proving the fix is not voda-specific.
          latin = directory.search("struja")
          cyrillic = directory.search("струја")

          assert_equal :struja, cyrillic.first[:key]
          assert_equal(latin.map { |entry| entry[:key] },
                       cyrillic.map { |entry| entry[:key] })
        end

        test "search ignores generic question words instead of fuzzy-matching them" do
          built = ServiceDirectory.new(
            [
              {
                key: :old_items,
                title: "Stari namještaj",
                keywords: %w(stari namjestaj),
                answer: "Odvoz starog namještaja.",
                source_url: "https://example.test/stari"
              }
            ]
          )

          assert_empty built.search("sta sve mozes da uradis")
        end

        test "search uses fuzzy tokens only after an exact service term" do
          built = ServiceDirectory.new(
            [
              {
                key: :maticar,
                title: "Matičar",
                keywords: %w(maticar izvod),
                answer: "Izvodi se traže kod matičara.",
                source_url: "https://example.test/maticar"
              }
            ]
          )
          assert_empty built.search("maticara")
          results = built.search("izvod maticara")

          assert_equal :maticar, results.first[:key]
        end

        test "search respects the limit argument" do
          assert_operator directory.search("kvar prijava", limit: 1).size, :<=, 1
        end

        test "search ignores an unknown query" do
          assert_equal [], directory.search("xyzzy nepostojeci pojam")
        end

        test "search of a blank query returns an empty array" do
          assert_equal [], directory.search("")
          assert_equal [], directory.search(nil)
        end

        test "find returns the entry for a known symbol key" do
          assert_equal :struja, directory.find(:struja)[:key]
        end

        test "find accepts a string key" do
          assert_equal :voda, directory.find("voda")[:key]
        end

        test "find returns nil for an unknown key" do
          assert_nil directory.find(:nonexistent)
        end
      end
    end
  end
end
