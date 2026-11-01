# frozen_string_literal: true

require "test_helper"
require "capybara"

module Decidim
  module Bih
    class MagicLinkTest < ActionDispatch::IntegrationTest
      setup do
        @organization = create_organization
        host! @organization.host
        @user = FactoryBot.create(:user, :confirmed, organization: @organization)
        @phone = "+38765123456"
        @authorization = Decidim::Authorization.create!(
          user: @user, name: "sms", unique_id: Decidim::Bih::SmsAuthorization.unique_id_for(@phone),
          verification_metadata: { "verification_code" => "123456", "code_sent_at" => Time.current }
        )
        @raw = LoginToken.issue!(user: @user, purpose: "verify", phone: @phone)
      end

      test "GET shows the confirm page without consuming the token" do
        get "/v/#{@raw}"
        assert_response :success
        get "/v/#{@raw}"
        assert_response :success, "a link-preview prefetch must not burn the token"
        assert_nil LoginToken.last.consumed_at
      end

      test "GET short link renders a mounted engine consume form" do
        get "/v/#{@raw}"

        assert_response :success
        assert_includes response.body, "/biceriseno/v/#{@raw}",
                        "confirm form must post through the mounted engine route"
      end

      test "POST consumes, grants SMS authorization, and returns to account verification" do
        post "/v/#{@raw}"
        # Pinned rather than either-or. Two facts decide this destination and
        # both are fixed by the fixtures above: the user has no komsiluk, so
        # Onboarding::NextStep answers the picker (?setup=1), and the token's
        # purpose is "verify", which is the only purpose that gets the PWA
        # marker appended (&app=1) — see the engine's
        # CompletesPhoneAuthentication#phone_authentication_destination. If
        # either changes, this test should say so instead of shrugging.
        assert_redirected_to "/biceriseno/komsiluk?setup=1&app=1"
        assert @authorization.reload.granted?
        follow_redirect!
        assert_response :success # wallet requires login => session established
      end

      test "POST mounted engine magic link consumes the token" do
        post "/biceriseno/v/#{@raw}"

        # Same destination as the short route above, and for the same two
        # reasons: no komsiluk yet, purpose "verify".
        assert_redirected_to "/biceriseno/komsiluk?setup=1&app=1"
        assert @authorization.reload.granted?
      end

      test "POST rotates the session id (fixation guard)" do
        get "/v/#{@raw}"
        old_session = session.id
        post "/v/#{@raw}"
        assert_not_equal old_session, session.id
      end

      test "a consumed or unknown token cannot be replayed" do
        post "/v/#{@raw}"
        delete_session_cookie
        post "/v/#{@raw}"
        assert_response :unprocessable_entity
        post "/v/zzzz-not-a-token"
        assert_response :unprocessable_entity
      end

      test "tokens from another organization are rejected" do
        other = create_organization(host: "other.example.org")
        host! other.host
        post "/v/#{@raw}"
        assert_response :unprocessable_entity
      end

      test "blocked users are not signed in" do
        @user.update!(blocked: true, blocked_at: Time.current, extended_data: {})
        post "/v/#{@raw}"
        assert_response :unprocessable_entity
        assert_not @authorization.reload.granted?
      end

      test "deleted users are not signed in via magic link" do
        @user.update!(deleted_at: Time.current)
        raw_for_deleted = LoginToken.issue!(user: @user, purpose: "verify", phone: @phone)
        post "/v/#{raw_for_deleted}"
        assert_response :unprocessable_entity, "a deleted user must not be signed in"
        assert_not @authorization.reload.granted?, "authorization must not be granted for deleted user"
      end

      test "GET /v/:token sets Referrer-Policy: strict-origin to protect the token URL" do
        get "/v/#{@raw}"
        assert_response :success
        assert_equal "strict-origin", response.headers["Referrer-Policy"],
                     "Referrer-Policy must be strict-origin so the token URL does not leak in the Referer header"
        assert_includes response.headers["Cache-Control"], "no-store"
        assert_includes response.headers["Cache-Control"], "private"
        assert_equal "no-cache", response.headers["Pragma"]
        assert_equal "noindex, nofollow", response.headers["X-Robots-Tag"]
      end

      test "invalid token responses are also non-cacheable" do
        post "/v/not-a-live-token"

        assert_response :unprocessable_entity
        assert_includes response.headers["Cache-Control"], "no-store"
        assert_includes response.headers["Cache-Control"], "private"
        assert_equal "strict-origin", response.headers["Referrer-Policy"]
      end

      # Local-number binding end-to-end:
      # Unique_id was computed from the as-typed local number ("066900004").
      # Token was issued with phone: "066900004".
      # Consuming the token must grant the authorization (unique_id match).
      test "local-format number: consuming verify token grants authorization (unique_id matches as-typed)" do
        local_phone = "066900004"
        unique_id = Digest::SHA256.hexdigest(
          "#{local_phone}-#{Rails.application.secret_key_base}"
        )
        user = FactoryBot.create(:user, :confirmed, organization: @organization)
        auth = Decidim::Authorization.create!(
          user: user,
          name: "sms",
          unique_id: unique_id,
          granted_at: nil,
          verification_metadata: {
            "verification_code" => "555666",
            "code_sent_at" => 2.minutes.ago.iso8601
          }
        )
        raw = LoginToken.issue!(user: user, purpose: "verify", phone: local_phone)

        post "/v/#{raw}"

        # Same two facts as above fix this: a freshly created user with no
        # komsiluk, consuming a "verify" token.
        assert_redirected_to "/biceriseno/komsiluk?setup=1&app=1"
        assert auth.reload.granted?,
               "sms authorization must be granted when token.phone matches the as-typed unique_id"
      end

      private

      def delete_session_cookie
        cookies.delete(Rails.application.config.session_options[:key] || "_session_id")
        reset!
        host! @organization.host
      end
    end
  end
end
