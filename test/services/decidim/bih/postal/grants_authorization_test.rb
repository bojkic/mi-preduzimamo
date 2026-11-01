# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    # Exercises GrantsAuthorization concern in isolation by mixing it
    # into a minimal test host class.
    class GrantsAuthorizationTest < ActiveSupport::TestCase
      # A thin host that mixes in the concern so we can call the concern method
      # directly without a full controller.
      class TestHost
        include Decidim::Bih::GrantsAuthorization
      end

      setup do
        @organization = create_organization
        @user = FactoryBot.create(:user, :confirmed, organization: @organization)
        @host = TestHost.new
      end

      # ─── Basic postal grant ──────────────────────────────────────────────

      test "grants the postal_letter authorization when pending and returns true" do
        auth = pending_postal_auth(@user, "postal_letter")
        result = @host.grant_named_authorization(@user, "postal_letter")
        assert_equal true, result, "grant_named_authorization must return true on success"
        assert auth.reload.granted?
      end

      test "returns false when no pending postal authorization exists" do
        result = @host.grant_named_authorization(@user, "postal_letter")
        assert_equal false, result
      end

      test "returns false and is a no-op when the authorization is already granted" do
        auth = granted_postal_auth(@user)
        granted_at_before = auth.granted_at
        result = @host.grant_named_authorization(@user, "postal_letter")
        assert_equal false, result
        assert_in_delta granted_at_before.to_f, auth.reload.granted_at.to_f, 1.0
      end

      # ─── Active/!blocked/!deleted guard ──────────────────────────────────

      test "blocked user is rejected — authorization not granted" do
        pending_postal_auth(@user, "postal_letter")
        @user.update!(blocked: true, blocked_at: Time.current, extended_data: {})

        result = @host.grant_named_authorization(@user, "postal_letter")
        assert_equal false, result
        assert_not Decidim::Authorization.find_by(user: @user, name: "postal_letter")&.granted?
      end

      test "deleted user is rejected — authorization not granted" do
        pending_postal_auth(@user, "postal_letter")
        @user.update!(deleted_at: Time.current)

        result = @host.grant_named_authorization(@user, "postal_letter")
        assert_equal false, result
        assert_not Decidim::Authorization.find_by(user: @user, name: "postal_letter")&.granted?
      end

      # ─── SMS path is unchanged (phone binding still works) ───────────────

      test "GrantsSmsAuthorization phone-binding is unchanged" do
        phone = "+38766900001"
        unique_id = Digest::SHA256.hexdigest("#{phone}-#{Rails.application.secret_key_base}")

        sms_host_class = Class.new do
          include Decidim::Bih::GrantsSmsAuthorization
        end
        sms_host = sms_host_class.new

        sms_auth = Decidim::Authorization.create!(
          user: @user,
          name: "sms",
          unique_id: unique_id,
          granted_at: nil,
          verification_metadata: {
            "verification_code" => "777777",
            "code_sent_at" => Time.current.iso8601
          }
        )

        sms_host.grant_sms_authorization(@user, nil, expected_phone: phone)
        assert sms_auth.reload.granted?, "sms path must still grant when phone matches"
      end

      test "GrantsSmsAuthorization rejects when phone does not match" do
        wrong_phone = "+38766000000"
        right_phone = "+38766900001"
        unique_id = Digest::SHA256.hexdigest("#{right_phone}-#{Rails.application.secret_key_base}")

        sms_host_class = Class.new do
          include Decidim::Bih::GrantsSmsAuthorization
        end
        sms_host = sms_host_class.new

        sms_auth = Decidim::Authorization.create!(
          user: @user,
          name: "sms",
          unique_id: unique_id,
          granted_at: nil,
          verification_metadata: {
            "verification_code" => "888888",
            "code_sent_at" => Time.current.iso8601
          }
        )

        result = sms_host.grant_sms_authorization(@user, nil, expected_phone: wrong_phone)
        assert_equal false, result
        assert_not sms_auth.reload.granted?, "wrong phone must not grant the sms auth"
      end

      # ─── postal grant does not require phone binding ─────────────────────

      test "postal grant does not check the phone column" do
        # Postal auth stores no phone/unique_id (post-mailing state)
        auth = Decidim::Authorization.create!(
          user: @user,
          name: "postal_letter",
          granted_at: nil,
          verification_metadata: {
            "address" => "Neka ulica 1",
            "verification_code" => "555444",
            "letter_sent_at" => 1.day.ago.iso8601
          }
        )

        @host.grant_named_authorization(@user, "postal_letter")
        assert auth.reload.granted?, "postal grant must succeed without any phone binding"
      end

      private

      def pending_postal_auth(user, name)
        # Post-mailing state: code is in "verification_code" key
        Decidim::Authorization.create!(
          user: user,
          name: name,
          granted_at: nil,
          verification_metadata: {
            "address" => "Ulica 1",
            "verification_code" => "123456",
            "letter_sent_at" => 1.day.ago.iso8601
          }
        )
      end

      def granted_postal_auth(user)
        # Decidim validates verification_metadata must be blank when granted_at is set
        Decidim::Authorization.create!(
          user: user,
          name: "postal_letter",
          granted_at: 1.hour.ago,
          verification_metadata: {}
        )
      end
    end
  end
end
