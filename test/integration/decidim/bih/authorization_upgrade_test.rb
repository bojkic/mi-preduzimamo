# frozen_string_literal: true

require "test_helper"
require "capybara"

module Decidim
  module Bih
    # Calls the real 0.32 command through public entrypoints. Synthetic stored
    # pending/granted rows also exercise an existing installation's data shape.
    class AuthorizationUpgradeTest < ActionDispatch::IntegrationTest
      include ::Devise::Test::IntegrationHelpers

      PHONE = "+15555550101"
      CODE = "123456"

      setup do
        @organization = create_organization
        host! @organization.host
        @user = FactoryBot.create(:user, :confirmed, organization: @organization)
      end

      test "typed wrong code cannot reach the canonical grant but a correct code can" do
        auth = phone_authorization
        sign_in @user
        post phone_confirm_path, params: { verification_code: "000000" }
        assert_response :redirect
        assert_not auth.reload.granted?
        assert_nil CitizenPhoneRecord.find_by(user: @user)
        post phone_confirm_path, params: { verification_code: CODE }
        assert_response :redirect
        assert auth.reload.granted?
        assert_equal PHONE, CitizenPhone.for(@user)
        assert_equal 0, auth.failed_attempts
      end

      test "typed exhausted attempts remain rejected even when a correct code follows" do
        auth = phone_authorization
        sign_in @user
        PhoneVerification::AttemptLimiter::MAX_ATTEMPTS.times do
          post phone_confirm_path, params: { verification_code: "000000" }
        end
        post phone_confirm_path, params: { verification_code: CODE }
        assert_not auth.reload.granted?
        assert_nil CitizenPhoneRecord.find_by(user: @user)
      end

      test "upstream persisted confirmation lock is respected by a correct typed code" do
        auth = phone_authorization
        auth.update!(failed_attempts: Decidim.verification_max_failed_attempts, locked_at: Time.current)
        sign_in @user
        post phone_confirm_path, params: { verification_code: CODE }
        assert_not auth.reload.granted?
        assert auth.locked_for_confirmation?
        assert_nil CitizenPhoneRecord.find_by(user: @user)
      end

      test "an expired persisted lock clears and permits the existing pending challenge" do
        auth = phone_authorization
        auth.update!(failed_attempts: Decidim.verification_max_failed_attempts,
                     locked_at: (Decidim.verification_unlock_in + 1.minute).ago)
        sign_in @user
        post phone_confirm_path, params: { verification_code: CODE }
        assert auth.reload.granted?
        assert_equal 0, auth.failed_attempts
        assert_nil auth.locked_at
        assert_equal PHONE, CitizenPhone.for(@user)
      end

      test "expired code cannot create a phone grant or contact rows" do
        auth = phone_authorization(sent_at: 25.hours.ago)
        sign_in @user
        post phone_confirm_path, params: { verification_code: CODE }
        assert_not auth.reload.granted?
        assert_nil CitizenPhoneRecord.find_by(user: @user)
      end

      test "another signed in user cannot use a valid phone link" do
        auth = phone_authorization
        raw = LoginToken.issue!(user: @user, purpose: "verify", phone: PHONE)
        sign_in FactoryBot.create(:user, :confirmed, organization: @organization)
        post "/v/#{raw}"
        assert_response :unprocessable_entity
        assert_not auth.reload.granted?
        assert_nil LoginToken.find_by!(token_digest: LoginToken.digest(raw)).consumed_at
      end

      test "foreign organization cannot use a valid phone link" do
        auth = phone_authorization
        raw = LoginToken.issue!(user: @user, purpose: "verify", phone: PHONE)
        host! create_organization.host
        post "/v/#{raw}"
        assert_response :unprocessable_entity
        assert_not auth.reload.granted?
      end

      test "phone bound to another authorization is not granted by the link" do
        auth = phone_authorization
        raw = LoginToken.issue!(user: @user, purpose: "verify", phone: "+15555550102")
        post "/v/#{raw}"
        assert_response :unprocessable_entity
        assert_not auth.reload.granted?
        assert_nil CitizenPhoneRecord.find_by(user: @user)
      end

      test "blocked user cannot consume an otherwise valid verification link" do
        auth = phone_authorization
        raw = LoginToken.issue!(user: @user, purpose: "verify", phone: PHONE)
        @user.update!(blocked: true, blocked_at: Time.current, extended_data: {})
        post "/v/#{raw}"
        assert_response :unprocessable_entity
        assert_not auth.reload.granted?
        assert_nil CitizenPhoneRecord.find_by(user: @user)
      end

      test "an expired verification link cannot grant a fresh pending authorization" do
        auth = phone_authorization
        raw = LoginToken.issue!(user: @user, purpose: "verify", phone: PHONE)
        LoginToken.find_by!(token_digest: LoginToken.digest(raw)).update!(expires_at: 1.minute.ago)
        post "/v/#{raw}"
        assert_response :unprocessable_entity
        assert_not auth.reload.granted?
      end

      test "one proof grants once consumes once and cannot be replayed" do
        auth = phone_authorization
        raw = LoginToken.issue!(user: @user, purpose: "verify", phone: PHONE)
        post "/v/#{raw}"
        assert_response :redirect
        assert auth.reload.granted?
        granted_at = auth.granted_at
        assert LoginToken.find_by!(token_digest: LoginToken.digest(raw)).consumed_at
        post "/v/#{raw}"
        assert_response :unprocessable_entity
        assert_equal granted_at, auth.reload.granted_at
        assert_equal 1, CitizenPhoneRecord.where(user: @user).count
        assert_equal 1, Viber::BusinessContact.where(user: @user).count
      end

      %w(pending_verification_code verification_code).each do |key|
        test "postal physical link grants using #{key} without a compatibility adapter" do
          auth = postal_authorization(key:)
          raw = LoginToken.issue!(user: @user, purpose: "postal")
          post "/v/#{raw}"
          assert_response :redirect
          assert auth.reload.granted?
          assert_equal({}, auth.verification_metadata)
          granted_at = auth.granted_at
          post "/v/#{raw}"
          assert_response :unprocessable_entity
          assert_equal granted_at, auth.reload.granted_at
        end
      end

      test "locked postal authorization is not granted and its token is not consumed" do
        auth = postal_authorization
        auth.update!(failed_attempts: Decidim.verification_max_failed_attempts, locked_at: Time.current)
        raw = LoginToken.issue!(user: @user, purpose: "postal")
        post "/v/#{raw}"
        assert_response :unprocessable_entity
        assert_not auth.reload.granted?
        assert_nil LoginToken.find_by!(token_digest: LoginToken.digest(raw)).consumed_at
      end

      test "expired postal code is rejected by upstream expiry" do
        auth = postal_authorization
        auth.update!(verification_metadata: auth.verification_metadata.merge("code_sent_at" => 25.hours.ago.iso8601))
        raw = LoginToken.issue!(user: @user, purpose: "postal")
        post "/v/#{raw}"
        assert_response :unprocessable_entity
        assert_not auth.reload.granted?
      end

      test "already granted postal data is preserved rather than granted twice" do
        auth = postal_authorization
        auth.grant!
        granted_at = auth.reload.granted_at
        raw = LoginToken.issue!(user: @user, purpose: "postal")
        post "/v/#{raw}"
        assert_response :unprocessable_entity
        assert_equal granted_at, auth.reload.granted_at
      end

      private

      def phone_confirm_path
        Decidim::Bih.public_path("verifikacija/telefon/kod")
      end

      def phone_authorization(sent_at: Time.current)
        auth = Decidim::Authorization.create!(user: @user, name: "sms",
                                              unique_id: SmsAuthorization.unique_id_for(PHONE),
                                              verification_metadata: { "verification_code" => CODE, "code_sent_at" => sent_at.iso8601 })
        LoginToken.issue!(user: @user, purpose: "verify", phone: PHONE)
        auth
      end

      def postal_authorization(key: "verification_code")
        Decidim::Authorization.create!(user: @user, name: "postal_letter",
                                       verification_metadata: { key => CODE, "letter_sent_at" => Time.current.iso8601 })
      end
    end
  end
end
