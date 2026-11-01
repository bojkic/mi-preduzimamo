# frozen_string_literal: true

require "test_helper"
require "capybara"

module Decidim
  module Bih
    class ReportStaffAlertTest < ActiveSupport::TestCase
      include ActiveJob::TestHelper

      setup do
        @organization = create_organization
        @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
        @triager = FactoryBot.create(:user, :confirmed, organization: @organization)
        @citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
        @role = OperatorRole.create!(organization: @organization, user: @triager,
                                     role: "report_triager", expires_at: 1.day.from_now)
        @report = Report.create!(organization: @organization, description: "Private citizen detail",
                                 address: "Private location", anonymous: true)
        clear_enqueued_jobs
      end

      def alerts
        Decidim::Notification.where(event_name: ReportStaffAlertJob::EVENT_NAME)
      end

      test "only active same-organization staff receive a private review link" do
        FactoryBot.create(:user, :admin, :confirmed, organization: create_organization)
        blocked = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
        blocked.update!(blocked: true)
        ReportStaffAlertJob.perform_now(@report.id)

        assert_equal [@admin.id, @triager.id].sort, alerts.pluck(:decidim_user_id).sort
        notification = alerts.find_by!(user: @admin)
        event = notification.event_class_instance
        assert_equal "/admin/bih/reports/#{@report.reference}", event.resource_path
        assert_includes event.notification_title, @report.reference
        assert_not_includes notification.extra.to_json, @report.description
        assert_not_includes notification.extra.to_json, @report.address
        assert_equal 2, @report.events.find_by!(event_type: "staff_alerts_created").metadata["recipient_count"]
        assert_no_enqueued_jobs(only: ActionMailer::MailDeliveryJob)
      end

      test "revoked and expired triage roles are excluded at delivery" do
        @role.update!(revoked_at: Time.current)
        ReportStaffAlertJob.perform_now(@report.id)
        assert_equal [@admin.id], alerts.pluck(:decidim_user_id)
      end

      test "expired triage roles are excluded" do
        @role.update!(expires_at: 1.minute.ago)
        ReportStaffAlertJob.perform_now(@report.id)
        assert_equal [@admin.id], alerts.pluck(:decidim_user_id)
      end

      test "job replays do not recreate even dismissed alerts" do
        ReportStaffAlertJob.perform_now(@report.id)
        alerts.delete_all
        ReportStaffAlertJob.perform_now(@report.id)
        assert_empty alerts
        assert_equal 1, @report.events.where(event_type: "staff_alerts_created").count
      end

      test "notification batch and audit marker roll back together" do
        Decidim::Notification.stub(:create!, ->(**) { raise ActiveRecord::RecordInvalid }) do
          assert_raises(ActiveRecord::RecordInvalid) { ReportStaffAlertJob.perform_now(@report.id) }
        end
        assert_empty alerts
        assert_not @report.events.exists?(event_type: "staff_alerts_created")
        ReportStaffAlertJob.perform_now(@report.id)
        assert_equal 2, alerts.count
      end

      test "intake captures a metadata-only staff alert for durable chat replay" do
        capture = DurableEffects.capture do
          ReportIntake.new.call(organization: @organization, description: "Private description")
        end
        effect = capture.effects.find { |item| item["job_class"] == "Decidim::Bih::ReportStaffAlertJob" }
        assert_equal [capture.result.id], effect.fetch("arguments")
        assert_not_includes effect.to_json, "Private description"
        assert_empty alerts
      end

      test "push only queues for opted-in devices and does not duplicate on replay" do
        @admin.update!(notification_settings: @admin.notification_settings.merge(
          "subscriptions" => { "browser" => { "auth" => "test-device", "p256dh" => "test", "endpoint" => "https://fcm.googleapis.com/fcm/send/test-device" } }
        ))
        WebPush.stub(:enabled?, true) do
          assert_enqueued_jobs 1, only: WebPushDeliveryJob do
            ReportStaffAlertJob.perform_now(@report.id)
            ReportStaffAlertJob.perform_now(@report.id)
          end
        end
      end

      test "missing reports are harmless" do
        ReportStaffAlertJob.perform_now(-1)
        assert_empty alerts
      end
    end
  end
end
