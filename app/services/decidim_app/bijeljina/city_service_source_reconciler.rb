# frozen_string_literal: true

require "digest"

module DecidimApp
  module Bijeljina
    # Reconcile membership of a complete authoritative document, not guessed
    # similarity between names or dates. No approval survives changed evidence.
    class CityServiceSourceReconciler
      WITHDRAWABLE_STATES = %w(pending_review answer_approved failed board_published published).freeze
      Result = Struct.new(:withdrawn_ids, :status, keyword_init: true)

      def initialize(organization:)
        @organization = organization
      end

      def with_document_lock(source_key:, document_url:)
        CityServiceIncident.synchronize(organization) do
          key = Digest::SHA256.hexdigest([organization.id, source_key, document_url].join("\0"))[0, 15].to_i(16)
          CityServiceEvent.connection.execute("SELECT pg_advisory_xact_lock(#{key})")
          yield
        end
      end

      def reconcile_article(source:, article:, events:, complete: true, observed_at: Time.current)
        return skipped unless complete && article.complete && article.content_version.present?

        reconcile(source_key: source.fetch(:key), document_url: article.source_url, document_version: article.content_version,
                  events:, observed_at:, url_key: "canonical_article_url", version_key: "article_content_version",
                  preserve_expired: false, reason: "canonical_article_changed")
      end

      # Public snapshot API keeps every identity/completeness field explicit.
      # rubocop:disable Metrics/ParameterLists
      def reconcile_snapshot(source:, source_url:, content_version:, events:, complete:, observed_at: Time.current)
        return skipped unless complete && content_version.present?

        reconcile(source_key: source.fetch(:key), document_url: source_url, document_version: content_version,
                  events:, observed_at:, url_key: "source_document_url", version_key: "source_document_version",
                  preserve_expired: true, reason: "complete_source_snapshot_changed", retire_invalid_legacy: true)
      end

      # rubocop:enable Metrics/ParameterLists

      private

      attr_reader :organization

      def reconcile(source_key:, document_url:, document_version:, events:, **policy)
        observed_at, url_key, version_key, preserve_expired, reason = policy.values_at(:observed_at, :url_key, :version_key, :preserve_expired, :reason)
        current_events = Array(events)
        validate_event_identities!(current_events, source_key:, document_url:, url_key:)

        with_document_lock(source_key:, document_url:) do
          scope = CityServiceEvent.for_organization(organization).where(source_key:, state: WITHDRAWABLE_STATES)
                                  .where("extraction_metadata ->> ? = ?", url_key, document_url)
                                  .where("extraction_metadata ->> ? IS NOT NULL", version_key)
                                  .where("extraction_metadata ->> ? <> ?", version_key, document_version)
                                  .where.not(id: current_events.map(&:id))
          scope = scope.where("ends_at IS NULL OR ends_at >= ?", observed_at) if preserve_expired
          withdrawn = []
          scope.order(:id).lock.each do |event|
            event.withdraw_source_version!(document_url:, document_version:, observed_at:, reason:)
            withdrawn << event.id
          end
          withdrawn.concat(retire_invalid_legacy(source_key:, document_url:, document_version:, observed_at:, current_events:)) if policy[:retire_invalid_legacy]
          if withdrawn.any?
            current_events.select(&:pending_review?).each do |event|
              event.update!(extraction_metadata: event.extraction_metadata.merge("source_document_changed" => true))
            end
          end
          Result.new(withdrawn_ids: withdrawn, status: :reconciled)
        end
      end

      # Older electricity extraction mistook date headings for clock ranges.
      # A complete replacement snapshot lets us retire those unusable records,
      # but supplies neither corrected times nor a one-to-one replacement.
      def retire_invalid_legacy(source_key:, document_url:, document_version:, observed_at:, current_events:)
        return [] unless source_key == "electricity_outages"

        scope = CityServiceEvent.for_organization(organization).where(
          source_key:, source_url: document_url, content_version: nil, state: %w(pending_review failed)
        ).where("starts_at IS NULL OR ends_at IS NULL OR ends_at <= starts_at").where.not(id: current_events.map(&:id))
        # A historical failed publication can carry review stamps even though its
        # parsed window was invalid. Retire expired failures without erasing that
        # real review history; active reviewed records remain protected.
        scope = scope.where("(reviewed_at IS NULL AND reviewed_by_id IS NULL AND reviewed_content_version IS NULL) OR " \
                            "(state = 'failed' AND starts_at < :observed_at AND ends_at < :observed_at)", observed_at:)
        scope.order(:id).lock.map do |event|
          event.withdraw_source_version!(document_url:, document_version:, observed_at:, reason: "invalid_legacy_window_replaced_by_complete_snapshot")
          event.id
        end
      end

      def validate_event_identities!(events, source_key:, document_url:, url_key:)
        valid = events.all? do |event|
          event.persisted? && event.decidim_organization_id == organization.id && event.source_key == source_key &&
            event.extraction_metadata[url_key] == document_url
        end
        raise ArgumentError, "source reconciliation event identity mismatch" unless valid
      end

      def skipped
        Result.new(withdrawn_ids: [], status: :incomplete)
      end
    end
  end
end
