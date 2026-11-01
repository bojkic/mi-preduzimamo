# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/synthetic_event_source_registry"

module DecidimApp
  module Bijeljina
    class CityServiceSourceCheckStoreTest < ActiveSupport::TestCase
      include SyntheticEventSourceRegistry
      setup do
        @now = Time.utc(2040, 9, 9, 12)
        @source = CityServiceSources.fetch("public_transport")
        @store = CityServiceSourceCheckStore.new(clock: -> { @now })
        DecidimApp::CityServiceSourceSnapshot.delete_all
      end

      test "cold citizen reads are unavailable without calling the collector" do
        collector = Object.new
        def collector.check(**)
          raise "citizen path attempted network collection"
        end
        store = CityServiceSourceCheckStore.new(collector:)

        result = store.check(keys: ["public_transport"], max_items: 8).first
        assert_equal :unavailable, result.status
        assert_equal :prepared_source_missing, result.error_code
      end

      test "pre-upgrade empty event snapshots stay unavailable until prepared under the current parser identity" do
        source = CityServiceSources.fetch("water_service")
        empty = CityServiceNoticeCollector::SourceCheckResult.new(source_key: "water_service", status: :empty, notices: [], checked_at: @now)
        @store.record(check: empty, source:)
        snapshot = @store.snapshot(source_key: "water_service")
        old_identity = Digest::SHA256.hexdigest(JSON.generate([CityServiceSourceCheckStore::PARSER_VERSION, source]))
        snapshot.update!(source_version: old_identity)
        result = @store.check(keys: ["water_service"]).sole
        assert_equal :unavailable, result.status
        assert_equal :prepared_source_version_changed, result.error_code
        assert_equal @now, snapshot.reload.last_success_at
        @store.record(check: empty, source:)
        assert_equal :empty, @store.check(keys: ["water_service"]).sole.status
        assert_not_equal old_identity, snapshot.reload.source_version
        assert_equal Digest::SHA256.hexdigest(JSON.generate([CityServiceSourceCheckStore::PARSER_VERSION, @source])), @store.version_for(@source)
      end

      test "one preparation supports distinct consumer limits and survives Redis eviction" do
        notices = 12.times.map { |index| notice(index) }
        @store.record(check: check(notices:), response: { body: "official listing" })
        Rails.cache.clear

        assert_equal 1, @store.check(keys: ["public_transport"], max_items: 1).first.notices.size
        result = @store.check(keys: ["public_transport"], max_items: 8).first
        assert_equal 8, result.notices.size
        assert_equal @now, result.checked_at
        assert_equal Digest::SHA256.hexdigest("official listing"), result.content_hash
      end

      test "failed refresh preserves recoverable last good and distinct last attempt" do
        @store.record(check: check(notices: [notice(1)]))
        old_time = @now
        @now += 60
        failure = CityServiceNoticeCollector::SourceCheckResult.new(source_key: "public_transport", status: :malformed,
                                                                    notices: [], error_code: :parser_error)
        @store.record(check: failure)
        result = @store.check(keys: ["public_transport"]).first
        row = @store.snapshot(source_key: "public_transport")

        assert_equal :malformed, result.status
        assert_nil result.checked_at
        assert_equal old_time, result.last_success_at
        assert_equal @now, result.attempted_at
        assert_equal 1, row.last_good_payload.fetch("notices").size
        assert_equal true, result.last_good_evidence.fetch("available")
        assert_equal old_time.iso8601, result.last_good_evidence.fetch("checked_at")
        assert_equal "retained_for_review_not_current_answer_evidence", result.last_good_evidence.fetch("usage")
        assert_empty result.notices
        assert_equal "ok", row.check_payload.fetch("history").last.fetch("status")
      end

      test "stale provider feed keeps its cause and preserves last good without exposing it" do
        @store.record(check: check(notices: [notice(1)]))
        previous_success = @now
        @now += 60
        stale = CityServiceNoticeCollector::SourceCheckResult.new(source_key: "public_transport", status: :stale,
                                                                  notices: [], error_code: :source_feed_stale)
        @store.record(check: stale)
        result = @store.check(keys: ["public_transport"]).sole
        assert_equal :stale, result.status
        assert_equal :source_feed_stale, result.error_code
        assert_equal previous_success, result.last_success_at
        assert_empty result.notices
        assert_equal 1, @store.snapshot(source_key: "public_transport").last_good_payload.fetch("notices").size
      end

      test "expired facts cannot become fresh from reading or a failed attempt" do
        @store.record(check: check(notices: [notice(1)]))
        original_time = @now
        @now += 15.days
        result = @store.check(keys: ["public_transport"]).first

        assert_equal :stale, result.status
        assert_equal original_time, result.checked_at
        assert_empty result.notices
      end

      test "caller deadline failure does not poison shared source health" do
        @store.record(check: check(notices: [notice(1)]))
        failure = CityServiceNoticeCollector::SourceCheckResult.new(source_key: "public_transport", status: :unavailable,
                                                                    notices: [], error_code: :deadline_exceeded)
        @store.record(check: failure)
        assert_equal :ok, @store.check(keys: ["public_transport"]).first.status
      end

      test "changed source version cannot reuse unrelated prior facts" do
        @store.record(check: check(notices: [notice(1)]))
        @store.stub(:version_for, "changed-parser-or-endpoint") do
          assert_equal :prepared_source_version_changed, @store.check(keys: ["public_transport"]).first.error_code
        end
      end

      test "failed attempt under changed version reports current cause without exposing last good" do
        @store.record(check: check(notices: [notice(1)]))
        @now += 60
        @store.stub(:version_for, "changed-parser-or-endpoint") do
          failure = CityServiceNoticeCollector::SourceCheckResult.new(source_key: "public_transport", status: :unavailable,
                                                                      notices: [], error_code: :source_unreachable)
          @store.record(check: failure)
          result = @store.check(keys: ["public_transport"]).sole
          assert_equal :unavailable, result.status
          assert_equal :source_unreachable, result.error_code
          assert_empty result.notices
          assert_equal true, result.last_good_evidence.fetch("available")
        end
      end

      test "partial attempt under changed version remains partial and cannot answer citizens" do
        @store.record(check: check(notices: [notice(1)]))
        @store.stub(:version_for, "changed-parser-or-endpoint") do
          partial = CityServiceNoticeCollector::SourceCheckResult.new(source_key: "public_transport", status: :ok,
                                                                      notices: [notice(2)], checked_at: @now,
                                                                      error_code: :partial_source_coverage)
          @store.record(check: partial)
          result = @store.check(keys: ["public_transport"]).sole
          assert_equal :partial, result.status
          assert_equal :partial_source_coverage, result.error_code
          assert_empty result.notices
        end
      end

      test "refresh collects sufficient bounded notices exactly once" do
        calls = 0
        collector = Object.new
        collector.define_singleton_method(:check) do |**options|
          calls += 1
          raise "insufficient extraction limit" unless options[:max_items] == 30

          [CityServiceNoticeCollector::SourceCheckResult.new(source_key: "public_transport", status: :empty,
                                                             notices: [], checked_at: options[:now])]
        end
        store = CityServiceSourceCheckStore.new(collector:, clock: -> { @now })
        store.refresh(keys: ["public_transport"], max_items: 1)
        assert_equal 1, calls
        assert_equal :empty, store.check(keys: ["public_transport"]).first.status
      end

      test "limits and expired deadlines reject without collection" do
        assert_raises(ArgumentError) { @store.check(keys: ["public_transport"], max_items: 0) }
        deadline = Decidim::Bih::Concierge::Dialogue::TurnBudget.new(timeout: 0.001)
        deadline.stub(:expired?, true) do
          assert_raises(CityServiceNoticeCollector::DeadlineExceeded) { @store.check(keys: ["public_transport"], deadline:) }
        end
      end

      test "partial coverage error cannot replace last-good complete notices" do
        @store.record(check: check(notices: [notice(1), notice(2)]))
        @now += 60
        partial = CityServiceNoticeCollector::SourceCheckResult.new(source_key: "public_transport", status: :ok,
                                                                    notices: [notice(1)], checked_at: @now, error_code: :partial_source_coverage)
        @store.record(check: partial)
        assert_equal 2, @store.snapshot(source_key: "public_transport").last_good_payload.fetch("notices").size
        assert_equal :partial_source_coverage, @store.check(keys: ["public_transport"]).first.error_code
      end

      private

      def check(notices:)
        CityServiceNoticeCollector::SourceCheckResult.new(source_key: "public_transport", status: :ok, notices:, checked_at: @now)
      end

      def notice(index)
        CityServiceNoticeCollector::Notice.new(source_key: "public_transport", source_label: "Transport", provider: "City",
                                               title: "P#{index} route", body: "Public route", url: "https://public-transport.example.invalid/p#{index}.pdf",
                                               fingerprint: "route-#{index}", fetched_at: @now)
      end
    end
  end
end
