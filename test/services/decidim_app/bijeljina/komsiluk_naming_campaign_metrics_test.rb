# frozen_string_literal: true

require "test_helper"
require "decidim/participatory_processes/test/factories"
require "decidim/proposals/test/factories"

module DecidimApp
  module Bijeljina
    class KomsilukNamingCampaignMetricsTest < ActiveSupport::TestCase
      setup do
        @organization = create_organization
        create(:user, :admin, :confirmed, organization: @organization)
        @area_one = create_area("komsiluk-1", "Savino")
        @area_two = create_area("komsiluk-2", "Dašnica")
        @component = KomsilukNamingCampaignSetup.call(
          organization: @organization,
          nomination_start: Date.new(2026, 9, 1),
          nomination_end: Date.new(2026, 9, 21),
          voting_end: Date.new(2026, 10, 5)
        ).fetch(:component)
        @taxonomy_one = Decidim::Taxonomy.find(KomsilukNamingCampaign.taxonomy_id_for_area(@area_one))
        @taxonomy_two = Decidim::Taxonomy.find(KomsilukNamingCampaign.taxonomy_id_for_area(@area_two))
      end

      test "reports unique verified active participants and excludes ineligible activity" do
        author = eligible_user(@area_one)
        voter = eligible_user(@area_one)
        unverified_voter = assigned_user(@area_one)
        wrong_area_voter = eligible_user(@area_two)
        proposal = citizen_proposal(author, @taxonomy_one)

        create_vote(voter, proposal)
        create_vote(author, proposal)
        create_vote_without_campaign_validation(unverified_voter, proposal)
        create_vote_without_campaign_validation(wrong_area_voter, proposal)

        report = KomsilukNamingCampaignMetrics.call(organization: @organization)
        row = report.fetch(:areas).find { |item| item.fetch(:area_slug) == @area_one.slug }

        assert_equal 3, row.fetch(:assigned_members)
        assert_equal 2, row.fetch(:sms_verified_members)
        assert_equal 1, row.fetch(:citizen_proposals)
        assert_equal 2, row.fetch(:final_votes)
        assert_equal 2, row.fetch(:unique_voters)
        assert_equal 2, row.fetch(:verified_active_participants)
        assert_equal 2, report.dig(:totals, :verified_active_participants)
        assert_equal [@area_one.slug], report.fetch(:community_prize_leaders)

        serialized = report.to_json
        assert_no_match(/user_id|phone|address|coordinate|member_ids/, serialized)
      end

      test "does not shortlist an individual winner below the minimum local electorate" do
        author = eligible_user(@area_one)
        proposal = citizen_proposal(author, @taxonomy_one)
        eligible_user(@area_one).tap { |user| create_vote(user, proposal) }

        report = KomsilukNamingCampaignMetrics.call(organization: @organization)
        assert_empty report.fetch(:personal_prize_shortlist)
      end

      private

      def create_area(slug, name)
        Decidim::Bih::LocalArea.create!(
          organization: @organization,
          kind: "komsiluk",
          slug:,
          name: { "sr" => name }
        )
      end

      def assigned_user(area)
        user = create(:user, :confirmed, organization: @organization)
        Decidim::Bih::CitizenProfile.for_user(user, organization: @organization)
                                    .assign_komsiluk!(area, source: :dropdown)
        user
      end

      def eligible_user(area)
        assigned_user(area).tap do |user|
          create(:authorization, :granted, user:, name: "sms")
        end
      end

      def citizen_proposal(user, taxonomy)
        proposal = build(:proposal, component: @component, users: [user])
        proposal.taxonomies << taxonomy
        proposal.save!
        proposal
      end

      def create_vote(user, proposal)
        Decidim::Proposals::ProposalVote.create!(proposal:, author: user)
      end

      # Corrupt/direct rows must not inflate campaign KPIs. Temporarily bypass
      # the host validation to prove the aggregate read model fails closed.
      def create_vote_without_campaign_validation(user, proposal)
        vote = Decidim::Proposals::ProposalVote.new(proposal:, author: user)
        vote.save!(validate: false)
      end
    end
  end
end
