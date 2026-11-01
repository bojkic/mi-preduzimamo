# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module Goodwill
      # R6 — time-windowed recognition leaderboard. Verifies that
      # Account.contribution_leaderboard_since aggregates only "earn" credits
      # booked within the window, stays citizen-only and org-scoped, and exposes
      # a #windowed_score.
      class WindowedLeaderboardTest < ActiveSupport::TestCase
        setup do
          @organization = create_organization
          @ledger = Decidim::Bih::Goodwill::Ledger.new
        end

        test "windows on when points were earned (transaction created_at)" do
          alice = FactoryBot.create(:user, :confirmed, organization: @organization)

          # Last month's earn must NOT count toward this month's board.
          travel_to(1.month.ago) do
            @ledger.award(alice, 50, reason: "proposal")
          end
          # This month's earn.
          @ledger.award(alice, 20, reason: "report")

          board = Account.contribution_leaderboard_since(
            @organization, since: Time.current.beginning_of_month
          )

          assert_equal [alice.id], board.map(&:owner_id)
          assert_equal 20, board.first.attributes["windowed_score"].to_i
        end

        test "ranks within the window, highest first, and is org-scoped" do
          alice = FactoryBot.create(:user, :confirmed, organization: @organization)
          bob = FactoryBot.create(:user, :confirmed, organization: @organization)
          carol = FactoryBot.create(:user, :confirmed, organization: @organization)
          @ledger.award(alice, 30, reason: "proposal")
          @ledger.award(bob, 100, reason: "volunteer_hour")
          @ledger.award(carol, 5, reason: "comment")

          # Another org's earner must not leak in.
          other = create_organization
          ouser = FactoryBot.create(:user, :confirmed, organization: other)
          @ledger.award(ouser, 999, reason: "proposal")

          board = Account.contribution_leaderboard_since(
            @organization, since: Time.current.beginning_of_week
          )

          assert_equal [bob.id, alice.id, carol.id], board.map(&:owner_id)
          assert_equal([100, 30, 5], board.map { |a| a.attributes["windowed_score"].to_i })
        end

        test "ignores spending — only earn credits count in the window" do
          alice = FactoryBot.create(:user, :confirmed, organization: @organization)
          @ledger.award(alice, 50, reason: "proposal")

          account = @ledger.account_for(alice)
          system_account = @ledger.system_account_for(@organization)
          @ledger.post(
            organization: @organization, kind: "redeem", reason: "reward",
            entries: [{ account:, amount: -20 }, { account: system_account, amount: 20 }]
          )

          board = Account.contribution_leaderboard_since(
            @organization, since: Time.current.beginning_of_month
          )

          assert_equal 50, board.first.attributes["windowed_score"].to_i
        end

        test "is empty when nobody earned in the window" do
          alice = FactoryBot.create(:user, :confirmed, organization: @organization)
          travel_to(2.months.ago) { @ledger.award(alice, 50, reason: "proposal") }

          board = Account.contribution_leaderboard_since(
            @organization, since: Time.current.beginning_of_month
          )

          assert_empty board
        end

        test "excludes groups (recognition cohort is citizens only)" do
          alice = FactoryBot.create(:user, :confirmed, organization: @organization)
          group = FactoryBot.create(:user, :confirmed, organization: @organization)
          group.update!(extended_data: group.extended_data.merge("group" => true))

          @ledger.award(alice, 10, reason: "report")
          # Force-credit the group account directly (groups never earn via rules).
          @ledger.post(
            organization: @organization, kind: "earn", reason: "report",
            entries: [
              { account: @ledger.system_account_for(@organization), amount: -10 },
              { account: @ledger.account_for(group), amount: 10 }
            ]
          )

          board = Account.contribution_leaderboard_since(
            @organization, since: Time.current.beginning_of_month
          )

          assert_equal [alice.id], board.map(&:owner_id)
        end
      end
    end
  end
end
