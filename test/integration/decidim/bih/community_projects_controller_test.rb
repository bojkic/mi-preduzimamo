# frozen_string_literal: true

require "test_helper"
require "capybara"
require "decidim/participatory_processes/test/factories"
require "decidim/budgets/test/factories"

module Decidim
  module Bih
    class CommunityProjectsControllerTest < ActionDispatch::IntegrationTest
      include ::Devise::Test::IntegrationHelpers

      setup do
        @organization = create_organization
        host! @organization.host
        @reviewer = create(:user, :confirmed, :admin, organization: @organization)
        @editor = create(:user, :confirmed, organization: @organization)
        @profile = create_partner_profile(@organization, "Partner zajednice")
        @membership = create_membership(@profile, @editor, role: "content_editor")
        @budget = DecidimApp::Bijeljina::CommunityProjectsSetup.call(
          organization: @organization,
          publish: true
        )
      end

      test "catalog excludes participatory-budget mappings while old detail links stay native" do
        project = create(
          :project,
          budget: published_budget(@organization),
          title: translated("Postojeći projekat"),
          description: translated("Opis Postojeći projekat"),
          budget_amount: 5_000
        )
        ProjectDonationLink.create!(
          organization: @organization,
          project:,
          campaign_key: "postojeci-projekat"
        )
        native_path = native_project_path(project)

        get "/biceriseno/projekti"

        assert_response :success
        assert_not_includes response.body, "Postojeći projekat"
        assert_select "a[href='#{native_path}']", count: 0
        assert_select "a[href='/biceriseno/projekti/#{project.id}']", count: 0

        get "/biceriseno/projekti/#{project.id}"

        assert_redirected_to native_path, status: :moved_permanently
      end

      test "approved partner project uses the custom detail and preserves native participation" do
        project = create_moderated_project("Park za sve")

        assert project.can_participate?(@editor)
        assert_not project.can_participate?(nil)

        get "/biceriseno/projekti"

        assert_response :success
        assert_select "a[href='/biceriseno/projekti/#{project.id}']", text: /Pogledaj projekat/

        get "/biceriseno/projekti/#{project.id}"

        assert_response :success
        assert_includes response.body, "Park za sve"
        assert_includes response.body, "5.000"
        assert_not_includes response.body, I18n.t("decidim.bih.community_projects.show.fundraising_paused_note")
        assert_not_includes response.body, I18n.t("decidim.bih.community_projects.show.participation_paused_note")
        assert_select "#comments"
        assert_match(/follow|praćen|prati/i, response.body)
      end

      test "suspended partner leaves approved project transparency public but hides active help" do
        project = create_moderated_project("Privremeno skriven projekat")
        volunteer_manager = create(:user, :confirmed, organization: @organization)
        create_membership(@profile, volunteer_manager, role: "volunteer_coordinator")
        need = ContributionNeed.create!(
          organization: @organization,
          partner_profile: @profile,
          author: volunteer_manager,
          project:,
          need_type: "equipment",
          title: "Oprema za projekat",
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
          author: volunteer_manager,
          partner_profile: @profile,
          partner_name: @profile.display_name,
          budget_project: project,
          title: "Volontiranje uz projekat",
          active: true,
          review_status: "approved"
        )

        @profile.update!(verification_status: "suspended")

        get "/biceriseno/projekti"
        assert_response :success
        assert_not_includes response.body, "Privremeno skriven projekat"

        get "/biceriseno/projekti/#{project.id}"
        assert_response :success
        assert_includes response.body, "Privremeno skriven projekat"
        assert_not_includes response.body, need.title
        assert_not_includes response.body, opportunity.title
        assert_includes response.body, I18n.t("decidim.bih.community_projects.show.participation_paused_note")
        assert_select ".mi-metric-card span", text: I18n.t("decidim.bih.community_projects.show.raised"), count: 0
        assert_select "progress", count: 0
        assert_select "a[href^='https://fondacijabijeljina.com']", count: 0

        get native_project_path(project)
        assert_redirected_to "/biceriseno/projekti/#{project.id}", status: :found
        follow_redirect!
        assert_response :success
      end

      test "hidden storage process keeps moderated project public but unpublished component pauses it" do
        project = create_moderated_project("Privremeno skriven projekat")

        @budget.component.update!(published_at: nil)
        assert_project_hidden(project)

        @budget.component.update!(published_at: Time.current)
        assert_not @budget.participatory_space.published?

        get "/biceriseno/projekti"
        assert_response :success
        assert_includes response.body, "Privremeno skriven projekat"

        get "/biceriseno/projekti/#{project.id}"
        assert_response :success
      end

      test "project ids and partner ids from another tenant cannot be read or submitted" do
        other = create_organization
        outsider = create(:user, :confirmed, organization: other)
        foreign_profile = create_partner_profile(other, "Drugi tenant")
        create_membership(foreign_profile, outsider, role: "content_editor")
        foreign_budget = published_budget(other)
        foreign_project = create(:project, budget: foreign_budget, title: translated("Tuđi projekat"))
        foreign_submission = create_submission(
          profile: foreign_profile,
          representative: outsider,
          status: "approved",
          project: foreign_project
        )
        ProjectDonationLink.create!(
          organization: other,
          project: foreign_project,
          campaign_key: "tudji-projekat"
        )

        get "/biceriseno/projekti/#{foreign_project.id}"
        assert_response :not_found

        sign_in @editor
        assert_no_difference -> { PartnerProjectSubmission.count } do
          post "/biceriseno/projekti", params: submission_params(foreign_profile.id, title: "Pogrešan tenant")
        end
        assert_response :redirect

        foreign_submission.update!(review_status: "changes_requested", project: nil, rejection_reason: "Dopuniti")
        assert_no_changes -> { foreign_submission.reload.title } do
          patch "/biceriseno/projekti/prijave/#{foreign_submission.id}",
                params: submission_params(foreign_profile.id, title: "Neovlaštena izmjena")
        end
        assert_response :redirect
      end

      test "content editors submit projects atomically while volunteer-only staff cannot" do
        sign_in @editor

        assert_difference -> { PartnerProjectSubmission.where(review_status: "submitted").count }, 1 do
          assert_no_difference -> { PartnerProjectSubmission.where(review_status: "draft").count } do
            post "/biceriseno/projekti", params: submission_params(@profile.id, title: "Nova česma")
          end
        end
        assert_response :redirect

        coordinator = create(:user, :confirmed, organization: @organization)
        create_membership(@profile, coordinator, role: "volunteer_coordinator")
        sign_out @editor
        sign_in coordinator

        assert_no_difference -> { PartnerProjectSubmission.count } do
          post "/biceriseno/projekti", params: submission_params(@profile.id, title: "Nedozvoljen projekat")
        end
        assert_response :redirect
      end

      test "revoked members lose private review access and current content editors may resubmit" do
        submission = create_submission(
          profile: @profile,
          representative: @editor,
          status: "changes_requested",
          reason: "Dodajte detaljan plan"
        )
        sign_in @editor

        get "/biceriseno/projekti"
        assert_includes response.body, submission.title
        assert_includes response.body, "Dodajte detaljan plan"

        @membership.update!(status: "revoked", revoked_at: Time.current)
        get "/biceriseno/projekti"
        assert_response :success
        assert_not_includes response.body, submission.title
        assert_not_includes response.body, "Dodajte detaljan plan"

        get "/biceriseno/projekti/prijave/#{submission.id}/uredi"
        assert_response :redirect

        successor = create(:user, :confirmed, organization: @organization)
        create_membership(@profile, successor, role: "content_editor")
        sign_out @editor
        sign_in successor

        get "/biceriseno/projekti/prijave/#{submission.id}/uredi"
        assert_response :success
        assert_select "form[action='/biceriseno/projekti/prijave/#{submission.id}'][method='post']"
        assert_select "input[name='_method'][value='patch']"

        patch "/biceriseno/projekti/prijave/#{submission.id}",
              params: submission_params(@profile.id, title: "Dopunjen plan")

        assert_response :redirect
        submission.reload
        assert_equal "submitted", submission.review_status
        assert_equal "Dopunjen plan", submission.title
        assert_equal successor, submission.representative
        assert_nil submission.rejection_reason
      end

      test "accepted staff retain private decision history when the partner is suspended" do
        submission = create_submission(
          profile: @profile,
          representative: @editor,
          status: "rejected",
          reason: "Cilj nije dovoljno jasan"
        )
        @profile.update!(verification_status: "suspended")
        sign_in @editor

        get "/biceriseno/projekti"

        assert_response :success
        assert_includes response.body, submission.title
        assert_includes response.body, "Cilj nije dovoljno jasan"
        get "/biceriseno/projekti/novi"
        assert_response :redirect
      end

      test "stale resubmission is rejected without overwriting a newer edit" do
        submission = create_submission(
          profile: @profile,
          representative: @editor,
          status: "changes_requested",
          reason: "Dopuniti plan"
        )
        sign_in @editor
        get "/biceriseno/projekti/prijave/#{submission.id}/uredi"
        stale_version = Capybara.string(response.body)
                                .find("input[name='partner_project_submission[lock_version]']", visible: :all)[:value]

        submission.update!(title: "Novija izmjena drugog urednika")
        patch "/biceriseno/projekti/prijave/#{submission.id}",
              params: submission_params(
                @profile.id,
                title: "Zastarjela izmjena"
              ).deep_merge(partner_project_submission: { lock_version: stale_version })

        assert_redirected_to "/biceriseno/projekti#moji-projekti"
        assert_equal "Novija izmjena drugog urednika", submission.reload.title
        assert_equal "changes_requested", submission.review_status
        assert_equal I18n.t("decidim.bih.community_projects.flash.stale_submission"), flash[:alert]
      end

      private

      def create_partner_profile(organization, name)
        PartnerProfile.create!(
          organization:,
          display_name: name,
          slug: "#{name.parameterize}-#{SecureRandom.hex(4)}",
          kind: "business",
          verification_status: "verified",
          verified_at: Time.current
        )
      end

      def create_membership(profile, user, role:)
        profile.memberships.create!(
          organization: profile.organization,
          user:,
          role:,
          status: "accepted",
          accepted_at: Time.current
        )
      end

      def published_budget(organization)
        process = create(:participatory_process, organization:, published_at: Time.current)
        component = create(:budgets_component, participatory_space: process, published_at: Time.current)
        create(:budget, component:)
      end

      def create_project(title)
        create(
          :project,
          budget: @budget,
          title: translated(title),
          description: translated("Opis #{title}"),
          budget_amount: 5_000
        )
      end

      def create_moderated_project(title)
        project = create_project(title)
        create_submission(
          profile: @profile,
          representative: @editor,
          status: "approved",
          project:
        )
        ProjectDonationLink.create!(
          organization: @organization,
          project:,
          campaign_key: "project-#{project.id}"
        )
        project
      end

      def create_submission(profile:, representative:, status:, project: nil, reason: nil)
        PartnerProjectSubmission.create!(
          organization: profile.organization,
          partner_profile: profile,
          representative:,
          reviewer: (status == "draft" || status == "submitted" ? nil : reviewer_for(profile.organization)),
          project:,
          title: "Prijava #{SecureRandom.hex(4)}",
          description: "Detaljan opis projekta za zajednicu",
          budget_amount: 5_000,
          review_status: status,
          submitted_at: (Time.current unless status == "draft"),
          reviewed_at: (Time.current unless %w(draft submitted).include?(status)),
          rejection_reason: reason
        )
      end

      def reviewer_for(organization)
        return @reviewer if organization == @organization

        create(:user, :confirmed, :admin, organization:)
      end

      def submission_params(profile_id, title:)
        {
          partner_project_submission: {
            partner_profile_id: profile_id,
            title:,
            description: "Detaljan opis projekta za javnu provjeru",
            budget_amount: 4_000,
            address: "Bijeljina"
          }
        }
      end

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

      def assert_project_hidden(project)
        get "/biceriseno/projekti"
        assert_response :success
        assert_not_includes response.body, "Privremeno skriven projekat"
        get "/biceriseno/projekti/#{project.id}"
        assert_response :not_found
      end
    end
  end
end
