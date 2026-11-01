# frozen_string_literal: true
require "test_helper"

module Decidim
  module Bih
    module Goodwill
      class ReconciliationTest < ActiveSupport::TestCase
        test "repair follows ledger and refreshes recognition without adding transactions" do
          organization = create_organization
          user = FactoryBot.create(:user, :confirmed, organization:)
          ledger = Ledger.new
          ledger.award(user, 25, reason: "proposal")
          account = ledger.account_for(user)
          account.update_columns(cached_balance: 999, cached_contribution: 888)
          refreshed = []
          ContributionProjection.stub(:after_commit, ->(item) { refreshed << item.id }) do
            assert_no_difference -> { Transaction.count } do
              drift = Reconciliation.run(organization, fix: true)
              assert_equal [account.id], drift.map { |row| row[:account_id] }
            end
          end
          assert_equal [account.id], refreshed
          assert_equal 25, account.reload.balance
          assert_equal 25, account.contribution_score
          assert_empty Reconciliation.run(organization, fix: true)
        end
      end
    end
  end
end
