# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module Goodwill
      class ReferralsTest < ActiveSupport::TestCase
        setup do
          @now = Time.iso8601("2026-09-27T12:00:00+02:00")
          travel_to @now
          @organization = create_organization
          @referrer = FactoryBot.create(:user, :confirmed, organization: @organization, nickname: "ana")
          @invitee = FactoryBot.create(:user, :confirmed, organization: @organization, nickname: "bojan", created_at: 3.days.ago)
          @area = Decidim::Bih::LocalArea.create!(organization: @organization, kind: "komsiluk",
                                                slug: "referral-area", name: { "sr" => "Komšiluk" }, zona: "grad")
        end

        teardown do
          travel_back
        end

        test "attribute links an invitee to the referrer by code" do
          referral = Referrals.attribute(invitee: @invitee, code: "ana")
          assert referral
          assert_equal @referrer.id, referral.referrer_id
          assert_equal "pending", referral.status
        end

        test "attribute rejects self-referral, unknown code, and double attribution" do
          assert_nil Referrals.attribute(invitee: @invitee, code: "bojan")
          assert_nil Referrals.attribute(invitee: @invitee, code: "nobody")

          Referrals.attribute(invitee: @invitee, code: "ana")
          assert_nil Referrals.attribute(invitee: @invitee, code: "ana")
        end

        test "phone verification and neighborhood choice pay exactly once after the delay without an earn requirement" do
          referral = attribute_earlier(@invitee)
          verify_phone(@invitee)
          choose_neighborhood(@invitee)
          assert_equal 0, Ledger.new.account_for(@invitee).contribution_score

          assert_equal referral, Referrals.reward(@invitee)
          assert_equal 25, Ledger.new.account_for(@referrer).contribution_score
          assert_equal "rewarded", referral.reload.status
          assert_equal 25, referral.ledger_transaction.credited_amount

          assert_nil Referrals.reward(@invitee)
          assert_equal 25, Ledger.new.account_for(@referrer).contribution_score
          assert_equal 1, Transaction.where(organization: @organization, reason: "referral").count
        end

        test "reward is a no-op without a pending referral" do
          assert_nil Referrals.reward(@invitee)
          assert_equal 0, Ledger.new.account_for(@referrer).contribution_score
        end

        test "unverified invitees remain pending even with a neighborhood and earned points" do
          referral = attribute_earlier(@invitee)
          choose_neighborhood(@invitee)
          Ledger.new.award(@invitee, 5, reason: "comment", idempotency_key: "c:1")

          assert_equal :pending_activity, Referrals.reward(@invitee)
          assert_equal ["pending", "waiting_eligibility"], [referral.reload.status, referral.pending_reason]
          assert_equal 0, Ledger.new.account_for(@referrer).contribution_score
        end

        test "phone verification and its welcome award do not replace choosing a neighborhood" do
          referral = attribute_earlier(@invitee)
          verify_phone(@invitee)
          Ledger.new.award(@invitee, 10, reason: "verification", idempotency_key: "verification:#{@invitee.id}")

          assert_equal :pending_activity, Referrals.reward(@invitee)
          assert_equal "waiting_eligibility", referral.reload.pending_reason
          assert_equal 0, Ledger.new.account_for(@referrer).contribution_score

          choose_neighborhood(@invitee)
          assert_equal referral, Referrals.reward(@invitee)
          assert_equal 25, Ledger.new.account_for(@referrer).contribution_score
        end

        test "the delay starts after both attribution and phone verification" do
          referral = attribute_earlier(@invitee)
          verify_phone(@invitee, at: @now - 1.hour)
          choose_neighborhood(@invitee)

          assert_equal :pending_activity, Referrals.reward(@invitee)
          assert_equal "waiting_delay", referral.reload.pending_reason
          assert_equal @now + 23.hours, referral.next_attempt_at
          assert_equal 0, Ledger.new.account_for(@referrer).contribution_score

          travel_to @now + 23.hours
          assert_equal referral, Referrals.reward(@invitee)
          assert_equal 25, Ledger.new.account_for(@referrer).contribution_score
        end

        test "ten actual monthly payments leave the oldest eligible overflow queued for the Sarajevo month boundary" do
          referrals = (0..Referrals::MONTHLY_CAP).map do |index|
            invitee = FactoryBot.create(:user, :confirmed, organization: @organization,
                                        nickname: "inv#{index}", created_at: 3.days.ago)
            row = attribute_earlier(invitee, at: @now - 2.days + index.minutes)
            verify_phone(invitee)
            choose_neighborhood(invitee)
            row
          end
          overflow = referrals.last

          assert_equal :pending_activity, Referrals.reward(overflow.invitee)
          assert referrals.first(Referrals::MONTHLY_CAP).all? { |row| row.reload.status == "rewarded" }
          assert_equal ["pending", "carryover"], [overflow.reload.status, overflow.pending_reason]
          assert_equal Time.iso8601("2026-10-01T00:00:00+02:00"), overflow.next_attempt_at
          assert_equal 250, Ledger.new.account_for(@referrer).contribution_score

          assert_equal :pending_activity, Referrals.reward(overflow.invitee)
          assert_equal 10, Transaction.where(organization: @organization, reason: "referral").count
          travel_to overflow.next_attempt_at + 1.second
          assert_equal overflow, Referrals.reward(overflow.invitee)
          assert_equal Time.current, overflow.reload.rewarded_at
          assert_equal 275, Ledger.new.account_for(@referrer).contribution_score
          assert_equal 11, Transaction.where(organization: @organization, reason: "referral").count
        end

        private

        def attribute_earlier(invitee, at: @now - 2.days)
          Referrals.attribute(invitee:, code: "ana").tap { |referral| referral.update!(created_at: at) }
        end

        def verify_phone(invitee, at: @now - 2.days)
          Decidim::Authorization.create!(user: invitee, name: "sms", unique_id: SecureRandom.hex(12), granted_at: at)
        end

        def choose_neighborhood(invitee)
          Decidim::Bih::CitizenProfile.create!(organization: @organization, user: invitee,
                                               komsiluk: @area, source: "registration", assigned_at: @now - 2.days)
        end
      end
    end
  end
end
