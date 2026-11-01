# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module Goodwill
      # Round 25 — RewardsCatalog must read table-backed rewards when the org
      # has any, and otherwise fall back to the legacy config list so nothing
      # breaks before an operator seeds the table.
      class RewardsCatalogTest < ActiveSupport::TestCase
        setup do
          @organization = create_organization
        end

        test "falls back to the config catalog when the table is empty for the org" do
          rewards = RewardsCatalog.all(@organization)

          config_keys = Array(Decidim::Bih.goodwill_rewards_catalog).map { |r| r[:key] }
          assert_equal config_keys.sort, rewards.map(&:key).sort
          # Config-path rewards keep their i18n-resolved names.
          torba = rewards.find { |r| r.key == "torba" }
          assert torba.cost.positive?
        end

        test "reads table-backed rewards when present, ignoring config" do
          Reward.create!(
            organization: @organization,
            key: "specijalna",
            title: { "sr" => "Specijalna nagrada" },
            cost: 250,
            active: true
          )

          rewards = RewardsCatalog.all(@organization)
          assert_equal ["specijalna"], rewards.map(&:key)
          reward = rewards.first
          assert_equal 250, reward.cost
          I18n.with_locale(:sr) { assert_equal "Specijalna nagrada", reward.name }
        end

        test "table path only returns active rewards" do
          Reward.create!(organization: @organization, key: "live", title: { "sr" => "Aktivna" }, cost: 100, active: true)
          Reward.create!(organization: @organization, key: "retired", title: { "sr" => "Povučena" }, cost: 100, active: false)

          keys = RewardsCatalog.all(@organization).map(&:key)
          assert_includes keys, "live"
          assert_not_includes keys, "retired"
        end

        test "table rewards are scoped per organization" do
          other = create_organization
          Reward.create!(organization: @organization, key: "mine", title: { "sr" => "Moja" }, cost: 100)
          Reward.create!(organization: other, key: "theirs", title: { "sr" => "Tuđa" }, cost: 100)

          assert_equal ["mine"], RewardsCatalog.all(@organization).map(&:key)
        end

        test "retiring every table reward never restores legacy offers" do
          reward = Reward.create!(organization: @organization, key: "only", title: { "sr" => "Jedina" }, cost: 100)
          reward.update!(active: false)
          assert_empty RewardsCatalog.all(@organization)
          assert_nil RewardsCatalog.find("torba", @organization)
        end

        test "deleting the last adopted reward keeps the catalog empty" do
          reward = Reward.create!(organization: @organization, key: "only", title: { "sr" => "Jedina" }, cost: 100)
          reward.destroy!
          assert_equal "managed", RewardsCatalog.mode(@organization)
          assert_empty RewardsCatalog.all(@organization)
        end

        test "explicit closure survives creating another active reward" do
          Decidim::Bih::Setting.put(@organization, RewardsCatalog::NAMESPACE, "mode", "closed")
          Reward.create!(organization: @organization, key: "only", title: { "sr" => "Jedina" }, cost: 100)
          assert_equal "closed", RewardsCatalog.mode(@organization)
          assert_empty RewardsCatalog.all(@organization)
        end

        test "find returns a table reward by key for the org" do
          Reward.create!(organization: @organization, key: "kupon", title: { "sr" => "Kupon" }, cost: 600)
          found = RewardsCatalog.find("kupon", @organization)
          assert_equal "kupon", found.key
          assert_equal 600, found.cost
        end

        test "find falls back to config when the table is empty" do
          found = RewardsCatalog.find("torba", @organization)
          assert_equal "torba", found.key
        end

        test "all without an organization uses config (no behavior change for global callers)" do
          rewards = RewardsCatalog.all
          config_keys = Array(Decidim::Bih.goodwill_rewards_catalog).map { |r| r[:key] }
          assert_equal config_keys.sort, rewards.map(&:key).sort
        end
      end
    end
  end
end
