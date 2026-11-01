# frozen_string_literal: true

require "test_helper"
require "rake"
require "tmpdir"

module Tasks
  # Nightly rollup of the 48-hour Redis chat metrics into
  # decidim_bih_concierge_metric_rollups: yesterday and today in Europe/Sarajevo,
  # positive counts only, stamped with release SHA and prompt version, idempotent.
  class MilicaMetricsRollupTest < ActiveSupport::TestCase
    TASK = "decidim_bih:concierge:rollup_metrics"
    Metrics = DecidimApp::Bijeljina::Milica

    def self.load_tasks
      return if Rake::Task.task_defined?(TASK)

      Rails.application.load_tasks
    end

    setup do
      self.class.load_tasks
      @organization = create_organization
      @cache = ActiveSupport::Cache::MemoryStore.new
    end

    teardown do
      Rake::Task[TASK].reenable
    end

    def run_task(host = @organization.host)
      Rake::Task[TASK].reenable
      capture_io { Rake::Task[TASK].invoke(host) }
    end

    def rows
      Decidim::Bih::ConciergeMetricRollup.where(organization: @organization)
    end

    def row(day:, kind:, topic:, label:, latency_bucket: nil)
      rows.find_by(day:, kind:, topic:, label:, latency_bucket:)
    end

    test "aborts when the host does not resolve to an organization" do
      assert_raises(SystemExit) { run_task("nope.example.org") }
      assert_equal 0, Decidim::Bih::ConciergeMetricRollup.count
    end

    test "rolls yesterday's and today's Sarajevo-day buckets into stamped rows and stays idempotent" do
      now = Time.zone.local(2026, 9, 13, 3, 5) # Europe/Sarajevo, CEST
      yesterday = Date.new(2026, 9, 12)
      today = Date.new(2026, 9, 13)

      Rails.stub(:cache, @cache) do
        travel_to(now) do
          # Yesterday, local day edges included: 00:15 CEST is still 2026-09-11 22:15 UTC.
          Metrics::AnswerMetrics.record(topic: "water", outcome: "fallback", now: Time.zone.local(2026, 9, 12, 0, 15))
          Metrics::AnswerMetrics.record(topic: "water", outcome: "answered", now: Time.zone.local(2026, 9, 12, 10))
          Metrics::AnswerMetrics.record(topic: "water", outcome: "answered", now: Time.zone.local(2026, 9, 12, 23, 30))
          Metrics::ReadMetrics.record(topic: "waste", action: "ask_information", status: "ok", elapsed_ms: 42.0,
                                      now: Time.zone.local(2026, 9, 12, 12))
          Metrics::ReadMetrics.record_stage(stage: "understanding", status: "completed", duration_ms: 900, now: Time.zone.local(2026, 9, 12, 12))
          # Today so far.
          Metrics::AnswerMetrics.record(topic: "unknown", outcome: "busy", now: Time.zone.local(2026, 9, 13, 1, 10))
          Metrics::ReadMetrics.record_stage(stage: "understanding", status: "completed", duration_ms: 900, now: Time.zone.local(2026, 9, 13, 2))

          stdout, = run_task

          assert_match(/concierge rollup host=#{Regexp.escape(@organization.host)} days=2026-09-12,2026-09-13 rows=6/, stdout)
          assert_match(/prompt_version=#{Decidim::Bih::Concierge::Dialogue::Contracts::VERSION}\b/, stdout)

          assert_equal 2, row(day: yesterday, kind: "answer", topic: "water", label: "answered").count
          assert_equal 1, row(day: yesterday, kind: "answer", topic: "water", label: "fallback").count
          assert_equal 1, row(day: today, kind: "answer", topic: "unknown", label: "busy").count
          assert_nil row(day: today, kind: "answer", topic: "water", label: "answered"), "yesterday's answers must not leak into today"
          assert_equal 1, row(day: yesterday, kind: "read", topic: "waste", label: "ok", latency_bucket: "50").count
          assert_equal 1, row(day: yesterday, kind: "stage", topic: "understanding", label: "completed", latency_bucket: "1000").count
          assert_equal 1, row(day: today, kind: "stage", topic: "understanding", label: "completed", latency_bucket: "1000").count
          assert_nil row(day: yesterday, kind: "answer", topic: "water", label: "clarification"), "a zero count is never written"
          assert_equal 6, rows.count

          stamped = rows.first
          assert_equal Decidim::Bih::Concierge::Dialogue::Contracts::VERSION, stamped.prompt_version
          expected_sha = Metrics::MetricRollup.release_sha
          assert_equal expected_sha, stamped.release_sha
          assert(expected_sha.nil? || expected_sha.match?(/\A\h{40}\z/))

          # A second run rewrites the same rows with the same counts.
          run_task
          assert_equal 6, rows.count
          assert_equal 2, row(day: yesterday, kind: "answer", topic: "water", label: "answered").count

          # A counter that moved is overwritten with the snapshot value, not incremented twice.
          Metrics::AnswerMetrics.record(topic: "water", outcome: "answered", now: Time.zone.local(2026, 9, 12, 11))
          run_task
          assert_equal 3, row(day: yesterday, kind: "answer", topic: "water", label: "answered").count
          assert_equal 6, rows.count
        end
      end
    end

    test "expired snapshot keys never erase a stored day" do
      now = Time.zone.local(2026, 9, 13, 3, 5)
      Decidim::Bih::ConciergeMetricRollup.create!(
        organization: @organization, day: Date.new(2026, 9, 12), kind: "answer", topic: "water", label: "answered", count: 7
      )

      Rails.stub(:cache, @cache) do
        travel_to(now) { run_task }
      end

      assert_equal 7, row(day: Date.new(2026, 9, 12), kind: "answer", topic: "water", label: "answered").count
    end

    test "rows never carry text, identifiers or coordinates" do
      columns = Decidim::Bih::ConciergeMetricRollup.column_names
      %w(text message body sender digest user_id latitude longitude phone email payload).each do |forbidden|
        assert_empty columns.grep(/#{forbidden}/), "column matching #{forbidden} must not exist"
      end
      assert_equal %w(count created_at day decidim_organization_id facet id kind label latency_bucket prompt_version release_sha topic traffic_kind updated_at),
                   columns.sort
    end

    test "dimensioned counters retain capture release and remain separate from legacy totals" do
      now = Time.zone.local(2026, 9, 15, 3)
      yesterday = now.to_date - 1
      samples = [{ topic: "water", label: "answered", facet: "status", traffic_kind: "synthetic", release_sha: "a" * 40, prompt_version: 1, count: 6 }]
      snapshot = lambda do |**options|
        options.fetch(:now).to_date == yesterday ? samples : []
      end
      Rails.stub(:cache, @cache) do
        Metrics::DimensionedAnswerMetrics.stub(:snapshot, snapshot) do
          rollup = Metrics::MetricRollup.new(organization: @organization, now:, release_sha: "b" * 40, prompt_version: 2)
          2.times { rollup.call }
          detail = rows.find_by(kind: "answer_detail")
          assert_equal 6, detail.count
          assert_equal "a" * 40, detail.release_sha
          assert_equal 1, detail.prompt_version
          assert_equal "synthetic", detail.traffic_kind
          assert_equal "status", detail.facet
          assert_equal 1, rows.where(kind: "answer_detail").count
          assert_equal 0, rows.where(kind: "answer").sum(:count)
          samples.first[:count] = 2 # expired/partial cache cannot reduce a durable bucket
          rollup.call
          assert_equal 6, detail.reload.count
        end
      end
    end

    test "late concurrent detail views cannot overwrite a larger saved snapshot" do
      attributes = detail_attributes(count: 10)
      stored = Decidim::Bih::ConciergeMetricRollup.create!(organization: @organization, day: Date.new(2026, 9, 14), kind: "answer_detail", **attributes)
      # Two workers have loaded count10 before either saves. The larger worker
      # finishes first; the old read/max/save path then incorrectly saved90.
      stale_views = 2.times.map { Decidim::Bih::ConciergeMetricRollup.find(stored.id) }
      loader = ->(**) { stale_views.shift }
      Decidim::Bih::ConciergeMetricRollup.stub(:find_or_initialize_by, loader) do
        write_detail(attributes.merge(count: 100))
        write_detail(attributes.merge(count: 90))
      end
      assert_equal 100, stored.reload.count
      assert_equal 1, rows.where(kind: "answer_detail").count
    end

    test "simultaneous first detail inserts converge without a uniqueness error" do
      attributes = detail_attributes(count: 10)
      # Both workers observed no row. The old implementation's second save!
      # raised RecordNotUnique instead of preserving and completing the bucket.
      pending_views = 2.times.map do
        Decidim::Bih::ConciergeMetricRollup.new(organization: @organization, day: Date.new(2026, 9, 14), kind: "answer_detail", **attributes)
      end
      loader = ->(**) { pending_views.shift }
      Decidim::Bih::ConciergeMetricRollup.stub(:find_or_initialize_by, loader) do
        write_detail(attributes.merge(count: 90))
        write_detail(attributes.merge(count: 100))
      end
      assert_equal 100, rows.find_by!(kind: "answer_detail").count
      assert_equal 1, rows.where(kind: "answer_detail").count
    end

    test "atomic detail identity keeps release facet traffic and nil release buckets separate" do
      write_detail(detail_attributes(count: 20))
      write_detail(detail_attributes(count: 7).merge(facet: "fee"))
      write_detail(detail_attributes(count: 8).merge(traffic_kind: "synthetic"))
      write_detail(detail_attributes(count: 9).merge(release_sha: "b" * 40))
      write_detail(detail_attributes(count: 6).merge(release_sha: nil, prompt_version: nil))
      write_detail(detail_attributes(count: 3).merge(release_sha: nil, prompt_version: nil))
      assert_equal [6, 7, 8, 9, 20], rows.where(kind: "answer_detail").order(:count).pluck(:count)
    end

    test "legacy snapshot upserts remain monotonic while refreshing rollup provenance" do
      rollup = Metrics::MetricRollup.new(organization: @organization, release_sha: "a" * 40, prompt_version: 1)
      key = { day: Date.new(2026, 9, 14), kind: "answer", topic: "water", label: "answered", latency_bucket: nil }
      rollup.send(:store_bucket, 100, key)
      later = Metrics::MetricRollup.new(organization: @organization, release_sha: "b" * 40, prompt_version: 2)
      later.send(:store_bucket, 90, key)
      stored = rows.find_by!(key)
      assert_equal 100, stored.count
      assert_equal "b" * 40, stored.release_sha
      assert_equal 2, stored.prompt_version
      assert_equal 1, rows.count
    end

    test "atomic writes still reject invalid metric dimensions before persistence" do
      assert_raises(ActiveRecord::RecordInvalid) { write_detail(detail_attributes(count: 6).merge(facet: "private text")) }
      assert_empty rows
    end

    def detail_attributes(count:)
      { topic: "water", label: "answered", facet: "status", traffic_kind: "unclassified", release_sha: "a" * 40, prompt_version: 1, count: }
    end

    def write_detail(attributes)
      rollup = Metrics::MetricRollup.new(organization: @organization, release_sha: nil, prompt_version: 1)
      now = Time.zone.local(2026, 9, 15, 3)
      Metrics::DimensionedAnswerMetrics.stub(:snapshot, [attributes]) do
        rollup.send(:write_dimensions, Date.new(2026, 9, 14), snapshot_now: now, hours: 24)
      end
    end

    test "release_sha is the checkout HEAD and nil without a repository" do
      sha = Metrics::MetricRollup.release_sha
      assert(sha.nil? || sha.match?(/\A\h{40}\z/), "release sha must be a full commit id or nil")

      Dir.mktmpdir("mi-no-git") do |dir|
        assert_nil Metrics::MetricRollup.release_sha(root: dir)
      end
    end

    test "days are yesterday and today in the application time zone" do
      rollup = Metrics::MetricRollup.new(organization: @organization, now: Time.utc(2026, 9, 12, 22, 30), release_sha: nil)

      # 22:30 UTC is already 00:30 on 13.9. in Sarajevo.
      assert_equal [Date.new(2026, 9, 12), Date.new(2026, 9, 13)], rollup.days
    end
  end
end
