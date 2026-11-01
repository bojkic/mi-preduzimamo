# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module Goodwill
      # R14 — lightweight goodwill measurement (active earners, points issued,
      # redemptions, referrals, gifts) over a rolling window vs the prior window.
      class MetricsTest < ActiveSupport::TestCase
        setup do
          @organization = create_organization
          @ledger = Decidim::Bih::Goodwill::Ledger.new
          @alice = FactoryBot.create(:user, :confirmed, organization: @organization)
          @bob = FactoryBot.create(:user, :confirmed, organization: @organization)
        end

        def backdate(txn, days)
          when_at = days.days.ago
          txn.update_column(:created_at, when_at) # rubocop:disable Rails/SkipsModelValidations
          txn.entries.update_all(created_at: when_at) # rubocop:disable Rails/SkipsModelValidations
          txn
        end

        test "current window counts recent earners and points issued" do
          @ledger.award(@alice, 40, reason: "proposal")
          @ledger.award(@bob, 10, reason: "comment")

          snap = Metrics.new(@organization).snapshot
          assert_equal 7, snap[:window_days]
          assert_equal 2, snap[:current][:active_earners]
          assert_equal 50, snap[:current][:points_issued]
        end

        test "earns in the prior window land in :previous, not :current" do
          old = @ledger.award(@alice, 100, reason: "volunteer_hour")
          backdate(old, 10) # 10 days ago => prior 7-day window

          @ledger.award(@bob, 20, reason: "proposal") # now

          snap = Metrics.new(@organization).snapshot
          assert_equal 20, snap[:current][:points_issued]
          assert_equal 100, snap[:previous][:points_issued]
          assert_equal 1, snap[:current][:active_earners]
          assert_equal 1, snap[:previous][:active_earners]
        end

        test "redemptions and gifts are counted by transaction kind" do
          @ledger.award(@alice, 100, reason: "volunteer_hour")
          @ledger.spend(owner: @alice, amount: 30, kind: "redeem", reason: "reward")
          @ledger.transfer(from_owner: @alice, to_owner: @bob, amount: 20, kind: "gift")

          cur = Metrics.new(@organization).snapshot[:current]
          assert_equal 1, cur[:redemptions]
          assert_equal 1, cur[:gifts]
        end

        test "referrals count rewarded referrals in the window" do
          Referral.create!(
            organization: @organization, referrer: @alice, invitee: @bob,
            status: "rewarded", rewarded_at: 1.day.ago
          )

          assert_equal 1, Metrics.new(@organization).snapshot[:current][:referrals]
        end

        test "is organization-scoped" do
          @ledger.award(@alice, 40, reason: "proposal")
          other = create_organization
          ouser = FactoryBot.create(:user, :confirmed, organization: other)
          Decidim::Bih::Goodwill::Ledger.new.award(ouser, 500, reason: "proposal")

          assert_equal 40, Metrics.new(@organization).snapshot[:current][:points_issued]
        end
      end
    end
  end
end
