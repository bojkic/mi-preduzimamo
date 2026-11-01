# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module Goodwill
      class LedgerTest < ActiveSupport::TestCase
        setup do
          @organization = create_organization
          @user = FactoryBot.create(:user, :confirmed, organization: @organization)
          @ledger = Decidim::Bih::Goodwill::Ledger.new
        end

        # --- sum-zero invariant ---------------------------------------------

        test "post rejects entries that do not sum to zero" do
          system_account = @ledger.system_account_for(@organization)
          user_account = @ledger.account_for(@user)

          assert_raises(ArgumentError) do
            @ledger.post(
              organization: @organization,
              kind: "earn",
              entries: [
                { account: system_account, amount: -20 },
                { account: user_account, amount: 19 }
              ]
            )
          end
        end

        test "transaction model rejects unbalanced entries" do
          system_account = @ledger.system_account_for(@organization)
          user_account = @ledger.account_for(@user)
          txn = Transaction.new(organization: @organization, kind: "earn")
          txn.entries.build(organization: @organization, account: system_account, amount: -20)
          txn.entries.build(organization: @organization, account: user_account, amount: 10)

          assert_not txn.valid?
          assert_includes txn.errors.attribute_names, :base
        end

        test "post rejects an account from another organization without writing or changing caches" do
          other_organization = create_organization
          outsider = FactoryBot.create(:user, :confirmed, organization: other_organization)
          system_account = @ledger.system_account_for(@organization)
          outsider_account = @ledger.account_for(outsider)

          assert_no_difference -> { Transaction.count } do
            assert_raises(ArgumentError) do
              @ledger.post(
                organization: @organization,
                kind: "earn",
                entries: [
                  { account: system_account, amount: -20 },
                  { account: outsider_account, amount: 20 }
                ]
              )
            end
          end

          assert_equal 0, system_account.reload.cached_balance
          assert_equal 0, outsider_account.reload.cached_balance
        end

        test "entry model rejects account and transaction tenant mismatches" do
          other_organization = create_organization
          outsider = FactoryBot.create(:user, :confirmed, organization: other_organization)
          txn = Transaction.new(organization: @organization, kind: "earn")
          txn.entries.build(
            organization: @organization,
            account: @ledger.account_for(outsider),
            amount: 10
          )
          txn.entries.build(
            organization: @organization,
            account: @ledger.system_account_for(@organization),
            amount: -10
          )

          assert_not txn.valid?
          assert_includes txn.errors.attribute_names, :entries
          assert_includes txn.entries.first.errors.attribute_names, :account
        end

        # --- append-only -----------------------------------------------------

        test "entries cannot be updated" do
          txn = @ledger.award(@user, 20, reason: "proposal")
          entry = txn.entries.first
          assert_raises(Decidim::Bih::Goodwill::AppendOnlyError) { entry.update!(amount: 999) }
        end

        test "entries cannot be destroyed" do
          txn = @ledger.award(@user, 20, reason: "proposal")
          assert_raises(Decidim::Bih::Goodwill::AppendOnlyError) { txn.entries.first.destroy }
        end

        test "transactions cannot be destroyed" do
          txn = @ledger.award(@user, 20, reason: "proposal")
          assert_raises(Decidim::Bih::Goodwill::AppendOnlyError) { txn.destroy }
        end

        # --- contribution vs wallet -----------------------------------------

        test "contribution counts only earn credits; wallet counts all signed entries" do
          account = @ledger.account_for(@user)
          @ledger.award(@user, 20, reason: "proposal")
          @ledger.award(@user, 5, reason: "comment")

          # A redeem spends 10 (debit user, credit system) — not an earn.
          system_account = @ledger.system_account_for(@organization)
          @ledger.post(
            organization: @organization,
            kind: "redeem",
            reason: "reward",
            entries: [
              { account: account, amount: -10 },
              { account: system_account, amount: 10 }
            ]
          )

          account.reload # cached aggregates live on the row; refresh the held ref
          assert_equal 25, account.contribution_score
          assert_equal 15, account.balance
        end

        # --- earn books a balanced double entry -----------------------------

        test "earn books a balanced double entry (system debit, user credit)" do
          txn = @ledger.award(@user, 20, reason: "proposal")
          assert_equal 0, txn.entries.sum(&:amount)
          assert_equal 20, @ledger.account_for(@user).balance
          assert_equal(-20, @ledger.system_account_for(@organization).balance)
        end

        test "award is a no-op for non-positive amounts" do
          assert_nil @ledger.award(@user, 0, reason: "x")
          assert_nil @ledger.award(@user, -5, reason: "x")
          assert_equal 0, @ledger.account_for(@user).balance
        end

        # --- reversal -------------------------------------------------------

        test "revoking an earn corrects wallet and recognized contribution without changing the original" do
          account = @ledger.account_for(@user)
          earn = @ledger.award(@user, 20, reason: "proposal")
          @ledger.reverse(earn)

          account.reload # cached aggregates live on the row; refresh the held ref
          assert_equal 0, account.balance # earn +20, reversal -20
          assert_equal 0, account.contribution_score
          assert_equal 20, earn.reload.credited_amount
          assert_equal(-20, CreditCorrection.find_by!(original_transaction: earn).recognition_delta)
        end
      end
    end
  end
end
