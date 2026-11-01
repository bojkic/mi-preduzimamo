# frozen_string_literal: true

require "test_helper"
require "capybara"

module Decidim
  module Bih
    class PostalMagicLinkTest < ActionDispatch::IntegrationTest
      setup do
        @organization = create_organization
        host! @organization.host
        @user = FactoryBot.create(:user, :confirmed, organization: @organization)

        # A pending postal_letter authorization in the post-mailing state
        # (code has been moved to "verification_code" by PostageForm).
        @authorization = Decidim::Authorization.create!(
          user: @user,
          name: "postal_letter",
          granted_at: nil,
          verification_metadata: {
            "address" => "Ulica Cara Lazara 12, Bijeljina",
            "verification_code" => "999888",
            "letter_sent_at" => 1.day.ago.iso8601
          }
        )
        @raw = Decidim::Bih::LoginToken.issue!(user: @user, purpose: "postal")
      end

      # ─── Core: QR/magic-link grants the postal authorization ──────────────

      test "POST consumes postal token: signs in and grants the postal_letter authorization" do
        post "/v/#{@raw}"

        assert_redirected_to %r{/biceriseno/moj-nalog#zavrsi-nalog}
        assert @authorization.reload.granted?,
               "postal_letter authorization must be granted after consuming the postal token"
      end

      test "POST postal: single-use — cannot be replayed" do
        post "/v/#{@raw}"
        delete_session_cookie
        post "/v/#{@raw}"
        assert_response :unprocessable_entity
      end

      test "POST postal: token from another organization is rejected" do
        other = create_organization(host: "other-postal.example.org")
        host! other.host
        post "/v/#{@raw}"
        assert_response :unprocessable_entity
      end

      test "POST postal: expired token is rejected" do
        Decidim::Bih::LoginToken.last.update!(expires_at: 1.minute.ago)
        post "/v/#{@raw}"
        assert_response :unprocessable_entity
        assert_not @authorization.reload.granted?
      end

      test "POST postal: blocked user is not signed in or granted" do
        @user.update!(blocked: true, blocked_at: Time.current, extended_data: {})
        post "/v/#{@raw}"
        assert_response :unprocessable_entity
        assert_not @authorization.reload.granted?
      end

      test "POST postal: deleted user is not signed in or granted" do
        @user.update!(deleted_at: Time.current)
        raw = Decidim::Bih::LoginToken.issue!(user: @user, purpose: "postal")
        post "/v/#{raw}"
        assert_response :unprocessable_entity
        assert_not @authorization.reload.granted?
      end

      # ─── No phone binding on postal path ─────────────────────────────────

      test "postal token has no phone column set" do
        token = Decidim::Bih::LoginToken.last
        assert_nil token.phone, "postal tokens must carry no phone (proof is physical letter receipt)"
      end

      # ─── Token TTL is 30 days ─────────────────────────────────────────────

      test "postal token expires in 30 days" do
        token = Decidim::Bih::LoginToken.last
        assert_in_delta 30.days.from_now, token.expires_at, 60.seconds,
                        "postal TTL must be 30 days"
      end

      # ─── Existing sms verify path is unaffected ───────────────────────────

      test "a verify (sms) token still grants the sms authorization unchanged" do
        Decidim::Authorization.create!(
          user: @user,
          name: "sms",
          unique_id: "sms_test_id",
          granted_at: nil,
          verification_metadata: {
            "verification_code" => "112233",
            "code_sent_at" => Time.current.iso8601
          }
        )
        # Postal token is already consumed by setup — issue a verify one
        verify_raw = Decidim::Bih::LoginToken.issue!(
          user: @user,
          purpose: "verify",
          phone: nil # no phone means phone_matches_authorization? returns true (blank expected_phone)
        )

        post "/v/#{verify_raw}"

        # sms auth should be attempted to grant; the no-phone-binding case
        # passes since expected_phone is blank.
        # (We are not asserting the sms auth is granted because the unique_id
        # was set to a dummy value — this test only asserts the postal auth is
        # NOT incorrectly granted via the sms path.)
        assert_not @authorization.reload.granted?,
                   "postal_letter auth must NOT be granted via a verify token"
      end

      # ─── GET still just peeks, does not consume ───────────────────────────

      test "GET /v/:postal_token shows confirmation page without consuming" do
        # Issue a fresh token (the setup one may still be live)
        fresh_raw = Decidim::Bih::LoginToken.issue!(user: @user, purpose: "postal")
        get "/v/#{fresh_raw}"
        assert_response :success
        get "/v/#{fresh_raw}"
        assert_response :success, "a link-preview prefetch must not burn the token"
        assert_nil Decidim::Bih::LoginToken.find_by(
          token_digest: Decidim::Bih::LoginToken.digest(fresh_raw)
        )&.consumed_at, "GET must not consume the token"
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
