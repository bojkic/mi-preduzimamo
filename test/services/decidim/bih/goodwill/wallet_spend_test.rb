# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module Goodwill
      class WalletSpendTest < ActiveSupport::TestCase
        setup do
          @organization = create_organization
          @ledger = Decidim::Bih::Goodwill::Ledger.new
          @alice = FactoryBot.create(:user, :confirmed, organization: @organization)
          @bob = FactoryBot.create(:user, :confirmed, organization: @organization)
        end

        test "transfer gifts wallet points without touching contribution score" do
          @ledger.award(@alice, 100, reason: "volunteer_hour")
          @ledger.transfer(from_owner: @alice, to_owner: @bob, amount: 40, kind: "gift")

          alice = @ledger.account_for(@alice)
          bob = @ledger.account_for(@bob)
          assert_equal 60, alice.balance
          assert_equal 40, bob.balance
          assert_equal 100, alice.contribution_score # recognition is earned-only
          assert_equal 0, bob.contribution_score # a gift is not an earn
        end

        test "transfer raises InsufficientBalance and writes nothing when overdrawn" do
          @ledger.award(@alice, 30, reason: "proposal")

          assert_raises(Decidim::Bih::Goodwill::InsufficientBalanceError) do
            @ledger.transfer(from_owner: @alice, to_owner: @bob, amount: 31, kind: "gift")
          end

          assert_equal 30, @ledger.account_for(@alice).balance
          assert_equal 0, @ledger.account_for(@bob).balance
        end

        test "transfer rejects self-transfer and cross-organization transfer" do
          @ledger.award(@alice, 50, reason: "proposal")
          assert_raises(ArgumentError) do
            @ledger.transfer(from_owner: @alice, to_owner: @alice, amount: 10, kind: "gift")
          end

          other = create_organization
          ouser = FactoryBot.create(:user, :confirmed, organization: other)
          assert_raises(ArgumentError) do
            @ledger.transfer(from_owner: @alice, to_owner: ouser, amount: 10, kind: "gift")
          end
        end

        test "spend debits the wallet to the system account, overdraw-guarded" do
          @ledger.award(@alice, 100, reason: "volunteer_hour")
          @ledger.spend(owner: @alice, amount: 70, kind: "redeem", reason: "reward:majica")

          account = @ledger.account_for(@alice)
          assert_equal 30, account.balance
          assert_equal 100, account.contribution_score
          assert_equal(-30, @ledger.system_account_for(@organization).balance) # 100 earned out, 70 back in

          assert_raises(Decidim::Bih::Goodwill::InsufficientBalanceError) do
            @ledger.spend(owner: @alice, amount: 31, kind: "redeem", reason: "x")
          end
        end

        # --- overdraw race: the balance guard must read the POST-lock balance ---
        #
        # The advisory lock serializes spenders, but the guard must compare
        # against the balance as it stands AFTER the lock is held, not a value
        # snapshotted before the lock. We model a losing-race spender by handing
        # #spend an account object whose in-memory cached_balance is stale-high
        # (as if loaded before a concurrent spend drained the wallet). The guard
        # must reload inside the lock and refuse the overdraw rather than trusting
        # the stale snapshot.
        test "spend re-reads the balance inside the lock so a stale snapshot cannot overdraw" do
          @ledger.award(@alice, 100, reason: "volunteer_hour")
          # Concurrent spender drains the wallet to 0 first.
          @ledger.spend(owner: @alice, amount: 100, kind: "redeem", reason: "drain")
          assert_equal 0, @ledger.account_for(@alice).balance

          # The losing-race spender holds a fresh object but with a stale-high
          # cached_balance (its pre-lock snapshot read 100). account_for is what
          # #spend uses internally, so stub it to return our poisoned object.
          stale = @ledger.account_for(@alice)
          stale.cached_balance = 100 # stale pre-lock read
          @ledger.define_singleton_method(:account_for) { |_owner| stale }

          assert_raises(Decidim::Bih::Goodwill::InsufficientBalanceError) do
            @ledger.spend(owner: @alice, amount: 50, kind: "redeem", reason: "race")
          end

          # The poisoned object must have been reloaded to the true DB balance (0).
          assert_equal 0, stale.balance, "guard must reload to the true post-lock balance"
          assert_equal 0, Decidim::Bih::Goodwill::Ledger.new.account_for(@alice).balance,
                       "no overdraw must have occurred"
        end

        test "transfer re-reads the balance inside the lock so a stale snapshot cannot overdraw" do
          @ledger.award(@alice, 100, reason: "volunteer_hour")
          @ledger.spend(owner: @alice, amount: 100, kind: "redeem", reason: "drain")
          assert_equal 0, @ledger.account_for(@alice).balance

          stale = @ledger.account_for(@alice)
          stale.cached_balance = 100 # stale pre-lock read
          real_account_for = @ledger.method(:account_for)
          alice = @alice
          # Only the FROM account is poisoned; the TO account resolves normally.
          @ledger.define_singleton_method(:account_for) do |owner|
            owner == alice ? stale : real_account_for.call(owner)
          end

          assert_raises(Decidim::Bih::Goodwill::InsufficientBalanceError) do
            @ledger.transfer(from_owner: @alice, to_owner: @bob, amount: 50, kind: "gift")
          end

          assert_equal 0, Decidim::Bih::Goodwill::Ledger.new.account_for(@alice).balance
          assert_equal 0, Decidim::Bih::Goodwill::Ledger.new.account_for(@bob).balance
        end
      end
    end
  end
end
