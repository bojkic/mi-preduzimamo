# frozen_string_literal: true

require "test_helper"
require "decidim/participatory_processes/test/factories"
require "decidim/budgets/test/factories"

module DecidimApp
  module Bijeljina
    class ProjectDonationLinksSetupTest < ActiveSupport::TestCase
      setup do
        @organization = create_organization
        process = create(:participatory_process, organization: @organization)
        component = create(:budgets_component, participatory_space: process)
        budget = create(:budget, component:)
        @legacy_campaign_key = ProjectDonationLinksSetup::LEGACY_LINKS.fetch(1)
        @project = create(:project, budget:)
      end

      test "seeds a legacy campaign link without copying the project title" do
        with_legacy_project_mapping do
          links = ProjectDonationLinksSetup.call(organization: @organization)

          assert_equal 1, links.size
          assert_equal @project, links.first.project
          assert_equal @legacy_campaign_key, links.first.campaign_key
          assert links.first.active?
        end
      end

      test "is idempotent" do
        with_legacy_project_mapping do
          first = ProjectDonationLinksSetup.call(organization: @organization)
          second = ProjectDonationLinksSetup.call(organization: @organization)

          assert_equal first.first.id, second.first.id
          assert_equal 1, Decidim::Bih::ProjectDonationLink.where(
            organization: @organization,
            project: @project
          ).count
        end
      end

      test "ordinary reruns preserve an operator mapping change and deactivation" do
        with_legacy_project_mapping do
          link = ProjectDonationLinksSetup.call(organization: @organization).sole
          link.update!(campaign_key: "approved-replacement", active: false)

          rerun = ProjectDonationLinksSetup.call(organization: @organization).sole

          assert_equal link.id, rerun.id
          assert_equal "approved-replacement", rerun.campaign_key
          assert_not rerun.active?
        end
      end

      test "explicit repair restores the checked-in legacy mapping" do
        with_legacy_project_mapping do
          link = ProjectDonationLinksSetup.call(organization: @organization).sole
          link.update!(campaign_key: "broken-mapping", active: false)

          repaired = ProjectDonationLinksSetup.call(organization: @organization, repair: true).sole

          assert_equal @legacy_campaign_key, repaired.campaign_key
          assert repaired.active?
        end
      end

      test "does not attach an id collision belonging to another tenant" do
        with_legacy_project_mapping do
          other_organization = create_organization

          assert_empty ProjectDonationLinksSetup.call(organization: other_organization)
        end
      end

      test "does not recreate a missing legacy project" do
        with_legacy_project_mapping do
          @project.destroy!

          assert_empty ProjectDonationLinksSetup.call(organization: @organization)
          assert_nil Decidim::Budgets::Project.find_by(id: @project.id)
        end
      end

      private

      # Production intentionally maps fixed historic ids. Tests use a normally
      # sequenced project so a project left by another full-suite case cannot
      # collide with a hard-coded primary key.
      def with_legacy_project_mapping
        original = ProjectDonationLinksSetup::LEGACY_LINKS
        replace_legacy_links(@project.id => @legacy_campaign_key)
        yield
      ensure
        replace_legacy_links(original) if original
      end

      def replace_legacy_links(links)
        ProjectDonationLinksSetup.send(:remove_const, :LEGACY_LINKS)
        ProjectDonationLinksSetup.const_set(:LEGACY_LINKS, links.freeze)
      end
    end
  end
end
