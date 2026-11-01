# frozen_string_literal: true

require "test_helper"

class TopicNotificationDeliveryTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include ActionMailer::TestHelper

  setup do
    @organization = create_organization
    @user = create(:user, :confirmed, organization: @organization, locale: "sr")
    Decidim::Bih::EmailConfirmation.mark_confirmed!(@user)
    clear_enqueued_jobs
  end

  test "topic choice stops a mail queued before the choice changed" do
    delivery = Decidim::NotificationMailer.event_received(
      "decidim.events.core.welcome_notification", "Decidim::WelcomeNotificationEvent", @user, @user, "affected_user", {}
    )
    delivery.deliver_later
    Decidim::Bih::TopicPreferences.set!(@user, topic: :platform_news, enabled: false)
    assert_no_emails { perform_enqueued_jobs(only: ActionMailer::MailDeliveryJob) }
  end

  test "email selection ignores retired frequency and activity filters" do
    @user.update!(notification_types: "none", notifications_sending_frequency: "none")
    generator = Decidim::EmailNotificationGenerator.new(
      "decidim.events.core.welcome_notification", Decidim::WelcomeNotificationEvent, @user, [@user], [@user], {}
    )
    Decidim::Bih::WebPush.stub(:available_for?, false) do
      assert_enqueued_emails(1) { generator.generate }
    end
  end

  test "a matching push prevents an additional event email" do
    generator = Decidim::EmailNotificationGenerator.new(
      "decidim.events.core.welcome_notification", Decidim::WelcomeNotificationEvent, @user, [], [@user], {}
    )
    Decidim::Bih::WebPush.stub(:available_for?, true) do
      assert_no_enqueued_emails { generator.generate }
    end
  end

  test "newsletter unsubscribe disables platform topic even without legacy timestamp" do
    @user.update!(newsletter_notifications_at: nil)
    ok = false
    Decidim::UnsubscribeSettings.call(@user) { on(:ok) { ok = true } }
    assert ok
    assert_not Decidim::Bih::TopicPreferences.enabled?(@user.reload, topic: :platform_news)
    assert Decidim::Bih::TopicPreferences.enabled?(@user, topic: :community_news)
  end

  test "report update remains in inbox with every topic off and sends nothing" do
    Decidim::Bih::TopicPreferences.set_all!(@user, enabled: false)
    report = create_report
    clear_enqueued_jobs
    assert_difference -> { Decidim::Notification.where(user: @user, event_name: "decidim.events.bih.report_status_update").count }, 1 do
      assert_no_enqueued_emails { report.update!(status: "u_obradi") }
    end
    notification = Decidim::Notification.where(user: @user, event_name: "decidim.events.bih.report_status_update").last
    assert_includes notification.event_class_instance.notification_title, report.reference
    assert_nil Decidim::Bih::ReporterMailer.status_update(report).message.to
  end

  test "report chooses one email when there is no push instead of email plus paid copy" do
    report = create_report
    clear_enqueued_jobs
    Decidim::Bih::WebPush.stub(:available_for?, false) do
      assert_no_difference -> { Decidim::Bih::AccountNotification.count } do
        assert_enqueued_emails(1) { report.update!(status: "u_obradi") }
      end
    end
  end

  test "unproven current email is not made eligible by default topics" do
    @user.update_columns(email: "new-mailbox@example.org", confirmed_at: nil) # rubocop:disable Rails/SkipsModelValidations -- Simulate a changed current mailbox without Devise reconfirmation.
    assert_not Decidim::Bih::Messaging::ProactiveEmail.allowed?(@user.reload, topic: :platform_news)
  end

  test "anonymous report contact still receives only its report correspondence" do
    report = Decidim::Bih::Report.create!(organization: @organization, description: "Rupa na putu", reporter_email: "report-contact@example.org")
    assert_equal ["report-contact@example.org"], Decidim::Bih::ReporterMailer.status_update(report).to
  end

  test "newsletter audience uses current topic and proven address without legacy subscription timestamp" do
    @user.update!(newsletter_notifications_at: nil)
    audience = -> { Decidim::Bih::NewsletterEligibility.narrow(Decidim::User.where(id: @user.id), organization: @organization).pluck(:id) }
    assert_equal [@user.id], audience.call
    Decidim::Bih::TopicPreferences.set!(@user, topic: :platform_news, enabled: false)
    assert_empty audience.call
  end

  test "temporary email suppression expires but a hard bounce stays blocking" do
    suppress = lambda do |reason|
      Decidim::Bih::Messaging::TransportSuppression.ingest!(
        organization: @organization, provider: "smtp", channel: "email",
        destination: { kind: "email", value: @user.email }, reason:, source: "provider_webhook", user: @user
      )
    end
    suppress.call("temporary_failure")
    assert_not Decidim::Bih::Messaging::ProactiveEmail.allowed?(@user, topic: :platform_news)
    travel 4.days do
      assert Decidim::Bih::Messaging::ProactiveEmail.allowed?(@user, topic: :platform_news)
      suppress.call("hard_bounce")
      assert_not Decidim::Bih::Messaging::ProactiveEmail.allowed?(@user, topic: :platform_news)
    end
  end

  private

  def create_report
    Decidim::Bih::Report.create!(organization: @organization, author: @user,
                                 description: "Rupa na putu", reporter_email: @user.email)
  end
end
