# frozen_string_literal: true

require "test_helper"
require "support/synthetic_foundation_reference"

module Decidim
  module Bih
    # The weekly analytics digest carries the host's foundation call-status
    # review reminder when the effective expiry is within 14 days.
    class AnalyticsDigestReminderTest < ActionMailer::TestCase
      include SyntheticFoundationReference

      teardown do
        Decidim::Bih.analytics_digest_reminders_provider = @previous_reminder_provider
        restore_synthetic_foundation_reference
      end
      RECIPIENT = "analytics@example.test"

      setup do
        install_synthetic_foundation_reference
        @source_expiry = Date.iso8601(@synthetic_foundation_metadata.fetch("review_expires_on"))
        @previous_reminder_provider = Decidim::Bih.analytics_digest_reminders_provider
        Decidim::Bih.analytics_digest_reminders_provider = DecidimApp::Bijeljina::ContentReviewReminders.method(:call)
        @organization = create_organization
        @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
      end

      test "fires at 14 days before the approved override expires, with the admin URL, and not at 15" do
        approve_override!(expires_on: Date.current + 14)
        body = digest_body

        assert_includes body, "https://#{@organization.host}/admin/bih/foundation-status"
        assert_includes body, I18n.t("decidim_app.admin.foundation_status.digest_reminder.expiring",
                                     date: (Date.current + 14).strftime("%d.%m.%Y."), days: 14,
                                     url: "https://#{@organization.host}/admin/bih/foundation-status")
        assert_includes body, I18n.t("decidim.bih.admin.analytics.digest.review_link", url: "https://#{@organization.host}/admin/bih/analytics")

        override = DecidimApp::Bijeljina::FoundationStatusOverride.approved_for(@organization)
        override.stage(review_expires_on: Date.current + 15)
        override.save!
        override.approve!(actor: @admin)

        assert_not_includes digest_body, "/admin/bih/foundation-status"
      end

      test "an expired override is reported as expired" do
        approve_override!(reviewed_on: Date.current - 40, expires_on: Date.current - 3)

        assert_includes digest_body, I18n.t("decidim_app.admin.foundation_status.digest_reminder.expired",
                                            date: (Date.current - 3).strftime("%d.%m.%Y."), days: -3,
                                            url: "https://#{@organization.host}/admin/bih/foundation-status")
      end

      test "a draft override does not count; the explicitly authored YAML expiry is what reminds" do
        draft = DecidimApp::Bijeljina::FoundationStatusOverride.for_organization(@organization)
        draft.stage(current_open_status: "open", reviewed_on: Date.current, review_expires_on: Date.current + 3)
        draft.save!

        travel_to (@source_expiry - 15).to_time(:utc) + 9.hours do
          assert_not_includes digest_body, "/admin/bih/foundation-status", "15 days before the YAML expiry"
        end
        travel_to (@source_expiry - 14).to_time(:utc) + 9.hours do
          body = digest_body
          assert_includes body, "/admin/bih/foundation-status"
          assert_includes body, @source_expiry.strftime("%d.%m.%Y.")
        end
      end

      test "the reminder provider returns plain aggregate lines and never breaks the digest" do
        lines = DecidimApp::Bijeljina::ContentReviewReminders.call(organization: @organization, today: @source_expiry - 14)
        assert_equal 1, lines.size
        assert_includes lines.first, "preostalo dana: 14"
        assert_empty DecidimApp::Bijeljina::ContentReviewReminders.call(organization: @organization, today: @source_expiry - 15)

        previous = Decidim::Bih.analytics_digest_reminders_provider
        Decidim::Bih.analytics_digest_reminders_provider = ->(organization:) { raise "provider down #{organization.id}" }
        assert_includes digest_body, I18n.t("decidim.bih.admin.analytics.digest.datasets_heading")
      ensure
        Decidim::Bih.analytics_digest_reminders_provider = previous
      end

      private

      def approve_override!(expires_on:, reviewed_on: Date.current)
        override = DecidimApp::Bijeljina::FoundationStatusOverride.for_organization(@organization)
        override.stage(current_open_status: "open", reviewed_on:, review_expires_on: expires_on)
        override.save!
        assert_equal :approved, override.approve!(actor: @admin)
        override
      end

      def digest_body
        Decidim::Bih::Admin::AnalyticsDigestMailer.digest(organization: @organization, recipient: RECIPIENT).body.to_s
      end
    end
  end
end
