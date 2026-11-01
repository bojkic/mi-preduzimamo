# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    # Re-keys existing rows onto the fact-derived content version.
    #
    # Without this, the first scrape after the deploy would compute a new
    # version for notices whose facts did not change, fail to find the stored
    # row, and open a fresh one — superseding whatever was published and pulling
    # live alerts off the board. The identity changed; the facts did not, and
    # citizens must not be able to tell.
    #
    # Every stored reference to the old version travels with it, so a reviewed
    # row stays reviewed instead of resurfacing as a changed source.
    class CityServiceFactVersionBackfill
      # Terminal rows keep their historical identity: nothing re-observes them,
      # and re-keying them would collide with the row that replaced them.
      REKEYABLE_STATES = %w(pending_review answer_approved failed board_published published).freeze
      Result = Struct.new(:rekeyed_ids, :skipped_ids, :collisions, keyword_init: true)

      def initialize(organization:)
        @organization = organization
      end

      def call(apply: false)
        rekeyed = []
        skipped = []
        collisions = []
        planned = {}

        candidates.each do |event|
          version = CityServiceFactVersion.for_record(event)
          if version == event.content_version
            skipped << event.id
            next
          end

          fingerprint = CityServiceEventIngestor.fingerprint_for(
            source_key: event.source_key, occurrence: event.source_occurrence_id, content_version: version
          )
          if planned.has_key?(fingerprint) || taken_elsewhere?(event, fingerprint)
            collisions << event.id
            next
          end

          planned[fingerprint] = event
          rekeyed << event.id
          rekey!(event, version:, fingerprint:) if apply
        end

        Result.new(rekeyed_ids: rekeyed.sort, skipped_ids: skipped.sort, collisions: collisions.sort)
      end

      private

      attr_reader :organization

      def candidates
        CityServiceEvent.for_organization(organization)
                        .where(state: REKEYABLE_STATES, superseded_by_id: nil)
                        .where.not(source_occurrence_id: nil)
                        .where.not(content_version: nil)
                        .order(:id)
      end

      def taken_elsewhere?(event, fingerprint)
        CityServiceEvent.for_organization(organization)
                        .where(source_key: event.source_key, source_fingerprint: fingerprint)
                        .where.not(id: event.id).exists?
      end

      def rekey!(event, version:, fingerprint:)
        previous = event.content_version
        attributes = { content_version: version, source_fingerprint: fingerprint,
                       extraction_metadata: retarget(event.extraction_metadata, previous, version) }
        attributes[:reviewed_content_version] = version if event.reviewed_content_version == previous
        # Identity only. Validations and callbacks belong to facts changing,
        # and nothing here changes a fact.
        event.update_columns(**attributes, updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
      end

      # A stored version reference is an exact string match or it is something
      # else entirely; nothing here rewrites a substring.
      def retarget(value, previous, version)
        case value
        when Hash then value.transform_values { |item| retarget(item, previous, version) }
        when Array then value.map { |item| retarget(item, previous, version) }
        when String then value == previous ? version : value
        else value
        end
      end
    end
  end
end
