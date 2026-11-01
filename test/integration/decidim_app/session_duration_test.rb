# frozen_string_literal: true

require "test_helper"
require "capybara"

class SessionDurationTest < ActionDispatch::IntegrationTest
  setup do
    @organization = create_organization
    host! @organization.host
    @user = FactoryBot.create(:user, :confirmed, organization: @organization)
    @phone = "+38765123456"
    Decidim::Authorization.create!(
      user: @user, name: "sms",
      unique_id: Decidim::Bih::SmsAuthorization.unique_id_for(@phone), granted_at: Time.current
    )
  end

  test "phone login persists beyond the old timeout and logout ends the session" do
    raw = Decidim::Bih::LoginToken.issue!(user: @user, purpose: "login", phone: @phone)
    post "/v/#{raw}"
    assert_response :redirect

    session_cookie = Array(response.headers["Set-Cookie"]).join("\n")
    assert_match(/expires=/i, session_cookie)
    assert_equal 365.days.to_i, Rails.application.config.session_options[:expire_after].to_i
    assert_equal 365.days.to_i, Decidim::User.timeout_in.to_i

    travel 364.days do
      get "/account"
      assert_redirected_to "/biceriseno/moj-nalog"
      follow_redirect!
      assert_response :success
    end

    # Activity near the end of the first year renews access into the next.
    travel 728.days do
      get "/biceriseno/moj-nalog"
      assert_response :success
    end

    delete "/users/sign_out"
    get "/biceriseno/moj-nalog"
    assert_redirected_to "/users/sign_in"
  end

  test "an unused session expires after 365 days" do
    raw = Decidim::Bih::LoginToken.issue!(user: @user, purpose: "login", phone: @phone)
    post "/v/#{raw}"
    assert_response :redirect

    travel 366.days do
      get "/biceriseno/moj-nalog"
      assert_redirected_to "/users/sign_in"
    end
  end
end
