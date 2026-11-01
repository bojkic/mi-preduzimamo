# frozen_string_literal: true

# Standalone Minitest uses refute helpers rather than ActiveSupport assert_not aliases.
# rubocop:disable Rails/RefuteMethods

require "bundler/setup"
require "minitest/autorun"
require "active_support"
require "active_support/time"
require "active_support/core_ext/enumerable"
require_relative "../../../../app/services/decidim_app/bijeljina/city_reference_health"

module DecidimApp
  module Bijeljina
    class CityReferenceHealthTest < Minitest::Test
      Snapshot = Struct.new(:source_version, :check_payload, :last_good_payload, :attempted_at, :last_success_at, keyword_init: true)
      NOW = Time.iso8601("2026-09-15T12:00:00Z")
      SOURCE_URL = "https://community.example.invalid/archive/2026.html"
      PROCEDURE_URL = "https://community.example.invalid/procedures/authored-health"
      REVIEW_HASH = Digest::SHA256.hexdigest("authored-health-procedure")

      def setup
        owner = ServiceProcedures
        @prior_procedure_hosts = owner::REVIEWED_HOSTS
        owner.send(:remove_const, :REVIEWED_HOSTS)
        owner.const_set(:REVIEWED_HOSTS, ["community.example.invalid"].freeze)
      end

      def teardown
        owner = ServiceProcedures
        owner.send(:remove_const, :REVIEWED_HOSTS)
        owner.const_set(:REVIEWED_HOSTS, @prior_procedure_hosts)
      end

      def test_public_calls_version_and_tenant_are_reader_gates_not_fetch_status
        snapshot = public_snapshot(source_version: "old")
        result = public_health(snapshot)
        assert_equal "unavailable", result[:status]
        assert_equal "public_calls_source_version_changed", result[:error_code]
        assert_equal "ok", result[:last_attempt_status]
        assert_equal NOW, result[:attempted_at]
        assert_equal NOW, result[:last_success_at]
        snapshot.source_version = "v2"
        snapshot.check_payload["organization_id"] = 2
        assert_equal "public_calls_tenant_mismatch", public_health(snapshot)[:error_code]
      end

      def test_public_calls_requires_current_check_including_no_future_check
        [NOW - 3601, NOW + 1].each do |checked_at|
          snapshot = public_snapshot
          snapshot.check_payload["checked_at"] = checked_at.iso8601
          assert_equal "stale", public_health(snapshot)[:status]
        end
        snapshot = public_snapshot
        snapshot.check_payload["status"] = "empty"
        result = public_health(snapshot)
        assert_equal "empty", result[:status]
        assert_equal "requires_requested_fact_and_applicability", result[:answer_readiness]
      end

      def test_public_calls_does_not_promote_failed_or_malformed_preparation
        snapshot = public_snapshot
        snapshot.check_payload.merge!("status" => "unavailable", "error_code" => "article_fetch_failed")
        result = public_health(snapshot)
        assert_equal "unreviewed", result[:status]
        assert_equal "article_fetch_failed", result[:last_attempt_error_code]
        snapshot.check_payload.merge!("status" => "ok", "checked_at" => "not a time")
        result = public_health(snapshot)
        assert_equal "reference_snapshot_malformed", result[:error_code]
        assert_equal "ok", result[:last_attempt_status]
        assert_equal NOW, result[:attempted_at]
        assert_equal "public_calls_not_prepared", public_health(nil)[:error_code]
      end

      def test_gazette_fresh_fetch_does_not_renew_old_retained_index
        snapshot = public_snapshot(last_success_at: NOW - (46 * 86_400))
        result = gazette_health(snapshot)
        assert_equal "stale", result[:status]
        assert_equal "gazette_index_stale", result[:error_code]
        assert_equal "ok", result[:last_attempt_status]
      end

      def test_gazette_failed_attempt_retains_fresh_last_good_reader_basis
        snapshot = public_snapshot
        snapshot.check_payload.merge!("status" => "unavailable", "error_code" => "timeout")
        result = gazette_health(snapshot)
        assert_equal "ok", result[:status]
        assert_equal "last_good_gazette_index", result[:reader_basis]
        assert_equal "unavailable", result[:last_attempt_status]
        assert_equal "timeout", result[:last_attempt_error_code]
        assert_includes result[:warning_codes], "latest_source_check_unavailable"
        assert_equal "not_verified", result[:current_legal_status]
      end

      def test_gazette_old_version_uses_bundled_capture_not_recent_success
        result = gazette_health(public_snapshot(source_version: "old"))
        assert_equal "stale", result[:status]
        assert_equal "bundled_gazette_index", result[:reader_basis]
        assert_equal "2026-01-01", result[:index_captured_on]
        assert_includes result[:warning_codes], "gazette_snapshot_version_changed_using_bundled_index"
        assert_equal "stale", gazette_health(nil)[:status]
        assert_equal "ok", gazette_health(nil, fallback_checked_on: "2026-09-14")[:status]
      end

      def test_procedure_review_is_not_expired_by_missing_or_old_fetch
        assert_equal "ok", procedure_health(nil)[:status]
        snapshot = public_snapshot(attempted_at: NOW - (90 * 86_400))
        snapshot.check_payload.merge!("status" => "unavailable", "error_code" => "timeout")
        result = procedure_health(snapshot)
        assert_equal "ok", result[:status]
        assert_equal "reviewed_procedure_card", result[:reader_basis]
        assert_includes result[:warning_codes], "latest_source_check_unavailable"
        assert_equal snapshot.attempted_at, result[:attempted_at]
      end

      def test_procedure_changed_hash_barrier_survives_later_failed_fetch
        snapshot = public_snapshot
        snapshot.check_payload.merge!("status" => "unavailable", "review_required_for_hash" => REVIEW_HASH, "source_url" => PROCEDURE_URL)
        result = procedure_health(snapshot)
        assert_equal "unreviewed", result[:status]
        assert_equal "procedure_source_changed_review_required", result[:error_code]
        snapshot.check_payload["review_required_for_hash"] = "old-review"
        assert_equal "ok", procedure_health(snapshot)[:status]
        snapshot.check_payload.merge!("status" => "unreviewed", "review_required_for_hash" => nil)
        assert_equal "unreviewed", procedure_health(snapshot)[:status]
      end

      def test_procedure_review_requires_nonfuture_date_within_reader_window
        ["2025-09-14", "2026-09-16"].each do |date|
          result = procedure_health(nil, source_checked_on: date)
          assert_equal "stale", result[:status]
          assert_equal "procedure_review_expired", result[:error_code]
        end
      end

      def test_unknown_reference_is_not_ready
        result = CityReferenceHealth.call(family: "unknown", snapshot: nil, now: NOW, contract: {})
        assert_equal "unavailable", result[:status]
        assert_equal "not_checked", result[:last_attempt_status]
      end

      def test_gazette_mismatched_publisher_is_not_a_reader_basis_or_a_recent_capture
        snapshot = public_snapshot
        snapshot.last_good_payload["source_url"] = "https://other.example.invalid/archive/2026.html"
        result = gazette_health(snapshot, fallback_source_url: "https://other.example.invalid/archive/2026.html")
        assert_equal "unavailable", result[:status]
        assert_equal "gazette_not_configured", result[:error_code]
        assert_equal "ok", result[:last_attempt_status]
        assert_equal NOW, result[:last_success_at]
      end

      def test_gazette_source_mismatch_can_only_fall_back_to_a_bound_configured_catalogue
        snapshot = public_snapshot
        snapshot.last_good_payload["source_identity"] = "old-source"
        result = gazette_health(snapshot)
        assert_equal "stale", result[:status]
        assert_equal "bundled_gazette_index", result[:reader_basis]
        assert_equal "2026-01-01", result[:index_captured_on]
        assert_includes result[:warning_codes], "gazette_snapshot_source_changed_using_configured_index"
      end

      def test_gazette_legacy_headerless_snapshot_does_not_match_the_configured_publisher
        snapshot = public_snapshot
        snapshot.last_good_payload.delete("source_identity")
        result = gazette_health(snapshot, fallback_source_url: "")
        assert_equal "unavailable", result[:status]
        assert_equal "ok", result[:last_attempt_status]
      end

      def test_gazette_without_a_configured_identity_cannot_borrow_a_fallback_date
        result = gazette_health(public_snapshot, source_url: "", fallback_source_url: "", fallback_checked_on: "2026-09-14")
        assert_equal "unavailable", result[:status]
        assert_equal "gazette_not_configured", result[:error_code]
      end

      def test_procedure_health_refuses_pending_and_revoked_reviews_despite_successful_fetch
        %w(pending unreviewed revoked).each do |state|
          result = procedure_health(public_snapshot, review_status: state)
          assert_equal "unreviewed", result[:status]
          assert_equal "procedure_review_not_approved", result[:error_code]
          assert_equal "ok", result[:last_attempt_status]
          assert_nil result[:reader_basis]
        end
      end

      def test_procedure_health_requires_approved_source_and_download_origins
        ["http://community.example.invalid/card", "https://other.example.invalid/card",
         "https://user:synthetic-password@community.example.invalid/card", "https://community.example.invalid:444/card"].each do |url|
          %i(source_url form_download_url).each do |field|
            result = procedure_health(public_snapshot, **{ field => url })
            assert_equal "unavailable", result[:status]
            assert_equal "procedure_configuration_invalid", result[:error_code]
            assert_equal "ok", result[:last_attempt_status]
            refute_includes result.to_s, "synthetic-password"
          end
        end
      end

      def test_procedure_effective_dates_gate_readiness_without_rewriting_latest_fetch_evidence
        [{ effective_from: "2026-09-16" }, { effective_until: "2026-09-14" }].each do |changes|
          result = procedure_health(public_snapshot, **changes)
          assert_equal "stale", result[:status]
          assert_equal "procedure_not_effective_on_requested_day", result[:error_code]
          assert_equal NOW, result[:last_success_at]
          assert_equal "ok", result[:last_attempt_status]
        end
        result = procedure_health(nil, effective_from: "2026-09-15", effective_until: "2026-09-15")
        assert_equal "ok", result[:status]
        assert_equal "requires_requested_fact_and_applicability", result[:answer_readiness]
      end

      def test_procedure_schema_hash_delivery_and_document_errors_are_not_health_success
        [{ reviewed_content_hash: "not-a-reviewed-hash" }, { record_kind: "personal_record" },
         { required_documents: "not a reviewed list" }, { delivery: { document_method: "unreviewed-channel" } },
         { steps: ["bad\u0000text"] }, { effective_from: "2026-09-16", effective_until: "2026-09-15" }].each do |changes|
          result = procedure_health(public_snapshot, **changes)
          assert_equal "unavailable", result[:status]
          assert_equal "procedure_configuration_invalid", result[:error_code]
          assert_equal "ok", result[:last_attempt_status]
        end
      end

      def test_procedure_health_uses_the_same_local_day_as_the_reader
        card = procedure_card(source_checked_on: "2026-09-16")
        result = CityReferenceHealth.call(family: "procedure", snapshot: nil, now: Time.utc(2026, 9, 15, 22, 30), contract: { card: })
        assert_equal "ok", result[:status]
        assert_equal "2026-09-16", result[:reviewed_on]
        result = CityReferenceHealth.call(family: "procedure", snapshot: nil, now: Time.utc(2026, 9, 15, 20), contract: { card: })
        assert_equal "stale", result[:status]
        assert_equal "procedure_review_expired", result[:error_code]
      end

      def test_policy_results_match_actual_reader_states_for_authored_cards_and_snapshots
        cases = [
          [procedure_card, nil, "ok"],
          [procedure_card(review_status: "pending"), nil, "unreviewed"],
          [procedure_card(source_checked_on: "2025-09-14"), nil, "stale"],
          [procedure_card(effective_from: "2026-09-16"), nil, "stale"],
          [procedure_card(source_url: "https://other.example.invalid/card"), nil, "unavailable"],
          [procedure_card, { "status" => "unavailable", "review_required_for_hash" => REVIEW_HASH, "source_url" => PROCEDURE_URL }, "unreviewed"],
          [procedure_card, { "status" => "unavailable", "error_code" => "timeout" }, "ok"]
        ]
        cases.each do |card, payload, expected|
          snapshot = payload && public_snapshot(check_payload: payload)
          store = Object.new
          store.define_singleton_method(:snapshot) { |**| snapshot }
          read = Milica::ProcedureRead.new(source_store: store).call(card:, locale: "sr", now: NOW)
          health = CityReferenceHealth.call(family: "procedure", snapshot:, now: NOW, contract: { card: })
          assert_equal expected, read.fetch(:status)
          assert_equal expected, health.fetch(:status)
          assert_equal read.fetch(:warnings).first, health.fetch(:error_code) unless expected == "ok"
          assert_equal "requires_requested_fact_and_applicability", health[:answer_readiness]
        end
      end

      def test_health_does_not_publish_procedure_text_facts_or_claim_unknown_fees_are_known
        card = procedure_card(steps: ["PRIVATE AUTHORED MARKER MUST NOT BE EMITTED"], fee: { administrative_fee_bam: nil, delivery_cost: "postage", postage_amount_bam: nil })
        health = CityReferenceHealth.call(family: "procedure", snapshot: nil, now: NOW, contract: { card: })
        assert_equal "ok", health[:status]
        assert_equal "requires_requested_fact_and_applicability", health[:answer_readiness]
        refute health.key?(:facts)
        refute health.key?(:source)
        refute_includes health.to_s, "PRIVATE AUTHORED MARKER"
        refute_includes health.to_s, PROCEDURE_URL
      end

      def test_missing_procedure_is_not_ready_and_does_not_hide_observed_fetch_status
        snapshot = public_snapshot
        health = CityReferenceHealth.call(family: "procedure", snapshot:, now: NOW, contract: { card: nil })
        assert_equal "unavailable", health[:status]
        assert_equal "reviewed_procedure_not_found", health[:error_code]
        assert_equal "ok", health[:last_attempt_status]
        assert_equal NOW, health[:last_success_at]
      end

      private

      def public_snapshot(**overrides)
        Snapshot.new(source_version: "v2", check_payload: { "status" => "ok", "organization_id" => 1, "checked_at" => NOW.iso8601 },
                     last_good_payload: { "entries" => [], "source_url" => SOURCE_URL, "source_identity" => GazetteSourceIdentity.for_url(SOURCE_URL) }, attempted_at: NOW, last_success_at: NOW, **overrides)
      end

      def public_health(snapshot)
        CityReferenceHealth.call(family: "public_calls", snapshot:, now: NOW, contract: { expected_version: "v2", organization_id: 1, max_age: 3600 })
      end

      def gazette_health(snapshot, **overrides)
        CityReferenceHealth.call(family: "gazette", snapshot:, now: NOW,
                                 contract: { expected_version: "v2", today: NOW.to_date, fallback_checked_on: "2026-01-01", source_url: SOURCE_URL, fallback_source_url: SOURCE_URL }.merge(overrides))
      end

      def procedure_card(**overrides)
        { key: "authored_health", title: "Izmišljeni javni postupak", owner: "Izmišljena služba",
          steps: ["Izmišljeni pregledani korak."], record_kind: "procedure", review_status: "reviewed",
          reviewed_content_hash: REVIEW_HASH, source_url: PROCEDURE_URL, source_checked_on: "2026-08-01",
          location_scope: "Izmišljena zajednica", fee: nil, required_documents: nil,
          processing_time: nil, effective_from: nil, effective_until: nil }.merge(overrides)
      end

      def procedure_health(snapshot, **overrides)
        card = procedure_card(**overrides)
        CityReferenceHealth.call(family: "procedure", snapshot:, now: NOW, contract: { card: })
      end
    end
  end
end

# rubocop:enable Rails/RefuteMethods
