# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    class RejectVolunteerOpportunityTest < ActiveSupport::TestCase
      include ActiveJob::TestHelper

      setup do
        @organization = create_organization(badges_enabled: false)
        @volunteer = FactoryBot.create(:user, :confirmed, organization: @organization)
        @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
        @profile = PartnerProfile.create!(
          organization: @organization,
          display_name: "Udruženje pregled",
          slug: "udruzenje-pregled",
          kind: "association",
          verification_status: "verified",
          verified_at: Time.current
        )
        @opportunity = VolunteerOpportunity.create!(
          organization: @organization,
          author: @volunteer,
          title: "Pomoć na događaju",
          category: "community_care",
          partner_profile: @profile,
          partner_name: @profile.display_name,
          active: false,
          review_status: "pending"
        )
      end

      test "rejects with reason, awards no points and notifies the author" do
        perform_enqueued_jobs do
          assert_equal :ok,
                       RejectVolunteerOpportunity.call(
                         @opportunity,
                         reviewer: @admin,
                         reason: "Nedostaje lokacija"
                       )
        end

        @opportunity.reload
        assert @opportunity.rejected?
        assert_not @opportunity.active?
        assert_equal "Nedostaje lokacija", @opportunity.rejection_reason
        assert_equal @admin.id, @opportunity.reviewed_by_id
        assert_equal 0, Decidim::Bih::Goodwill::Ledger.new.account_for(@volunteer).contribution_score
        notification = Decidim::Notification.where(
          decidim_user_id: @volunteer.id,
          event_class: "Decidim::Bih::VolunteerDecisionEvent"
        ).first
        assert_not_nil notification
        assert_equal "opportunity", notification.extra["kind"]
        assert_equal "rejected", notification.extra["status"]
      end

      test "requires a rejection reason" do
        assert_equal :invalid, RejectVolunteerOpportunity.call(@opportunity, reviewer: @admin, reason: "")

        assert @opportunity.reload.pending_review?
        assert_nil @opportunity.rejection_reason
      end
    end
  end
end
