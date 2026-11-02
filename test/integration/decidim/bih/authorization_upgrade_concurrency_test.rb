# frozen_string_literal: true

require "test_helper"
require "capybara"

module Decidim
  module Bih
    class AuthorizationUpgradeConcurrencyTest < ActiveSupport::TestCase
      self.use_transactional_tests = false
      PHONE = "+15555550101"

      setup do
        @organization = create_organization
        @user = FactoryBot.create(:user, :confirmed, organization: @organization)
        @authorization = Decidim::Authorization.create!(user: @user, name: "sms",
                                                        unique_id: SmsAuthorization.unique_id_for(PHONE),
                                                        verification_metadata: { "verification_code" => "123456", "code_sent_at" => Time.current.iso8601 })
      end

      teardown do
        if @organization&.persisted?
          Decidim::Authorization.where(user: @user).delete_all
          LoginToken.where(user: @user).delete_all
          CitizenPhoneRecord.where(user: @user).delete_all
          Viber::BusinessContact.where(user: @user).delete_all
          @user.destroy! if @user&.persisted?
          @organization.static_pages.delete_all
          @organization.destroy!
        end
      end

      test "concurrent completion creates exactly one grant and one pair of contact rows" do
        LoginToken.issue!(user: @user, purpose: "verify", phone: PHONE)
        results = race do
          PhoneVerification::Complete.call(user: Decidim::User.find(@user.id), phone: PHONE)
        end
        assert results.all?(&:granted?)
        assert_equal 1, results.count(&:first_grant?)
        assert @authorization.reload.granted?
        assert_equal 1, CitizenPhoneRecord.where(user: @user).count
        assert_equal 1, Viber::BusinessContact.where(user: @user).count
        assert_empty LoginToken.where(user: @user, purpose: "verify", consumed_at: nil)
      end

      test "concurrent requests with the same proof open only one successful session" do
        raw = LoginToken.issue!(user: @user, purpose: "verify", phone: PHONE)
        statuses = race do
          session = ActionDispatch::Integration::Session.new(Rails.application)
          session.host! @organization.host
          session.post "/v/#{raw}"
          session.response.status
        end
        assert_equal [302, 422], statuses.sort
        assert @authorization.reload.granted?
        assert LoginToken.find_by!(token_digest: LoginToken.digest(raw)).consumed_at
        assert_equal 1, CitizenPhoneRecord.where(user: @user).count
        assert_equal 1, Viber::BusinessContact.where(user: @user).count
      end

      private

      def race
        start = Queue.new
        threads = 2.times.map do
          Thread.new do
            start.pop
            ActiveRecord::Base.connection_pool.with_connection { yield }
          end
        end
        2.times { start << true }
        threads.map(&:value)
      end
    end
  end
end
