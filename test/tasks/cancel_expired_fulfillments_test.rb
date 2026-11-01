# frozen_string_literal: true

require "test_helper"
require "rake"

module Tasks
  # The cancel_expired_fulfillments rake task must resolve the reward NAME for
  # the citizen's cancel notification using the fulfillment's organization, so
  # an admin-managed (table-backed) reward renders its localized title rather
  # than the raw key.
  class CancelExpiredFulfillmentsTest < ActiveSupport::TestCase
    TASK = "decidim_bih:goodwill:cancel_expired_fulfillments"

    def self.load_tasks
      return if Rake::Task.task_defined?(TASK)

      Rails.application.load_tasks
    end

    setup do
      self.class.load_tasks
      @organization = create_organization
      @user = FactoryBot.create(:user, :confirmed, organization: @organization)
      @ledger = Decidim::Bih::Goodwill::Ledger.new
    end

    teardown do
      Rake::Task[TASK].reenable
    end

    # Build an open fulfillment whose reward expired 7+ days ago, backed by a
    # real ledger spend transaction so the task's reversal has something to
    # reverse.
    def cancelable_fulfillment(reward_key:, cost: 100)
      @ledger.award(@user, cost, reason: "volunteer_hour")
      txn = @ledger.spend(owner: @user, amount: cost, kind: "redeem", reason: "reward:#{reward_key}")

      Decidim::Bih::Goodwill::RewardFulfillment.create!(
        organization: @organization,
        user: @user,
        ledger_transaction: txn,
        reward_key:,
        cost:,
        status: "requested",
        reward_expires_at: 10.days.ago
      )
    end

    test "cancel notification resolves a table-backed reward title, not the raw key" do
      Decidim::Bih::Goodwill::Reward.create!(
        organization: @organization,
        key: "vip_kupon",
        title: { "sr" => "VIP kupon" },
        cost: 100,
        active: true
      )
      cancelable_fulfillment(reward_key: "vip_kupon")

      published = []
      Decidim::EventsManager.stub(:publish, ->(**kwargs) { published << kwargs }) do
        capture_io { Rake::Task[TASK].invoke }
      end

      event = published.find { |e| e[:event] == "decidim.events.bih.goodwill.reward_canceled" }
      assert event, "expected a reward_canceled event to be published"
      I18n.with_locale(:sr) do
        assert_equal "VIP kupon", event[:extra][:reward_name],
                     "table-backed reward must resolve its title, not the raw key"
      end

      fulfillment = Decidim::Bih::Goodwill::RewardFulfillment.last
      audit_event = fulfillment.events.where(event_type: "canceled").last
      assert audit_event, "expected expired cancellation to append an audit event"
      assert_nil audit_event.actor
      assert_equal "background", audit_event.source
      assert_equal "system", audit_event.actor_role
      assert_equal "requested", audit_event.metadata["from_status"]
      assert_equal "canceled", audit_event.metadata["to_status"]
      assert_equal "expired_reward_cancel", audit_event.metadata["action"]
      assert audit_event.metadata["reversal_transaction_id"].present?
    end
  end
end
