# frozen_string_literal: true

class IdentifyLinkedCityBoardNotices < ActiveRecord::Migration[7.0]
  def up
    # Backfill only real event/projection relationships. An absent author alone
    # is not evidence of an official source. No jobs or publication replay.
    execute <<~SQL.squish
      WITH linked AS (
        SELECT DISTINCT p.id AS post_id, e.id AS event_id, e.source_url, e.provider, e.source_label,
                        e.starts_at, e.ends_at, e.event_type, e.published_at
        FROM decidim_bih_komsiluk_posts p
        JOIN decidim_app_city_service_events e
          ON e.decidim_organization_id = p.decidim_organization_id
         AND (e.komsiluk_post_ids @> jsonb_build_array(p.id) OR EXISTS (
           SELECT 1 FROM decidim_app_city_service_projections pr
           WHERE pr.post_id = p.id AND pr.incident_id = e.incident_id
         ))
        WHERE p.origin = 'legacy' AND p.decidim_user_id IS NULL
      ), sources AS (
        SELECT post_id, jsonb_agg(DISTINCT event_id) AS event_ids,
               COALESCE(jsonb_agg(DISTINCT source_url) FILTER (WHERE source_url IS NOT NULL), '[]'::jsonb) AS urls,
               max(COALESCE(NULLIF(provider, ''), source_label)) AS provider,
               min(starts_at) AS starts_at, max(ends_at) AS ends_at,
               min(published_at) AS published_at, max(event_type) AS event_type
        FROM linked GROUP BY post_id
      )
      UPDATE decidim_bih_komsiluk_posts p
      SET origin = 'city_service', published_at = COALESCE(p.published_at, s.published_at, p.created_at),
          details = p.details || jsonb_build_object('source', jsonb_strip_nulls(jsonb_build_object(
            'event_ids', s.event_ids, 'urls', s.urls, 'provider', s.provider,
            'starts_at', s.starts_at, 'ends_at', s.ends_at, 'event_type', s.event_type)))
      FROM sources s WHERE p.id = s.post_id
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Source provenance must not be removed from published notices"
  end
end
