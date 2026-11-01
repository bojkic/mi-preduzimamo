# frozen_string_literal: true

require "test_helper"
require "decidim/proposals/test/factories"
require "minitest/mock"

module Decidim
  module Bih
    module Goodwill
      # R1 — every goodwill EARN notifies the earner in their Decidim
      # notifications bell exactly once, via Decidim::Bih::Goodwill::
      # PointsEarnedEvent published from the single Ledger#award seam. Gift /
      # regrant / redeem / adjustment must NOT notify, and a notification failure
      # must never break or roll back the award.
      class PointsEarnedNotificationTest < ActiveSupport::TestCase
        include ActiveJob::TestHelper

        setup do
          # This R1 suite is about the POINTS-earned notification only. Disable the
          # org's gamification badges so the badge-earned notification (and its
          # email render, which needs a compiled pack the test env lacks) does not
          # fire here — badge mirroring has its own coverage in badges_test.rb.
          @organization = create_organization(badges_enabled: false)
          @user = FactoryBot.create(:user, :confirmed, organization: @organization)
          @other = FactoryBot.create(:user, :confirmed, organization: @organization)
          @ledger = Decidim::Bih::Goodwill::Ledger.new
        end

        def notifications_for(user)
          Decidim::Notification.where(decidim_user_id: user.id)
        end

        def earned_notifications_for(user)
          notifications_for(user).where(
            event_class: "Decidim::Bih::Goodwill::PointsEarnedEvent"
          )
        end

        # --- happy path: an earn notifies the earner -------------------------

        test "a direct Ledger.award earn notifies the earner once" do
          perform_enqueued_jobs do
            Decidim::Bih::Goodwill::Ledger.award(@user, 100, reason: "volunteer_hour")
          end

          notifications = earned_notifications_for(@user)
          assert_equal 1, notifications.count
          notification = notifications.first
          assert_equal @user.id, notification.decidim_resource_id
          assert_equal 100, notification.extra["amount"]
          assert_equal "volunteer_hour", notification.extra["reason"]
        end

        test "an EarningRules.award earn notifies the earner once" do
          component = FactoryBot.create(:proposal_component, organization: @organization)
          proposal = FactoryBot.create(:proposal, component:, users: [@user], published_at: Time.current)
          perform_enqueued_jobs do
            EarningRules.new.award(@user, :proposal, idempotency_key: IdempotencyKey.proposal(proposal.id, @user.id))
          end

          assert_equal 1, earned_notifications_for(@user).count
        end

        test "the notification title renders the amount and action label" do
          perform_enqueued_jobs do
            Decidim::Bih::Goodwill::Ledger.award(@user, 100, reason: "volunteer_hour")
          end

          notification = earned_notifications_for(@user).first
          title = notification.event_class_instance.notification_title
          assert_includes title, "100"
          # Action label comes from decidim.bih.goodwill.actions.volunteer_hour.
          assert_includes title, I18n.t("decidim.bih.goodwill.actions.volunteer_hour")
        end

        test "only the earner is notified, not other users" do
          perform_enqueued_jobs do
            Decidim::Bih::Goodwill::Ledger.award(@user, 20, reason: "report")
          end

          assert_equal 1, earned_notifications_for(@user).count
          assert_equal 0, earned_notifications_for(@other).count
        end

        # --- idempotency: a dropped (duplicate) award does NOT re-notify ------

        test "an idempotency-dropped award does not notify a second time" do
          perform_enqueued_jobs do
            first = Decidim::Bih::Goodwill::Ledger.award(@user, 20, reason: "report", idempotency_key: "dup")
            assert_not_nil first
            second = Decidim::Bih::Goodwill::Ledger.award(@user, 20, reason: "report", idempotency_key: "dup")
            assert_nil second, "the duplicate award must be dropped"
          end

          assert_equal 1, earned_notifications_for(@user).count
        end

        # --- non-earn postings must NEVER notify -----------------------------

        test "a gift (wallet transfer) does not notify" do
          # Fund the giver via an earn first, then clear that earn's notification.
          Decidim::Bih::Goodwill::Ledger.award(@user, 50, reason: "volunteer_hour")
          recipient = FactoryBot.create(:user, :confirmed, organization: @organization,
                                                           extended_data: { "group" => true })

          perform_enqueued_jobs do
            @ledger.transfer(from_owner: @user, to_owner: recipient, amount: 10, kind: "gift")
          end

          # No NEW earned notification from the transfer (the earn above is async
          # but not under perform_enqueued_jobs, so it never enqueued here).
          assert_equal 0, earned_notifications_for(recipient).count
        end

        test "a redeem (wallet spend) does not notify" do
          Decidim::Bih::Goodwill::Ledger.award(@user, 50, reason: "volunteer_hour")

          perform_enqueued_jobs do
            @ledger.spend(owner: @user, amount: 10, kind: "redeem")
          end

          # Only earns notify; the spend adds nothing.
          assert_equal 0, earned_notifications_for(@user).count
        end

        test "an adjustment (reversal) does not notify" do
          earn = Decidim::Bih::Goodwill::Ledger.award(@user, 20, reason: "report")

          perform_enqueued_jobs do
            @ledger.reverse(earn)
          end

          assert_equal 0, earned_notifications_for(@user).count
        end

        # --- resilience: a failing publish must not break the award ----------

        test "a failing notification publish does not break or roll back the award" do
          Decidim::EventsManager.stub(:publish, ->(*) { raise "boom" }) do
            transaction = nil
            assert_nothing_raised do
              transaction = Decidim::Bih::Goodwill::Ledger.award(@user, 100, reason: "volunteer_hour")
            end
            assert_not_nil transaction, "the award must still succeed"
          end

          # The points landed even though the notification raised.
          assert_equal 100, @ledger.account_for(@user).contribution_score
        end
      end
    end
  end
end
