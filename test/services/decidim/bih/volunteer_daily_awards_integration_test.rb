# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    class VolunteerDailyAwardsIntegrationTest < ActiveSupport::TestCase
      setup do
        @previous_unit = Decidim::Bih.volunteer_work_award_unit
        Decidim::Bih.volunteer_work_award_unit = :day
        travel_to Time.utc(2026, 11, 1, 12)
        @organization = create_organization(badges_enabled: false)
        @citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
        @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
        @first = opportunity("Park")
        @second = opportunity("Biblioteka")
        @first_signup = approved_signup(@first)
        @second_signup = approved_signup(@second)
      end

      teardown do
        Decidim::Bih.volunteer_work_award_unit = @previous_unit
        travel_back
      end

      test "historic approved work remains readable and editable without invented dates" do
        legacy = create_legacy_volunteer_log!(
          organization: @organization, opportunity: @first, user: @citizen,
          hours: 1, status: "approved"
        )
        assert_nil legacy.reload.work_date
        assert legacy.update!(hours: 2)

        fresh = VolunteerLog.new(
          organization: @organization, opportunity: @first, user: @citizen,
          hours: 1, status: "approved"
        )
        assert_not fresh.valid?
        assert_includes fresh.errors.attribute_names, :work_date

        fresh.status = "rejected"
        assert_not fresh.valid?
        assert_includes fresh.errors.attribute_names, :work_date
      end

      test "distinct opportunities and retries pay one base award on a local date" do
        date = Date.new(2026, 9, 24)
        attend(@first_signup, date)
        attend(@second_signup, date)
        one = claim(@first, date, "09:00", "10:00")
        two = claim(@second, date, "14:00", "16:00")

        assert_equal :ok, VerifyVolunteerLog.call(one, verifier: @admin)
        assert_equal :ok, VerifyVolunteerLog.call(two, verifier: @admin)
        assert_equal :already, VerifyVolunteerLog.call(one.reload, verifier: @admin)
        assert_equal 100, account.contribution_score
        assert_equal 1, Goodwill::Transaction.where(organization: @organization, reason: "volunteer_day").count
        assert_equal 3, VolunteerLog.approved.where(organization: @organization, user: @citizen).sum(:hours)
      end

      test "correcting one claim retains the day and correcting the last reverses it" do
        date = Date.new(2026, 9, 24)
        attend(@first_signup, date)
        attend(@second_signup, date)
        one = claim(@first, date, "09:00", "10:00")
        two = claim(@second, date, "14:00", "16:00")
        assert_equal :ok, VerifyVolunteerLog.call(one, verifier: @admin)
        assert_equal :ok, VerifyVolunteerLog.call(two, verifier: @admin)

        assert_equal :ok, CorrectVolunteerLog.call(one, verifier: @admin, reason: "Pogrešan termin")
        assert_equal 100, account.contribution_score
        assert daily_award(date).active?

        assert_equal :ok, CorrectVolunteerLog.call(two, verifier: @admin, reason: "Dupli unos")
        assert_equal 0, account.contribution_score
        assert_equal 0, account.balance
        assert_not daily_award(date).active?
        correction = Goodwill::CreditCorrection.find_by!(original_transaction_id: daily_award(date).transaction_id)
        assert_equal 0, correction.target_amount
        assert_equal(-100, correction.recognition_delta)
        assert_equal "settled", correction.settlement.status
        assert_equal(-100, correction.settlement.wallet_delta)

        replacement = claim(@first, date, "11:00", "12:00")
        assert_equal :ok, VerifyVolunteerLog.call(replacement, verifier: @admin)
        assert_equal 100, account.contribution_score
        assert_equal 2, daily_award(date).version
      end

      test "Sarajevo date wins over UTC date at midnight" do
        date = Date.new(2026, 9, 25)
        attend(@first_signup, date)
        log = claim(@first, date, "00:30", "01:30")
        assert_equal Date.new(2026, 9, 24), log.worked_from_at.utc.to_date

        assert_equal :ok, VerifyVolunteerLog.call(log, verifier: @admin)
        assert_equal 100, account.contribution_score
        assert_equal "volunteer_day:#{@citizen.id}:2026-09-25", daily_transaction.idempotency_key
      end

      test "autumn daylight-saving change records three elapsed hours for one date" do
        date = Date.new(2026, 10, 25)
        attend(@first_signup, date)
        log = claim(@first, date, "01:30", "03:30")
        assert_equal 3, (log.worked_until_at - log.worked_from_at) / 3600

        assert_equal :ok, VerifyVolunteerLog.call(log, verifier: @admin)
        assert_equal 100, account.contribution_score
      end

      test "work without dated attendance cannot be paid or self-verified" do
        date = Date.new(2026, 9, 25)
        log = claim(@first, date, "09:00", "10:00")
        assert_equal :invalid, VerifyVolunteerLog.call(log, verifier: @admin)
        assert_equal 0, account.contribution_score

        attend(@first_signup, date)
        assert_equal :invalid, VerifyVolunteerLog.call(log, verifier: @citizen)
        assert log.reload.pending?
      end

      test "combined attendance and verification persist separate audit facts" do
        date = Date.new(2026, 9, 25)
        log = claim(@first, date, "09:00", "10:00")
        assert_equal :ok, VerifyVolunteerLog.call(log, verifier: @admin, confirm_attendance: true)
        assert VolunteerAttendance.confirmed.exists?(signup: @first_signup, work_date: date)
        assert OperatorAuditEvent.where(organization: @organization,
                                        event_type: "volunteering_dated_attendance_confirmed").exists?
        assert OperatorAuditEvent.where(organization: @organization,
                                        event_type: "volunteer_log_verified", resource_id: log.id).exists?
      end

      test "fractional actual hours keep the funded hourly bonus and its reversal separate" do
        group = FactoryBot.create(:user, :confirmed, organization: @organization,
                                                     name: "Volonterska organizacija",
                                                     extended_data: { "group" => true })
        profile = PartnerProfile.create!(organization: @organization,
                                         display_name: "Volonterska organizacija",
                                         slug: "volonterska-organizacija",
                                         kind: "association", verification_status: "verified",
                                         legacy_user_group: group, verified_at: Time.current)
        Goodwill::Ledger.new.award(group, 100, reason: "gift")
        @first.update!(partner_profile: profile, org_bonus_points_per_hour: 50,
                       org_bonus_budget_cap: 1_000, org_bonus_recognition: "cleanup")
        date = Date.new(2026, 9, 24)
        attend(@first_signup, date)
        log = claim(@first, date, "09:00", "10:30")

        assert_equal :ok, VerifyVolunteerLog.call(log, verifier: @admin)
        assert_equal 100, account.contribution_score
        assert_equal 175, account.balance
        assert_equal 25, Goodwill::Ledger.new.account_for(group).reload.balance
        assert_equal 75, @first.reload.org_bonus_awarded_points

        assert_equal :ok, CorrectVolunteerLog.call(log, verifier: @admin, reason: "Pogrešan interval")
        assert_equal 0, account.contribution_score
        assert_equal 0, account.balance
        assert_equal 100, Goodwill::Ledger.new.account_for(group).reload.balance
        assert_equal 0, @first.reload.org_bonus_awarded_points
      end

      test "an unfunded organization bonus stays unpaid and can settle on retry without doubling base points" do
        group = FactoryBot.create(:user, :confirmed, organization: @organization,
                                                     name: "Neprofitna grupa",
                                                     extended_data: { "group" => true })
        profile = PartnerProfile.create!(organization: @organization,
                                         display_name: "Neprofitna grupa", slug: "neprofitna-grupa",
                                         kind: "association", verification_status: "verified",
                                         legacy_user_group: group, verified_at: Time.current)
        @first.update!(partner_profile: profile, org_bonus_points_per_hour: 50,
                       org_bonus_budget_cap: 1_000, org_bonus_recognition: "cleanup")
        date = Date.new(2026, 9, 24)
        attend(@first_signup, date)
        log = claim(@first, date, "09:00", "10:30")

        assert_equal :ok, VerifyVolunteerLog.call(log, verifier: @admin)
        assert_equal 100, account.balance
        assert_not Goodwill::Transaction.where(organization: @organization,
                                               reason: "volunteer_org_bonus").exists?

        commitment = Goodwill::VolunteerBonusCommitment.find_by!(log:)
        assert_equal "unfunded", commitment.status
        assert_equal 75, commitment.outstanding_points
        Goodwill::Ledger.new.award(group, 100, reason: "gift")
        assert_equal :already, VerifyVolunteerLog.call(log.reload, verifier: @admin)
        assert_equal 100, account.balance, "repeating hours review cannot trigger a finance retry"
        assert_nil Goodwill::VolunteerOrgBonus.retry(log, actor: @citizen, reason: "Retry")
        assert Goodwill::VolunteerOrgBonus.retry(log, actor: @admin, reason: "Sredstva su dopunjena")
        assert Goodwill::VolunteerOrgBonus.retry(log, actor: @admin, reason: "Ponovljeni zahtjev")
        assert_equal "paid", commitment.reload.status
        assert_equal 175, account.balance
        assert_equal 100, account.contribution_score
        assert_equal 1, Goodwill::Transaction.where(organization: @organization,
                                                    reason: "volunteer_org_bonus").count
      end

      test "partial bonus installments settle once and correcting the claim reverses every installment" do
        group = bonus_offer(funds: 30)
        log = approved_bonus_claim
        commitment = Goodwill::VolunteerBonusCommitment.find_by!(log:)
        assert_equal "partially_paid", commitment.status
        assert_equal 30, commitment.current_paid_points
        assert_equal 45, commitment.outstanding_points
        Goodwill::Ledger.new.award(group, 45, reason: "test_bonus_funding")
        Goodwill::VolunteerOrgBonus.retry(log, actor: @admin, reason: "Dopuna")
        Goodwill::VolunteerOrgBonus.retry(log, actor: @admin, reason: "Provjera ponavljanja")
        assert_equal 2, commitment.payments.count
        assert_equal 75, commitment.reload.current_paid_points
        assert_equal 175, account.balance
        assert_equal 100, account.contribution_score
        assert_equal :ok, CorrectVolunteerLog.call(log, verifier: @admin, reason: "Pogrešan rad")
        assert_equal "reversed", commitment.reload.status
        assert_equal 0, commitment.current_paid_points
        assert_equal 0, account.balance
        assert_equal 75, Goodwill::Ledger.new.account_for(group).reload.balance
        assert_equal 0, @first.reload.org_bonus_awarded_points
        assert_nil Goodwill::VolunteerOrgBonus.call(log.reload)
      end

      test "an explicit payment reversal never silently reopens the same bonus claim" do
        bonus_offer(funds: 100)
        log = approved_bonus_claim
        commitment = Goodwill::VolunteerBonusCommitment.find_by!(log:)
        Goodwill::Ledger.new.reverse(commitment.payments.sole, actor: @admin)
        assert_equal "reversed", commitment.effective_status
        assert_nil Goodwill::VolunteerOrgBonus.retry(log, actor: @admin, reason: "Provjera")
        assert_equal 1, commitment.payments.count
        assert_equal 100, account.balance
        assert_equal 0, @first.reload.org_bonus_awarded_points
      end

      test "spent bonus correction records pending recovery without making a negative wallet" do
        bonus_offer(funds: 100)
        log = approved_bonus_claim
        Goodwill::Ledger.new.spend(owner: @citizen, amount: 175, kind: "redeem", reason: "test_spend")
        assert_equal :ok, CorrectVolunteerLog.call(log, verifier: @admin, reason: "Netačan rad")
        commitment = Goodwill::VolunteerBonusCommitment.find_by!(log:)
        assert_equal "admin_pending", commitment.status
        assert_equal 75, commitment.current_paid_points
        assert_equal 0, account.balance
        assert_nil Goodwill::VolunteerOrgBonus.call(log.reload)
        Goodwill::Ledger.new.award(@citizen, 75, reason: "test_recovery_funds")
        Goodwill::VolunteerOrgBonus.retry(log, actor: @admin, reason: "Poravnanje povrata")
        assert_equal "reversed", commitment.reload.status
        assert_equal 0, commitment.current_paid_points
        assert_equal 0, account.balance
      end

      test "participant limit counts people while repeat logs preserve an admitted person's eligibility" do
        bonus_offer(funds: 300, participants: 1)
        first = approved_bonus_claim
        second = claim(@first, first.work_date, "11:00", "12:00")
        assert_equal :ok, VerifyVolunteerLog.call(second, verifier: @admin)
        assert_equal 225, account.balance
        assert_equal 100, account.contribution_score
        other = FactoryBot.create(:user, :confirmed, organization: @organization)
        outsider = VolunteerLog.create!(organization: @organization, opportunity: @first, user: other,
                                        work_date: first.work_date, worked_from_at: first.worked_from_at, worked_until_at: first.worked_until_at,
                                        hours: first.hours, status: "approved")
        assert_nil Goodwill::VolunteerOrgBonus.call(outsider)
        assert_equal "participant_limit", Goodwill::VolunteerBonusCommitment.find_by!(log: outsider).status
        assert_equal 125, @first.reload.org_bonus_awarded_points
      end

      test "finance retries reject another organization and missing reasons" do
        bonus_offer(funds: 0)
        log = approved_bonus_claim
        foreign = FactoryBot.create(:user, :admin, :confirmed, organization: create_organization)
        assert_nil Goodwill::VolunteerOrgBonus.retry(log, actor: foreign, reason: "Retry")
        assert_nil Goodwill::VolunteerOrgBonus.retry(log, actor: @admin, reason: " ")
        assert_equal "unfunded", Goodwill::VolunteerBonusCommitment.find_by!(log:).status
      end

      private

      def bonus_offer(funds:, participants: nil)
        group = FactoryBot.create(:user, :confirmed, organization: @organization,
                                                     name: "Bonus organization", extended_data: { "group" => true })
        profile = PartnerProfile.create!(organization: @organization, display_name: "Bonus organization",
                                         slug: "bonus-#{group.id}", kind: "association", verification_status: "verified",
                                         legacy_user_group: group, verified_at: Time.current)
        @first.update!(partner_profile: profile, org_bonus_points_per_hour: 50,
                       org_bonus_budget_cap: 1_000, org_bonus_max_participants: participants)
        Goodwill::Ledger.new.award(group, funds, reason: "test_bonus_funding") if funds.positive?
        group
      end

      def approved_bonus_claim
        date = Date.new(2026, 9, 24)
        attend(@first_signup, date)
        log = claim(@first, date, "09:00", "10:30")
        assert_equal :ok, VerifyVolunteerLog.call(log, verifier: @admin)
        log
      end

      def opportunity(title)
        VolunteerOpportunity.create!(organization: @organization, title:, active: true,
                                     review_status: "approved",
                                     starts_at: local_time(Date.new(2026, 9, 1), "00:00"),
                                     ends_at: local_time(Date.new(2026, 12, 1), "23:00"))
      end

      def approved_signup(opportunity)
        VolunteerSignup.create!(organization: @organization, opportunity:, user: @citizen,
                                status: "going", review_status: "approved", review_source: "admin",
                                reviewer: @admin, reviewed_at: Time.current,
                                first_session_at: opportunity.starts_at)
      end

      def attend(signup, date)
        assert_equal :confirmed,
                     ConfirmVolunteerAttendance.call(signup, confirmer: @admin, work_date: date).status
      end

      def claim(opportunity, date, from, until_time)
        started = local_time(date, from)
        finished = local_time(date, until_time)
        VolunteerLog.create!(organization: @organization, opportunity:, user: @citizen,
                             work_date: date, worked_from_at: started, worked_until_at: finished,
                             hours: (finished - started) / 3600, status: "pending")
      end

      def local_time(date, clock)
        Time.find_zone!("Europe/Sarajevo").parse("#{date.iso8601} #{clock}")
      end

      def account
        Goodwill::Ledger.new.account_for(@citizen).reload
      end

      def daily_award(date)
        VolunteerDailyAward.find_by!(organization: @organization, user: @citizen, work_date: date)
      end

      def daily_transaction
        Goodwill::Transaction.find_by!(organization: @organization, reason: "volunteer_day")
      end
    end
  end
end
