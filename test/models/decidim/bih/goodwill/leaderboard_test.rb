# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module Goodwill
      class LeaderboardTest < ActiveSupport::TestCase
        setup do
          @organization = create_organization
          @ledger = Decidim::Bih::Goodwill::Ledger.new
        end

        test "ranks user accounts by contribution score, highest first" do
          alice = FactoryBot.create(:user, :confirmed, organization: @organization)
          bob = FactoryBot.create(:user, :confirmed, organization: @organization)
          carol = FactoryBot.create(:user, :confirmed, organization: @organization)
          @ledger.award(alice, 30, reason: "proposal")
          @ledger.award(bob, 100, reason: "volunteer_hour")
          @ledger.award(carol, 5, reason: "comment")

          board = Account.contribution_leaderboard(@organization)

          assert_equal [bob.id, alice.id, carol.id], board.map(&:owner_id)
          assert_equal [100, 30, 5], board.map(&:contribution_score)
        end

        test "is organization-scoped and ignores spending (recognition is monotonic)" do
          alice = FactoryBot.create(:user, :confirmed, organization: @organization)
          @ledger.award(alice, 50, reason: "proposal")

          # Spending (redeem) must not lower contribution rank.
          account = @ledger.account_for(alice)
          system_account = @ledger.system_account_for(@organization)
          @ledger.post(
            organization: @organization, kind: "redeem", reason: "reward",
            entries: [{ account:, amount: -20 }, { account: system_account, amount: 20 }]
          )

          # A user in another organization must not appear.
          other = create_organization
          ouser = FactoryBot.create(:user, :confirmed, organization: other)
          Decidim::Bih::Goodwill::Ledger.new.award(ouser, 999, reason: "proposal")

          board = Account.contribution_leaderboard(@organization)

          assert_equal [alice.id], board.map(&:owner_id)
          assert_equal 50, board.first.contribution_score
        end

        test "returns nothing when no one has earned yet" do
          assert_empty Account.contribution_leaderboard(@organization)
        end

        test "excludes citizens who opted out of public recognition" do
          visible = FactoryBot.create(:user, :confirmed, organization: @organization)
          hidden = FactoryBot.create(
            :user,
            :confirmed,
            organization: @organization,
            extended_data: { "bih_public_recognition" => false }
          )
          @ledger.award(visible, 10, reason: "proposal")
          @ledger.award(hidden, 100, reason: "volunteer_hour")

          assert_equal [visible.id], Account.contribution_leaderboard(@organization).map(&:owner_id)
        end
      end
    end
  end
end
