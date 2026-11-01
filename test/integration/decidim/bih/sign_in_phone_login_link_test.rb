# frozen_string_literal: true

require "test_helper"
require "capybara"

module Decidim
  module Bih
    class SignInPhoneLoginLinkTest < ActionDispatch::IntegrationTest
      setup do
        @organization = create_organization
        host! @organization.host
      end

      test "one phone form is available without a duplicate sign-in link" do
        get "/users/sign_in"

        assert_response :success
        assert_select "form#mi-auth-phone-form[action='/biceriseno/prijava']", count: 1
        assert_select "a[href='/biceriseno/prijava']", count: 0
        assert_select "#mi-auth-code-form", count: 0
      end

      test "the old phone entry redirects to the canonical sign-in page" do
        get "/biceriseno/prijava"

        assert_redirected_to "/users/sign_in"
        follow_redirect!
        assert_response :success
        assert_select "a[href=?]", Decidim::Bih.registration_path
      end

      test "requesting a message shows code entry before resend on the canonical page" do
        post "/biceriseno/prijava", params: { phone: "+38765999999" }

        assert_redirected_to "/users/sign_in"
        follow_redirect!
        assert_response :success
        assert_select ".mi-auth > section:first-child #mi-auth-code-form", count: 1
        assert_select ".mi-auth > section:nth-child(2) #mi-auth-phone-form", count: 1
        assert_select "#mi-auth-phone-title", text: I18n.t("decidim.bih.phone_sessions.new.resend_title")
        assert_match(/no-store/, response.headers["Cache-Control"])
      end

      test "invalid code keeps code entry ahead of resend" do
        post "/biceriseno/prijava", params: { phone: "+38765999999" }
        post "/biceriseno/prijava/kod", params: { verification_code: "000000" }

        assert_response :unprocessable_entity
        assert_select ".mi-auth > section:first-child #mi-auth-code-form", count: 1
        assert_select ".mi-auth > section:nth-child(2) #mi-auth-phone-form", count: 1
      end

      test "Decidim's sign-in page links new citizens to the same registration" do
        get "/users/sign_in"

        assert_response :success
        assert_select "a[href=?]", Decidim::Bih.registration_path
      end
    end
  end
end
