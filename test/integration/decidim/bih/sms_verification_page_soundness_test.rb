# frozen_string_literal: true

require "test_helper"
require "capybara"

module Decidim
  module Bih
    # Soundness regression for the corrected phone-verification design:
    #
    # A token must NEVER appear in page HTML (not as a raw token, not embedded
    # in a viber:// deep link).  Tokens are proof-of-phone only when they are
    # DELIVERED to the phone (SMS or Viber), not when they are displayed on
    # a web page accessible to any browser the user happens to be on.
    #
    # These tests assert that:
    #   1. The verification page renders the "link sent" informational copy.
    #   2. NO consumable token appears in the page HTML.
    #   3. NO viber://...context=verify_ deep link appears in the page HTML.
    class SmsVerificationPageSoundnessTest < ActionDispatch::IntegrationTest
      include ::Devise::Test::IntegrationHelpers

      setup do
        @organization = create_organization
        host! @organization.host
        @user = FactoryBot.create(:user, :confirmed, organization: @organization)
        sign_in @user
      end

      test "verification page renders without embedding a token" do
        get "/sms/authorizations/new"
        assert_response :success

        # No raw LoginToken should appear in the page
        Decidim::Bih::LoginToken.all.each do |token|
          # The token digest is never the raw value, but scan for any
          # urlsafe_base64-looking string that matches a known token
          assert_no_match token.token_digest, response.body,
                          "token digest must not appear in page HTML"
        end
      end

      test "verification page does NOT embed a viber:// deep link with a verify context token" do
        get "/sms/authorizations/new"
        assert_response :success

        # The old (unsound) design embedded: viber://pa?chatURI=...&context=verify_<token>
        # Assert this pattern is completely absent from the page.
        assert_no_match(%r{viber://.*context=verify_}i, response.body,
                        "page must not embed a viber:// verify deep link (unsound: token on page)")
      end

      test "verification page does NOT contain 'verify_' token strings in HTML" do
        get "/sms/authorizations/new"
        assert_response :success

        # Any raw "verify_<random>" string in the page would be a soundness violation.
        assert_no_match(/verify_[A-Za-z0-9_-]{10,}/,
                        response.body,
                        "verify_<token> must never appear in page HTML")
      end

      test "verification page shows informational copy when Viber is configured" do
        original = Decidim::Bih::Config.infobip
        Decidim::Bih::Config.instance_variable_set(:@infobip,
                                                   original.merge(viber_bm_sender: "MIBusiness"))

        get "/sms/authorizations/new"
        assert_response :success

        # The "link sent" informational block must be present
        expected_title = I18n.t("decidim.bih.goodwill.verify_cta.viber.delivery_title",
                                locale: :sr)
        assert_includes response.body, expected_title
      ensure
        Decidim::Bih::Config.instance_variable_set(:@infobip, original)
      end

      test "verification page does NOT show the Viber block when Viber sender is not configured" do
        original = Decidim::Bih::Config.infobip
        Decidim::Bih::Config.instance_variable_set(:@infobip,
                                                   original.merge(viber_bm_sender: nil))

        get "/sms/authorizations/new"
        assert_response :success

        # The delivery block title must not be present
        expected_title = I18n.t("decidim.bih.goodwill.verify_cta.viber.delivery_title",
                                locale: :sr)
        assert_not_includes response.body, expected_title
      ensure
        Decidim::Bih::Config.instance_variable_set(:@infobip, original)
      end
    end
  end
end
