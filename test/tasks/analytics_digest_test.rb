# frozen_string_literal: true

require "test_helper"
require "rake"
require "securerandom"
require "open3"
require "tempfile"

Rails.application.load_tasks unless Rake::Task.task_defined?("decidim_bih:analytics:digest")

module Decidim
  module Bih
    class AnalyticsDigestTaskTest < ActiveSupport::TestCase
      include ActionMailer::TestHelper

      setup do
        @organization = create_organization
        @citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
        Rake::Task["decidim_bih:analytics:digest"].reenable if
          Rake::Task.task_defined?("decidim_bih:analytics:digest")
      end

      test "digest task skips gracefully when analytics delivery is not opted in" do
        ENV.delete("BIH_ANALYTICS_DIGEST_ENABLED")
        ENV["BIH_ANALYTICS_DIGEST_EMAIL"] = "analytics@example.test"

        assert_no_emails do
          Rake::Task["decidim_bih:analytics:digest"].invoke
        end
      ensure
        ENV.delete("BIH_ANALYTICS_DIGEST_EMAIL")
      end

      # A successful task exit with no opted-in recipient must stay visible.
      test "a skipped organization logs the token the cron health smoke greps for" do
        ENV.delete("BIH_ANALYTICS_DIGEST_ENABLED")
        ENV.delete("BIH_ANALYTICS_DIGEST_EMAIL")

        log = nil
        assert_no_emails do
          log = capture_digest_log do
            Rake::Task["decidim_bih:analytics:digest"].reenable
            Rake::Task["decidim_bih:analytics:digest"].invoke
          end
        end

        assert_includes log, "skipped=no_opt_in_recipient"
        assert_includes log, @organization.host
        # The other half of the contract: execute the exported read-only detector.
        detector = Rails.root.join("script/mi_analytics_digest_health")
        assert_includes detector.read, "skipped=no_opt_in_recipient"
        Tempfile.create("authored-digest-health-") do |file|
          file.write("[#{Time.now.utc.iso8601}] analytics-digest START\n#{log}\n[#{Time.now.utc.iso8601}] analytics-digest END\n")
          file.flush
          output, error, result = Open3.capture3(RbConfig.ruby, detector.to_s, "--log", file.path)
          assert_equal 1, result.exitstatus, error
          assert_equal "no_opt_in_recipient", JSON.parse(output).fetch("reason")
          assert_equal "warn", JSON.parse(output).fetch("status")
        end
      end

      test "digest task sends aggregate analytics with explicit global opt-in" do
        ENV["BIH_ANALYTICS_DIGEST_ENABLED"] = "1"
        ENV["BIH_ANALYTICS_DIGEST_EMAIL"] = "analytics@example.test"
        create_private_analytics_source_data!

        Rake::Task["decidim_bih:analytics:digest"].reenable
        Rake::Task["decidim_bih:analytics:digest"].invoke

        org_deliveries = deliveries_for_org(@organization, "analytics@example.test")
        assert_equal 1, org_deliveries.size,
                     "expected one analytics digest for #{@organization.host}"

        mail = org_deliveries.first
        body = mail.body.to_s

        assert_equal ["analytics@example.test"], mail.to
        assert_empty mail.attachments
        assert_includes mail.subject, "Interni analitički sažetak"
        assert_includes body, I18n.t("decidim.bih.admin.analytics.digest.datasets_heading")
        assert_includes body, I18n.t("decidim.bih.admin.analytics.datasets.report_triage")
        assert_includes body, "Zaprimljeno preko SLA"
        assert_includes body, "waste/fallback/sr"
        assert_not_includes body, "Private analytics report"
        assert_not_includes body, "analytics-citizen@example.org"
        assert_not_includes body, "+387 65 999 111"
        assert_not_includes body, "private-analytics-session"
        assert_not_includes body, "Private bot prompt"

        # The one bounded-window dataset in the digest. digest_sections has
        # computed mi_bot_review_comparison on every run since the digest
        # existed; the body never printed it, so an operator would only ever
        # have seen cumulative figures that cannot report a change.
        assert_includes body, I18n.t("decidim.bih.admin.analytics.datasets.mi_bot_review_comparison")
        assert_includes body, "waste/fallback/sr not_helpful/30d"
      ensure
        ENV.delete("BIH_ANALYTICS_DIGEST_ENABLED")
        ENV.delete("BIH_ANALYTICS_DIGEST_EMAIL")
      end

      test "per-organization analytics recipient override wins without global env opt-in" do
        ENV.delete("BIH_ANALYTICS_DIGEST_ENABLED")
        ENV.delete("BIH_ANALYTICS_DIGEST_EMAIL")
        Decidim::Bih::Setting.put(@organization, "analytics", "operator_email", "perorg-analytics@example.test")
        create_private_analytics_source_data!

        Rake::Task["decidim_bih:analytics:digest"].reenable
        Rake::Task["decidim_bih:analytics:digest"].invoke

        org_deliveries = deliveries_for_org(@organization, "perorg-analytics@example.test")
        assert_equal 1, org_deliveries.size,
                     "expected the analytics digest to use the per-org recipient"
      ensure
        ENV.delete("BIH_ANALYTICS_DIGEST_ENABLED")
        ENV.delete("BIH_ANALYTICS_DIGEST_EMAIL")
      end

      private

      # The rake task logs through Rails.logger; the cron wrapper redirects it
      # into shared/log/analytics-digest.log, which is what the smoke greps.
      def capture_digest_log
        buffer = StringIO.new
        previous = Rails.logger
        Rails.logger = ActiveSupport::Logger.new(buffer)
        yield
        buffer.string
      ensure
        Rails.logger = previous
      end

      def create_private_analytics_source_data!
        Decidim::Bih::Report.create!(
          organization: @organization,
          description: "Private analytics report description",
          address: "Private analytics address",
          reporter_email: "analytics-citizen@example.org",
          reporter_phone: "+387 65 999 111",
          status: "primljeno",
          created_at: 3.days.ago,
          updated_at: 3.days.ago
        )

        Decidim::Bih::ConciergeFeedback.create!(
          organization: @organization,
          user: @citizen,
          reply_id: SecureRandom.uuid,
          session_digest: "private-analytics-session",
          value: "not_helpful",
          locale: "sr",
          metadata: {
            "outcome" => "fallback",
            "answer_intent" => "waste",
            "reply_length" => 100,
            "quick_replies_count" => 1,
            "raw_prompt" => "Private bot prompt"
          }
        )
      end

      def deliveries_for_org(organization, recipient)
        ActionMailer::Base.deliveries.select do |mail|
          mail.to.include?(recipient) &&
            mail.body.to_s.include?(organization.host)
        end
      end
    end
  end
end
