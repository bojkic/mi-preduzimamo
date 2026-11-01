# frozen_string_literal: true

require "test_helper"
require "decidim/participatory_processes/test/factories"
require "decidim/proposals/test/factories"

module DecidimApp
  module Bijeljina
    class KomsilukNamingCampaignPolicyTest < ActiveSupport::TestCase
      setup do
        @organization = create_organization
        create(:user, :admin, :confirmed, organization: @organization)
        @area_one = create_area("komsiluk-1", "Savino")
        @area_two = create_area("komsiluk-2", "Dašnica")
        result = KomsilukNamingCampaignSetup.call(
          organization: @organization,
          nomination_start: Date.new(2026, 9, 1),
          nomination_end: Date.new(2026, 9, 21),
          voting_end: Date.new(2026, 10, 5)
        )
        @component = result.fetch(:component)
        @taxonomy_one = taxonomy_for(@area_one)
        @taxonomy_two = taxonomy_for(@area_two)
        @proposal_one = official_proposal_for(@taxonomy_one)
        @proposal_two = official_proposal_for(@taxonomy_two)
        @user = create(:user, :confirmed, organization: @organization)
        @authorization = create(:authorization, :granted, user: @user, name: "sms")
      end

      test "proposal form ignores a submitted area and assigns the private profile Komšiluk" do
        assign(@user, @area_one)
        form = proposal_form(@user, taxonomies: [@taxonomy_two.id])

        assert form.valid?, form.errors.full_messages.to_sentence
        assert_equal [@taxonomy_one.id], form.taxonomies
        assert_empty form.taxonomy_filters
      end

      test "proposal form requires a Komšiluk assignment" do
        form = proposal_form(@user)

        assert_not form.valid?
        assert_includes form.errors[:base], I18n.t("decidim_app.bijeljina.komsiluk_naming_campaign.errors.komsiluk_required")
      end

      test "existing campaign participation prevents switching areas" do
        assign(@user, @area_one)
        citizen_proposal(@user, @taxonomy_one)
        assign(@user, @area_two)

        form = proposal_form(@user)
        assert_not form.valid?
        assert_includes form.errors[:base], I18n.t("decidim_app.bijeljina.komsiluk_naming_campaign.errors.campaign_area_locked")
      end

      test "vote model accepts own Komšiluk and rejects another one" do
        assign(@user, @area_one)

        assert Decidim::Proposals::ProposalVote.new(proposal: @proposal_one, author: @user).valid?
        wrong_vote = Decidim::Proposals::ProposalVote.new(proposal: @proposal_two, author: @user)
        assert_not wrong_vote.valid?
        assert wrong_vote.errors[:proposal].any?
      end

      test "SMS action authorization enforces own Komšiluk only for the campaign" do
        assign(@user, @area_one)

        own_status, = authorizer(@authorization, @component, @proposal_one).authorize
        wrong_status, wrong_data = authorizer(@authorization, @component, @proposal_two).authorize
        assert_equal :ok, own_status
        assert_equal :unauthorized, wrong_status
        assert_equal "decidim_app.bijeljina.komsiluk_naming_campaign.authorization.wrong_komsiluk",
                     wrong_data.dig(:extra_explanation, :key)

        other_component = create(:proposal_component, organization: @organization)
        outside_status, = authorizer(@authorization, other_component, nil).authorize
        assert_equal :ok, outside_status
      end

      test "SMS authorization preserves normal missing status" do
        status, data = authorizer(nil, @component, @proposal_one).authorize

        assert_equal :missing, status
        assert_equal :authorize, data.fetch(:action)
      end

      test "SMS workflow uses the campaign-aware authorizer" do
        manifest = Decidim::Verifications.find_workflow_manifest(:sms)

        assert_equal KomsilukNamingActionAuthorizer, manifest.action_authorizer_class
      end

      test "a participant may remove an old vote after changing Komšiluk" do
        assign(@user, @area_one)
        Decidim::Proposals::ProposalVote.create!(proposal: @proposal_one, author: @user)
        assign(@user, @area_two)

        status, = authorizer(@authorization, @component, @proposal_one).authorize
        assert_equal :ok, status
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

      def taxonomy_for(area)
        Decidim::Taxonomy.find(KomsilukNamingCampaign.taxonomy_id_for_area(area))
      end

      def official_proposal_for(taxonomy)
        Decidim::Proposals::Proposal
          .where(component: @component)
          .with_official_origin
          .joins(:taxonomies)
          .find_by!(decidim_taxonomies: { id: taxonomy.id })
      end

      def assign(user, area)
        Decidim::Bih::CitizenProfile.for_user(user, organization: @organization)
                                    .assign_komsiluk!(area, source: :dropdown)
      end

      def proposal_form(user, taxonomies: [])
        Decidim::Proposals::ProposalForm.new(
          title: "Novi prijedlog naziva",
          body: "Ovaj naziv opisuje istoriju i zajedništvo našeg komšiluka.",
          taxonomies:
        ).with_context(
          current_organization: @organization,
          current_user: user,
          current_component: @component,
          current_participatory_space: @component.participatory_space
        )
      end

      def citizen_proposal(user, taxonomy)
        proposal = build(:proposal, component: @component, users: [user])
        proposal.taxonomies << taxonomy
        proposal.save!
        proposal
      end

      def authorizer(authorization, component, resource)
        KomsilukNamingActionAuthorizer.new(authorization, {}, component, resource)
      end
    end
  end
end
