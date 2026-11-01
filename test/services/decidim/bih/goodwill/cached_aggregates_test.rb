# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module Goodwill
      # The cached account aggregates (cached_balance / cached_contribution),
      # maintained incrementally in Ledger#build_and_save, must never drift from
      # the authoritative recompute over the immutable ledger.
      class CachedAggregatesTest < ActiveSupport::TestCase
        setup do
          @organization = create_organization
          @alice = FactoryBot.create(:user, :confirmed, organization: @organization)
          @bob = FactoryBot.create(:user, :confirmed, organization: @organization)
          @ledger = Decidim::Bih::Goodwill::Ledger.new
        end

        def assert_consistent(owner)
          account = @ledger.account_for(owner).reload
          assert_equal account.recomputed_balance, account.cached_balance, "balance cache drift"
          assert_equal account.recomputed_contribution, account.cached_contribution, "contribution cache drift"
        end

        test "cache reads equal the recompute and stay consistent across all kinds" do
          @ledger.award(@alice, 100, reason: "volunteer_hour")
          assert_equal 100, @ledger.account_for(@alice).balance
          assert_equal 100, @ledger.account_for(@alice).contribution_score
          assert_consistent(@alice)

          @ledger.transfer(from_owner: @alice, to_owner: @bob, amount: 40, kind: "gift")
          assert_equal 60, @ledger.account_for(@alice).balance
          assert_equal 100, @ledger.account_for(@alice).contribution_score # recognition intact
          assert_equal 40, @ledger.account_for(@bob).balance
          assert_equal 0, @ledger.account_for(@bob).contribution_score # gifts aren't earns
          assert_consistent(@alice)
          assert_consistent(@bob)

          @ledger.spend(owner: @alice, amount: 10, kind: "redeem", reason: "x")
          assert_equal 50, @ledger.account_for(@alice).balance
          assert_consistent(@alice)

          earn = @ledger.award(@alice, 25, reason: "comment")
          assert_equal 75, @ledger.account_for(@alice).balance
          @ledger.reverse(earn)
          assert_equal 50, @ledger.account_for(@alice).balance # earn reversed (adjustment debit)
          assert_equal 100, @ledger.account_for(@alice).contribution_score # revoked earn no longer counts
          assert_consistent(@alice)

          # The system (issuance) account is also cache-consistent.
          sys = @ledger.system_account_for(@organization).reload
          assert_equal sys.recomputed_balance, sys.cached_balance
        end
      end
    end
  end
end
