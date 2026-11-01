# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/synthetic_reference_archive"

module DecidimApp
  module Bijeljina
    # Authored community catalog and real generic index/cache wiring; no
    # municipal issue, extracted decision or actual publisher is copied.
    class GazetteTest < ActiveSupport::TestCase
      include SyntheticReferenceArchive

      setup do
        @prior_gazette_env = %w(MI_GAZETTE_SOURCE_URL BIJELJINA_GAZETTE_URL).to_h { |key| [key, ENV[key]] }
        @prior_gazette_env.each_key { |key| ENV.delete(key) }
        travel_to Time.utc(2026, 9, 15, 12)
        DecidimApp::CityServiceSourceSnapshot.delete_all
        install_synthetic_reference_archive
        rows = synthetic_archive_entries.map do |row|
          summary = row[:number] == "02/2026" ? "Измишљени примјер: javne nabavke; pregled nabavki." : nil
          row.merge(date: "#{row.fetch(:number).to_i}. јуна 2026. године", summary:)
        end
        swap_archive_constant(GazetteData, :ENTRIES, rows.freeze)
        @store = CityServiceSourceCheckStore.new
        Gazette.reset!
      end

      teardown do
        Gazette.reset!
        restore_synthetic_reference_archive
        @prior_gazette_env.each { |key, value| value ? ENV[key] = value : ENV.delete(key) }
        travel_back
      end

      test "index builds a GazetteIndex from the bundled catalog" do
        assert_instance_of Decidim::Bih::City::GazetteIndex, Gazette.index
        assert_not_empty Gazette.index.all
      end

      test "memoizes the index" do
        assert_same Gazette.index, Gazette.index
      end

      test "every catalog entry has the documented fields" do
        Gazette.index.all.each do |entry|
          assert entry[:title].present?, "missing title"
          assert_match(%r{\A\d{2}/\d{4}\z}, entry[:number])
          assert entry[:date].present?, "missing date for #{entry[:number]}"
          assert entry[:url].to_s.end_with?(".pdf"), "url not a pdf for #{entry[:number]}"
        end
      end

      test "does not surface issues whose contents were not extracted (no fabricated summaries)" do
        # "parking" only ever appeared in placeholder summaries, which were
        # removed — searching it now correctly returns nothing rather than a
        # fabricated decision.
        assert_empty Gazette.index.search("паркинг")
      end

      test "query is script-insensitive over authored content (Latin matches Cyrillic)" do
        latin = Gazette.index.search("nabavki").map { |entry| entry[:number] }
        cyrillic = Gazette.index.search("набавки").map { |entry| entry[:number] }

        assert_not_empty latin
        assert_equal cyrillic, latin
      end

      test "finds the public-procurement decision (javne nabavke)" do
        results = Gazette.index.search("javne nabavke")

        assert_includes results.map { |entry| entry[:number] }, "02/2026"
      end

      test "recent returns the newest issues first" do
        recent = Gazette.index.recent(limit: 3).map { |entry| entry[:number] }

        assert_equal %w(07/2026 06/2026 05/2026), recent
      end

      test "unknown query returns no results" do
        assert_empty Gazette.index.search("автомобил квантна физика свемир")
      end

      test "exposes no inherited municipal source url" do
        assert_equal(
          "",
          Gazette::DEFAULT_SOURCE_URL
        )
        assert_equal Gazette::DEFAULT_SOURCE_URL, Gazette.source_url
      end

      def promote_index(source_url: SyntheticReferenceArchive::URL, entries: nil, version: CityReferenceRefresh::VERSION, extra: {})
        entry = GazetteData::ENTRIES.first.merge(number: "30/2026", source_pdf_pages: [2])
        payload = { "status" => "ok", "source_url" => source_url, "source_identity" => GazetteSourceIdentity.for_url(source_url),
                    "entries" => JSON.parse(JSON.generate(entries || [entry])) }.merge(extra)
        @store.promote(source_key: CityReferenceRefresh::GAZETTE_KEY, source_version: version, payload:, success: true,
                       attempted_at: Time.current, checked_at: Time.current, content_hash: Digest::SHA256.hexdigest(JSON.generate(payload)))
      end

      test "prepared index and metadata require the selected publisher identity" do
        row = promote_index
        assert_equal row.id, Gazette.prepared_snapshot.id
        assert_equal ["30/2026"], Gazette.index.all.map { |entry| entry.fetch(:number) }
        assert_equal [2], Gazette.metadata_for("30/2026").fetch(:source_pdf_pages)
        assert_equal Date.new(2026, 9, 15), Gazette.index_checked_on
      end

      test "same-publisher failed attempts retain actual last-good reader data" do
        original = promote_index.last_good_payload.deep_dup
        @store.promote(source_key: CityReferenceRefresh::GAZETTE_KEY, source_version: CityReferenceRefresh::VERSION,
                       payload: { "status" => "unavailable", "error_code" => "synthetic_failure" }, success: false, attempted_at: Time.current + 60)
        assert_equal original, Gazette.prepared_snapshot.last_good_payload
        assert_equal ["30/2026"], Gazette.index.all.map { |entry| entry.fetch(:number) }
        assert_equal Date.new(2026, 9, 15), Gazette.index_checked_on
      end

      test "publisher changes invalidate memoized data dates pages and acts without resetting the module" do
        promote_index
        prior_index = Gazette.index
        ENV["MI_GAZETTE_SOURCE_URL"] = "https://other.example.invalid/archive/2026.html"
        assert_nil Gazette.prepared_snapshot
        assert_empty Gazette.index.all
        assert_not_same prior_index, Gazette.index
        assert_nil Gazette.index_checked_on
        assert_nil Gazette.metadata_for("30/2026")
        assert_nil Gazette.metadata_for("02/2026")
        assert_empty Gazette.acts
      end

      test "archive path and query changes are new sources even on the same host" do
        promote_index
        ["https://community.example.invalid/other.html", "https://community.example.invalid/archive/2026.html?selection=other"].each do |url|
          ENV["MI_GAZETTE_SOURCE_URL"] = url
          assert_nil Gazette.prepared_snapshot
          assert_empty Gazette.index.all
          assert_nil Gazette.index_checked_on
        end
      end

      test "headerless legacy snapshots remain stored but cannot become a prepared publisher index" do
        row = promote_index(extra: { "source_identity" => nil })
        assert_nil Gazette.prepared_snapshot
        assert_not_includes Gazette.index.all.map { |entry| entry.fetch(:number) }, "30/2026"
        assert_equal row.id, @store.snapshot(source_key: CityReferenceRefresh::GAZETTE_KEY).id
        assert_equal 7, Gazette.index.all.size
      end

      test "contradictory source url and identity headers cannot lend prepared facts" do
        promote_index(extra: { "source_url" => "https://other.example.invalid/archive/2026.html" })
        assert_nil Gazette.prepared_snapshot
        assert_not_includes Gazette.index.all.map { |entry| entry.fetch(:number) }, "30/2026"
      end

      test "no publisher or reviewed catalogue means no stored-cache lookup or inherited evidence" do
        promote_index
        swap_archive_constant(GazetteData, :BASE, "")
        CityServiceSourceCheckStore.stub(:new, ->(**) { raise "unconfigured publisher must not read cache" }) do
          assert_empty Gazette.index.all
          assert_nil Gazette.index_checked_on
          assert_nil Gazette.metadata_for("30/2026")
          assert_empty Gazette.acts
        end
      end

      test "an explicitly reviewed offline catalogue works without enabling background fetching" do
        assert_empty Gazette.source_url
        assert_equal SyntheticReferenceArchive::URL, Gazette.current_source_url
        assert_equal 7, Gazette.index.all.size
        assert_equal Date.new(2026, 9, 9), Gazette.index_checked_on
        assert_equal [1], Gazette.metadata_for("02/2026").fetch(:source_pdf_pages)
      end

      test "source url honours the BIJELJINA_GAZETTE_URL env override" do
        ENV["BIJELJINA_GAZETTE_URL"] = "https://override.test/glasnik"
        assert_equal "https://override.test/glasnik", Gazette.source_url
      ensure
        ENV.delete("BIJELJINA_GAZETTE_URL")
      end
    end
  end
end
