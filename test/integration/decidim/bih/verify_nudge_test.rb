# frozen_string_literal: true

require "test_helper"
require "capybara"

module Decidim
  module Bih
    class VerifyNudgeTest < ActionDispatch::IntegrationTest
      include ::Devise::Test::IntegrationHelpers

      setup do
        @organization = create_organization
        host! @organization.host
        @user = FactoryBot.create(:user, :confirmed, organization: @organization)
      end

      test "signed-in unverified users see the verification nudge" do
        sign_in @user
        # Use the hub canonical URL (legacy /biceriseno/tabla 301s here).
        get "/biceriseno/zajednistvo?tab=tabla"
        assert_response :success
        assert_includes response.body, "verify-nudge"
        assert_includes response.body, I18n.t("decidim.bih.account.verify_nudge.message", locale: :sr)
        assert_includes response.body, "/biceriseno/moj-nalog"
      end

      test "verified users do not see the nudge" do
        FactoryBot.create(:authorization, :granted, user: @user, name: "sms")
        sign_in @user
        get "/biceriseno/zajednistvo?tab=tabla"
        assert_response :success
        assert_not_includes response.body, "verify-nudge"
      end

      test "anonymous visitors do not see the nudge" do
        get "/biceriseno/zajednistvo?tab=tabla"
        assert_response :success
        assert_not_includes response.body, "verify-nudge"
      end

      test "signed-in users from another organization are treated as anonymous" do
        other_organization = create_organization
        other_user = FactoryBot.create(:user, :confirmed, organization: other_organization)

        sign_in other_user
        get "/biceriseno/zajednistvo?tab=tabla"

        assert_response :success
        assert_not_includes response.body, "verify-nudge"
      end
    end
  end
end
