# frozen_string_literal: true

require "test_helper"
require "rake"

# Load all decidim_bih rake tasks for this test session.
# Guard against double-loading: calling load_tasks twice registers every task
# action twice (Rake enhances rather than replaces), so a single invoke sends
# duplicate emails. Both this file and
# test/integration/automation_scripts_test.rb call load_tasks at the top level;
# the guard makes whichever loads second a no-op.
Rails.application.load_tasks unless Rake::Task.task_defined?("decidim_bih:reports:stale_digest")

module Decidim
  module Bih
    # Tests for the `decidim_bih:reports:stale_digest` rake task.
    #
    # The task iterates ALL organizations globally — which is correct product
    # behaviour. These tests therefore avoid asserting a global email count and
    # instead select the delivery that belongs to *this* test's organization by
    # matching the org host in the body. This keeps the assertions valid even if
    # another org with stale reports is visible in the same worker's DB.
    class StaleDigestTaskTest < ActiveSupport::TestCase
      include ActionMailer::TestHelper

      setup do
        @organization = create_organization
        # Ensure rake task can be re-invoked in test.
        Rake::Task["decidim_bih:reports:stale_digest"].reenable if
          Rake::Task.task_defined?("decidim_bih:reports:stale_digest")
      end

      test "digest task skips gracefully when BIH_OPERATOR_EMAIL is unset" do
        ENV.delete("BIH_OPERATOR_EMAIL")

        # With no operator email the task bails out immediately — nothing is
        # sent regardless of what organizations or reports exist in the DB.
        assert_no_emails do
          Rake::Task["decidim_bih:reports:stale_digest"].invoke
        end
      end

      test "digest task sends an email for each org with stale reports" do
        ENV["BIH_OPERATOR_EMAIL"] = "operator@example.test"

        report = Decidim::Bih::Report.create!(
          organization: @organization,
          description: "Stara prijava",
          status: "proslijedjeno",
          created_at: 35.days.ago
        )

        Rake::Task["decidim_bih:reports:stale_digest"].reenable
        Rake::Task["decidim_bih:reports:stale_digest"].invoke

        # The task sends one digest per org that has stale reports. Other orgs
        # that happen to exist in this worker's DB may also receive a digest —
        # that is correct behaviour. We assert only that *this* org's digest
        # was delivered exactly once.
        org_deliveries = deliveries_for_org(@organization)
        assert_equal 1, org_deliveries.size,
                     "expected exactly 1 digest email for #{@organization.host}, " \
                     "got #{org_deliveries.size}"

        mail = org_deliveries.first
        assert_equal ["operator@example.test"], mail.to
        assert_includes mail.body.to_s, report.reference
        assert_includes mail.body.to_s, I18n.t("decidim.bih.reports.stale_digest.triage_heading", count: 1)
        assert_includes mail.body.to_s, I18n.t("decidim.bih.reports.stale_digest.stale_heading", count: 1, days: Decidim::Bih::Report::STALE_DAYS)

        # Organization#name is a translatable Hash — must never bleed into subject.
        subject = mail.subject
        assert_not_includes subject, "=>", "subject must not contain raw Hash rocket"
        assert_not_includes subject, '{"', "subject must not contain raw Hash literal"
        # Subject must contain the resolved org name or its host (not a stringified Hash).
        org_identifier = @organization.host
        assert(
          subject.include?(org_identifier) || subject.match?(/\A\[.+\]/),
          "expected subject to contain org identifier, got: #{subject.inspect}"
        )
      ensure
        ENV.delete("BIH_OPERATOR_EMAIL")
      end

      test "digest task sends when a non-stale attention bucket has work" do
        ENV["BIH_OPERATOR_EMAIL"] = "operator@example.test"

        report = Decidim::Bih::Report.create!(
          organization: @organization,
          description: "Private over-SLA description",
          address: "Private over-SLA address",
          status: "primljeno",
          created_at: 3.days.ago,
          updated_at: 3.days.ago
        )

        Rake::Task["decidim_bih:reports:stale_digest"].reenable
        Rake::Task["decidim_bih:reports:stale_digest"].invoke

        org_deliveries = deliveries_for_org(@organization)
        assert_equal 1, org_deliveries.size,
                     "expected one triage digest for #{@organization.host}"

        body = org_deliveries.first.body.to_s
        assert_includes body, I18n.t("decidim.bih.admin.reports.index.sla.buckets.received_over_sla")
        assert_includes body, "forward_received_report"
        assert_includes body, I18n.t("decidim.bih.reports.stale_digest.no_stale")
        assert_not_includes body, report.reference
        assert_not_includes body, "Private over-SLA description"
        assert_not_includes body, "Private over-SLA address"
      ensure
        ENV.delete("BIH_OPERATOR_EMAIL")
      end

      test "digest task sends no email when all reports are fresh" do
        ENV["BIH_OPERATOR_EMAIL"] = "operator@example.test"

        Decidim::Bih::Report.create!(
          organization: @organization,
          description: "Svježa prijava",
          status: "proslijedjeno",
          review_state: "validated",
          forwarded_at: 1.day.ago,
          created_at: 1.day.ago
        )

        Rake::Task["decidim_bih:reports:stale_digest"].reenable
        Rake::Task["decidim_bih:reports:stale_digest"].invoke

        # There must be no digest addressed to the operator that references this
        # org — other orgs' digests are irrelevant to this assertion.
        org_deliveries = deliveries_for_org(@organization)
        assert_empty org_deliveries,
                     "expected no digest for #{@organization.host} (all reports fresh), " \
                     "but got #{org_deliveries.size} email(s)"
      ensure
        ENV.delete("BIH_OPERATOR_EMAIL")
      end

      test "digest mail body contains references, not PII" do
        ENV["BIH_OPERATOR_EMAIL"] = "operator@example.test"

        report = Decidim::Bih::Report.create!(
          organization: @organization,
          description: "Stara prijava",
          reporter_email: "gradjanin@example.org",
          reporter_phone: "+387 65 123 456",
          status: "proslijedjeno",
          created_at: 35.days.ago
        )

        Rake::Task["decidim_bih:reports:stale_digest"].reenable
        Rake::Task["decidim_bih:reports:stale_digest"].invoke

        # Find the one digest that belongs to this org regardless of how many
        # orgs the task processed in total.
        org_deliveries = deliveries_for_org(@organization)
        assert_equal 1, org_deliveries.size,
                     "expected exactly 1 digest email for #{@organization.host}, " \
                     "got #{org_deliveries.size}"

        body = org_deliveries.first.body.to_s

        assert_includes body, report.reference
        assert_includes body, I18n.t("decidim.bih.reports.stale_digest.triage_heading", count: 1)
        assert_not_includes body, "gradjanin@example.org"
        assert_not_includes body, "+387 65 123 456"
      ensure
        ENV.delete("BIH_OPERATOR_EMAIL")
      end

      test "an org with a Setting recipient override gets its own recipient; an org with neither override nor ENV is skipped" do
        ENV.delete("BIH_OPERATOR_EMAIL")

        org_with_override = @organization
        org_without = create_organization(host: "no-recipient.example.test")

        Decidim::Bih::Setting.put(org_with_override, "reports", "operator_email", "perorg@example.test")

        [org_with_override, org_without].each do |org|
          Decidim::Bih::Report.create!(
            organization: org,
            description: "Stara prijava",
            status: "proslijedjeno",
            created_at: 35.days.ago
          )
        end

        Rake::Task["decidim_bih:reports:stale_digest"].reenable
        Rake::Task["decidim_bih:reports:stale_digest"].invoke

        # The override org's digest goes to its own recipient.
        override_deliveries = ActionMailer::Base.deliveries.select do |mail|
          mail.to.include?("perorg@example.test") &&
            mail.body.to_s.include?(org_with_override.host)
        end
        assert_equal 1, override_deliveries.size,
                     "expected the override org's digest to go to its own recipient"

        # The org with neither a Setting override nor ENV is skipped entirely —
        # no digest references its host at all.
        skipped_deliveries = ActionMailer::Base.deliveries.select do |mail|
          mail.body.to_s.include?(org_without.host)
        end
        assert_empty skipped_deliveries,
                     "expected the org with no recipient to be skipped, " \
                     "but #{skipped_deliveries.size} email(s) referenced it"
      ensure
        ENV.delete("BIH_OPERATOR_EMAIL")
      end

      private

      # Returns every delivered message addressed to the operator whose body
      # references *this* test's organization (matched by host in the review
      # link the mailer always includes).
      def deliveries_for_org(organization)
        ActionMailer::Base.deliveries.select do |mail|
          mail.to.include?("operator@example.test") &&
            mail.body.to_s.include?(organization.host)
        end
      end
    end
  end
end
