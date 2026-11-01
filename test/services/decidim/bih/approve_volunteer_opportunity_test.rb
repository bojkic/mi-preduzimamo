# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    class ApproveVolunteerOpportunityTest < ActiveSupport::TestCase
      setup do
        @old_proposal_unit = Decidim::Bih.volunteer_proposal_award_unit
        Decidim::Bih.volunteer_proposal_award_unit = :proposal
        @organization = create_organization
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

      teardown do
        Decidim::Bih.volunteer_proposal_award_unit = @old_proposal_unit
      end

      test "approves and publishes a pending opportunity with proposer points" do
        assert_equal :ok, ApproveVolunteerOpportunity.call(@opportunity, reviewer: @admin, confirm_partner: true)

        @opportunity.reload
        assert @opportunity.active?
        assert @opportunity.approved?
        assert_equal @admin.id, @opportunity.reviewed_by_id
        assert_not_nil @opportunity.reviewed_at
        assert_equal 25, Decidim::Bih::Goodwill::Ledger.new.account_for(@volunteer).contribution_score
      end

      test "approval is idempotent for already approved opportunities" do
        ApproveVolunteerOpportunity.call(@opportunity, reviewer: @admin, confirm_partner: true)
        assert_equal :already, ApproveVolunteerOpportunity.call(@opportunity.reload, reviewer: @admin, confirm_partner: true)

        assert_equal 25, Decidim::Bih::Goodwill::Ledger.new.account_for(@volunteer).contribution_score
      end

      test "all terms of a series share one proposer award" do
        @opportunity.update!(series_key: "weekly-proposal-1", series_position: 1, series_total: 2)
        second = @opportunity.dup
        second.series_position = 2
        second.save!

        assert_equal :ok, ApproveVolunteerOpportunity.call(@opportunity, reviewer: @admin, confirm_partner: true)
        assert_equal :ok, ApproveVolunteerOpportunity.call(second, reviewer: @admin, confirm_partner: true)

        assert_equal 25, Decidim::Bih::Goodwill::Ledger.new.account_for(@volunteer).contribution_score
        assert_equal 1, VolunteerProposalAward.where(organization: @organization,
                                                     proposal_identity: "series:weekly-proposal-1").count
      end

      test "an admin may publish their own proposal and earns once" do
        @opportunity.update!(author: @admin)

        assert_equal :ok, ApproveVolunteerOpportunity.call(@opportunity, reviewer: @admin, confirm_partner: true)
        assert_equal 25, Decidim::Bih::Goodwill::Ledger.new.account_for(@admin).contribution_score
      end

      test "a historic term award prevents a new proposal credit after cutover" do
        @opportunity.update!(series_key: "legacy-series-1", series_position: 2, series_total: 2)
        first_term = @opportunity.dup
        first_term.series_position = 1
        first_term.save!
        historical = Decidim::Bih::Goodwill::Ledger.new.award(
          @volunteer, 25, reason: "volunteer_opportunity",
          idempotency_key: "volunteer_opportunity:#{first_term.id}"
        )

        assert_equal :ok, ApproveVolunteerOpportunity.call(@opportunity, reviewer: @admin, confirm_partner: true)
        assert_equal 25, Decidim::Bih::Goodwill::Ledger.new.account_for(@volunteer).contribution_score
        marker = VolunteerProposalAward.find_by!(organization: @organization,
                                                 proposal_identity: "series:legacy-series-1")
        assert_equal historical.id, marker.legacy_transaction_id
      end
    end
  end
end
