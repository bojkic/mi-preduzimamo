# frozen_string_literal: true

# Stores spent ActiveHashcash stamps so Decidim Awesome's admin spam protection
# cannot reuse the same proof-of-work token twice.
class CreateActiveHashcashStamps < ActiveRecord::Migration[5.2]
  def up
    unless table_exists?(:active_hashcash_stamps)
      create_table :active_hashcash_stamps do |t|
        t.string :version, null: false
        t.integer :bits, null: false
        t.date :date, null: false
        t.string :resource, null: false
        t.string :ext, null: false
        t.string :rand, null: false
        t.string :counter, null: false
        t.string :request_path
        t.string :ip_address

        if t.respond_to?(:jsonb)
          t.jsonb :context
        elsif t.respond_to?(:json)
          t.json :context
        end

        t.timestamps
      end
    end

    unless index_exists?(:active_hashcash_stamps, [:ip_address, :created_at])
      add_index :active_hashcash_stamps, [:ip_address, :created_at],
                where: "ip_address IS NOT NULL"
    end

    return if index_exists?(:active_hashcash_stamps,
                            [:counter, :rand, :date, :resource, :bits, :version, :ext],
                            name: "index_active_hashcash_stamps_unique")

    add_index :active_hashcash_stamps,
              [:counter, :rand, :date, :resource, :bits, :version, :ext],
              name: "index_active_hashcash_stamps_unique",
              unique: true
  end

  def down
    drop_table :active_hashcash_stamps if table_exists?(:active_hashcash_stamps)
  end
end
