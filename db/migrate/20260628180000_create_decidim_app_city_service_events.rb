# frozen_string_literal: true

class CreateDecidimAppCityServiceEvents < ActiveRecord::Migration[7.2]
  def change
    create_table :decidim_app_city_service_events do |t|
      t.references :decidim_organization, null: false, foreign_key: { to_table: :decidim_organizations }
      t.references :reviewed_by, foreign_key: { to_table: :decidim_users }
      t.string :source_key, null: false
      t.string :source_label
      t.string :provider
      t.string :source_url
      t.string :source_fingerprint, null: false
      t.datetime :fetched_at
      t.string :parser_version, null: false, default: "unknown"
      t.string :event_type, null: false
      t.string :severity, null: false
      t.string :targeting_level, null: false, default: "unknown"
      t.jsonb :affected_area_slugs, null: false, default: []
      t.jsonb :target_komsiluk_slugs, null: false, default: []
      t.string :title, null: false
      t.text :summary, null: false
      t.text :affected_text
      t.text :recommended_action
      t.text :viber_text
      t.datetime :starts_at
      t.datetime :ends_at
      t.decimal :confidence, precision: 5, scale: 4, null: false, default: 0
      t.string :state, null: false, default: "pending_review"
      t.datetime :reviewed_at
      t.datetime :published_at
      t.datetime :dismissed_at
      t.text :review_note
      t.jsonb :classifier_reasons, null: false, default: []
      t.jsonb :komsiluk_post_ids, null: false, default: []
      t.string :viber_dedupe_key
      t.string :viber_delivery
      t.integer :viber_jobs_count, null: false, default: 0
      t.integer :viber_recipients_count, null: false, default: 0
      t.jsonb :policy_snapshot, null: false, default: {}

      t.timestamps
    end

    add_index :decidim_app_city_service_events,
              [:decidim_organization_id, :source_key, :source_fingerprint],
              unique: true,
              name: "idx_app_city_events_org_source_fingerprint"
    add_index :decidim_app_city_service_events,
              [:decidim_organization_id, :state, :starts_at],
              name: "idx_app_city_events_org_state_starts"
    add_index :decidim_app_city_service_events,
              [:decidim_organization_id, :source_key, :state],
              name: "idx_app_city_events_org_source_state"
  end
end
