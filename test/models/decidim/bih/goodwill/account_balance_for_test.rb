# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module Goodwill
      # Focused coverage for Account.balance_for — the single source of truth for
      # the "find the citizen's wallet and read its balance, or 0" lookup shared
      # by the wallet/rewards/gifts controllers and the community hub.
      class AccountBalanceForTest < ActiveSupport::TestCase
        setup do
          @organization = create_organization
          @user = FactoryBot.create(:user, :confirmed, organization: @organization)
          @ledger = Decidim::Bih::Goodwill::Ledger.new
        end

        test "returns 0 when user is nil" do
          assert_equal 0, Account.balance_for(nil, @organization)
        end

        test "returns 0 when the user has no account yet" do
          assert_equal 0, Account.balance_for(@user, @organization)
        end

        test "returns the account balance for an existing account" do
          @ledger.award(@user, 30, reason: "proposal")

          assert_equal 30, Account.balance_for(@user, @organization)
        end

        test "returns 0 for an account in a different organization (org-scoped)" do
          # Give the user a real wallet with a balance in their own organization.
          @ledger.award(@user, 30, reason: "proposal")

          # Looking the same user up scoped to a DIFFERENT organization must not
          # surface their balance — there is no account for that (org, owner) pair.
          other_organization = create_organization

          assert_equal 0, Account.balance_for(@user, other_organization)
        end
      end
    end
  end
end
