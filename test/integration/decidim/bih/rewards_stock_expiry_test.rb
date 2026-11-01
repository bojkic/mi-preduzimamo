# frozen_string_literal: true

require "test_helper"
require "capybara"

module Decidim
  module Bih
    # Round 11, Item 1 — stock + expiry guards on rewards.
    class RewardsStockExpiryTest < ActionDispatch::IntegrationTest
      include ::Devise::Test::IntegrationHelpers

      setup do
        @organization = create_organization
        host! @organization.host
        @user = FactoryBot.create(:user, :confirmed, organization: @organization)
        @ledger = Decidim::Bih::Goodwill::Ledger.new
      end

      # --- stock guard ---

      test "redeeming a reward with available stock succeeds" do
        with_catalog([{ key: "majica", cost: 500, stock: 3 }]) do
          @ledger.award(@user, 600, reason: "volunteer_hour")
          sign_in @user
          assert_difference -> { Decidim::Bih::Goodwill::RewardFulfillment.count }, 1 do
            post "/biceriseno/nagrade/redeem/majica", params: redemption_params
          end

          assert_response :redirect
          assert_equal 100, @ledger.account_for(@user).balance
          assert_equal 1, fixture_fulfillments.count
        end
      end

      test "stock boundary: first redemption up to stock limit succeeds" do
        with_catalog([{ key: "majica", cost: 100, stock: 1 }]) do
          @ledger.award(@user, 500, reason: "volunteer_hour")
          sign_in @user
          assert_difference -> { Decidim::Bih::Goodwill::RewardFulfillment.count }, 1 do
            post "/biceriseno/nagrade/redeem/majica", params: redemption_params
          end

          assert_response :redirect
          assert_equal 1, fixture_fulfillments.count
          assert_equal 400, @ledger.account_for(@user).balance
        end
      end

      test "stock boundary: redeeming when stock is exhausted returns out_of_stock flash" do
        with_catalog([{ key: "majica", cost: 100, stock: 1 }]) do
          # Fill the stock with another user
          other = FactoryBot.create(:user, :confirmed, organization: @organization)
          @ledger.award(other, 500, reason: "volunteer_hour")
          Decidim::Bih::Goodwill::RedeemReward.call(other, "majica")

          @ledger.award(@user, 500, reason: "volunteer_hour")
          sign_in @user
          post "/biceriseno/nagrade/redeem/majica", params: redemption_params

          assert_response :redirect
          assert_equal 500, @ledger.account_for(@user).balance # wallet untouched
          # No fulfillment created for @user since stock was exhausted
          assert_equal 0, Decidim::Bih::Goodwill::RewardFulfillment.where(decidim_user_id: @user.id).count
        end
      end

      test "canceled fulfillment releases stock slot" do
        admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
        with_catalog([{ key: "majica", cost: 100, stock: 1 }]) do
          @ledger.award(@user, 500, reason: "volunteer_hour")
          Decidim::Bih::Goodwill::RedeemReward.call(@user, "majica")
          fulfillment = fixture_fulfillments.last

          # Cancel the fulfillment — should free the slot
          sign_in admin
          post "/admin/bih/goodwill/reward-fulfillment/#{fulfillment.id}/canceled",
               params: { private_reason: "Nagrada više nije dostupna" }
          assert_equal "canceled", fulfillment.reload.status

          # Now a new redemption should succeed
          sign_in @user
          post "/biceriseno/nagrade/redeem/majica", params: redemption_params
          assert_response :redirect
          assert_equal 2, Decidim::Bih::Goodwill::RewardFulfillment.where(decidim_user_id: @user.id).count
        end
      end

      # Fix 1 regression: fulfilled fulfillments hold their stock slot, so a
      # second redemption when stock=1 must be rejected (over-issue fix).
      test "fulfilled fulfillment does NOT release stock slot" do
        admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
        with_catalog([{ key: "majica", cost: 100, stock: 1 }]) do
          @ledger.award(@user, 500, reason: "volunteer_hour")
          Decidim::Bih::Goodwill::RedeemReward.call(@user, "majica")
          fulfillment = fixture_fulfillments.last

          # Admin marks it as fulfilled (delivered)
          sign_in admin
          post "/admin/bih/goodwill/reward-fulfillment/#{fulfillment.id}/fulfilled"
          assert_equal "fulfilled", fulfillment.reload.status

          # A second user should now be blocked — stock still exhausted
          other = FactoryBot.create(:user, :confirmed, organization: @organization)
          @ledger.award(other, 500, reason: "volunteer_hour")
          sign_in other
          post "/biceriseno/nagrade/redeem/majica", params: redemption_params

          assert_response :redirect
          assert_equal 500, @ledger.account_for(other).balance # untouched
          assert_equal 0, Decidim::Bih::Goodwill::RewardFulfillment.where(decidim_user_id: other.id).count
        end
      end

      # --- expiry ---

      test "an expired reward is not shown in the catalog" do
        with_catalog([{ key: "majica", cost: 500, expires_at: 1.day.ago }]) do
          get "/biceriseno/zajednistvo?tab=nagrade"
          assert_response :success
          assert_not_includes response.body, I18n.t("decidim.bih.goodwill.rewards.majica")
        end
      end

      test "a non-expired reward is shown in the catalog" do
        with_catalog([{ key: "majica", cost: 500, expires_at: 1.day.from_now }]) do
          get "/biceriseno/zajednistvo?tab=nagrade"
          assert_response :success
          assert_includes response.body, I18n.t("decidim.bih.goodwill.rewards.majica")
        end
      end

      test "redeeming an expired reward is rejected" do
        with_catalog([{ key: "majica", cost: 500, expires_at: 1.hour.ago }]) do
          @ledger.award(@user, 600, reason: "volunteer_hour")
          sign_in @user
          assert_no_difference -> { Decidim::Bih::Goodwill::RewardFulfillment.count } do
            post "/biceriseno/nagrade/redeem/majica", params: redemption_params
          end

          assert_response :redirect
          assert_equal 600, @ledger.account_for(@user).balance # untouched
          assert_equal 0, fixture_fulfillments.count
        end
      end

      test "reward with no expiry is always available" do
        with_catalog([{ key: "majica", cost: 500 }]) do
          @ledger.award(@user, 600, reason: "volunteer_hour")
          sign_in @user
          post "/biceriseno/nagrade/redeem/majica", params: redemption_params

          assert_response :redirect
          assert_equal 100, @ledger.account_for(@user).balance
        end
      end

      # --- remaining stock display ---

      test "catalog shows remaining stock when stock is set" do
        with_catalog([{ key: "majica", cost: 500, stock: 5 }]) do
          get "/biceriseno/zajednistvo?tab=nagrade"
          assert_response :success
          assert_includes response.body, "5"
        end
      end

      # --- cancelable_expired scope (the rake task's underlying query) ---

      test "cancelable_expired scope finds open fulfillments expired >= 7 days ago" do
        # Ensure positive balance before spending
        @ledger.award(@user, 100, reason: "volunteer_hour")
        stale_txn = @ledger.spend(owner: @user, amount: 1, kind: "redeem", reason: "reward:majica")

        stale = Decidim::Bih::Goodwill::RewardFulfillment.create!(
          organization: @organization,
          ledger_transaction: stale_txn,
          user: @user,
          reward_key: "majica",
          cost: 1,
          status: "requested",
          reward_expires_at: 8.days.ago
        )

        fresh_txn = @ledger.award(@user, 10, reason: "volunteer_hour")
        fresh = Decidim::Bih::Goodwill::RewardFulfillment.create!(
          organization: @organization,
          ledger_transaction: fresh_txn,
          user: @user,
          reward_key: "majica",
          cost: 1,
          status: "requested",
          reward_expires_at: 3.days.ago # within grace period
        )

        cancelable = Decidim::Bih::Goodwill::RewardFulfillment.cancelable_expired
        assert_includes cancelable.map(&:id), stale.id
        assert_not_includes cancelable.map(&:id), fresh.id
      end

      test "cancelable_expired scope skips already-canceled fulfillments" do
        txn = @ledger.award(@user, 10, reason: "volunteer_hour")
        canceled = Decidim::Bih::Goodwill::RewardFulfillment.create!(
          organization: @organization,
          ledger_transaction: txn,
          user: @user,
          reward_key: "majica",
          cost: 1,
          status: "canceled",
          reward_expires_at: 8.days.ago
        )

        assert_not_includes Decidim::Bih::Goodwill::RewardFulfillment
          .cancelable_expired.map(&:id),
                            canceled.id
      end

      private

      def fixture_fulfillments
        Decidim::Bih::Goodwill::RewardFulfillment.where(organization: @organization, user: @user)
      end

      def redemption_params
        { redemption_confirmed: "1", redemption_request_key: SecureRandom.uuid }
      end

      def with_catalog(catalog)
        previous = Decidim::Bih.goodwill_rewards_catalog
        Decidim::Bih.goodwill_rewards_catalog = catalog
        yield
      ensure
        Decidim::Bih.goodwill_rewards_catalog = previous
      end
    end
  end
end
