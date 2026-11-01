# frozen_string_literal: true

require "time"

module DecidimApp
  module Bijeljina
    # Operator evidence, not a second answer gate. Existing typed readers still
    # enforce the requested fact's review, time and geography contracts.
    module CityServiceSourceHealth
      module_function

      def call(source_key:, check:, now: Time.current)
        profile = CityServiceSourceProfiles.fetch(source_key)
        notices = Array(value(check, :notices))
        metadata = notices.map { |notice| value(notice, :metadata) || {} }
        status = value(check, :status).to_s.presence || "not_checked"
        error_code = value(check, :error_code)&.to_s
        {
          family: profile.fetch(:family), status:, error_code:, attempted_at: iso(value(check, :attempted_at)),
          checked_at: iso(value(check, :checked_at)), last_success_at: iso(value(check, :last_success_at)),
          extraction: extraction(status, error_code:), empty_reason: empty_reason(status, profile),
          latest_publication_at: latest(metadata.map { |item| item["source_published_at"] }, now:),
          observation: observation(metadata, profile, now:),
          applicability: states(metadata, "temporal_status"), geography: states(metadata, "geographic_status", "coverage_status"),
          review: status == "unreviewed" ? "unreviewed" : "requires_record_review",
          coverage: { returned_records: notices.size, complete: false, scope: "prepared_records_not_service_coverage" },
          last_good: value(check, :last_good_evidence),
          next_action: next_action(status, profile, error_code:), answer_readiness: "requires_claim_time_place_and_review"
        }
      end

      def states(metadata, field, fallback = nil)
        metadata.map { |item| item[field] || item[fallback] }.compact.uniq.presence || ["unknown"]
      end

      def extraction(status, error_code: nil)
        return "source_content_stale" if status == "stale" && error_code == "source_feed_stale"

        { "ok" => "recognized", "empty" => "recognized_empty", "unreviewed" => "requires_review",
          "malformed" => "invalid_shape", "unavailable" => "fetch_or_preparation_failed", "stale" => "check_expired" }.fetch(status, "unknown")
      end

      def empty_reason(status, profile)
        return unless status == "empty"

        profile.fetch(:quiet_allowed) ? "no_relevant_records_in_checked_scope" : "reference_or_measurement_coverage_requires_review"
      end

      def next_action(status, profile, error_code: nil)
        return "inspect_provider_feed" if status == "stale" && error_code == "source_feed_stale"

        return "inspect_fetch_or_parser" if %w(unavailable malformed).include?(status)
        return "refresh_source" if %w(stale not_checked).include?(status)
        return "review_extracted_claims" if status == "unreviewed"
        return "inspect_expected_output" if status == "empty" && !profile.fetch(:quiet_allowed)

        "verify_requested_fact_coverage"
      end

      def observation(metadata, profile, now:)
        return { state: "not_applicable" } unless profile.fetch(:family) == "observation"

        times = observation_times(metadata)
        valid = times.compact.select { |time| time <= now }
        { state: valid.empty? ? "unknown" : "dated_observations", latest_at: valid.max&.iso8601,
          oldest_at: valid.min&.iso8601, oldest_age_seconds: age_seconds(valid.min, now:),
          missing_time_count: times.count(nil), future_time_count: times.compact.count { |time| time > now },
          scope: "per_record_reader_decides_freshness" }
      end

      def observation_times(metadata)
        metadata.flat_map { |item| Array(item["readings"]).presence || [item] }.map { |item| parse_time(item["observed_at"]) }
      end

      def age_seconds(time, now:)
        (now - time).to_i if time
      end

      def latest(values, now:)
        values.filter_map { |value| parse_time(value) }.select { |time| time <= now }.max&.iso8601
      end

      def iso(value)
        parse_time(value)&.iso8601
      end

      def parse_time(value)
        return value if value.is_a?(Time) || value.is_a?(ActiveSupport::TimeWithZone)
        return unless value.to_s.match?(/(?:Z|[+-]\d{2}:\d{2})\z/)

        Time.iso8601(value.to_s)
      rescue ArgumentError
        nil
      end

      def value(object, key)
        return object.public_send(key) if object.respond_to?(key)
        return object[key] || object[key.to_s] if object.respond_to?(:key?)

        nil
      end
    end
  end
end
