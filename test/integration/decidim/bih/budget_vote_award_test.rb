# frozen_string_literal: true

require "test_helper"
require "decidim/participatory_processes/test/factories"
require "decidim/budgets/test/factories"

module Decidim
  module Bih
    module Goodwill
      # Item 1 — BudgetVoteAwardOverride: completing a participatory budget
      # checkout awards budget_vote:5 exactly once. Re-saving the order after
      # checkout must NOT re-award (idempotency guard).
      #
      # THE WALL: the award must never touch line_items, checked_out_at, or
      # any vote-weight attribute — the binding vote is unaffected.
      class BudgetVoteAwardTest < ActiveSupport::TestCase
        include ActiveJob::TestHelper

        setup do
          @organization = create_organization
          @user = FactoryBot.create(:user, :confirmed, organization: @organization)
          participatory_process = FactoryBot.create(:participatory_process, organization: @organization)
          # Use the :with_projects trait so the order has enough budget to check out
          component = FactoryBot.create(:budgets_component, participatory_space: participatory_process)
          @budget = FactoryBot.create(:budget, component:)
          @order = FactoryBot.create(:order, :with_projects, budget: @budget, user: @user)
          @project = @order.projects.first
        end

        # Invoke the award_goodwill_for_budget_vote callback directly, faking
        # saved_changes to simulate a nil→timestamp transition. This tests the
        # override logic in isolation from budget-domain checkout validators.
        def invoke_award_callback(order, checked_out_at: Time.current, previous: nil)
          order.define_singleton_method(:saved_changes) do
            { "checked_out_at" => [previous, checked_out_at] }
          end
          order.define_singleton_method(:saved_change_to_checked_out_at?) { true }
          order.define_singleton_method(:checked_out_at) { checked_out_at }
          order.award_goodwill_for_budget_vote
        end

        test "checking out a budget order awards budget_vote points to the voter" do
          perform_enqueued_jobs do
            invoke_award_callback(@order)
          end

          assert_equal 5, Ledger.new.account_for(@user).contribution_score
        end

        test "re-saving a checked-out order does NOT re-award (idempotency — previous not nil)" do
          # First checkout — awards
          perform_enqueued_jobs do
            invoke_award_callback(@order)
          end
          assert_equal 5, Ledger.new.account_for(@user).contribution_score

          # Simulate a re-save where checked_out_at WAS already set (previous is NOT nil)
          perform_enqueued_jobs do
            @order.define_singleton_method(:saved_changes) do
              { "checked_out_at" => [1.day.ago, Time.current] }
            end
            @order.define_singleton_method(:saved_change_to_checked_out_at?) { true }
            @order.define_singleton_method(:checked_out_at) { Time.current }
            @order.award_goodwill_for_budget_vote
          end

          assert_equal 5, Ledger.new.account_for(@user).contribution_score,
                       "re-checkout must not re-award (previous was not nil)"
        end

        test "idempotency key prevents double-award even when callback fires twice for same order" do
          2.times do
            perform_enqueued_jobs do
              invoke_award_callback(@order)
            end
          end
          assert_equal 5, Ledger.new.account_for(@user).contribution_score,
                       "same idempotency key must prevent double award"
        end

        test "THE WALL: the award does not write to line_items or vote weights" do
          line_item_count_before = @order.line_items.count
          project_amount_before = @project.budget_amount

          perform_enqueued_jobs do
            invoke_award_callback(@order)
          end

          @order.reload
          @project.reload

          assert_equal line_item_count_before, @order.line_items.count,
                       "line_items count must be unchanged by the award"
          assert_equal project_amount_before, @project.budget_amount,
                       "project budget_amount must be unchanged by the award"
        end

        test "a non-checkout save (no saved_change_to_checked_out_at) does not award" do
          @order.define_singleton_method(:saved_change_to_checked_out_at?) { false }
          perform_enqueued_jobs { @order.award_goodwill_for_budget_vote }

          assert_equal 0, Ledger.new.account_for(@user).contribution_score
        end

        # S3 — Budget re-vote farming via cancel→re-checkout.
        # Cancelling an order destroys the row (old order ID gone). A new order
        # on the SAME budget gets a new ID. The idempotency key is now keyed on
        # (budget, voter) rather than (order_id, voter), so the second checkout
        # on the same budget must NOT award a second time.
        test "cancel and re-checkout on the SAME budget does NOT re-award (S3 idempotency)" do
          # First checkout on @order — awards budget_vote points.
          perform_enqueued_jobs do
            invoke_award_callback(@order)
          end
          assert_equal 5, Ledger.new.account_for(@user).contribution_score,
                       "first checkout must award 5 points"

          # Simulate cancel: destroy the original order row.
          @order.destroy!

          # Re-checkout: create a fresh order on the SAME budget for the SAME user.
          second_order = FactoryBot.create(:order, :with_projects, budget: @budget, user: @user)

          # The new order has a different id but the SAME decidim_budgets_budget_id
          # and decidim_user_id, so the idempotency key "budget_vote:<budget_id>:voter:<user_id>"
          # matches the one already recorded — no second award.
          perform_enqueued_jobs do
            invoke_award_callback(second_order)
          end

          assert_equal 5, Ledger.new.account_for(@user).contribution_score,
                       "re-checkout on same budget must not award a second time (idempotency key is budget+voter)"
        end
      end
    end
  end
end
