# frozen_string_literal: true

require "test_helper"
require "rake"
require "json"
require "English"

Rails.application.load_tasks unless Rake::Task.task_defined?("decidim_bih:messaging:backfill")

module Decidim
  module Bih
    # Maintenance reads stay available after matrix consolidation. The retired
    # import cannot recreate current matrix state, even with old apply flags.
    class MessagingTasksTest < ActiveSupport::TestCase
      BACKFILL = "decidim_bih:messaging:backfill"
      COMPARE = "decidim_bih:messaging:shadow_compare"
      DIAGNOSTICS = "decidim_bih:messaging:diagnostics"
      WRAPPER = Rails.root.join("script/mi_messaging_shadow_compare")

      setup do
        @organization = create_organization
        @citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
        [BACKFILL, COMPARE, DIAGNOSTICS].each { |task| Rake::Task[task].reenable }
        ENV.delete("APPLY")
        ENV.delete("MI_MESSAGING_BACKFILL_CONFIRM")
      end

      teardown do
        ENV.delete("APPLY")
        ENV.delete("MI_MESSAGING_BACKFILL_CONFIRM")
        ENV.delete("FAIL_ON_DIFF")
      end

      test "the retired backfill task reports canonical counts and writes nothing" do
        write_topic_preference!

        out, = capture_io { Rake::Task[BACKFILL].invoke(@organization.host) }
        summary = JSON.parse(out)

        assert_equal false, summary.fetch("apply")
        assert_equal 0, summary.fetch("planned")
        assert_equal 1, summary.fetch("already_current")
        assert_equal 0, summary.fetch("imported")
        assert_equal 1, Decidim::Bih::Messaging::Preference.count
      end

      test "the dry-run output carries no citizen identifier" do
        write_topic_preference!

        out, = capture_io { Rake::Task[BACKFILL].invoke(@organization.host) }

        assert_not_includes out, @citizen.email
        assert_not_includes out, @citizen.nickname
        assert_not_includes out, @citizen.id.to_s.rjust(12, "0")
        assert_not JSON.parse(out).has_key?("last_user_id")
      end

      test "retired apply refuses even a formerly valid host confirmation" do
        write_topic_preference!
        ENV["APPLY"] = "1"
        ENV["MI_MESSAGING_BACKFILL_CONFIRM"] = @organization.host

        assert_raises(SystemExit) do
          capture_io { Rake::Task[BACKFILL].invoke(@organization.host) }
        end
        assert_equal 1, Decidim::Bih::Messaging::Preference.count
      end

      test "an unknown host aborts rather than guessing an organization" do
        assert_raises(SystemExit) do
          capture_io { Rake::Task[BACKFILL].invoke("nobody.example.invalid") }
        end
      end

      test "the comparison task prints an aggregate report and stays read-only" do
        write_topic_preference!
        ENV["FAIL_ON_DIFF"] = "0"

        out, = capture_io { Rake::Task[COMPARE].invoke(@organization.host) }
        report = JSON.parse(out)

        assert report.has_key?("evaluated")
        assert report.has_key?("reason_counts")
        assert report.has_key?("policy_version")
        assert_equal 1, Decidim::Bih::Messaging::Preference.count
        assert_equal 0, Decidim::Bih::Messaging::Intent.count
      end

      test "the diagnostics task reports correlation aggregates" do
        out, = capture_io { Rake::Task[DIAGNOSTICS].invoke(@organization.host) }
        diagnostics = JSON.parse(out)

        assert_equal 0, diagnostics.fetch("intents")
        assert diagnostics.has_key?("uncertain")
      end

      test "the host wrapper exists, is executable and only calls the read-only task" do
        assert_predicate WRAPPER, :exist?
        assert File.executable?(WRAPPER), "script/mi_messaging_shadow_compare must be executable"
        contents = WRAPPER.read

        assert_includes contents, COMPARE
        assert_not_includes contents, "APPLY"
        assert_not_includes contents, BACKFILL
      end

      test "the wrapper refuses to run without an organization host" do
        output = `#{WRAPPER} 2>&1`

        assert_equal 64, $CHILD_STATUS.exitstatus
        assert_includes output, "usage"
      end

      private

      def write_topic_preference!
        Decidim::Bih::TopicPreferences.set!(@citizen, topic: :report_updates, enabled: false)
      end
    end
  end
end
