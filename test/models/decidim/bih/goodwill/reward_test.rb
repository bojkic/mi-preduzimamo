# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module Goodwill
      # Round 25 — table-backed rewards catalog entry. Validates the model's
      # validations and the active/available scopes that drive the public list.
      class RewardTest < ActiveSupport::TestCase
        setup do
          @organization = create_organization
        end

        def build_reward(**attrs)
          Reward.new(
            {
              organization: @organization,
              key: "majica",
              title: { "sr" => "Majica", "en" => "T-shirt" },
              cost: 500
            }.merge(attrs)
          )
        end

        test "is valid with the minimal required attributes" do
          assert build_reward.valid?
        end

        test "requires a key" do
          reward = build_reward(key: "")
          assert_not reward.valid?
          assert_includes reward.errors.attribute_names, :key
        end

        test "requires a positive cost" do
          assert_not build_reward(cost: 0).valid?
          assert_not build_reward(cost: -10).valid?
          assert build_reward(cost: 1).valid?
        end

        test "enforces key uniqueness within an organization" do
          build_reward.save!
          dup = build_reward(title: { "sr" => "Druga" })
          assert_not dup.valid?
          assert_includes dup.errors.attribute_names, :key
        end

        test "allows the same key in a different organization" do
          build_reward.save!
          other = create_organization
          assert build_reward(organization: other).valid?
        end

        test "stock when present must be a non-negative integer" do
          assert_not build_reward(stock: -1).valid?
          assert build_reward(stock: 0).valid?
          assert build_reward(stock: 5).valid?
          assert build_reward(stock: nil).valid? # nil = unlimited
        end

        test "active scope returns only active rewards" do
          active = build_reward(key: "a")
          active.save!
          inactive = build_reward(key: "b", active: false)
          inactive.save!

          assert_includes Reward.active, active
          assert_not_includes Reward.active, inactive
        end

        test "available scope excludes inactive, out-of-stock and expired rewards" do
          ok = build_reward(key: "ok")
          ok.save!
          unlimited_future = build_reward(key: "future", stock: nil, expires_at: 2.days.from_now)
          unlimited_future.save!
          inactive = build_reward(key: "inactive", active: false)
          inactive.save!
          out_of_stock = build_reward(key: "oos", stock: 0)
          out_of_stock.save!
          expired = build_reward(key: "expired", expires_at: 1.day.ago)
          expired.save!

          available = Reward.available
          assert_includes available, ok
          assert_includes available, unlimited_future
          assert_not_includes available, inactive
          assert_not_includes available, out_of_stock
          assert_not_includes available, expired
        end

        test "expired? reflects the hard deadline" do
          assert build_reward(expires_at: 1.minute.ago).expired?
          assert_not build_reward(expires_at: 1.minute.from_now).expired?
          assert_not build_reward(expires_at: nil).expired?
        end

        test "name resolves from the title jsonb for the current locale" do
          reward = build_reward(title: { "sr" => "Majica", "en" => "T-shirt" })
          I18n.with_locale(:en) { assert_equal "T-shirt", reward.name }
          I18n.with_locale(:sr) { assert_equal "Majica", reward.name }
        end

        test "description resolves from the description jsonb and is nil when blank" do
          assert_nil build_reward(description: {}).description
          reward = build_reward(description: { "sr" => "Pamučna majica" })
          I18n.with_locale(:sr) { assert_equal "Pamučna majica", reward.description }
        end

        test "key becomes read-only after redemption history exists" do
          reward = build_reward
          reward.save!

          RewardFulfillment.stub(:exists?, true) do
            reward.key = "nova-majica"
            assert_not reward.valid?
            assert_includes reward.errors.attribute_names, :key
          end
        end
      end
    end
  end
end
