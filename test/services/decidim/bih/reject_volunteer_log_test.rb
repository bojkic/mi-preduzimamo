# frozen_string_literal: true

require "test_helper"
require "minitest/mock"

module Decidim
  module Bih
    class RejectVolunteerLogTest < ActiveSupport::TestCase
      include ActiveJob::TestHelper

      setup do
        @organization = create_organization(badges_enabled: false)
        @volunteer = FactoryBot.create(:user, :confirmed, organization: @organization)
        @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
        @opportunity = VolunteerOpportunity.create!(
          organization: @organization, title: "Čišćenje parka", active: true
        )
        @log = create_legacy_volunteer_log!(
          organization: @organization, opportunity: @opportunity,
          user: @volunteer, hours: 3, status: "pending"
        )
      end

      test "rejects with reason, awards no points and notifies the volunteer" do
        perform_enqueued_jobs do
          assert_equal :ok,
                       RejectVolunteerLog.call(
                         @log,
                         verifier: @admin,
                         reason: "Nema potvrde organizatora"
                       )
        end

        @log.reload
        assert @log.rejected?
        assert_equal "Nema potvrde organizatora", @log.rejection_reason
        assert_equal @admin.id, @log.verified_by_id
        assert_equal 0, Decidim::Bih::Goodwill::Ledger.new.account_for(@volunteer).contribution_score
        notification = Decidim::Notification.where(
          decidim_user_id: @volunteer.id,
          event_class: "Decidim::Bih::VolunteerDecisionEvent"
        ).first
        assert_not_nil notification
        assert_equal "log", notification.extra["kind"]
        assert_equal "rejected", notification.extra["status"]
      end

      test "requires a rejection reason" do
        assert_equal :invalid, RejectVolunteerLog.call(@log, verifier: @admin, reason: "")

        assert @log.reload.pending?
        assert_nil @log.rejection_reason
      end

      test "notification failure does not roll back rejection" do
        Decidim::EventsManager.stub(:publish, ->(*) { raise "boom" }) do
          assert_equal :ok,
                       RejectVolunteerLog.call(
                         @log,
                         verifier: @admin,
                         reason: "Nema potvrde organizatora"
                       )
        end

        assert @log.reload.rejected?
        assert_equal "Nema potvrde organizatora", @log.rejection_reason
      end
    end
  end
end
