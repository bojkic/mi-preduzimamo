# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    # Only proven shared occurrence identity or exactly matching whole-area
    # and minute-level validity can establish a conflict. Similar headlines,
    # overlapping neighborhoods and feeder names are not identity evidence.
    module CityServiceEvidenceConflict
      module_function

      def events(scope)
        eligible = scope.reorder(nil).to_sql
        pair = CityServiceEvent.connection.select_rows(<<~SQL.squish).first
          WITH eligible AS (#{eligible})
          SELECT current.id, other.id FROM eligible current JOIN eligible other
            ON current.id < other.id AND current.source_key = other.source_key
            AND current.source_occurrence_id = other.source_occurrence_id
          WHERE #{same_occurrence_sql}
          UNION ALL
          SELECT current.id, other.id FROM eligible current JOIN eligible other
            ON current.id < other.id AND current.source_key = other.source_key
            AND current.starts_at = other.starts_at AND current.ends_at = other.ends_at
          WHERE #{opposing_scope_sql}
          LIMIT 1
        SQL
        return [] unless pair

        records = scope.where(id: pair).order(:id).to_a
        records.size == 2 ? records : []
      end

      def same_occurrence_sql
        <<~SQL.squish
          current.source_occurrence_id IS NOT NULL AND current.source_occurrence_id <> ''
          AND current.source_occurrence_id = other.source_occurrence_id
          AND (current.starts_at IS DISTINCT FROM other.starts_at
            OR current.ends_at IS DISTINCT FROM other.ends_at
            OR current.lifecycle IS DISTINCT FROM other.lifecycle)
        SQL
      end

      def opposing_scope_sql
        <<~SQL.squish
          current.starts_at = other.starts_at AND current.ends_at = other.ends_at
          AND current.extraction_metadata->>'temporal_precision' = 'minute'
          AND other.extraction_metadata->>'temporal_precision' = 'minute'
          AND ((current.lifecycle = 'resolved' AND other.lifecycle IN ('scheduled', 'ongoing'))
            OR (other.lifecycle = 'resolved' AND current.lifecycle IN ('scheduled', 'ongoing')))
          AND (current.targeting_level = 'citywide' AND other.targeting_level = 'citywide'
            OR (#{whole_area_sql("current")} AND #{whole_area_sql("other")}
              AND current.affected_area_slugs @> other.affected_area_slugs
              AND other.affected_area_slugs @> current.affected_area_slugs))
        SQL
      end

      def whole_area_sql(name)
        <<~SQL.squish
          #{name}.affected_area_slugs <> '[]'::jsonb
          AND #{name}.extraction_metadata->'coverage'->>'status' = 'resolved'
          AND jsonb_array_length(#{name}.extraction_metadata->'coverage'->'affected_places') > 0
          AND NOT EXISTS (
            SELECT 1 FROM jsonb_array_elements(#{name}.extraction_metadata->'coverage'->'affected_places') place
            WHERE place->>'relation' IS DISTINCT FROM 'whole'
          )
          AND #{name}.affected_area_slugs <@ (
            SELECT jsonb_agg(place->'slug') FROM jsonb_array_elements(#{name}.extraction_metadata->'coverage'->'affected_places') place
          )
        SQL
      end
    end
  end
end
