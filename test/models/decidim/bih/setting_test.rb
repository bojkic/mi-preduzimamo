# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    # Round 25 (W4.2 / W4.4) — the operator-editable key/value store. The reader
    # (namespace_for) is carefully guarded; these tests pin down the WRITER's
    # behavior, including the concurrent-write race that a naive
    # find_or_initialize_by + save! exposes (ActiveRecord::RecordNotUnique on a
    # double-submit).
    class SettingTest < ActiveSupport::TestCase
      setup do
        @organization = create_organization
      end

      test "put persists a new value" do
        assert_equal "putevi@grad.example",
                     Decidim::Bih::Setting.put(@organization, "sistem48_routing", "putevi", "putevi@grad.example")

        assert_equal({ "putevi" => "putevi@grad.example" },
                     Decidim::Bih::Setting.namespace_for(@organization, "sistem48_routing"))
      end

      test "put updates an existing value" do
        Decidim::Bih::Setting.put(@organization, "sistem48_routing", "putevi", "old@grad.example")

        assert_equal "new@grad.example",
                     Decidim::Bih::Setting.put(@organization, "sistem48_routing", "putevi", "new@grad.example")
        assert_equal({ "putevi" => "new@grad.example" },
                     Decidim::Bih::Setting.namespace_for(@organization, "sistem48_routing"))
      end

      test "put with a blank value clears the override" do
        Decidim::Bih::Setting.put(@organization, "sistem48_routing", "putevi", "putevi@grad.example")

        assert_nil Decidim::Bih::Setting.put(@organization, "sistem48_routing", "putevi", "")
        assert_empty Decidim::Bih::Setting.namespace_for(@organization, "sistem48_routing")
      end

      # A concurrent double-submit can have two requests both miss the row with
      # find_or_initialize_by, then race to INSERT — the loser hits the unique
      # index and raises RecordNotUnique. The writer must absorb that and still
      # persist the value, never bubbling a 500.
      test "put survives a RecordNotUnique race and still persists the value" do
        organization_id = @organization.id
        raised_once = false
        original_save = Decidim::Bih::Setting.instance_method(:save!)

        Decidim::Bih::Setting.define_method(:save!) do |*args, &blk|
          unless raised_once
            raised_once = true
            # Simulate the competing transaction having already committed the row.
            Decidim::Bih::Setting.connection.execute(
              <<~SQL.squish
                INSERT INTO decidim_bih_settings
                  (decidim_organization_id, namespace, key, value, created_at, updated_at)
                VALUES
                  (#{organization_id}, 'sistem48_routing', 'putevi', '"loser@grad.example"', NOW(), NOW())
              SQL
            )
            raise ActiveRecord::RecordNotUnique, "duplicate key value violates unique constraint"
          end
          original_save.bind(self).call(*args, &blk)
        end

        begin
          assert_nothing_raised do
            assert_equal "putevi@grad.example",
                         Decidim::Bih::Setting.put(@organization, "sistem48_routing", "putevi", "putevi@grad.example")
          end
        ensure
          Decidim::Bih::Setting.remove_method(:save!)
        end

        assert_equal({ "putevi" => "putevi@grad.example" },
                     Decidim::Bih::Setting.namespace_for(@organization, "sistem48_routing"))
      end
    end
  end
end
