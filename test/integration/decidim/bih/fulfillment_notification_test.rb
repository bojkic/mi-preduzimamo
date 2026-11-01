# frozen_string_literal: true

require "test_helper"
require "capybara"

module Decidim
  module Bih
    # Round 11, Item 2 — bell notifications on reserve, fulfillment and cancellation.
    class FulfillmentNotificationTest < ActionDispatch::IntegrationTest
      include ::Devise::Test::IntegrationHelpers
      include ActiveJob::TestHelper

      setup do
        @organization = create_organization(badges_enabled: false)
        host! @organization.host
        @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
        @citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
        @ledger = Decidim::Bih::Goodwill::Ledger.new
        @ledger.award(@citizen, 600, reason: "volunteer_hour")
        Decidim::Bih::Goodwill::RedeemReward.call(@citizen, "majica")
        @fulfillment = Decidim::Bih::Goodwill::RewardFulfillment.last
      end

      test "marking reserved sends a bell notification to the citizen" do
        sign_in @admin

        perform_enqueued_jobs do
          post "/admin/bih/goodwill/reward-fulfillment/#{@fulfillment.id}/reserved"
        end

        notif = Decidim::Notification.where(
          decidim_user_id: @citizen.id,
          event_name: "decidim.events.bih.goodwill.reward_reserved"
        ).last
        assert_not_nil notif, "expected a reward_reserved notification"
      end

      test "marking reserved twice sends one bell notification" do
        sign_in @admin

        perform_enqueued_jobs do
          post "/admin/bih/goodwill/reward-fulfillment/#{@fulfillment.id}/reserved"
          post "/admin/bih/goodwill/reward-fulfillment/#{@fulfillment.id}/reserved"
        end

        count = Decidim::Notification.where(
          decidim_user_id: @citizen.id,
          event_name: "decidim.events.bih.goodwill.reward_reserved"
        ).count
        assert_equal 1, count
      end

      test "marking fulfilled sends a bell notification to the citizen" do
        sign_in @admin

        perform_enqueued_jobs do
          post "/admin/bih/goodwill/reward-fulfillment/#{@fulfillment.id}/fulfilled"
        end

        notif = Decidim::Notification.where(
          decidim_user_id: @citizen.id,
          event_name: "decidim.events.bih.goodwill.reward_fulfilled"
        ).last
        assert_not_nil notif, "expected a reward_fulfilled notification"
      end

      test "canceling a fulfillment sends a bell notification to the citizen" do
        sign_in @admin

        perform_enqueued_jobs do
          post "/admin/bih/goodwill/reward-fulfillment/#{@fulfillment.id}/canceled",
               params: { private_reason: "Nagrada više nije dostupna" }
        end

        notif = Decidim::Notification.where(
          decidim_user_id: @citizen.id,
          event_name: "decidim.events.bih.goodwill.reward_canceled"
        ).last
        assert_not_nil notif, "expected a reward_canceled notification"
      end

      test "fulfilling does not send a notification to another organization's citizen" do
        other = create_organization
        outsider = FactoryBot.create(:user, :confirmed, organization: other)
        @ledger.award(outsider, 600, reason: "volunteer_hour")
        Decidim::Bih::Goodwill::RedeemReward.call(outsider, "majica")
        outsider_fulfillment = Decidim::Bih::Goodwill::RewardFulfillment
                               .where(decidim_user_id: outsider.id).last

        sign_in @admin
        # Admin scoped to @organization cannot touch outsider's fulfillment
        perform_enqueued_jobs do
          post "/admin/bih/goodwill/reward-fulfillment/#{outsider_fulfillment.id}/fulfilled"
        end

        assert_equal "requested", outsider_fulfillment.reload.status
        assert_equal 0, Decidim::Notification.where(
          decidim_user_id: outsider.id,
          event_name: "decidim.events.bih.goodwill.reward_fulfilled"
        ).count
      end

      test "reserving does not send a notification to another organization's citizen" do
        other = create_organization
        outsider = FactoryBot.create(:user, :confirmed, organization: other)
        @ledger.award(outsider, 600, reason: "volunteer_hour")
        Decidim::Bih::Goodwill::RedeemReward.call(outsider, "majica")
        outsider_fulfillment = Decidim::Bih::Goodwill::RewardFulfillment
                               .where(decidim_user_id: outsider.id).last

        sign_in @admin
        perform_enqueued_jobs do
          post "/admin/bih/goodwill/reward-fulfillment/#{outsider_fulfillment.id}/reserved"
        end

        assert_equal "requested", outsider_fulfillment.reload.status
        assert_equal 0, Decidim::Notification.where(
          decidim_user_id: outsider.id,
          event_name: "decidim.events.bih.goodwill.reward_reserved"
        ).count
      end

      test "redemption flash includes reward name" do
        sign_in @citizen
        @ledger.award(@citizen, 500, reason: "proposal")
        post "/biceriseno/nagrade/redeem/majica",
             params: { redemption_confirmed: "1", redemption_request_key: SecureRandom.uuid }
        assert_response :redirect
        # Flash should include the reward name
        follow_redirect!
        assert_includes response.body, I18n.t("decidim.bih.goodwill.rewards.majica")
      end
    end
  end
end
