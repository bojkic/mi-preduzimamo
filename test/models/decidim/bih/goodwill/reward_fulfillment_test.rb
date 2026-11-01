# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module Goodwill
      class RewardFulfillmentTest < ActiveSupport::TestCase
        setup do
          @organization = create_organization
          @user = FactoryBot.create(:user, :confirmed, organization: @organization)
          @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
          @transaction = Ledger.new.award(@user, 100, reason: "proposal")
        end

        test "mark stamps status and handler" do
          fulfillment = RewardFulfillment.create!(
            organization: @organization,
            ledger_transaction: @transaction,
            user: @user,
            reward_key: "naljepnice",
            cost: 100,
            status: "requested"
          )

          assert fulfillment.mark!("reserved", by: @admin)
          assert_equal "reserved", fulfillment.status
          assert_equal @admin.id, fulfillment.handled_by_id
          assert fulfillment.handled_at.present?

          event = fulfillment.events.last
          assert_equal "reserved", event.event_type
          assert_equal @admin, event.actor
          assert_equal "requested", event.metadata["from_status"]
          assert_equal "reserved", event.metadata["to_status"]
          assert_equal "naljepnice", event.metadata["reward_key"]
          assert_equal 100, event.metadata["cost"]
          assert_equal @transaction.id, event.metadata["ledger_transaction_id"]
        end

        test "mark is a no-op for the current status" do
          fulfillment = RewardFulfillment.create!(
            organization: @organization,
            ledger_transaction: @transaction,
            user: @user,
            reward_key: "naljepnice",
            cost: 100,
            status: "requested"
          )

          assert fulfillment.mark!("reserved", by: @admin)
          assert_no_difference -> { fulfillment.events.count } do
            assert_not fulfillment.mark!("reserved", by: @admin)
          end
        end

        test "status update rolls back when the audit event cannot be recorded" do
          other_admin = FactoryBot.create(:user, :admin, :confirmed, organization: create_organization)
          fulfillment = RewardFulfillment.create!(
            organization: @organization,
            ledger_transaction: @transaction,
            user: @user,
            reward_key: "naljepnice",
            cost: 100,
            status: "requested"
          )

          assert_raises ActiveRecord::RecordInvalid do
            fulfillment.mark!("reserved", by: other_admin)
          end

          fulfillment.reload
          assert_equal "requested", fulfillment.status
          assert_nil fulfillment.handled_by_id
          assert_equal 0, fulfillment.events.count
        end

        test "terminal statuses cannot be changed to another terminal state" do
          fulfillment = RewardFulfillment.create!(
            organization: @organization,
            ledger_transaction: @transaction,
            user: @user,
            reward_key: "naljepnice",
            cost: 100,
            status: "fulfilled"
          )

          assert_no_difference -> { fulfillment.events.count } do
            assert_not fulfillment.mark!("canceled", by: @admin)
          end
          assert_equal "fulfilled", fulfillment.reload.status
        end
      end
    end
  end
end
