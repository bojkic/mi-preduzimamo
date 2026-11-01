# frozen_string_literal: true

class AddCityServiceAutomaticPublicationChecks < ActiveRecord::Migration[7.2]
  def change
    change_table :decidim_app_city_service_automation_decisions, bulk: true do |t|
      t.string :publication_revision
      t.datetime :checked_at
      t.bigint :checked_by_id
      t.string :check_result
      t.string :checked_publication_revision
      t.string :checked_policy_version
      t.string :checked_evidence_digest
    end
    add_index :decidim_app_city_service_automation_decisions, :checked_by_id, name: "idx_city_auto_checked_by"
    add_foreign_key :decidim_app_city_service_automation_decisions, :decidim_users, column: :checked_by_id
    reversible do |direction|
      direction.up do
        execute <<~SQL
          UPDATE decidim_app_city_service_automation_decisions AS d
          SET publication_revision = e.extraction_metadata ->> 'publication_revision'
          FROM decidim_app_city_service_events AS e
          WHERE d.event_id = e.id AND d.outcome = 'published'
            AND d.policy_version = e.extraction_metadata -> 'automation_publication' ->> 'policy_version'
            AND d.content_version = e.content_version
            AND e.state IN ('board_published', 'published')
        SQL
      end
    end
    add_check_constraint :decidim_app_city_service_automation_decisions,
                         '(checked_at IS NULL AND checked_by_id IS NULL AND check_result IS NULL AND checked_publication_revision IS NULL AND checked_policy_version IS NULL AND checked_evidence_digest IS NULL) OR ' \
                         "(checked_at IS NOT NULL AND checked_by_id IS NOT NULL AND check_result IN ('ok', 'corrected', 'withdrawn') AND checked_publication_revision IS NOT NULL AND checked_policy_version IS NOT NULL AND checked_evidence_digest IS NOT NULL)",
                         name: 'city_automation_check_complete'
  end
end
