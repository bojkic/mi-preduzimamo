# frozen_string_literal: true

require "test_helper"
require "webmock/minitest"
require_relative "../../../support/synthetic_procedures"
require_relative "../../../support/synthetic_reference_archive"

module DecidimApp
  module Bijeljina
    class CityReferenceRefreshTest < ActiveSupport::TestCase
      include SyntheticProcedures
      include SyntheticReferenceArchive
      setup do
        config = WebMock::Config.instance
        @webmock_config = %i(allow_net_connect allow_localhost allow net_http_connect_on_start).to_h { |key| [key, config.public_send(key)] }
        WebMock.disable_net_connect!
        DecidimApp::CityServiceSourceSnapshot.delete_all
        @now = Time.utc(2026, 9, 9, 12)
        @store = CityServiceSourceCheckStore.new(clock: -> { @now })
        install_synthetic_procedures(day: @now.to_date)
        install_synthetic_reference_archive
      end

      teardown do
        restore_synthetic_reference_archive
        restore_synthetic_procedures
        WebMock.reset!
        @webmock_config.each { |key, value| WebMock::Config.instance.public_send("#{key}=", value) }
      end

      test "procedure review barrier survives failed checks and clears only when reviewed content returns" do
        documents = ServiceProcedures.all.to_h do |card|
          [card[:source_url], synthetic_procedure_html(card.fetch(:key))]
        end
        fetcher = lambda do |source:, **|
          body = documents.fetch(source.fetch(:source_url))
          { http_status: body ? 200 : 503, body: body.to_s }
        end
        refresh = CityReferenceRefresh.new(store: @store, fetcher:, clock: -> { @now })
        results = refresh.refresh_procedures
        assert(results.all? { |result| result[:status] == "ok" })
        assert(results.all? { |result| result[:reviewed_on] == ServiceProcedures.find(result[:key])[:source_checked_on] })
        original = @store.snapshot(source_key: "reference:procedure:maticar").last_good_payload
        card = ServiceProcedures.find(:maticar)
        original_document = documents.fetch(card.fetch(:source_url))
        reader = Milica::ProcedureRead.new(source_store: @store)
        documents[card.fetch(:source_url)] = '<div class="entry__article">Changed requirements</div>'
        @now += 1.day
        result = refresh.refresh_procedures.find { |entry| entry[:key] == :maticar || entry[:key] == "maticar" }
        assert_equal "unreviewed", result[:status]
        row = @store.snapshot(source_key: "reference:procedure:maticar")
        assert_equal original, row.last_good_payload
        assert_equal "procedure_content_changed", row.check_payload["error_code"]
        assert_equal "unreviewed", reader.call(card:, locale: "sr", now: @now)[:status]

        documents[card.fetch(:source_url)] = nil
        2.times do
          @now += 1.day
          refresh.refresh_procedures
          row = @store.snapshot(source_key: "reference:procedure:maticar")
          assert_equal "unavailable", row.check_payload["status"]
          assert_equal original, row.last_good_payload
          blocked = reader.call(card:, locale: "sr", now: @now)
          assert_equal "unreviewed", blocked[:status]
          assert_nil blocked[:facts]
        end

        documents[card.fetch(:source_url)] = original_document
        @now += 1.day
        refresh.refresh_procedures
        row = @store.snapshot(source_key: "reference:procedure:maticar")
        assert_equal "ok", row.check_payload["status"]
        assert_not row.check_payload.has_key?("review_required_for_hash")
        restored = reader.call(card:, locale: "sr", now: @now)
        assert_equal "ok", restored[:status]
        assert_equal "2026-09-09", restored[:validity]["reviewed_on"]
      end

      test "reference failures are recorded before releasing the refresh lock" do
        held = false
        promotions = 0
        store = Object.new
        store.define_singleton_method(:with_refresh_lock) do |_, &block|
          held = true
          block.call
        ensure
          held = false
        end
        store.define_singleton_method(:snapshot) { |**| nil }
        assertion = -> { assert held, "failure promotion must remain inside the source lock" }
        store.define_singleton_method(:promote) do |**|
          assertion.call
          promotions += 1
        end
        fetcher = ->(**) { raise IOError, "Synthetic reference failure" }

        CityReferenceRefresh.new(store:, fetcher:, clock: -> { @now }).call

        assert_equal 1 + ServiceProcedures.all.size, promotions
        assert_not held
      end

      test "unconfigured archive and empty procedure catalogue do not lock read promote or fetch" do
        swap_archive_constant(CityReferenceRefresh, :GAZETTE_URL, "")
        ServiceProcedures.instance_variable_set(:@all, [].freeze)
        store = Object.new
        %i(with_refresh_lock snapshot promote).each do |method|
          store.define_singleton_method(method) { |*_, **_, &_block| raise "unconfigured source must not touch storage" }
        end
        refresh = CityReferenceRefresh.new(store:, fetcher: ->(**) { raise "unconfigured source must not fetch" })
        assert_equal :disabled, refresh.refresh_gazette.fetch(:status)
        result = refresh.call
        assert_equal :disabled, result.fetch(:gazette).fetch(:status)
        assert_empty result.fetch(:procedures)
      end

      test "a truncated later archive preserves an actual last-good issue snapshot" do
        html = synthetic_archive_html
        fetcher = ->(source:, **) { { http_status: 200, body: source.fetch(:source_url).end_with?(".pdf") ? "%PDF-1.4 authored bytes" : html } }
        refresh = CityReferenceRefresh.new(store: @store, fetcher:, clock: -> { @now })
        assert_equal :ok, refresh.refresh_gazette.fetch(:status)
        original = @store.snapshot(source_key: CityReferenceRefresh::GAZETTE_KEY).last_good_payload.deep_dup
        html = synthetic_archive_html(issues: [7])
        assert_equal :unavailable, refresh.refresh_gazette.fetch(:status)
        assert_equal original, @store.snapshot(source_key: CityReferenceRefresh::GAZETTE_KEY).last_good_payload
        assert_equal 7, original.fetch("entries").size
      end

      test "unapproved or credential-bearing archive document links never reach a fetcher" do
        ["https://other.example.invalid/archive/authored-issue-7.pdf",
         "https://user:synthetic-password@community.example.invalid/archive/authored-issue-7.pdf"].each do |bad_url|
          calls = []
          html = synthetic_archive_html.sub('/archive/authored-issue-7.pdf', bad_url)
          fetcher = lambda do |source:, **|
            url = source.fetch(:source_url)
            calls << url
            raise "bad archive document must not be fetched" unless url == SyntheticReferenceArchive::URL

            { http_status: 200, body: html }
          end
          result = CityReferenceRefresh.new(store: @store, fetcher:, clock: -> { @now }).refresh_gazette
          assert_equal :unavailable, result.fetch(:status)
          assert_equal [SyntheticReferenceArchive::URL], calls
          assert_empty @store.snapshot(source_key: CityReferenceRefresh::GAZETTE_KEY).last_good_payload
        end
      end

      test "unapproved credential-bearing or nonhttps procedure sources fail before a fetcher" do
        original = ServiceProcedures.find("maticar")
        ["https://unapproved.example.invalid/procedure", "http://community.example.invalid/procedure",
         "https://user:synthetic-password@community.example.invalid/procedure", "https://community.example.invalid:444/procedure"].each do |url|
          ServiceProcedures.instance_variable_set(:@all, [original.merge(source_url: url)].freeze)
          calls = []
          fetcher = ->(source:, **) { calls << source.fetch(:source_url); raise "unapproved procedure must not fetch" }
          result = CityReferenceRefresh.new(store: @store, fetcher:, clock: -> { @now }).refresh_procedures
          assert_equal "maticar", result.first.fetch(:key)
          assert_equal :unavailable, result.first.fetch(:status)
          assert_empty calls
        end
      end

      test "a credential-bearing final URL on the same archive path is rejected" do
        calls = []
        fetcher = lambda do |source:, **|
          calls << source.fetch(:source_url)
          { http_status: 200, body: synthetic_archive_html,
            final_url: "https://user:synthetic-password@community.example.invalid/archive/2026.html" }
        end
        result = CityReferenceRefresh.new(store: @store, fetcher:, clock: -> { @now }).refresh_gazette
        assert_equal :unavailable, result.fetch(:status)
        assert_equal [SyntheticReferenceArchive::URL], calls
        assert_empty @store.snapshot(source_key: CityReferenceRefresh::GAZETTE_KEY).last_good_payload
      end

      test "malformed archive configuration does not block separately reviewed procedure sources" do
        swap_archive_constant(CityReferenceRefresh, :GAZETTE_URL, "not a valid URI")
        documents = ServiceProcedures.all.to_h { |card| [card.fetch(:source_url), synthetic_procedure_html(card.fetch(:key))] }
        calls = []
        fetcher = lambda do |source:, **|
          url = source.fetch(:source_url)
          calls << url
          { http_status: 200, body: documents.fetch(url) }
        end
        results = CityReferenceRefresh.new(store: @store, fetcher:, clock: -> { @now }).refresh_procedures
        assert_equal 4, results.size
        assert results.all? { |result| result.fetch(:status) == "ok" }
        assert_equal documents.keys.sort, calls.sort
      end

      test "an archive host does not implicitly approve procedure fetching on that host" do
        swap_archive_constant(ServiceProcedures, :REVIEWED_HOSTS, [].freeze)
        calls = []
        fetcher = ->(source:, **) { calls << source.fetch(:source_url); raise "archive approval cannot authorize procedure fetching" }
        results = CityReferenceRefresh.new(store: @store, fetcher:, clock: -> { @now }).refresh_procedures
        assert_equal 4, results.size
        assert results.all? { |result| result.fetch(:status) == :unavailable }
        assert_empty calls
      end

      test "a reviewed single-issue community archive does not inherit a municipal issue count" do
        swap_archive_constant(GazetteData, :ENTRIES, [synthetic_archive_entries.first].freeze)
        fetcher = ->(source:, **) { { http_status: 200, body: source.fetch(:source_url).end_with?(".pdf") ? "%PDF-1.4 authored bytes" : synthetic_archive_html(issues: [7]) } }
        result = CityReferenceRefresh.new(store: @store, fetcher:, clock: -> { @now }).refresh_gazette
        assert_equal :ok, result.fetch(:status)
        assert_equal 1, result.fetch(:count)
        coverage = @store.snapshot(source_key: CityReferenceRefresh::GAZETTE_KEY).last_good_payload.fetch("coverage")
        assert_equal 1, coverage.fetch("observed_issue_count")
        assert_equal false, coverage.fetch("full_year_complete")
      end

      test "archive promotion records the canonical configured publisher and identity" do
        fetcher = ->(source:, **) { { http_status: 200, body: source.fetch(:source_url).end_with?(".pdf") ? "%PDF-1.4 authored bytes" : synthetic_archive_html } }
        result = CityReferenceRefresh.new(store: @store, fetcher:, clock: -> { @now }).refresh_gazette
        assert_equal :ok, result.fetch(:status)
        payload = @store.snapshot(source_key: CityReferenceRefresh::GAZETTE_KEY).last_good_payload
        assert_equal SyntheticReferenceArchive::URL, payload.fetch("source_url")
        assert_equal GazetteSourceIdentity.for_url(SyntheticReferenceArchive::URL), payload.fetch("source_identity")
        assert GazetteSourceIdentity.matches_payload?(payload, source_url: SyntheticReferenceArchive::URL)
      end

      test "another publisher's last-good count does not block a reviewed single-issue archive" do
        fetcher = ->(source:, **) { { http_status: 200, body: source.fetch(:source_url).end_with?(".pdf") ? "%PDF-1.4 authored bytes" : synthetic_archive_html } }
        assert_equal :ok, CityReferenceRefresh.new(store: @store, fetcher:, clock: -> { @now }).refresh_gazette.fetch(:status)
        other_url = "https://other.example.invalid/archive/2026.html"
        swap_archive_constant(CityReferenceRefresh, :GAZETTE_URL, other_url)
        swap_archive_constant(GazetteData, :BASE, other_url)
        entry = synthetic_archive_entries.first.merge(url: "https://other.example.invalid/archive/authored-issue-7.pdf")
        swap_archive_constant(GazetteData, :ENTRIES, [entry].freeze)
        fetcher = ->(source:, **) { { http_status: 200, body: source.fetch(:source_url).end_with?(".pdf") ? "%PDF-1.4 other authored bytes" : synthetic_archive_html(issues: [7]) } }
        result = CityReferenceRefresh.new(store: @store, fetcher:, clock: -> { @now }).refresh_gazette
        assert_equal :ok, result.fetch(:status)
        assert_equal 1, result.fetch(:count)
        payload = @store.snapshot(source_key: CityReferenceRefresh::GAZETTE_KEY).last_good_payload
        assert GazetteSourceIdentity.matches_payload?(payload, source_url: other_url)
        assert_equal 1, payload.fetch("entries").size
      end

      test "unbound catalogues cannot lend old-year entries summaries pages or review provenance" do
        other_url = "https://other.example.invalid/archive/2026.html"
        swap_archive_constant(CityReferenceRefresh, :GAZETTE_URL, other_url)
        legacy = synthetic_archive_entries.first.merge(number: "07/2025")
        swap_archive_constant(GazetteData, :ENTRIES, [*synthetic_archive_entries, legacy].freeze)
        fetcher = ->(source:, **) { { http_status: 200, body: source.fetch(:source_url).end_with?(".pdf") ? "%PDF-1.4 authored original-7" : synthetic_archive_html(issues: [7]) } }
        result = CityReferenceRefresh.new(store: @store, fetcher:, clock: -> { @now }).refresh_gazette
        assert_equal :ok, result.fetch(:status)
        rows = @store.snapshot(source_key: CityReferenceRefresh::GAZETTE_KEY).last_good_payload.fetch("entries")
        assert_equal ["07/2026"], rows.map { |entry| entry.fetch("number") }
        assert_nil rows.first.fetch("summary")
        assert_empty rows.first.fetch("source_pdf_pages")
        assert_equal "issue_metadata_only", rows.first.fetch("summary_provenance")
      end

      test "archive preparation tracks current URLs and drops summaries when PDF content changes" do
        html = synthetic_archive_html
        fetcher = lambda do |source:, **|
          body = source.fetch(:source_url).end_with?(".pdf") ? "%PDF-1.4 changed document" : html
          { http_status: 200, body: }
        end
        result = CityReferenceRefresh.new(store: @store, fetcher:, clock: -> { @now }).refresh_gazette
        assert_equal :ok, result[:status]
        assert_equal 7, result[:count]
        rows = @store.snapshot(source_key: CityReferenceRefresh::GAZETTE_KEY).last_good_payload.fetch("entries")
        current = rows.select { |entry| entry["number"].end_with?("/2026") }
        assert(current.all? { |entry| entry["summary"].nil? })
        assert(current.all? { |entry| entry["summary_provenance"] == "issue_metadata_only" })
        assert(current.all? { |entry| entry["reviewed_acts"].empty? })
      end

      test "a truncated archive cannot erase the valid year snapshot" do
        fetcher = ->(**) { { http_status: 200, body: synthetic_archive_html(issues: [7]) } }
        result = CityReferenceRefresh.new(store: @store, fetcher:, clock: -> { @now }).refresh_gazette
        assert_equal :unavailable, result[:status]
        assert_empty @store.snapshot(source_key: CityReferenceRefresh::GAZETTE_KEY).last_good_payload
      end
    end
  end
end
