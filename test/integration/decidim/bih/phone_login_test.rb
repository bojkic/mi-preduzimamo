# frozen_string_literal: true

require "test_helper"
require "capybara"

module Decidim
  module Bih
    class PhoneLoginTest < ActionDispatch::IntegrationTest
      include ActiveJob::TestHelper

      setup do
        @original_magic_link_short_path_enabled = Decidim::Bih.magic_link_short_path_enabled
        @organization = create_organization
        host! @organization.host
        @user = FactoryBot.create(:user, :confirmed, organization: @organization)
        @phone = "+38765123456"
        Decidim::Authorization.create!(
          user: @user, name: "sms",
          unique_id: Digest::SHA256.hexdigest("#{@phone}-#{Rails.application.secret_key_base}"),
          granted_at: Time.current
        )
      end

      teardown do
        Decidim::Bih.magic_link_short_path_enabled = @original_magic_link_short_path_enabled
      end

      test "known verified phone issues a fresh challenge and enqueues phone delivery" do
        assert_enqueued_with(job: Decidim::Bih::Infobip::SendPhoneMessageJob) do
          post "/biceriseno/prijava", params: { phone: @phone }
        end
        assert_equal 1, LoginToken.where(purpose: "login").count
        assert_nil CitizenPhoneRecord.find_by(user: @user)
        assert_nil Viber::BusinessContact.find_by(user: @user)
      end

      # The number was hashed in E.164 at verification; a citizen types it the
      # way they say it. Both spellings must reach the same authorization
      # (2026-09-07: the owner's login "sent" nothing because it did not).
      test "a local BiH spelling of the verified number issues the same challenge" do
        assert_enqueued_with(job: Decidim::Bih::Infobip::SendPhoneMessageJob) do
          post "/biceriseno/prijava", params: { phone: "065 123 456" }
        end
        assert_equal 1, LoginToken.where(purpose: "login").count
      end

      test "known verified phone uses configured magic-link path in SMS text" do
        Decidim::Bih.magic_link_short_path_enabled = false
        captured = nil

        Decidim::Bih::Infobip::SendPhoneMessageJob.stub(:perform_later, ->(**kwargs) { captured = kwargs }) do
          post "/biceriseno/prijava", params: { phone: @phone }
        end

        assert_response :redirect
        assert_match %r{https://#{Regexp.escape(@organization.host)}/biceriseno/v/[A-Za-z0-9_-]+},
                     captured.fetch(:text)
      end

      test "known verified phone responds identically to unknown phone (no enumeration)" do
        perform_enqueued_jobs do
          post "/biceriseno/prijava", params: { phone: @phone }
        end
        known_status = response.status
        known_flash = flash[:notice]

        perform_enqueued_jobs do
          post "/biceriseno/prijava", params: { phone: "+38765999999" }
        end
        assert_equal known_status, response.status
        assert_equal known_flash, flash[:notice]
        assert_equal 1, LoginToken.where(purpose: "login").count, "no token for unknown phones"
      end

      test "no SMS job enqueued and no token minted for an unknown phone" do
        assert_no_enqueued_jobs(only: Decidim::Bih::Infobip::SendPhoneMessageJob) do
          post "/biceriseno/prijava", params: { phone: "+38765999999" }
        end
        assert_equal 0, LoginToken.where(purpose: "login").count
      end

      test "no SMS job enqueued and no token minted for a deleted user's phone" do
        @user.update!(deleted_at: Time.current)
        assert_no_enqueued_jobs(only: Decidim::Bih::Infobip::SendPhoneMessageJob) do
          post "/biceriseno/prijava", params: { phone: @phone }
        end
        assert_equal 0, LoginToken.where(purpose: "login").count,
                     "deleted user must not receive a login token"
      end

      test "production env does not log anything containing the raw token" do
        # Stub Rails.env to simulate production so the env-guard in enqueue_login_sms
        # suppresses the info line. Assert no log entry contains the raw token URL.
        logged_lines = []
        fake_logger = Object.new
        [:info, :error, :warn, :debug, :fatal].each do |level|
          fake_logger.define_singleton_method(level) do |msg = nil, &blk|
            logged_lines << (msg || (blk ? blk.call : ""))
          end
        end

        original_logger = Rails.logger
        Rails.logger = fake_logger

        prod_env = ActiveSupport::StringInquirer.new("production")
        Rails.instance_variable_set(:@_env, prod_env)

        begin
          assert_enqueued_with(job: Decidim::Bih::Infobip::SendPhoneMessageJob) do
            post "/biceriseno/prijava", params: { phone: @phone }
          end
        ensure
          Rails.logger = original_logger
          Rails.instance_variable_set(:@_env, ActiveSupport::StringInquirer.new("test"))
        end

        logged_lines.each do |line|
          # The raw token URL (https://.../v/<raw>) must not appear in any production log line.
          assert_no_match(%r{/v/[A-Za-z0-9\-_]{10,}}, line.to_s,
                          "raw token URL must not appear in production logs: #{line}")
        end
      end

      test "same phone in two orgs resolves the current org's user (no cross-org collision)" do
        # The sms unique_id recipe (SHA256(phone + secret_key_base)) is
        # organization-INDEPENDENT, so a second org's user with the SAME phone has
        # an identical unique_id. With a non-unique index an unscoped find_by can
        # return the OTHER org's row; the later org guard then aborts and the
        # legitimate (current-org) user never receives their login link.
        #
        # The unscoped row that the buggy lookup could return is simulated by
        # stubbing Decidim::Authorization.find_by to surface the OTHER org's row.
        # The org-scoped lookup never calls find_by, so the stub is inert for the
        # fixed code; the buggy code (which used find_by) would resolve the wrong
        # org and abort. This makes the regression deterministic despite the
        # database's unordered LIMIT 1.
        other_org = create_organization(host: "other-phone-login.lvh.me")
        other_user = FactoryBot.create(:user, :confirmed, organization: other_org)
        other_auth = Decidim::Authorization.create!(
          user: other_user, name: "sms",
          unique_id: Digest::SHA256.hexdigest("#{@phone}-#{Rails.application.secret_key_base}"),
          granted_at: Time.current
        )

        Decidim::Authorization.stub(:find_by, other_auth) do
          # Request is on the CURRENT org's host (set in setup).
          assert_enqueued_with(job: Decidim::Bih::Infobip::SendPhoneMessageJob) do
            post "/biceriseno/prijava", params: { phone: @phone }
          end
        end

        tokens = LoginToken.where(purpose: "login")
        assert_equal 1, tokens.count
        assert_equal @user.id, tokens.first.decidim_user_id,
                     "the login token must belong to the current org's user, not the other org's"
        assert_equal @organization.id, tokens.first.decidim_organization_id
      end

      # Where a signed-in citizen lands is Onboarding::NextStep's answer now, and
      # it depends on how far through the chain this user already is. The
      # fixture user has no komsiluk, so the answer is the picker (?setup=1) —
      # pinned rather than either-or, because "somewhere in the chain" would
      # still pass if the chain sent this citizen to the wrong step. No app=1
      # here: the PWA marker is appended for "verify" tokens only.
      test "consuming a login token signs the user in" do
        raw = LoginToken.issue!(user: @user, purpose: "login", phone: @phone)
        post "/v/#{raw}"
        assert_redirected_to "/biceriseno/komsiluk?setup=1"
        assert VerifiedPhone.consistent?(user: @user, organization: @organization)
        assert_equal @phone, CitizenPhone.for(@user)
        follow_redirect!
        assert_response :success
      end
    end
  end
end
