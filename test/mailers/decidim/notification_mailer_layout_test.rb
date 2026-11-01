# frozen_string_literal: true

require "test_helper"

module Decidim
  # The host loads decidim-bih after decidim-core, so the engine's
  # layouts/decidim/mailer.html.erb must win over core's. This is the proof
  # in the real host — the engine harness proves the same on a generated
  # host. What is pinned: Serbian welcome text (no English fallback), no dark
  # header band, no webpack stylesheet, the organisation's accent colour.
  class NotificationMailerLayoutTest < ActionMailer::TestCase
    setup do
      @organization = create_organization(
        colors: { "primary" => "#d86b4a", "tertiary" => "#1c3d53" }
      )
      @citizen = create(:user, :confirmed, organization: @organization, locale: "sr")
      Decidim::Bih::EmailConfirmation.mark_confirmed!(@citizen)
    end

    test "welcome mail is Serbian and uses the engine layout" do
      mail = Decidim::NotificationMailer.event_received(
        "decidim.events.core.welcome_notification",
        "Decidim::WelcomeNotificationEvent",
        @citizen,
        @citizen,
        "affected_user",
        { force_email: true }
      ).deliver_now
      html = (mail.html_part || mail).body.decoded

      assert_includes mail.subject, "Dobro došao/la"
      assert_not_includes mail.subject, "Thanks for joining"
      assert_includes html, "Zdravo"
      assert_not_includes html, "#1a181d"
      assert_not_includes html, "decidim-bar"
      assert_not_includes html, "/packs"
      assert_includes html, "#d86b4a"
      assert_includes html, I18n.t("decidim.newsletter_mailer.newsletter.no_reply_notice", locale: :sr)
    end
  end
end
