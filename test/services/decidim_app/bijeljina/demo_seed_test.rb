# frozen_string_literal: true

require "test_helper"
require "decidim/participatory_processes/test/factories"
require "decidim/proposals/test/factories"
require "decidim/debates/test/factories"
require "decidim/budgets/test/factories"

module DecidimApp
  module Bijeljina
    # Exercises the idempotent Bijeljina demo-content seeder against a real
    # DB-backed Decidim organization (locales sr/sr-Cyrl/bs/hr), seeding into a
    # freshly bootstrapped grant cycle + civic-debates space.
    class DemoSeedTest < ActiveSupport::TestCase
      setup do
        @organization = create_organization
        # The bootstrap admin the seeder uses for official authorship/traceability.
        create(:user, :admin, :confirmed, organization: @organization)

        # The seeder targets the 2026 grant cycle and the debates space; build
        # and publish their structure the way production already has it.
        @grant_cycle = GrantCycleSetup.call(organization: @organization, year: 2026)
        publish_space_and_components(@grant_cycle)

        @debates_space = CivicDebatesSetup.call(organization: @organization)
        publish_space_and_components(@debates_space)
      end

      test "seeds the expected number of proposals with official authorship" do
        DemoSeed.call(organization: @organization)

        proposals = proposals_in(@grant_cycle)

        assert_equal DemoSeed::PROPOSALS.size, proposals.count
        proposals.each do |proposal|
          assert proposal.authors.include?(@organization),
                 "proposal '#{proposal.title["sr"]}' is not officially authored"
          assert proposal.published?
        end
      end

      test "seeds a known Bijeljina-themed proposal title" do
        DemoSeed.call(organization: @organization)

        titles = proposals_in(@grant_cycle).map { |p| p.title["sr"] }

        assert_includes titles, "Biciklistička staza od centra do obale Drine"
      end

      test "seeds real votes so proposal counts are genuine, not faked" do
        DemoSeed.call(organization: @organization)

        proposal = proposals_in(@grant_cycle)
                   .find { |p| p.title["sr"] == "Novi vrtić za najmlađe" }

        assert proposal.proposal_votes_count.positive?
        assert_equal proposal.votes.count, proposal.proposal_votes_count
      end

      test "spreads proposal created_at into the past for the activity feed" do
        DemoSeed.call(organization: @organization)

        proposals = proposals_in(@grant_cycle)

        assert(proposals.all? { |p| p.created_at < Time.current })
        # Distinct timestamps so the feed orders meaningfully.
        assert_operator proposals.map(&:created_at).uniq.size, :>, 1
      end

      test "seeds the expected number of debates" do
        DemoSeed.call(organization: @organization)

        debates = debates_in(@debates_space)

        assert_equal DemoSeed::DEBATES.size, debates.count
        debates.each { |d| assert_equal @organization, d.author }
      end

      # Budget seeding was removed (2026-08-31): a fabricated participatory
      # budget total is a liability on a real civic platform, not a feature —
      # see the class comment on DemoSeed. This proves the seeder stays out of
      # the budgets component entirely, so a demo reset can never republish a
      # figure the foundation hasn't approved.
      test "does not seed any participatory-budget content" do
        DemoSeed.call(organization: @organization)

        budgets_component = @grant_cycle.components.find_by(manifest_name: "budgets")

        assert_empty Decidim::Budgets::Budget.where(component: budgets_component)
      end

      test "is idempotent: a second call creates no duplicate content" do
        DemoSeed.call(organization: @organization)
        DemoSeed.call(organization: @organization)

        assert_equal DemoSeed::PROPOSALS.size, proposals_in(@grant_cycle).count
        assert_equal DemoSeed::DEBATES.size, debates_in(@debates_space).count

        budgets_component = @grant_cycle.components.find_by(manifest_name: "budgets")
        assert_empty Decidim::Budgets::Budget.where(component: budgets_component)
      end

      test "is idempotent: a second call does not double the vote counts" do
        DemoSeed.call(organization: @organization)
        target = DemoSeed::PROPOSALS.find { |p| p[:title] == "Novi vrtić za najmlađe" }[:votes]
        DemoSeed.call(organization: @organization)

        proposal = proposals_in(@grant_cycle)
                   .find { |p| p.title["sr"] == "Novi vrtić za najmlađe" }

        assert_equal target, proposal.votes.count
      end

      test "returns a summary of what was seeded, with no budget/projects keys" do
        summary = DemoSeed.call(organization: @organization)

        assert_equal DemoSeed::PROPOSALS.size, summary[:proposals]
        assert_equal DemoSeed::DEBATES.size, summary[:debates]
        assert_not summary.has_key?(:budget)
        assert_not summary.has_key?(:projects)
      end

      private

      def publish_space_and_components(space)
        space.update!(published_at: Time.current)
        space.components.each { |c| c.update!(published_at: Time.current) }
      end

      def proposals_in(space)
        component = space.components.find_by(manifest_name: "proposals")
        Decidim::Proposals::Proposal.where(component:)
      end

      def debates_in(space)
        component = space.components.find_by(manifest_name: "debates")
        Decidim::Debates::Debate.where(component:)
      end
    end
  end
end
