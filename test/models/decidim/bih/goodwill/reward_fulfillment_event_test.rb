# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module Goodwill
      class RewardFulfillmentEventTest < ActiveSupport::TestCase
        setup do
          @organization = create_organization
          @user = FactoryBot.create(:user, :confirmed, organization: @organization)
          @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
          @ledger = Ledger.new
          @ledger.award(@user, 600, reason: "seed")
          @transaction = @ledger.spend(owner: @user, amount: 500, kind: "redeem", reason: "reward:majica")
          @fulfillment = RewardFulfillment.create!(
            organization: @organization,
            ledger_transaction: @transaction,
            user: @user,
            reward_key: "majica",
            cost: 500,
            status: "requested"
          )
        end

        test "fulfillment records append-only event with actor and sanitized metadata" do
          event = @fulfillment.record_event!(
            "reserved",
            actor: @admin,
            metadata: {
              from_status: "requested",
              to_status: "reserved",
              reward_key: "majica",
              cost: 500,
              action: "single",
              phone: "+387 65 123 456",
              pickup_location: "Kancelarija fondacije",
              provider_payload: { body: "raw provider payload" },
              details: {
                phone: "+387 65 000 111",
                note: "Preuzimanje u kancelariji",
                safe_count: 2
              }
            }
          )

          assert_equal @fulfillment, event.fulfillment
          assert_equal @organization, event.organization
          assert_equal @admin, event.actor
          assert_equal "admin", event.source
          assert_equal "admin", event.actor_role
          assert_equal "requested", event.metadata["from_status"]
          assert_equal "reserved", event.metadata["to_status"]
          assert_equal "majica", event.metadata["reward_key"]
          assert_equal 500, event.metadata["cost"]
          assert_equal "single", event.metadata["action"]
          assert_not event.metadata.has_key?("phone")
          assert_not event.metadata.has_key?("pickup_location")
          assert_not event.metadata.has_key?("provider_payload")
          assert_equal 2, event.metadata.dig("details", "safe_count")
          assert_not event.metadata.to_s.include?("+387 65 000 111")
          assert_not event.metadata.to_s.include?("Preuzimanje u kancelariji")
        end

        test "public request event can identify the citizen actor without admin defaults" do
          event = @fulfillment.record_event!(
            "requested",
            actor: @user,
            source: "public",
            actor_role: "citizen",
            metadata: { action: "redemption" }
          )

          assert_equal "public", event.source
          assert_equal "citizen", event.actor_role
          assert_equal @user.name, event.actor_label
          assert_equal "redemption", event.metadata["action"]
        end

        test "events cannot be updated or destroyed" do
          event = @fulfillment.record_event!("fulfilled", actor: @admin, metadata: { status: "fulfilled" })

          assert_raises ActiveRecord::ReadOnlyRecord do
            event.update!(metadata: { status: "canceled" })
          end
          assert_raises ActiveRecord::ReadOnlyRecord do
            event.destroy!
          end
        end

        test "event actor must belong to the same organization" do
          other_admin = FactoryBot.create(:user, :admin, :confirmed, organization: create_organization)
          event = RewardFulfillmentEvent.new(
            fulfillment: @fulfillment,
            actor: other_admin,
            event_type: "reserved",
            source: "admin",
            actor_role: "admin"
          )

          assert_not event.valid?
          assert event.errors[:decidim_user_id].any?
        end

        test "event organization must match the fulfillment organization" do
          event = RewardFulfillmentEvent.new(
            fulfillment: @fulfillment,
            organization: create_organization,
            actor: @admin,
            event_type: "reserved",
            source: "admin",
            actor_role: "admin"
          )

          assert_not event.valid?
          assert event.errors[:decidim_organization_id].any?
        end
      end
    end
  end
end
