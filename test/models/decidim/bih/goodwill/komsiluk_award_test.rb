# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module Goodwill
      # Tests that komsiluk_selected points are awarded once and only once
      # via the standard EarningRules path (idempotency key).
      class KomsilukAwardTest < ActiveSupport::TestCase
        setup do
          @organization = create_organization
          @user = FactoryBot.create(:user, :confirmed, organization: @organization)
          @rules = EarningRules.new
        end

        test "komsiluk_selected is in the earning schedule with positive points" do
          assert @rules.points_for(:komsiluk_selected).positive?
        end

        test "komsiluk_selected earns points on first award" do
          key = "komsiluk_selected:#{@user.id}"
          txn = @rules.award(@user, :komsiluk_selected, idempotency_key: key)
          assert_not_nil txn
          assert_equal @rules.points_for(:komsiluk_selected), txn.entries.select { |e| e.amount.positive? }.sum(&:amount)
        end

        test "komsiluk_selected does NOT re-award with same idempotency key" do
          key = "komsiluk_selected:#{@user.id}"
          @rules.award(@user, :komsiluk_selected, idempotency_key: key)

          # Second call with same key returns nil (already awarded)
          second_result = @rules.award(@user, :komsiluk_selected, idempotency_key: key)
          assert_nil second_result
        end

        test "contribution score increases by exactly komsiluk_selected points on first award" do
          ledger = Ledger.new
          account = ledger.account_for(@user)
          before = account.contribution_score

          key = "komsiluk_selected:#{@user.id}"
          @rules.award(@user, :komsiluk_selected, idempotency_key: key)

          account.reload
          assert_equal before + @rules.points_for(:komsiluk_selected), account.contribution_score
        end

        test "contribution score does not change on duplicate award attempt" do
          key = "komsiluk_selected:#{@user.id}"
          @rules.award(@user, :komsiluk_selected, idempotency_key: key)

          ledger = Ledger.new
          account = ledger.account_for(@user)
          score_after_first = account.contribution_score

          @rules.award(@user, :komsiluk_selected, idempotency_key: key)
          account.reload
          assert_equal score_after_first, account.contribution_score
        end
      end
    end
  end
end
