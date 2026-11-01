# frozen_string_literal: true

require "test_helper"
require "rake"

module Tasks
  # Round 25 — the import task brings the live config-driven rewards catalog
  # under DB management (idempotent upsert by key), so the operator does not
  # lose the existing 9-reward catalog when switching to the admin UI.
  class ImportRewardsCatalogTest < ActiveSupport::TestCase
    TASK = "decidim_bih:goodwill:import_rewards_catalog"

    def self.load_tasks
      return if Rake::Task.task_defined?(TASK)

      Rails.application.load_tasks
    end

    setup do
      self.class.load_tasks
      @organization = create_organization
    end

    teardown do
      Rake::Task[TASK].reenable
    end

    def run_task(host)
      capture_io { Rake::Task[TASK].invoke(host) }
    end

    test "aborts when the host does not resolve to an organization" do
      assert_raises(SystemExit) do
        capture_io { Rake::Task[TASK].invoke("nope.example.org") }
      end
    end

    test "imports every config reward into the table" do
      config_keys = Array(Decidim::Bih.goodwill_rewards_catalog).map { |r| r[:key] }
      assert_difference "Decidim::Bih::Goodwill::Reward.count", config_keys.size do
        run_task(@organization.host)
      end

      imported = Decidim::Bih::Goodwill::Reward.where(organization: @organization)
      assert_equal config_keys.sort, imported.pluck(:key).sort
      # Cost is carried over from config.
      torba = imported.find_by(key: "torba")
      assert_equal 300, torba.cost
      assert torba.active?
      # Title is seeded from the i18n name so the admin list is readable.
      assert torba.title.values.any?(&:present?)
    end

    test "is idempotent — re-running upserts without duplicating" do
      run_task(@organization.host)
      Rake::Task[TASK].reenable
      count = Decidim::Bih::Goodwill::Reward.count

      assert_no_difference "Decidim::Bih::Goodwill::Reward.count" do
        run_task(@organization.host)
      end
      assert_equal count, Decidim::Bih::Goodwill::Reward.count
    end

    test "re-running updates cost from config without overwriting admin edits to title" do
      run_task(@organization.host)
      reward = Decidim::Bih::Goodwill::Reward.find_by(organization: @organization, key: "torba")
      reward.update!(title: { "sr" => "Ručno uređena torba" })

      Rake::Task[TASK].reenable
      run_task(@organization.host)

      reward.reload
      assert_equal 300, reward.cost
      # An operator's title edit is preserved on re-import (we only fill blanks).
      assert_equal "Ručno uređena torba", reward.title["sr"]
    end
  end
end
