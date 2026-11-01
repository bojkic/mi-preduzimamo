# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module Goodwill
      # Item 2 — Verification closure: when a Decidim::Authorization is granted
      # for the first time (nil→timestamp), three things should happen:
      #   (a) :verified_citizen badge is set to 1 in real time
      #   (b) a one-time welcome bonus (action: "verification") is awarded
      #   (c) any pending referral is rewarded (existing behaviour, via ReferralRewardJob::REWARD_DELAY)
      # None of these should fire on a re-grant (granted_at already set).
      class VerificationAwardTest < ActiveSupport::TestCase
        include ActiveJob::TestHelper

        setup do
          @organization = create_organization(badges_enabled: false)
          @user = FactoryBot.create(:user, :confirmed, organization: @organization)
        end

        test "granting an authorization awards a one-time verification welcome bonus" do
          perform_enqueued_jobs do
            FactoryBot.create(:authorization, :granted, user: @user)
          end

          assert_equal 10, Ledger.new.account_for(@user).contribution_score,
                       "expected verification:10 points"
        end

        test "granting sets the verified_citizen badge score to 1" do
          FactoryBot.create(:authorization, :granted, user: @user)

          score = Decidim::Gamification.status_for(@user, :verified_citizen).score
          assert_equal 1, score
        end

        test "re-granting an existing authorization does NOT re-award" do
          # First: perform the initial grant and drain its jobs
          perform_enqueued_jobs do
            FactoryBot.create(:authorization, :granted, user: @user)
          end
          assert_equal 10, Ledger.new.account_for(@user).contribution_score

          # Now simulate a re-save of the already-granted auth.
          # The guard `granted_at_transitioned_from_nil?` must prevent a second award.
          auth = Decidim::Authorization.last
          perform_enqueued_jobs do
            # Re-save with granted_at already set — the guard must block a second award.
            # We reload to get a fresh AR object, then call save! which fires after_save.
            # saved_changes["granted_at"].first will be the existing timestamp (not nil).
            auth.reload.save!
          end

          assert_equal 10, Ledger.new.account_for(@user).contribution_score,
                       "re-save of already-granted auth must not award again"
        end

        test "verification welcome is idempotent (explicit key test)" do
          perform_enqueued_jobs do
            FactoryBot.create(:authorization, :granted, user: @user)
          end
          # Retry the same source through the earning rules, which preserve
          # the original admission and its immutable ledger request metadata.
          result = EarningRules.new.award(
            @user, :verification,
            idempotency_key: "verification:#{@user.id}"
          )
          assert_nil result, "second award with same idempotency key must be nil"
          assert_equal 10, Ledger.new.account_for(@user).contribution_score
        end
      end
    end
  end
end
