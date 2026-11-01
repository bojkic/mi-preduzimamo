# frozen_string_literal: true

require "test_helper"
require "support/synthetic_messaging_configuration"

module Decidim
  module Bih
    # Explicit fictional monitored mailbox fixture; no community mail defaults are enabled.
    #
    # The core SMTP default and the interceptor share the engine setting;
    # Decidim0.32 no longer accepts the legacy mailer_reply option.
    class MonitoredReplyMailboxTest < ActionMailer::TestCase
      include SyntheticMessagingConfiguration
      teardown { restore_synthetic_reply_mailbox }
      class SmtpReplyFixtureMailer < Decidim::ApplicationMailer
        layout false

        def probe(organization, reply_to = nil)
          @organization = organization
          headers = { to: "recipient@example.test", subject: "Reply fixture", body: "Synthetic fixture" }
          headers[:reply_to] = reply_to if reply_to
          mail(**headers)
        end
      end

      setup do
        install_synthetic_reply_mailbox
        @organization = create_organization
        @citizen = create(:user, :confirmed, organization: @organization, locale: "sr")
      end

      test "an explicitly configured synthetic community uses its monitored reply mailbox" do
        assert_operator Decidim::ApplicationMailer, :<, Decidim::Bih::MailReplyTo::CoreSmtpDefaults
        assert Decidim::Bih.mailer_reply_to.present?, "Explicit fixture requires its monitored mailbox"
        assert_match(/\A[^@\s]+@[^@\s]+\z/, Decidim::Bih.mailer_reply_to)
      end

      test "an engine mailer that does not inherit from ApplicationMailer still carries it" do
        assert_not_operator Decidim::Bih::RegistrationMailer, :<, Decidim::ApplicationMailer,
                            "if this ever changes, the reason this interceptor exists changes with it"

        mail = Decidim::Bih::RegistrationMailer.resume(@citizen, "tok").deliver_now

        assert_equal [Decidim::Bih.mailer_reply_to], mail.reply_to
      end

      test "core SMTP uses the monitored reply address before its sender fallback" do
        @organization.update!(smtp_settings: { "address" => "smtp.example.test", "port" => "587" })
        message = SmtpReplyFixtureMailer.probe(@organization).message

        assert_equal [Decidim::Bih.mailer_reply_to], message.reply_to
      end

      test "core SMTP preserves an explicit message reply address" do
        @organization.update!(smtp_settings: { "address" => "smtp.example.test", "port" => "587" })
        message = SmtpReplyFixtureMailer.probe(@organization, "thread@example.test").message

        assert_equal ["thread@example.test"], message.reply_to
      end

      test "a core mailer carries it too, without per-organization SMTP settings" do
        # This is the case core's own `set_smtp` returns early from, which is
        # covered by the core default hook and non-core interceptor.
        @organization.update!(smtp_settings: {})
        Decidim::Bih::EmailConfirmation.mark_confirmed!(@citizen)

        mail = Decidim::NotificationMailer.event_received(
          "decidim.events.core.welcome_notification",
          "Decidim::WelcomeNotificationEvent",
          @citizen, @citizen, "affected_user", { force_email: true }
        ).deliver_now

        assert_equal [Decidim::Bih.mailer_reply_to], mail.reply_to
      end
    end
  end
end
