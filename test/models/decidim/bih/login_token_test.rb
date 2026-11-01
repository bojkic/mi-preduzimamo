# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    class LoginTokenTest < ActiveSupport::TestCase
      setup do
        @organization = create_organization
        @user = FactoryBot.create(:user, :confirmed, organization: @organization)
      end

      test "issue! returns a raw token and stores only its digest" do
        raw = LoginToken.issue!(user: @user, purpose: "verify")
        assert_kind_of String, raw
        record = LoginToken.last
        assert_not_equal raw, record.token_digest
        assert_equal Digest::SHA256.hexdigest(raw), record.token_digest
        assert_equal "verify", record.purpose
        assert_in_delta 24.hours.from_now, record.expires_at, 5.seconds
      end

      test "issue! invalidates prior unconsumed tokens for the same user and purpose" do
        first = LoginToken.issue!(user: @user, purpose: "verify")
        LoginToken.issue!(user: @user, purpose: "verify")
        assert_nil LoginToken.consume!(raw: first, organization: @organization)
      end

      test "issue! locks the user before replacing a live token" do
        locked = false

        @user.stub(:lock!, -> { locked = true }) do
          LoginToken.issue!(user: @user, purpose: "verify")
        end

        assert locked, "issuing must serialize concurrent replacements on the user row"
      end

      test "consume! returns the record once and never again" do
        raw = LoginToken.issue!(user: @user, purpose: "verify")
        assert_equal @user, LoginToken.consume!(raw:, organization: @organization).user
        assert_nil LoginToken.consume!(raw:, organization: @organization)
      end

      test "consume! rejects expired tokens and other organizations" do
        raw = LoginToken.issue!(user: @user, purpose: "verify")
        LoginToken.last.update!(expires_at: 1.minute.ago)
        assert_nil LoginToken.consume!(raw:, organization: @organization)

        raw2 = LoginToken.issue!(user: @user, purpose: "verify")
        other_org = create_organization(host: "other.example.org")
        assert_nil LoginToken.consume!(raw: raw2, organization: other_org)
      end

      test "peek finds without consuming" do
        raw = LoginToken.issue!(user: @user, purpose: "verify")
        assert LoginToken.peek(raw:, organization: @organization)
        assert LoginToken.peek(raw:, organization: @organization), "peek must not consume"
      end
    end
  end
end
