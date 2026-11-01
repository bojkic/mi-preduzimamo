# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module Goodwill
      # Round 25 — a table-backed reward must redeem through the SAME RedeemReward
      # flow as a config reward, debiting the wallet, creating a fulfillment, and
      # decrementing remaining stock.
      class TableBackedRewardRedeemTest < ActiveSupport::TestCase
        setup do
          @organization = create_organization
          @user = FactoryBot.create(:user, :confirmed, organization: @organization)
          @ledger = Ledger.new
          @reward = Reward.create!(
            organization: @organization,
            key: "tbl_majica",
            title: { "sr" => "Tabela majica" },
            cost: 500,
            stock: 2,
            active: true
          )
        end

        test "redeems a table-backed reward and creates a fulfillment" do
          @ledger.award(@user, 1000, reason: "volunteer_hour")
          redeemed = nil
          assert_difference "RewardFulfillment.count", 1 do
            RedeemReward.call(@user, "tbl_majica") do
              on(:ok) { |r| redeemed = r }
              on(:invalid) { flunk "table reward should be valid" }
              on(:insufficient) { flunk "should be affordable" }
            end
          end

          assert_equal "tbl_majica", redeemed.key
          assert_equal 500, @ledger.account_for(@user).balance
          fulfillment = RewardFulfillment.last
          assert_equal "tbl_majica", fulfillment.reward_key
          assert_equal 500, fulfillment.cost
        end

        test "remaining stock decrements as table rewards are redeemed" do
          assert_equal 2, @reward.remaining_stock(@organization)

          @ledger.award(@user, 1000, reason: "volunteer_hour")
          RedeemReward.call(@user, "tbl_majica")

          assert_equal 1, @reward.remaining_stock(@organization)
        end

        test "redeeming an out-of-stock table reward broadcasts :out_of_stock" do
          @reward.update!(stock: 1)
          buyer1 = FactoryBot.create(:user, :confirmed, organization: @organization)
          @ledger.award(buyer1, 1000, reason: "volunteer_hour")
          RedeemReward.call(buyer1, "tbl_majica")

          @ledger.award(@user, 1000, reason: "volunteer_hour")
          state = nil
          assert_no_difference "RewardFulfillment.count" do
            RedeemReward.call(@user, "tbl_majica") do
              on(:ok) { state = :ok }
              on(:out_of_stock) { state = :out_of_stock }
            end
          end
          assert_equal :out_of_stock, state
        end

        test "redeeming an expired table reward broadcasts :expired" do
          @reward.update!(expires_at: 1.day.ago)
          @ledger.award(@user, 1000, reason: "volunteer_hour")
          state = nil
          RedeemReward.call(@user, "tbl_majica") do
            on(:ok) { state = :ok }
            on(:expired) { state = :expired }
          end
          assert_equal :expired, state
        end
      end
    end
  end
end
