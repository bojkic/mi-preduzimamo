# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module Goodwill
      # Per-citizen monthly contribution statement: groups the OWN account's
      # immutable ledger entries by month, with per-month earned / spent / net
      # subtotals and a cumulative running balance (oldest -> newest).
      class MonthlyStatementTest < ActiveSupport::TestCase
        setup do
          @organization = create_organization
          @ledger = Decidim::Bih::Goodwill::Ledger.new
          @alice = FactoryBot.create(:user, :confirmed, organization: @organization)
        end

        # Award `amount` to alice, then backdate the whole transaction (and its
        # entries) to `at` so it falls into a chosen month bucket.
        def earn_at(amount, at:, reason: "proposal")
          txn = @ledger.award(@alice, amount, reason:)
          txn.update_column(:created_at, at) # rubocop:disable Rails/SkipsModelValidations
          txn.entries.update_all(created_at: at) # rubocop:disable Rails/SkipsModelValidations
          txn
        end

        # Spend `amount` from alice's wallet (redeem), backdated to `at`.
        def spend_at(amount, at:)
          txn = @ledger.spend(owner: @alice, amount:, kind: "redeem", reason: "reward")
          txn.update_column(:created_at, at) # rubocop:disable Rails/SkipsModelValidations
          txn.entries.update_all(created_at: at) # rubocop:disable Rails/SkipsModelValidations
          txn
        end

        def months_for(account)
          Decidim::Bih::Goodwill::MonthlyStatement.new(account).months
        end

        test "nil account => empty statement" do
          assert_equal [], months_for(nil)
        end

        test "an account with no entries => empty statement" do
          account = Decidim::Bih::Goodwill::Account.new
          assert_equal [], months_for(account)
        end

        test "a single earn produces one month with earned/spent/net + balance" do
          earn_at(100, at: Time.utc(2026, 3, 10, 12))
          account = @ledger.account_for(@alice)

          months = months_for(account)
          assert_equal 1, months.length

          month = months.first
          assert_equal Date.new(2026, 3, 1), month[:month]
          assert_equal 100, month[:earned]
          assert_equal 0, month[:spent]
          assert_equal 100, month[:net]
          assert_equal 100, month[:running_balance]
        end

        test "entries spanning two months produce two ordered month buckets" do
          earn_at(100, at: Time.utc(2026, 3, 10, 12))
          earn_at(40, at: Time.utc(2026, 4, 5, 9))
          account = @ledger.account_for(@alice)

          months = months_for(account)
          assert_equal 2, months.length

          march = months.find { |m| m[:month] == Date.new(2026, 3, 1) }
          april = months.find { |m| m[:month] == Date.new(2026, 4, 1) }
          assert_not_nil march
          assert_not_nil april

          # Running balance is cumulative oldest -> newest.
          assert_equal 100, march[:running_balance]
          assert_equal 140, april[:running_balance]
        end

        test "months are ordered newest-first for presentation" do
          earn_at(10, at: Time.utc(2026, 1, 15, 12))
          earn_at(20, at: Time.utc(2026, 2, 15, 12))
          earn_at(30, at: Time.utc(2026, 3, 15, 12))
          account = @ledger.account_for(@alice)

          months = months_for(account)
          assert_equal(
            [Date.new(2026, 3, 1), Date.new(2026, 2, 1), Date.new(2026, 1, 1)],
            months.map { |m| m[:month] }
          )
        end

        test "earned, spent and net are computed per month" do
          # March: earn 100. April: earn 50 then spend 30 (net +20).
          earn_at(100, at: Time.utc(2026, 3, 10, 12))
          earn_at(50, at: Time.utc(2026, 4, 2, 12))
          spend_at(30, at: Time.utc(2026, 4, 20, 12))
          account = @ledger.account_for(@alice)

          months = months_for(account)
          march = months.find { |m| m[:month] == Date.new(2026, 3, 1) }
          april = months.find { |m| m[:month] == Date.new(2026, 4, 1) }

          assert_equal 100, march[:earned]
          assert_equal 0, march[:spent]
          assert_equal 100, march[:net]

          assert_equal 50, april[:earned]
          assert_equal(-30, april[:spent])
          assert_equal 20, april[:net]

          # Running balance: March 100, April 100 + 20 = 120.
          assert_equal 100, march[:running_balance]
          assert_equal 120, april[:running_balance]
        end

        test "running balance accumulates correctly across three months" do
          earn_at(100, at: Time.utc(2026, 1, 10, 12))
          spend_at(40, at: Time.utc(2026, 2, 10, 12))
          earn_at(25, at: Time.utc(2026, 3, 10, 12))
          account = @ledger.account_for(@alice)

          months = months_for(account)
          jan = months.find { |m| m[:month] == Date.new(2026, 1, 1) }
          feb = months.find { |m| m[:month] == Date.new(2026, 2, 1) }
          mar = months.find { |m| m[:month] == Date.new(2026, 3, 1) }

          assert_equal 100, jan[:running_balance]
          assert_equal 60, feb[:running_balance]
          assert_equal 85, mar[:running_balance]

          # Final running balance must equal the account's spendable balance.
          assert_equal account.balance, mar[:running_balance]
        end

        test "incoming gifts and outgoing gifts remain separate before netting" do
          earn_at(100, at: Time.current)
          bob = FactoryBot.create(:user, :confirmed, organization: @organization)
          @ledger.award(bob, 100, reason: "report")
          @ledger.transfer(from_owner: bob, to_owner: @alice, amount: 30, kind: "gift")
          @ledger.transfer(from_owner: @alice, to_owner: bob, amount: 20, kind: "gift")
          month = months_for(@ledger.account_for(@alice)).first
          assert_equal 100, month[:earned]
          assert_equal 30, month[:by_category]["received"]
          assert_equal(-20, month[:by_category]["given"])
          assert_equal 110, month[:net]
        end

        test "a purchase refund is not new earned contribution" do
          earn_at(100, at: Time.current)
          purchase = spend_at(40, at: Time.current)
          @ledger.reverse(purchase)
          month = months_for(@ledger.account_for(@alice)).first
          assert_equal 100, month[:earned]
          assert_equal(-40, month[:spent])
          assert_equal 40, month[:by_category]["refunds"]
          assert_equal 100, month[:net]
        end

        test "each month summarizes entries grouped by transaction kind" do
          earn_at(100, at: Time.utc(2026, 5, 5, 12))
          spend_at(30, at: Time.utc(2026, 5, 20, 12))
          account = @ledger.account_for(@alice)

          month = months_for(account).first
          by_kind = month[:by_kind]
          assert_equal 100, by_kind["earn"]
          assert_equal(-30, by_kind["redeem"])
        end
      end
    end
  end
end
