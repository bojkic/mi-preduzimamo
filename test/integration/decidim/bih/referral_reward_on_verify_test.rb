# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module Goodwill
      # Verification schedules settlement; the worker still rechecks the phone,
      # neighborhood and elapsed delay when it reaches the inviter's queue.
      class ReferralRewardOnVerifyTest < ActiveSupport::TestCase
        include ActiveJob::TestHelper

        setup do
          @now = Time.iso8601("2026-09-27T12:00:00+02:00")
          travel_to @now
          @organization = create_organization(badges_enabled: false)
          @referrer = FactoryBot.create(:user, :confirmed, organization: @organization, nickname: "ana")
          @invitee = FactoryBot.create(:user, :confirmed, organization: @organization, nickname: "bojan")
          Referrals.attribute(invitee: @invitee, code: "ana")
        end

        teardown do
          travel_back
        end

        test "verification schedules a referral payment after the delay when a neighborhood is selected" do
          area = Decidim::Bih::LocalArea.create!(organization: @organization, kind: "komsiluk",
                                                slug: "referral-hook", name: { "sr" => "Komšiluk" }, zona: "grad")
          Decidim::Bih::CitizenProfile.create!(organization: @organization, user: @invitee,
                                               komsiluk: area, source: "registration", assigned_at: @now)
          perform_enqueued_jobs(only: GoodwillAwardJob) { grant_phone }
          assert_equal 0, Ledger.new.account_for(@referrer).contribution_score

          travel_to @now + ReferralRewardJob::REWARD_DELAY
          perform_enqueued_jobs(only: ReferralRewardJob, at: Time.current)

          assert_equal 25, Ledger.new.account_for(@referrer).contribution_score
          assert_equal "rewarded", Referral.find_by(invitee_id: @invitee.id).status
        end

        test "verification without a neighborhood leaves the referral pending after the delay" do
          perform_enqueued_jobs(only: GoodwillAwardJob) { grant_phone }
          travel_to @now + ReferralRewardJob::REWARD_DELAY
          perform_enqueued_jobs(only: ReferralRewardJob, at: Time.current)

          assert_equal 0, Ledger.new.account_for(@referrer).contribution_score
          referral = Referral.find_by!(invitee_id: @invitee.id)
          assert_equal ["pending", "waiting_eligibility"], [referral.status, referral.pending_reason]
        end

        test "the referral job is enqueued with the REWARD_DELAY on verification" do
          assert_equal 24.hours, ReferralRewardJob::REWARD_DELAY
          grant_phone

          job = enqueued_jobs.find { |entry| entry["job_class"] == ReferralRewardJob.name }
          assert job, "ReferralRewardJob must be enqueued on verification"
          scheduled_at = job["scheduled_at"] && Time.zone.parse(job["scheduled_at"].to_s)
          enqueued_at = Time.zone.parse(job["enqueued_at"].to_s)
          assert_in_delta ReferralRewardJob::REWARD_DELAY, scheduled_at - enqueued_at, 1
        end

        test "a welcome award already paid before the referral worker does not replace a missing neighborhood" do
          perform_enqueued_jobs(only: GoodwillAwardJob) { grant_phone }
          assert_equal 10, Ledger.new.account_for(@invitee).contribution_score

          travel_to @now + ReferralRewardJob::REWARD_DELAY
          perform_enqueued_jobs(only: ReferralRewardJob, at: Time.current)

          assert_equal 0, Ledger.new.account_for(@referrer).contribution_score
          assert_equal "waiting_eligibility", Referral.find_by!(invitee_id: @invitee.id).pending_reason
        end

        private

        def grant_phone
          FactoryBot.create(:authorization, :granted, user: @invitee, name: "sms", unique_id: SecureRandom.hex(12))
        end
      end
    end
  end
end
