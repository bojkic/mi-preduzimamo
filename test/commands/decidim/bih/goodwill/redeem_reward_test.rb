# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module Goodwill
      class RedeemRewardTest < ActiveSupport::TestCase
        setup do
          @organization = create_organization
          @user = FactoryBot.create(:user, :confirmed, organization: @organization)
          @ledger = Decidim::Bih::Goodwill::Ledger.new
        end

        # Uses the host-configured catalog (torba 300, majica 500, termos 800).
        test "redeems an affordable reward, debiting the wallet and creating fulfillment" do
          @ledger.award(@user, 1000, reason: "volunteer_hour")
          redeemed = nil
          assert_difference "Decidim::Bih::Goodwill::RewardFulfillment.count", 1 do
            assert_difference "Decidim::Bih::Goodwill::RewardFulfillmentEvent.count", 1 do
              RedeemReward.call(@user, "majica") do
                on(:ok) { |reward| redeemed = reward }
                on(:insufficient) { flunk "should be affordable" }
                on(:invalid) { flunk "majica is a valid reward" }
              end
            end
          end

          assert_equal "majica", redeemed.key
          assert_equal 500, @ledger.account_for(@user).balance # 1000 - 500
          fulfillment = Decidim::Bih::Goodwill::RewardFulfillment.last
          assert_equal @user.id, fulfillment.user.id
          assert_equal "majica", fulfillment.reward_key
          assert_equal 500, fulfillment.cost
          assert_equal "requested", fulfillment.status
          assert_equal "redeem", fulfillment.ledger_transaction.kind

          event = fulfillment.events.last
          assert_equal "requested", event.event_type
          assert_equal @user, event.actor
          assert_equal "public", event.source
          assert_equal "citizen", event.actor_role
          assert_equal "redemption", event.metadata["action"]
          assert_equal "majica", event.metadata["reward_key"]
          assert_equal 500, event.metadata["cost"]
        end

        test "broadcasts :insufficient and writes nothing when too poor" do
          @ledger.award(@user, 100, reason: "proposal") # < cheapest (torba 300)
          state = nil
          assert_no_difference "Decidim::Bih::Goodwill::RewardFulfillment.count" do
            RedeemReward.call(@user, "torba") do
              on(:ok) { state = :ok }
              on(:insufficient) { state = :insufficient }
              on(:invalid) { state = :invalid }
            end
          end

          assert_equal :insufficient, state
          assert_equal 100, @ledger.account_for(@user).balance
        end

        test "broadcasts :invalid for an unknown reward" do
          state = nil
          RedeemReward.call(@user, "nonexistent") do
            on(:ok) { state = :ok }
            on(:insufficient) { state = :insufficient }
            on(:invalid) { state = :invalid }
          end

          assert_equal :invalid, state
        end

        test "same request key is idempotent" do
          @ledger.award(@user, 1000, reason: "volunteer_hour")
          request_key = SecureRandom.uuid
          states = []

          2.times do
            RedeemReward.call(@user, "majica", request_key) do
              on(:ok) { states << :ok }
              on(:already) { states << :already }
            end
          end

          assert_equal [:ok, :already], states
          assert_equal 1, RewardFulfillment.where(user: @user, request_key:).count
          assert_equal 500, @ledger.account_for(@user).balance
        end
      end
    end
  end
end
