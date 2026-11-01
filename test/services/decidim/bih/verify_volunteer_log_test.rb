# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    class VerifyVolunteerLogTest < ActiveSupport::TestCase
      setup do
        @old_work_unit = Decidim::Bih.volunteer_work_award_unit
        Decidim::Bih.volunteer_work_award_unit = :day
        travel_to Time.utc(2026, 11, 1, 12)
        @organization = create_organization(badges_enabled: false)
        @volunteer = FactoryBot.create(:user, :confirmed, organization: @organization)
        @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
        @opportunity = VolunteerOpportunity.create!(
          organization: @organization, title: "Čišćenje parka", active: true,
          review_status: "approved", starts_at: local_time("2026-09-01 00:00"),
          ends_at: local_time("2026-12-01 23:00")
        )
        @signup = VolunteerSignup.create!(
          organization: @organization, opportunity: @opportunity, user: @volunteer,
          status: "going", review_status: "approved", review_source: "admin",
          reviewer: @admin, reviewed_at: Time.current, first_session_at: @opportunity.starts_at
        )
        attendance = ConfirmVolunteerAttendance.call(
          @signup, confirmer: @admin, work_date: Date.new(2026, 9, 24)
        )
        assert_equal :confirmed, attendance.status
        @log = VolunteerLog.create!(
          organization: @organization, opportunity: @opportunity,
          user: @volunteer, hours: 3, status: "pending", work_date: Date.new(2026, 9, 24),
          worked_from_at: local_time("2026-09-24 09:00"),
          worked_until_at: local_time("2026-09-24 12:00")
        )
      end

      teardown do
        Decidim::Bih.volunteer_work_award_unit = @old_work_unit
        travel_back
      end

      test "verifying three actual hours awards one base volunteering day" do
        assert_equal :ok, VerifyVolunteerLog.call(@log, verifier: @admin)

        @log.reload
        assert @log.approved?
        assert_equal @admin.id, @log.verified_by_id
        assert_not_nil @log.verified_at

        account = Decidim::Bih::Goodwill::Ledger.new.account_for(@volunteer)
        assert_equal 100, account.contribution_score
        assert_equal 100, account.balance
        assert_equal 1, VolunteerDailyAward.where(organization: @organization, user: @volunteer).count
      end

      test "double verification does not double-award (idempotent)" do
        VerifyVolunteerLog.call(@log, verifier: @admin)
        assert_equal :already, VerifyVolunteerLog.call(@log.reload, verifier: @admin)

        assert_equal 100, Decidim::Bih::Goodwill::Ledger.new.account_for(@volunteer).contribution_score
      end

      test "respects a tuned volunteer_day value" do
        original = Decidim::Bih.goodwill_earning_schedule
        Decidim::Bih.goodwill_earning_schedule = original.merge(volunteer_day: 10)

        VerifyVolunteerLog.call(@log, verifier: @admin)
        assert_equal 10, Decidim::Bih::Goodwill::Ledger.new.account_for(@volunteer).contribution_score
      ensure
        Decidim::Bih.goodwill_earning_schedule = original
      end

      test "verifying pays an organization-funded bonus without changing recognition" do
        group = FactoryBot.create(:user, :confirmed, organization: @organization,
                                                     name: "Udruženje volontera",
                                                     extended_data: { "group" => true })
        profile = Decidim::Bih::PartnerProfile.create!(
          organization: @organization,
          display_name: "Udruženje volontera",
          slug: "udruzenje-volontera",
          kind: "association",
          verification_status: "verified",
          legacy_user_group: group,
          verified_at: Time.current
        )
        Decidim::Bih::Goodwill::Ledger.new.award(group, 100, reason: "gift")
        @opportunity.update!(
          partner_profile: profile,
          org_bonus_points_per_hour: 5,
          org_bonus_budget_cap: 20,
          org_bonus_max_participants: 1,
          org_bonus_recognition: "cleanup"
        )

        assert_equal :ok, VerifyVolunteerLog.call(@log, verifier: @admin)

        ledger = Decidim::Bih::Goodwill::Ledger.new
        assert_equal 85, ledger.account_for(group).balance
        assert_equal 115, ledger.account_for(@volunteer).balance
        assert_equal 100, ledger.account_for(@volunteer).contribution_score
        assert_equal 15, @opportunity.reload.org_bonus_awarded_points

        bonus = Decidim::Bih::Goodwill::Transaction.find_by!(reason: "volunteer_org_bonus")
        assert_equal "cleanup", bonus.metadata["recognition"]
        assert_equal @log.id, bonus.metadata["volunteer_log_id"]
      end

      test "returns :missing for a blank log without awarding points" do
        assert_equal :missing, VerifyVolunteerLog.call(nil, verifier: @admin)

        assert_equal 0, Decidim::Bih::Goodwill::Ledger.new.account_for(@volunteer).contribution_score
      end

      test "returns :invalid for a log not in the verifiable state" do
        @log.update!(status: "rejected", rejection_reason: "Nema potvrde")

        assert_equal :invalid, VerifyVolunteerLog.call(@log, verifier: @admin)

        assert @log.reload.rejected?
        assert_equal 0, Decidim::Bih::Goodwill::Ledger.new.account_for(@volunteer).contribution_score
      end

      test "the shared-engine hourly mode still requires dated attendance" do
        Decidim::Bih.volunteer_work_award_unit = :hour
        another = VolunteerLog.create!(
          organization: @organization, opportunity: @opportunity, user: @volunteer,
          hours: 1, status: "pending", work_date: Date.new(2026, 9, 25),
          worked_from_at: local_time("2026-09-25 09:00"),
          worked_until_at: local_time("2026-09-25 10:00")
        )

        assert_equal :invalid, VerifyVolunteerLog.call(another, verifier: @admin)
        assert_equal 0, Decidim::Bih::Goodwill::Ledger.new.account_for(@volunteer).contribution_score

        assert_equal :ok, VerifyVolunteerLog.call(@log, verifier: @admin)
        assert_equal 300, Decidim::Bih::Goodwill::Ledger.new.account_for(@volunteer).contribution_score
        assert_equal 1, Goodwill::Transaction.where(organization: @organization, reason: "volunteer_hour").count
      end

      private

      def local_time(value)
        Time.find_zone!("Europe/Sarajevo").parse(value)
      end
    end
  end
end
