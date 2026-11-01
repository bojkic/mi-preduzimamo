# frozen_string_literal: true

class CreateLaunchEventMessagesAndVotes < ActiveRecord::Migration[7.2]
  def change
    create_table :decidim_app_launch_event_deliveries do |t|
      t.references :decidim_organization, null: false, foreign_key: true, index: false
      t.references :decidim_user, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.references :actor, foreign_key: { to_table: :decidim_users, on_delete: :nullify }, index: false
      t.string :event_key, null: false
      t.string :message_key, null: false
      t.boolean :test_message, null: false, default: false
      t.string :status, null: false, default: "pending"
      t.string :token_digest
      t.string :phone_digest
      t.datetime :expires_at, null: false
      t.datetime :consumed_at
      t.datetime :attempted_at
      t.jsonb :provider_message_ids, null: false, default: []
      t.string :reason
      t.timestamps
    end
    add_index :decidim_app_launch_event_deliveries,
              [:decidim_organization_id, :decidim_user_id, :event_key, :message_key, :test_message],
              unique: true, name: "idx_launch_event_delivery_once"
    add_index :decidim_app_launch_event_deliveries, :token_digest, unique: true

    create_table :decidim_app_launch_event_votes do |t|
      t.references :decidim_organization, null: false, foreign_key: true, index: false
      t.references :decidim_user, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.string :event_key, null: false
      t.string :choice, null: false
      t.timestamps
    end
    add_index :decidim_app_launch_event_votes, [:decidim_organization_id, :decidim_user_id, :event_key],
              unique: true, name: "idx_launch_event_one_vote"
  end
end
