# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module City
      # Exercises the GENERIC gazette keyword-search machinery with a small
      # synthetic catalog — no Bijeljina data here (that lives in the host app
      # and is tested in DecidimApp::Bijeljina::GazetteTest).
      class GazetteIndexTest < ActiveSupport::TestCase
        ENTRIES = [
          {
            title: "Службени гласник",
            number: "03/2026",
            date: "2. марта 2026. године",
            url: "https://example.test/3-26.pdf",
            summary: "Одлука о јавним паркиралиштима и паркинг зонама у граду."
          },
          {
            title: "Службени гласник",
            number: "02/2026",
            date: "17. фебруара 2026. године",
            url: "https://example.test/2-26.pdf",
            summary: "Одлука о доношењу привременог плана јавних набавки и буџета."
          },
          {
            title: "Службени гласник",
            number: "01/2026",
            date: "23. јануара 2026. године",
            url: "https://example.test/1-26.pdf",
            summary: "Рјешење о именовању в.д. директора јавног предузећа."
          }
        ].freeze

        def index
          @index ||= GazetteIndex.new(ENTRIES)
        end

        test "all returns the entries as public hashes in declaration order" do
          entries = index.all
          numbers = entries.map { |entry| entry[:number] }

          assert_equal %w(03/2026 02/2026 01/2026), numbers
          assert_equal [:title, :number, :date, :url, :summary], entries.first.keys
        end

        test "search ranks entries by keyword relevance" do
          results = index.search("паркинг")

          assert_equal "03/2026", results.first[:number]
        end

        test "search is script-insensitive (Latin query matches Cyrillic body)" do
          assert_equal(index.search("паркинг").map { |entry| entry[:number] },
                       index.search("parking").map { |entry| entry[:number] })
        end

        test "search is diacritic-insensitive" do
          # "набавки" folds to "nabavki"; a query "nabavki" must still hit.
          results = index.search("nabavki")

          assert_equal "02/2026", results.first[:number]
        end

        test "search matches partial tokens (substring)" do
          # "imenovanju" is a substring-style hit against "именовању".
          results = index.search("imenovanje direktora")

          assert_equal "01/2026", results.first[:number]
        end

        test "search by issue number works" do
          results = index.search("02/2026")

          assert_equal "02/2026", results.first[:number]
        end

        test "search honours the limit" do
          assert_equal 1, index.search("одлука", limit: 1).size
        end

        test "search returns [] for an unknown query" do
          assert_empty index.search("банана свемир квантна")
        end

        test "search returns [] for a blank query" do
          assert_empty index.search("")
          assert_empty index.search(nil)
        end

        test "recent orders newest issue first by publication date" do
          numbers = index.recent.map { |entry| entry[:number] }

          assert_equal %w(03/2026 02/2026 01/2026), numbers
        end

        test "recent honours the limit" do
          assert_equal(%w(03/2026 02/2026), index.recent(limit: 2).map { |e| e[:number] })
        end

        test "recent falls back to issue number when dates are unparseable" do
          entries = [
            { title: "Г", number: "01/2025", date: "garbled", url: "u1" },
            { title: "Г", number: "12/2025", date: "garbled", url: "u2" }
          ]
          numbers = GazetteIndex.new(entries).recent.map { |entry| entry[:number] }

          assert_equal %w(12/2025 01/2025), numbers
        end

        test "recent orders by parsed publication date, not by issue number" do
          # A back-dated correction: the higher issue number is the OLDER date.
          # Date-based ordering must win, so the December issue (lower number)
          # comes first even though its number sorts below the January one.
          entries = [
            { title: "Г", number: "10/2026", date: "5. јануара 2026. године", url: "u1" },
            { title: "Г", number: "01/2026", date: "20. децембра 2026. године", url: "u2" }
          ]
          numbers = GazetteIndex.new(entries).recent.map { |entry| entry[:number] }

          assert_equal %w(01/2026 10/2026), numbers
        end

        test "constructor rejects a non-Array argument" do
          error = assert_raises(StandardError) { GazetteIndex.new("nope") }

          assert_kind_of GazetteError, error
        end

        test "constructor rejects a non-Hash entry" do
          error = assert_raises(StandardError) { GazetteIndex.new(["nope"]) }

          assert_kind_of GazetteError, error
        end

        # ---- .from_index_html parser (authored synthetic index) ----

        def fixture_html
          issues = 7.downto(1).map do |issue|
            number = issue == 5 ? "5/40" : "#{issue.to_s.rjust(2, '0')}/2040"
            %(<a href="/synthetic/issue-#{issue}.pdf">Измишљени службени гласник #{number} од 14. јуна 2040. године</a>)
          end.join
          "<html><body>#{issues}<a href='/synthetic/other.pdf'>Други документ</a>" \
            "<a href='/synthetic/index.html'>Службени гласник 99/2040</a></body></html>"
        end

        test "from_index_html extracts only the gazette issue links" do
          entries = GazetteIndex.from_index_html(fixture_html).all

          assert_equal 7, entries.size
          assert(entries.all? { |entry| entry[:url].end_with?(".pdf") })
        end

        test "from_index_html normalizes issue numbers and captures dates" do
          entries = GazetteIndex.from_index_html(fixture_html).all
          latest = entries.first

          assert_equal "07/2040", latest[:number]
          assert_equal "14. јуна 2040. године", latest[:date]
          assert_equal "/synthetic/issue-7.pdf", latest[:url]
        end

        test "from_index_html normalizes the short 5/40 form to 05/2040" do
          entries = GazetteIndex.from_index_html(fixture_html).all
          numbers = entries.map { |entry| entry[:number] }

          assert_includes numbers, "05/2040"
        end

        test "from_index_html absolutizes relative hrefs against base_url" do
          entries = GazetteIndex.from_index_html(fixture_html, base_url: "https://community.example.invalid").all

          assert_equal "https://community.example.invalid/synthetic/issue-7.pdf",
                       entries.first[:url]
        end

        test "from_index_html result is searchable and recent-ordered" do
          parsed = GazetteIndex.from_index_html(fixture_html)

          assert_equal "07/2040", parsed.recent.first[:number]
          assert_equal "02/2040", parsed.search("02/2040").first[:number]
        end

        test "duplicate issue links retain the first citation and unrelated documents are ignored" do
          duplicate = '<a href="/synthetic/duplicate.pdf">Службени гласник 07/2040 од 15. јуна 2040. године</a>'
          entries = GazetteIndex.from_index_html(fixture_html + duplicate).all
          assert_equal 7, entries.size
          assert_equal "/synthetic/issue-7.pdf", entries.first.fetch(:url)
          refute_includes entries.map { |row| row.fetch(:number) }, "99/2040"
        end

        test "from_index_html raises on blank html" do
          error = assert_raises(StandardError) { GazetteIndex.from_index_html("") }

          assert_kind_of GazetteError, error
        end
      end
    end
  end
end
