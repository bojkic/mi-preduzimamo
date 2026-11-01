# frozen_string_literal: true

require "test_helper"
require "rake"

module Tasks
  class PostalPurgeTaskTest < ActiveSupport::TestCase
    def self.load_tasks
      return if Rake::Task.task_defined?("decidim_bih:postal:purge_unconfirmed")

      Rails.application.load_tasks
    end

    setup do
      self.class.load_tasks
      @organization = create_organization
      @user = FactoryBot.create(:user, :confirmed, organization: @organization)
    end

    teardown do
      Rake::Task["decidim_bih:postal:purge_unconfirmed"].reenable
      ENV.delete("ORGANIZATION_ID")
      ENV.delete("HOST")
      ENV.delete("APPLY")
      ENV.delete("POSTAL_CUTOFF")
    end

    test "task aborts without ORGANIZATION_ID or HOST" do
      assert_raises(SystemExit) do
        capture_io do
          Rake::Task["decidim_bih:postal:purge_unconfirmed"].invoke
        end
      end
    end

    test "task runs dry-run by default (no deletions)" do
      ENV["ORGANIZATION_ID"] = @organization.id.to_s
      old_auth = pending_postal_auth(@user, created_at: 7.months.ago)

      assert_no_difference("Decidim::Authorization.count") do
        capture_io { Rake::Task["decidim_bih:postal:purge_unconfirmed"].invoke }
      end

      assert Decidim::Authorization.exists?(old_auth.id), "dry-run must not delete"
    end

    test "task deletes with APPLY=1" do
      ENV["ORGANIZATION_ID"] = @organization.id.to_s
      ENV["APPLY"] = "1"
      pending_postal_auth(@user, created_at: 7.months.ago)

      assert_difference("Decidim::Authorization.count", -1) do
        capture_io { Rake::Task["decidim_bih:postal:purge_unconfirmed"].invoke }
      end
    end

    test "task outputs the purge count" do
      ENV["ORGANIZATION_ID"] = @organization.id.to_s
      pending_postal_auth(@user, created_at: 7.months.ago)

      output, = capture_io { Rake::Task["decidim_bih:postal:purge_unconfirmed"].invoke }
      assert output.include?("purged_pending_postal_authorizations=1"),
             "task output must report the count"
    end

    private

    def pending_postal_auth(user, created_at: 7.months.ago)
      Decidim::Authorization.create!(
        user: user,
        name: "postal_letter",
        granted_at: nil,
        verification_metadata: {
          "address" => "Ulica 1, Bijeljina",
          "pending_verification_code" => "555666"
        },
        created_at: created_at,
        updated_at: created_at
      )
    end
  end
end
