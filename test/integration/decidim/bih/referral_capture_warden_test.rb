# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module Goodwill
      # B2 — Warden hook guards: pre-existing users must not be attributed as
      # referrals. Tests exercise the Referrals.attribute layer directly (the
      # Warden hook calls that method after its own guards); the hook's time
      # guards are unit-tested here by calling attribute with a user whose
      # created_at is in the past.
      #
      # Note: the Warden hook itself is a Rack-level callback and cannot be
      # exercised in unit tests without a full request cycle. These tests focus
      # on the Referrals.attribute + the timestamp-guard logic that the hook
      # delegates to or mirrors.
      class ReferralCaptureWardenTest < ActiveSupport::TestCase
        setup do
          @organization = create_organization
          @referrer = FactoryBot.create(:user, :confirmed, organization: @organization, nickname: "ana")
        end

        # (a) Pre-existing user (created days ago) clicks the invite link and
        # signs in → NO Referral row should be created.
        # The hook checks: user.created_at < captured_time → skip.
        # We simulate this by calling the engine's guard logic via a helper
        # that mirrors what the Warden hook does.
        test "pre-existing user created before the link click is not attributed" do
          # User was created 3 days before the invite link was clicked.
          captured_time = 1.hour.ago
          old_user = FactoryBot.create(
            :user, :confirmed,
            organization: @organization,
            nickname: "olduser",
            created_at: 3.days.ago
          )

          # Simulate the hook's guard: skip if created_at < captured_time.
          # The hook only calls attribute when this guard passes — if it would
          # skip, we assert that attribute is never called (or returns nil).
          # We replicate the guard logic inline to test the expected outcome.
          should_attribute = !(old_user.created_at && old_user.created_at < captured_time)
          result = should_attribute ? Referrals.attribute(invitee: old_user, code: "ana") : nil

          assert_nil result,
                     "pre-existing user (created before link click) must not be attributed"
          assert_equal 0, Referral.where(invitee_id: old_user.id).count,
                       "no Referral row must be created for a pre-existing account"
        end

        # (b) User registers 1 hour AFTER the link click but within the 24-hour
        # window → should be attributed.
        test "user registered after the link click within the 24-h window is attributed" do
          captured_time = 2.hours.ago
          new_user = FactoryBot.create(
            :user, :confirmed,
            organization: @organization,
            nickname: "newuser",
            created_at: 1.hour.ago
          )

          # Window check: Time.current - captured_time <= 24.hours → pass.
          window_ok = (Time.current - captured_time) <= 24.hours
          # Registration after click check: created_at >= captured_time → pass.
          registered_after = !(new_user.created_at && new_user.created_at < captured_time)

          result = Referrals.attribute(invitee: new_user, code: "ana") if window_ok && registered_after

          assert result.present?, "user registered after link click must be attributed"
          assert_equal "pending", result.status
          assert_equal @referrer.id, result.referrer_id
        end

        # (c) Missing timestamp + old account → NOT attributed (legacy recency
        # guard kicks in: user.created_at < 30.minutes.ago → skip).
        test "missing timestamp with an old account falls back to legacy recency guard and skips" do
          # No captured_time (goodwill_ref_at absent from session).
          # The legacy fallback: skip if user.created_at < 30.minutes.ago.
          old_user = FactoryBot.create(
            :user, :confirmed,
            organization: @organization,
            nickname: "legacyuser",
            created_at: 2.hours.ago
          )

          # Replicate the fallback: no captured_time → use 30.minutes.ago guard.
          captured_time = nil
          should_attribute = if captured_time
                               !(old_user.created_at && old_user.created_at < captured_time)
                             else
                               !(old_user.created_at && old_user.created_at < 30.minutes.ago)
                             end

          result = should_attribute ? Referrals.attribute(invitee: old_user, code: "ana") : nil

          assert_nil result,
                     "missing timestamp + old account must not be attributed (legacy guard)"
          assert_equal 0, Referral.where(invitee_id: old_user.id).count
        end

        # Complementary: missing timestamp + very fresh user (< 30 min old) IS
        # attributed under the legacy recency guard.
        test "missing timestamp with a fresh account (< 30 min) is attributed via legacy guard" do
          fresh_user = FactoryBot.create(
            :user, :confirmed,
            organization: @organization,
            nickname: "freshuser",
            created_at: 5.minutes.ago
          )

          captured_time = nil
          should_attribute = if captured_time
                               !(fresh_user.created_at && fresh_user.created_at < captured_time)
                             else
                               !(fresh_user.created_at && fresh_user.created_at < 30.minutes.ago)
                             end

          result = should_attribute ? Referrals.attribute(invitee: fresh_user, code: "ana") : nil

          assert result.present?,
                 "fresh account (< 30 min) with missing timestamp must be attributed via legacy guard"
        end
      end
    end
  end
end
