# frozen_string_literal: true

# Admin content-editor pilot (Wave 3 package N): an operator-reviewed override
# of one shipped city-service FAQ entry, and the foundation's own open/closed
# call status with its review window. No citizen data lives here: the only
# person referenced is the approving operator (an admin audit field).
class CreateDecidimAppCityServiceEntries < ActiveRecord::Migration[7.2]
  def change
    create_table :decidim_app_city_service_entries do |t|
      t.references :decidim_organization, null: false, foreign_key: { to_table: :decidim_organizations },
                                          index: { name: "idx_app_city_service_entries_org" }
      t.string :key, null: false
      t.string :title, null: false
      t.text :body, null: false
      t.string :source_url, null: false
      t.date :source_checked_on
      t.string :reviewed_content_hash
      t.string :state, null: false, default: "draft"
      t.datetime :approved_at
      t.references :approved_by, foreign_key: { to_table: :decidim_users },
                                 index: { name: "idx_app_city_service_entries_approved_by" }
      t.timestamps
    end
    add_index :decidim_app_city_service_entries, [:decidim_organization_id, :key],
              unique: true, name: "idx_app_city_service_entries_org_key"

    create_table :decidim_app_foundation_status_overrides do |t|
      t.references :decidim_organization, null: false, foreign_key: { to_table: :decidim_organizations },
                                          index: { unique: true, name: "idx_app_foundation_status_overrides_org" }
      t.string :current_open_status, null: false, default: "unverified"
      t.date :reviewed_on
      t.date :review_expires_on
      t.string :state, null: false, default: "draft"
      t.datetime :approved_at
      t.references :approved_by, foreign_key: { to_table: :decidim_users },
                                 index: { name: "idx_app_foundation_status_overrides_approved_by" }
      t.timestamps
    end
  end
end
