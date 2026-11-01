# frozen_string_literal: true

class AddCityNoticeIncidents < ActiveRecord::Migration[7.2]
  def change
    create_table :decidim_app_city_service_incidents do |t|
      t.references :decidim_organization, null: false, foreign_key: true
      t.string :identity_key, null: false
      t.string :service, null: false
      t.timestamps
    end
    add_index :decidim_app_city_service_incidents, [:decidim_organization_id, :identity_key], unique: true, name: "idx_city_incident_identity"
    add_reference :decidim_app_city_service_events, :incident, foreign_key: { to_table: :decidim_app_city_service_incidents }
    create_table :decidim_app_city_service_projections do |t|
      t.references :incident, null: false, foreign_key: { to_table: :decidim_app_city_service_incidents }
      t.references :komsiluk, null: false, foreign_key: { to_table: :decidim_bih_local_areas }
      t.references :post, null: false, foreign_key: { to_table: :decidim_bih_komsiluk_posts }
      t.string :revision, null: false
      t.timestamps
    end
    add_index :decidim_app_city_service_projections, [:incident_id, :komsiluk_id], unique: true, name: "idx_city_incident_board"
    create_table :decidim_app_city_service_duplicate_decisions do |t|
      t.references :decidim_organization, null: false, foreign_key: true
      t.bigint :event_id, null: false
      t.bigint :other_event_id, null: false
      t.string :decision, null: false
      t.references :reviewer, null: false, foreign_key: { to_table: :decidim_users }
      t.jsonb :previous_memberships, null: false, default: {}
      t.timestamps
    end
    add_foreign_key :decidim_app_city_service_duplicate_decisions, :decidim_app_city_service_events, column: :event_id
    add_foreign_key :decidim_app_city_service_duplicate_decisions, :decidim_app_city_service_events, column: :other_event_id
    add_index :decidim_app_city_service_duplicate_decisions, [:event_id, :other_event_id], unique: true, name: "idx_city_duplicate_pair"
    create_table :decidim_app_city_service_effects do |t|
      t.references :event, null: false, foreign_key: { to_table: :decidim_app_city_service_events }
      t.string :identity, null: false
      t.string :kind, null: false
      t.jsonb :payload, null: false, default: {}
      t.datetime :completed_at
      t.datetime :last_attempt_at
      t.integer :attempts, null: false, default: 0
      t.string :error_code
      t.timestamps
    end
    add_index :decidim_app_city_service_effects, :identity, unique: true
    add_index :decidim_app_city_service_effects, [:completed_at, :id], name: "idx_city_effect_pending"
    create_table :decidim_app_city_service_coverages do |t|
      t.references :decidim_organization, null: false, foreign_key: true
      t.string :identity_key, null: false
      t.string :source_key, null: false
      t.string :targeting_level, null: false
      t.jsonb :area_slugs, null: false, default: []
      t.jsonb :evidence, null: false, default: {}
      t.references :reviewer, null: false, foreign_key: { to_table: :decidim_users }
      t.references :event, null: false, foreign_key: { to_table: :decidim_app_city_service_events }
      t.date :valid_until, null: false
      t.datetime :revoked_at
      t.timestamps
    end
    add_index :decidim_app_city_service_coverages, [:decidim_organization_id, :identity_key], unique: true, name: "idx_city_coverage_identity"
    create_table :decidim_app_city_service_automation_decisions do |t|
      t.references :event, null: false, foreign_key: { to_table: :decidim_app_city_service_events }
      t.string :policy_version, null: false
      t.string :content_version, null: false
      t.string :mode, null: false
      t.string :outcome, null: false
      t.jsonb :blockers, null: false, default: []
      t.jsonb :target_slugs, null: false, default: []
      t.timestamps
    end
    add_index :decidim_app_city_service_automation_decisions, [:event_id, :policy_version, :content_version], unique: true, name: "idx_city_automation_decision"
  end
end
