# frozen_string_literal: true

require "date"
require "time"
require_relative "gazette_source_identity"
require_relative "milica/procedure_read"

module DecidimApp
  module Bijeljina
    # Prepared-reader gates for the operator table, not a claim that any query
    # has eligible facts. Keeps the latest fetch attempt separate from reviewed
    # fallback material, using each existing reader's own validity contract.
    module CityReferenceHealth
      ProcedureSnapshot = Struct.new(:check_payload, keyword_init: true)

      module_function

      def for_reference(reference_key:, snapshot:, organization:, now: Time.current)
        if reference_key == PublicCallsPreparation.snapshot_key(organization)
          source = CityServiceSources.find(PublicCallsPreparation::PARENT_SOURCE_KEY)
          unless source && source.fetch(:enabled, true)
            return call(family: "unknown", snapshot:, now:, contract: {})
                   .merge(family: "public_calls", status: "unavailable", error_code: "public_calls_source_not_configured")
          end
          cadence = source.fetch(:scrape_cadence)
          call(family: "public_calls", snapshot:, now:,
               contract: { expected_version: PublicCallsPreparation.version_for, organization_id: organization.id,
                           max_age: CityServiceSources::HEALTH_MAX_AGES.fetch(cadence) })
        elsif reference_key == CityReferenceRefresh::GAZETTE_KEY
          call(family: "gazette", snapshot:, now:, contract: { expected_version: CityReferenceRefresh::VERSION,
                                                               fallback_checked_on: GazetteData::SOURCE_CAPTURED_ON,
                                                               source_url: Gazette.current_source_url, fallback_source_url: GazetteData::BASE,
                                                               today: now.in_time_zone("Europe/Sarajevo").to_date })
        elsif reference_key.to_s.start_with?("reference:procedure:")
          card = ServiceProcedures.find(reference_key.delete_prefix("reference:procedure:"))
          call(family: "procedure", snapshot:, now:, contract: { card: })
        else
          call(family: "unknown", snapshot:, now:, contract: {})
        end
      end

      def call(family:, snapshot:, now:, contract:)
        payload = snapshot&.check_payload || {}
        raise ArgumentError, "invalid reference payload" unless payload.is_a?(Hash)

        evidence = attempt_evidence(family, snapshot, payload)
        projection = case family
                     when "public_calls" then public_calls(snapshot, payload, now, contract)
                     when "gazette" then gazette(snapshot, payload, contract)
                     when "procedure" then procedure(payload, now, contract)
                     else { status: "unavailable", error_code: "unsupported_reference_family" }
                     end
        evidence.merge(projection)
      rescue ArgumentError, KeyError, TypeError
        (evidence || { family:, last_attempt_status: "unknown", attempted_at: snapshot&.attempted_at,
                       last_success_at: snapshot&.last_success_at, warning_codes: [],
                       answer_readiness: "requires_requested_fact_and_applicability" })
          .merge(status: "unreviewed", error_code: "reference_snapshot_malformed")
      end

      def public_calls(snapshot, payload, now, contract)
        return { status: "unavailable", error_code: "public_calls_not_prepared" } unless snapshot
        return { status: "unavailable", error_code: "public_calls_source_version_changed" } unless snapshot.source_version == contract.fetch(:expected_version)
        return { status: "unavailable", error_code: "public_calls_tenant_mismatch" } unless payload["organization_id"].to_s == contract.fetch(:organization_id).to_s
        return { status: "unreviewed", error_code: payload["error_code"] || "public_calls_preparation_incomplete" } unless %w(ok empty).include?(payload["status"])

        checked_at = Time.iso8601(payload.fetch("checked_at"))
        return { status: "stale", error_code: "public_calls_preparation_stale", checked_at: } unless checked_at <= now && checked_at >= now - contract.fetch(:max_age)

        { status: payload.fetch("status"), reader_basis: "prepared_public_calls", checked_at: }
      end

      def gazette(snapshot, payload, contract)
        prepared = prepared_gazette?(snapshot, contract)
        checked_on = gazette_capture_on(prepared, snapshot, contract)
        return { status: "unavailable", error_code: "gazette_not_configured", current_legal_status: "not_verified" } unless checked_on

        warnings = attempt_warnings(payload)
        warnings << "gazette_snapshot_version_changed_using_bundled_index" if snapshot && snapshot.source_version != contract.fetch(:expected_version)
        if snapshot && !GazetteSourceIdentity.matches_payload?(snapshot.last_good_payload, source_url: contract[:source_url])
          warnings << "gazette_snapshot_source_changed_using_configured_index"
        end
        stale = checked_on < contract.fetch(:today) - 45
        { status: stale ? "stale" : "ok", error_code: stale ? "gazette_index_stale" : nil,
          reader_basis: prepared ? "last_good_gazette_index" : "bundled_gazette_index", index_captured_on: checked_on.iso8601,
          warning_codes: warnings, current_legal_status: "not_verified" }
      end

      def procedure(payload, now, contract)
        card = contract.fetch(:card)
        return { status: "unavailable", error_code: "reviewed_procedure_not_found" } unless card

        readiness = Milica::ProcedureRead.new(source_store: nil).assessment(card:, now:, snapshot: ProcedureSnapshot.new(check_payload: payload))
        status = readiness.fetch(:status)
        warnings = Array(readiness[:warnings])
        result = { status:, warning_codes: (attempt_warnings(payload) + warnings).uniq }
        result[:reviewed_on] = readiness.dig(:validity, "reviewed_on") if readiness[:validity]
        if status == "ok"
          result[:reader_basis] = "reviewed_procedure_card"
        else
          result[:error_code] = warnings.first || "procedure_unavailable"
        end
        result
      end

      def attempt_evidence(family, snapshot, payload)
        {
          family:, last_attempt_status: payload["status"] || "not_checked", last_attempt_error_code: payload["error_code"],
          attempted_at: snapshot&.attempted_at, last_success_at: snapshot&.last_success_at,
          answer_readiness: "requires_requested_fact_and_applicability", warning_codes: []
        }
      end

      def attempt_warnings(payload)
        return [] unless payload["status"]
        return [] if %w(ok empty).include?(payload["status"])

        ["latest_source_check_unavailable"]
      end

      def gazette_capture_on(prepared, snapshot, contract)
        checked_on = prepared ? snapshot.last_success_at&.to_date : nil
        expected = GazetteSourceIdentity.for_url(contract[:source_url])
        fallback_bound = expected && GazetteSourceIdentity.for_url(contract[:fallback_source_url]) == expected
        checked_on ||= contract.fetch(:fallback_checked_on) if fallback_bound
        checked_on.is_a?(String) ? Date.iso8601(checked_on) : checked_on
      end

      def prepared_gazette?(snapshot, contract)
        snapshot && snapshot.source_version == contract.fetch(:expected_version) &&
          GazetteSourceIdentity.matches_payload?(snapshot.last_good_payload, source_url: contract[:source_url]) &&
          snapshot.last_good_payload["entries"].is_a?(Array)
      end

      # Kept for existing direct callers; readiness above delegates the full
      # policy to ProcedureRead rather than maintaining a second gate here.
      def procedure_review_blocked?(payload, card)
        required = payload["review_required_for_hash"]
        current_review_blocked = required == card.fetch(:reviewed_content_hash) && payload["source_url"] == card.fetch(:source_url)
        current_review_blocked || (payload["status"] == "unreviewed" && required.nil?)
      end
    end
  end
end
