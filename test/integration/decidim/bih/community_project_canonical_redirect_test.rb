# frozen_string_literal: true

require "test_helper"
require "capybara/rails"
require "decidim/participatory_processes/test/factories"
require "decidim/budgets/test/factories"

module Decidim
  module Bih
    class CommunityProjectCanonicalRedirectTest < ActionDispatch::IntegrationTest
      setup do
        @organization = create_organization
        host! @organization.host
        @representative = create(:user, :confirmed, organization: @organization)
        @reviewer = create(:user, :confirmed, :admin, organization: @organization)
        @profile = PartnerProfile.create!(
          organization: @organization,
          display_name: "Partner projekta",
          slug: "partner-projekta",
          kind: "business",
          verification_status: "verified",
          verified_at: Time.current
        )
        @profile.memberships.create!(
          organization: @organization,
          user: @representative,
          role: "owner",
          status: "accepted",
          accepted_at: Time.current
        )
        @budget = DecidimApp::Bijeljina::CommunityProjectsSetup.call(
          organization: @organization,
          publish: true
        )
        @project = create(
          :project,
          budget: @budget,
          title: translated("Kanonski projekat"),
          description: translated("Opis odobrenog projekta"),
          budget_amount: 5_000
        )
        PartnerProjectSubmission.create!(
          organization: @organization,
          partner_profile: @profile,
          representative: @representative,
          reviewer: @reviewer,
          project: @project,
          title: "Kanonski projekat",
          description: "Opis odobrenog projekta",
          budget_amount: 5_000,
          review_status: "approved",
          submitted_at: 1.hour.ago,
          reviewed_at: Time.current
        )
        ProjectDonationLink.create!(
          organization: @organization,
          project: @project,
          campaign_key: "kanonski-projekat"
        )
      end

      test "redirects a moderated native project detail to the single community-project page" do
        get native_project_path(@project)

        assert_redirected_to "/biceriseno/projekti/#{@project.id}", status: :found
      end

      test "redirects the hidden storage budget index to the community-project catalog" do
        get native_projects_path(@project)

        assert_redirected_to "/biceriseno/projekti", status: :found
      end

      test "keeps the hidden storage process out of participatory-process discovery" do
        get "/processes/projekti-zajednice"
        assert_redirected_to "/biceriseno/projekti", status: :found

        create(
          :participatory_process,
          organization: @organization,
          title: translated("Pravi participativni proces"),
          published_at: Time.current
        )
        get "/processes"
        assert_response :success
        assert_includes response.body, "Pravi participativni proces"
        assert_not_includes response.body, "Projekti zajednice"
      end

      test "keeps an unrelated participatory-budget project on its native page" do
        process = create(:participatory_process, organization: @organization, published_at: Time.current)
        component = create(:budgets_component, participatory_space: process, published_at: Time.current)
        project = create(:project, budget: create(:budget, component:))

        get native_project_path(project)

        assert_response :success
      end

      test "keeps approved transparency and independent help public after the donation link is deactivated" do
        need = ContributionNeed.create!(
          organization: @organization,
          partner_profile: @profile,
          author: @representative,
          project: @project,
          need_type: "equipment",
          title: "Oprema ostaje aktivna",
          description: "Detaljan opis nenovčane potrebe",
          quantity: 2,
          unit: "komada",
          review_status: "approved",
          fulfillment_status: "open",
          reviewed_at: Time.current,
          published_at: Time.current
        )
        opportunity = VolunteerOpportunity.create!(
          organization: @organization,
          author: @representative,
          partner_profile: @profile,
          partner_name: @profile.display_name,
          budget_project: @project,
          title: "Volonterska pomoć ostaje aktivna",
          active: true,
          review_status: "approved"
        )
        ProjectDonationLink.find_by!(organization: @organization, project: @project).update!(active: false)

        get "/biceriseno/projekti"
        assert_response :success
        assert_not_includes response.body, "Kanonski projekat"

        get native_project_path(@project)

        assert_redirected_to "/biceriseno/projekti/#{@project.id}", status: :found

        get "/biceriseno/projekti/#{@project.id}"

        assert_response :success
        assert_includes response.body, "Kanonski projekat"
        assert_includes response.body, need.title
        assert_includes response.body, opportunity.title
        assert_includes response.body, I18n.t("decidim.bih.community_projects.show.fundraising_paused_note")
        assert_not_includes response.body, I18n.t("decidim.bih.community_projects.show.participation_paused_note")
        assert_select ".mi-metric-card span", text: I18n.t("decidim.bih.community_projects.show.raised"), count: 0
        assert_select "progress", count: 0
        assert_select "a[href^='https://fondacijabijeljina.com']", count: 0
      end

      private

      def translated(value)
        {
          "sr" => value,
          "sr-Cyrl" => Decidim::Bih::Transliterator.call(value),
          "bs" => value,
          "hr" => value
        }
      end

      def native_project_path(project)
        Decidim::EngineRouter.main_proxy(project.component).budget_project_path(
          budget_id: project.budget.id,
          id: project.id
        )
      end

      def native_projects_path(project)
        Decidim::EngineRouter.main_proxy(project.component).budget_projects_path(
          budget_id: project.budget.id
        )
      end
    end
  end
end
