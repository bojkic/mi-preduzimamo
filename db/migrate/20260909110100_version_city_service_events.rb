# frozen_string_literal: true

class VersionCityServiceEvents < ActiveRecord::Migration[7.2]
  def change
    change_table :decidim_app_city_service_events, bulk: true do |t|
      t.string :source_occurrence_id
      t.string :content_version
      t.datetime :source_published_at
      t.datetime :source_updated_at
      t.jsonb :extraction_metadata, null: false, default: {}
      t.string :lifecycle, null: false, default: "scheduled"
      t.string :reviewed_content_version
      t.bigint :superseded_by_id
    end
    add_index :decidim_app_city_service_events,
              [:decidim_organization_id, :source_key, :source_occurrence_id],
              name: "idx_city_events_occurrence"
    add_index :decidim_app_city_service_events, :superseded_by_id
    add_foreign_key :decidim_app_city_service_events, :decidim_app_city_service_events, column: :superseded_by_id
  end
end
