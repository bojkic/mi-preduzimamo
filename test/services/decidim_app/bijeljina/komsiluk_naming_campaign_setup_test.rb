# frozen_string_literal: true

require "test_helper"
require "decidim/participatory_processes/test/factories"
require "decidim/proposals/test/factories"

module DecidimApp
  module Bijeljina
    class KomsilukNamingCampaignSetupTest < ActiveSupport::TestCase
      setup do
        @organization = create_organization
        create(:user, :admin, :confirmed, organization: @organization)
        @areas = [
          create_area("komsiluk-1", "Savino (prijedlog)"),
          create_area("komsiluk-2", "Dašnica (prijedlog)")
        ]
        @dates = {
          nomination_start: Date.new(2026, 9, 1),
          nomination_end: Date.new(2026, 9, 21),
          voting_end: Date.new(2026, 10, 5)
        }
      end

      test "creates an unpublished Decidim campaign with one initial proposal per Komšiluk" do
        result = KomsilukNamingCampaignSetup.call(organization: @organization, **@dates)

        process = result.fetch(:process)
        component = result.fetch(:component)
        assert_nil process.published_at
        assert_nil component.published_at
        assert_equal KomsilukNamingCampaign::PROCESS_SLUG, process.slug
        assert_equal 3, process.steps.count
        assert_equal KomsilukNamingCampaignSetup::NOMINATION_STEP, process.active_step.title.fetch("sr")

        assert_equal 2, result.fetch(:areas)
        assert_equal 2, result.fetch(:initial_proposals)
        assert_equal 2, result.fetch(:root_taxonomy).children.count
        assert_equal 2, result.fetch(:taxonomy_filter).filter_items.count

        proposals = Decidim::Proposals::Proposal.where(component:).with_official_origin.order(:id)
        assert_equal(["Savino (prijedlog)", "Dašnica (prijedlog)"], proposals.map { |proposal| proposal.title.fetch("sr") })
        assert proposals.all?(&:published?)
        assert(proposals.all? { |proposal| proposal.taxonomy_ids.one? })

        assert_equal 1, component.settings.vote_limit
        assert_equal 1, component.settings.proposal_limit
        assert_equal true, component.step_settings.fetch(process.active_step.id.to_s).creation_enabled
        assert_equal false, component.step_settings.fetch(process.active_step.id.to_s).votes_enabled
        assert_equal({ "authorization_handlers" => { "sms" => {} } }, component.permissions.fetch("create"))
        assert_equal({ "authorization_handlers" => { "sms" => {} } }, component.permissions.fetch("vote"))
      end

      test "setup is idempotent" do
        first = KomsilukNamingCampaignSetup.call(organization: @organization, **@dates)
        counts = campaign_counts

        second = KomsilukNamingCampaignSetup.call(organization: @organization, **@dates)

        assert_equal first.fetch(:process).id, second.fetch(:process).id
        assert_equal first.fetch(:component).id, second.fetch(:component).id
        assert_equal counts, campaign_counts
      end

      test "rejects missing areas and invalid dates before creating a process" do
        @areas.each(&:destroy!)

        error = assert_raises(ArgumentError) do
          KomsilukNamingCampaignSetup.call(organization: @organization, **@dates)
        end
        assert_match(/Komšiluk/, error.message)
        assert_nil KomsilukNamingCampaign.process_for(@organization)
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

      def campaign_counts
        {
          processes: Decidim::ParticipatoryProcess.where(organization: @organization, slug: KomsilukNamingCampaign::PROCESS_SLUG).count,
          steps: KomsilukNamingCampaign.process_for(@organization).steps.count,
          components: KomsilukNamingCampaign.process_for(@organization).components.count,
          root_taxonomies: @organization.taxonomies.roots.where("name ->> 'sr' = ?", KomsilukNamingCampaignSetup::ROOT_NAME).count,
          child_taxonomies: @organization.taxonomies.where.not(parent_id: nil).count,
          proposals: Decidim::Proposals::Proposal.where(component: KomsilukNamingCampaign.component_for(@organization)).count
        }
      end
    end
  end
end
