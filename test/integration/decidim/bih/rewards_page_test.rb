# frozen_string_literal: true

require "test_helper"
require "capybara"

module Decidim
  module Bih
    # HTTP coverage for the rewards catalog + authenticated redemption.
    class RewardsPageTest < ActionDispatch::IntegrationTest
      include ::Devise::Test::IntegrationHelpers

      setup do
        @organization = create_organization
        host! @organization.host
        @user = FactoryBot.create(:user, :confirmed, organization: @organization)
      end

      test "GET nagrade renders the catalog for anonymous visitors" do
        # Legacy URL 301s to hub nagrade tab; test the canonical hub URL directly.
        get "/biceriseno/zajednistvo?tab=nagrade"

        assert_response :success
        assert_includes response.body, I18n.t("decidim.bih.goodwill.rewards.majica")
      end

      test "a signed-in citizen with enough points can redeem a reward" do
        Decidim::Bih::Goodwill::Ledger.new.award(@user, 1000, reason: "volunteer_hour")
        sign_in @user

        post "/biceriseno/nagrade/redeem/majica", params: redemption_params

        assert_response :redirect
        assert_equal 500, Decidim::Bih::Goodwill::Ledger.new.account_for(@user).balance
      end

      test "redeeming without enough points leaves the wallet untouched" do
        Decidim::Bih::Goodwill::Ledger.new.award(@user, 100, reason: "proposal")
        sign_in @user

        post "/biceriseno/nagrade/redeem/majica", params: redemption_params # costs 500

        assert_response :redirect
        assert_equal 100, Decidim::Bih::Goodwill::Ledger.new.account_for(@user).balance
      end

      test "redeem requires a signed-in user" do
        post "/biceriseno/nagrade/redeem/majica", params: redemption_params

        assert_response :redirect # bounced back to the catalog with an alert
        assert_equal 0, Decidim::Bih::Goodwill::Ledger.new.account_for(@user).balance
      end

      test "a signed-in user from another organization cannot redeem on this host" do
        other = create_organization
        outsider = FactoryBot.create(:user, :confirmed, organization: other)
        Decidim::Bih::Goodwill::Ledger.new.award(outsider, 1000, reason: "volunteer_hour")
        sign_in outsider

        assert_no_difference -> { Decidim::Bih::Goodwill::RewardFulfillment.count } do
          post "/biceriseno/nagrade/redeem/majica", params: redemption_params
        end

        assert_response :redirect
        assert_equal 1000, Decidim::Bih::Goodwill::Ledger.new.account_for(outsider).balance
      end

      test "redemption requires explicit confirmation and a request key" do
        Decidim::Bih::Goodwill::Ledger.new.award(@user, 1000, reason: "volunteer_hour")
        sign_in @user

        assert_no_difference -> { Decidim::Bih::Goodwill::RewardFulfillment.count } do
          post "/biceriseno/nagrade/redeem/majica"
        end

        assert_equal 1000, Decidim::Bih::Goodwill::Ledger.new.account_for(@user).balance
      end

      test "replayed redemption request is charged once and citizen can cancel before reservation" do
        Decidim::Bih::Goodwill::Ledger.new.award(@user, 1000, reason: "volunteer_hour")
        sign_in @user
        params = redemption_params

        2.times { post "/biceriseno/nagrade/redeem/majica", params: }

        assert_equal 1, Decidim::Bih::Goodwill::RewardFulfillment.where(user: @user).count
        assert_equal 500, Decidim::Bih::Goodwill::Ledger.new.account_for(@user).balance
        fulfillment = Decidim::Bih::Goodwill::RewardFulfillment.find_by!(user: @user)

        post "/biceriseno/nagrade/zahtjevi/#{fulfillment.id}/otkazi"

        assert_response :redirect
        assert_equal "canceled", fulfillment.reload.status
        assert_equal 1000, Decidim::Bih::Goodwill::Ledger.new.account_for(@user).balance
      end

      private

      def redemption_params
        { redemption_confirmed: "1", redemption_request_key: SecureRandom.uuid }
      end
    end
  end
end
