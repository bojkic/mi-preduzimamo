# frozen_string_literal: true

class CreateCityServiceSourceSnapshots < ActiveRecord::Migration[7.0]
  def change
    create_table :city_service_source_snapshots do |t|
      t.string :source_key, null: false
      t.string :source_version, null: false
      t.jsonb :check_payload, null: false, default: {}
      t.jsonb :last_good_payload, null: false, default: {}
      t.datetime :attempted_at
      t.datetime :last_success_at
      t.string :content_hash
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_index :city_service_source_snapshots, :source_key, unique: true
  end
end
