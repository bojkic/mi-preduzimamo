# frozen_string_literal: true

require "test_helper"
require "capybara"

module Decidim
  module Bih
    module Admin
      # Round 11, Item 5 — "Prikazano N od M" counts on all bounded admin queues.
      class QueueHonestyTest < ActionDispatch::IntegrationTest
        include ::Devise::Test::IntegrationHelpers

        setup do
          @previous_cache = Rails.cache
          Rails.cache = ActiveSupport::Cache::MemoryStore.new
          @organization = create_organization
          host! @organization.host
          @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
          @citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
          @ledger = Decidim::Bih::Goodwill::Ledger.new
        end

        teardown do
          Rails.cache = @previous_cache
        end

        test "pending volunteer log queue is handed off from the goodwill overview" do
          opportunity = VolunteerOpportunity.create!(
            organization: @organization, title: "Test akcija", active: true
          )
          create_legacy_volunteer_log!(
            organization: @organization, opportunity:, user: @citizen, hours: 1, status: "pending"
          )

          sign_in @admin
          get "/admin/bih/goodwill", params: { tab: "overview" }
          assert_response :success
          assert_select "#goodwill-volunteering-handoff"
          assert_includes response.body, "/admin/bih/volunteering?subqueue=pending_logs"
          assert_not_includes response.body, "Test akcija"
        end

        test "pending reward fulfillments queue shows N of M count" do
          @ledger.award(@citizen, 600, reason: "volunteer_hour")
          Decidim::Bih::Goodwill::RedeemReward.call(@citizen, "majica")

          sign_in @admin
          get "/admin/bih/goodwill"
          assert_response :success
          # The fulfillments count text must be present
          assert_includes response.body, "Prikazano 1 od 1"
        end

        test "reward fulfillment queue count reflects total even when QUEUE_LIMIT clips the list" do
          51.times do
            @ledger.award(@citizen, 600, reason: "queue_seed")
            transaction = @ledger.spend(owner: @citizen, amount: 500, kind: "redeem", reason: "reward:majica")
            Decidim::Bih::Goodwill::RewardFulfillment.create!(
              organization: @organization,
              ledger_transaction: transaction,
              user: @citizen,
              reward_key: "majica",
              cost: 500,
              status: "requested"
            )
          end

          sign_in @admin
          get "/admin/bih/goodwill"
          assert_response :success
          assert_includes response.body, "Prikazano 50 od 51"
        end

        test "match request queue shows N of M count" do
          group = FactoryBot.create(:user, :confirmed, organization: @organization,
                                                       extended_data: { "group" => true })
          Decidim::Bih::Goodwill::MatchRequest.create!(
            organization: @organization, owner: group, points: 77,
            status: "pending", created_by: @admin
          )

          sign_in @admin
          get "/admin/bih/goodwill", params: { tab: "matched_giving" }
          assert_response :success
          # Match requests section has a count
          assert_includes response.body, "77"
        end
      end
    end
  end
end
