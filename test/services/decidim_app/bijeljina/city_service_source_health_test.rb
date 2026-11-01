# frozen_string_literal: true

require "test_helper"

module DecidimApp
  module Bijeljina
    class CityServiceSourceHealthTest < ActiveSupport::TestCase
      test "quiet warnings and missing reference coverage carry different meanings" do
        check = { status: :empty, notices: [], checked_at: Time.current }
        quiet = CityServiceSourceHealth.call(source_key: "weather_warnings", check:)
        reference = CityServiceSourceHealth.call(source_key: "waste_schedule", check:)
        assert_equal "no_relevant_records_in_checked_scope", quiet[:empty_reason]
        assert_equal "inspect_expected_output", reference[:next_action]
        assert_equal false, quiet.dig(:coverage, :complete)
      end

      test "river observations use nested parameter times rather than fetch or publication date" do
        now = Time.iso8601("2026-09-15T12:00:00Z")
        check = { status: :ok, checked_at: now, notices: [{ metadata: {
          "source_published_at" => "2026-09-15T11:30:00Z", "readings" => [
            { "observed_at" => "2026-09-13T10:00:00Z" }, { "observed_at" => "2026-09-15T11:00:00Z" },
            { "observed_at" => "2026-09-15T14:00:00Z" }, { "observation_time_text" => "15.09.2026 11:00" }
          ]
        } }] }
        result = CityServiceSourceHealth.call(source_key: "water_levels", check:, now:)
        assert_equal "2026-09-15T11:30:00Z", result[:latest_publication_at]
        assert_equal "2026-09-13T10:00:00Z", result.dig(:observation, :oldest_at)
        assert_equal 180_000, result.dig(:observation, :oldest_age_seconds)
        assert_equal 1, result.dig(:observation, :missing_time_count)
        assert_equal 1, result.dig(:observation, :future_time_count)
      end

      test "failed attempts retain their time without marking last-good evidence current" do
        time = Time.iso8601("2026-09-15T12:00:00Z")
        check = { status: :malformed, checked_at: nil, attempted_at: time, notices: [],
                  last_good_evidence: { "available" => true, "usage" => "retained_for_review_not_current_answer_evidence" } }
        result = CityServiceSourceHealth.call(source_key: "water_service", check:)
        assert_equal time.iso8601, result[:attempted_at]
        assert_nil result[:checked_at]
        assert_equal "invalid_shape", result[:extraction]
        assert_equal "retained_for_review_not_current_answer_evidence", result.dig(:last_good, "usage")
      end

      test "stale provider content is distinguished from an expired preparation check" do
        content = CityServiceSourceHealth.call(source_key: "water_service", check: { status: :stale, error_code: "source_feed_stale", notices: [] })
        check = CityServiceSourceHealth.call(source_key: "water_service", check: { status: :stale, error_code: "prepared_check_expired", notices: [] })
        assert_equal "source_feed_stale", content[:error_code]
        assert_equal "source_content_stale", content[:extraction]
        assert_equal "inspect_provider_feed", content[:next_action]
        assert_equal "check_expired", check[:extraction]
        assert_equal "refresh_source", check[:next_action]
      end

      test "old reference content is not automatically a stale observation" do
        result = CityServiceSourceHealth.call(source_key: "waste_schedule", check: { status: :ok, notices: [] })
        assert_equal "not_applicable", result.dig(:observation, :state)
        assert_equal "recognized", result[:extraction]
      end
    end
  end
end
