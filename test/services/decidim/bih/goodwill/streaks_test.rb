# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module Goodwill
      # R11 — weekly streak (consecutive ISO weeks with >=1 earn) + season score
      # (earns since a configurable date), computed-on-read from the ledger.
      class StreaksTest < ActiveSupport::TestCase
        setup do
          @organization = create_organization
          @ledger = Decidim::Bih::Goodwill::Ledger.new
          @alice = FactoryBot.create(:user, :confirmed, organization: @organization)
        end

        # Award `amount` to alice with the transaction backdated `weeks_ago` weeks
        # (mid-week, so DATE_TRUNC('week') lands on the right Monday).
        def earn_weeks_ago(weeks, amount: 10)
          txn = @ledger.award(@alice, amount, reason: "proposal")
          when_at = (Date.current.beginning_of_week - (weeks * 7)).to_time + 3.days
          txn.update_column(:created_at, when_at) # rubocop:disable Rails/SkipsModelValidations
          txn.entries.update_all(created_at: when_at) # rubocop:disable Rails/SkipsModelValidations
          txn
        end

        test "earn_week_starts buckets a Monday-local (Sunday-UTC) earn by the LOCAL week" do
          # 2026-06-14 23:30 UTC == 2026-06-15 01:30 in Europe/Sarajevo — a Monday.
          # UTC bucketing would file it under the week of Mon 2026-06-08; the streak
          # walk compares against Date.current.beginning_of_week (local), so the
          # bucket must be the local Monday 2026-06-15.
          txn = @ledger.award(@alice, 10, reason: "proposal")
          when_at = Time.utc(2026, 6, 14, 23, 30)
          txn.update_column(:created_at, when_at) # rubocop:disable Rails/SkipsModelValidations
          txn.entries.update_all(created_at: when_at) # rubocop:disable Rails/SkipsModelValidations

          weeks = Streaks.earn_week_starts(@ledger.account_for(@alice))

          assert_includes weeks, Date.new(2026, 6, 15), "must bucket by the local Monday"
          assert_not_includes weeks, Date.new(2026, 6, 8), "must not bucket by the UTC-previous week"
        end

        test "no earns => zero streak" do
          assert_equal 0, Streaks.weekly_for(@ledger.account_for(@alice))
        end

        test "nil account => zero streak" do
          assert_equal 0, Streaks.weekly_for(nil)
        end

        test "earning this week is a streak of 1" do
          earn_weeks_ago(0)
          assert_equal 1, Streaks.weekly_for(@ledger.account_for(@alice))
        end

        test "three consecutive weeks ending this week is a streak of 3" do
          earn_weeks_ago(0)
          earn_weeks_ago(1)
          earn_weeks_ago(2)
          assert_equal 3, Streaks.weekly_for(@ledger.account_for(@alice))
        end

        test "a gap breaks the streak (only the trailing run counts)" do
          earn_weeks_ago(0)
          earn_weeks_ago(1)
          # gap at week 2
          earn_weeks_ago(3)
          earn_weeks_ago(4)
          assert_equal 2, Streaks.weekly_for(@ledger.account_for(@alice))
        end

        test "streak survives mid-week before earning this week (anchored at last week)" do
          # Earned last week and the week before, nothing yet this week.
          earn_weeks_ago(1)
          earn_weeks_ago(2)
          assert_equal 2, Streaks.weekly_for(@ledger.account_for(@alice))
        end

        test "an old earn with no recent activity is a broken streak (zero)" do
          earn_weeks_ago(5)
          assert_equal 0, Streaks.weekly_for(@ledger.account_for(@alice))
        end

        test "season score sums only earns since the configured date" do
          earn_weeks_ago(4, amount: 50) # before the season — excluded
          earn_weeks_ago(0, amount: 30) # within the season
          earn_weeks_ago(1, amount: 20) # within the season

          # Season starts 2 weeks ago, so only the week-0 + week-1 earns count.
          since = (Date.current.beginning_of_week - 14).to_time
          account = @ledger.account_for(@alice)
          assert_equal 50, Streaks.season_score(account, since:)
          # All-time contribution stays the full 100 regardless of season.
          assert_equal 100, account.contribution_score
        end

        test "season score is zero when since is nil" do
          earn_weeks_ago(0, amount: 30)
          assert_equal 0, Streaks.season_score(@ledger.account_for(@alice), since: nil)
        end
      end
    end
  end
end
