# frozen_string_literal: true

require "digest"

module DecidimApp
  module Bijeljina
    # One-off repair for occurrences that a churning source document split into
    # one unreviewed row per fetch. The cause is fixed at the parser
    # (CityServiceOfficialPostParser#content_version_for); this only clears what
    # the old identity already created.
    #
    # It collapses a group ONLY when every row is unreviewed, unpublished and
    # carries byte-identical facts, so it can never withdraw something a citizen
    # saw or overwrite a decision an operator made. Anything it is unsure about
    # it leaves in the queue.
    class CityServiceReobservationCleanup
      COLLAPSIBLE_STATES = %w(pending_review failed).freeze
      Result = Struct.new(:groups, :collapsed_ids, :kept_ids, keyword_init: true)

      def initialize(organization:)
        @organization = organization
      end

      def call(apply: false)
        collapsed = []
        kept = []
        groups = duplicate_groups
        groups.each do |rows|
          newest = rows.max_by(&:id)
          kept << newest.id
          older = rows - [newest]
          collapsed.concat(older.map(&:id))
          older.each { |row| row.supersede_with!(newest) } if apply
        end
        Result.new(groups: groups.size, collapsed_ids: collapsed.sort, kept_ids: kept.sort)
      end

      private

      attr_reader :organization

      def duplicate_groups
        rows = CityServiceEvent.for_organization(organization)
                               .where(state: COLLAPSIBLE_STATES, superseded_by_id: nil, reviewed_at: nil)
                               .where.not(source_occurrence_id: nil)
                               .order(:id).to_a
        rows.group_by { |row| [row.source_key, row.source_occurrence_id, facts_digest(row)] }
            .values.select { |group| group.size > 1 }
      end

      def facts_digest(row)
        Digest::SHA256.hexdigest(
          [
            row.title, row.summary, row.affected_text, row.recommended_action, row.viber_text,
            row.starts_at&.utc&.iso8601, row.ends_at&.utc&.iso8601,
            row.event_type, row.severity, row.lifecycle, row.targeting_level,
            row.affected_area_slugs.sort.join(","), row.extraction_metadata["source_quotation"]
          ].map(&:to_s).join("\u0000")
        )
      end
    end
  end
end
