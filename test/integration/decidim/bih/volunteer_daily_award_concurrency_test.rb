# frozen_string_literal: true

require "test_helper"
require "timeout"

module Decidim
  module Bih
    # Independent committed fixtures let the two workers use separate real PG
    # sessions. Cleanup is scoped to this test's disposable organization.
    class VolunteerDailyAwardConcurrencyTest < ActiveSupport::TestCase
      self.use_transactional_tests = false

      setup do
        @previous_unit = Decidim::Bih.volunteer_work_award_unit
        Decidim::Bih.volunteer_work_award_unit = :day
        travel_to Time.utc(2026, 11, 1, 12)
        @organization = create_organization(badges_enabled: false)
        @citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
        @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
        @work_date = Date.new(2026, 9, 24)
        @logs = [["Park", "09:00", "10:00"], ["Biblioteka", "14:00", "16:00"]].map do |title, from, until_time|
          opportunity = VolunteerOpportunity.create!(
            organization: @organization, title:, active: true, review_status: "approved",
            starts_at: local_time(Date.new(2026, 9, 1), "00:00"),
            ends_at: local_time(Date.new(2026, 12, 1), "23:00")
          )
          signup = VolunteerSignup.create!(
            organization: @organization, opportunity:, user: @citizen,
            status: "going", review_status: "approved", review_source: "admin",
            reviewer: @admin, reviewed_at: Time.current, first_session_at: opportunity.starts_at
          )
          assert_equal :confirmed,
                       ConfirmVolunteerAttendance.call(signup, confirmer: @admin, work_date: @work_date).status
          started = local_time(@work_date, from)
          finished = local_time(@work_date, until_time)
          VolunteerLog.create!(organization: @organization, opportunity:, user: @citizen,
                               work_date: @work_date, worked_from_at: started, worked_until_at: finished,
                               hours: (finished - started) / 3600, status: "pending")
        end
      end

      teardown do
        if @organization
          Decidim::Notification.where(decidim_user_id: [@citizen&.id, @admin&.id].compact).delete_all
          OperatorAuditEvent.where(organization: @organization).delete_all
          VolunteerAttendance.where(organization: @organization).delete_all
          VolunteerLog.where(organization: @organization).delete_all
          VolunteerDailyAward.where(organization: @organization).delete_all
          VolunteerSignup.where(organization: @organization).delete_all
          VolunteerOpportunity.where(organization: @organization).delete_all
          Goodwill::Entry.where(organization: @organization).delete_all
          Goodwill::Transaction.where(organization: @organization).delete_all
          Goodwill::Account.where(organization: @organization).delete_all
          Decidim::Gamification::BadgeScore.where(user_id: [@citizen&.id, @admin&.id].compact).delete_all
          @citizen&.destroy!
          @admin&.destroy!
          @organization.static_pages.delete_all
          @organization.destroy!
        end
      ensure
        Decidim::Bih.volunteer_work_award_unit = @previous_unit
        travel_back
      end

      test "two simultaneous reviews on separate opportunities issue one daily award" do
        ready = Queue.new
        release = Queue.new
        threads = @logs.map do |log|
          Thread.new do
            ActiveRecord::Base.connection_pool.with_connection do |connection|
              connection.execute("SET lock_timeout = '5s'")
              connection.execute("SET statement_timeout = '10s'")
              ready << connection.select_value("SELECT pg_backend_pid()")
              release.pop
              VerifyVolunteerLog.call(VolunteerLog.find(log.id), verifier: Decidim::User.find(@admin.id))
            ensure
              connection.execute("RESET lock_timeout")
              connection.execute("RESET statement_timeout")
            end
          end
        end

        results = Timeout.timeout(20) do
          pids = threads.size.times.map { ready.pop }
          assert_equal threads.size, pids.uniq.size
          threads.size.times { release << true }
          threads.map(&:value)
        end
        assert_equal [:ok, :ok], results.sort
        assert_equal 2, VolunteerLog.approved.where(organization: @organization).count
        assert_equal 1, VolunteerDailyAward.where(organization: @organization,
                                                  user: @citizen, work_date: @work_date).count
        assert_equal 1, Goodwill::Transaction.where(organization: @organization,
                                                    reason: "volunteer_day").count
        assert_equal 100, Goodwill::Ledger.new.account_for(@citizen).reload.contribution_score
      ensure
        threads&.each { |thread| thread.kill if thread.alive? }
        threads&.each(&:join)
      end

      private

      def local_time(date, clock)
        Time.find_zone!("Europe/Sarajevo").parse("#{date.iso8601} #{clock}")
      end
    end
  end
end
