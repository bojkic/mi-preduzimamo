# frozen_string_literal: true

require "test_helper"
require "capybara"
require "decidim/participatory_processes/test/factories"
require "decidim/budgets/test/factories"

module Decidim
  module Bih
    module Admin
      class CommunityContributionsControllerTest < ActionDispatch::IntegrationTest
        include ::Devise::Test::IntegrationHelpers

        setup do
          @organization = create_organization
          host! @organization.host
          @admin = create(:user, :confirmed, :admin, organization: @organization)
          @operator = create(:user, :confirmed, organization: @organization)
          @representative = create(:user, :confirmed, organization: @organization)
          @profile = create_partner_profile(@organization, "Partner za provjeru")
          create_membership(@profile, @representative)
          @budget = DecidimApp::Bijeljina::CommunityProjectsSetup.call(
            organization: @organization,
            publish: true
          )
          create_operator_role(@operator, "community_reviewer")
        end

        test "community reviewer sees only the current tenant queue and global admin remains allowed" do
          own = create_submission(@profile, @representative, title: "Naša prijava")
          foreign = create_foreign_submission("Tuđa prijava")

          sign_in @operator
          get "/admin/bih/community-contributions"

          assert_response :success
          assert_includes response.body, own.title
          assert_not_includes response.body, foreign.title

          sign_out @operator
          sign_in @admin
          get "/admin/bih/community-contributions"

          assert_response :success
          assert_includes response.body, own.title
        end

        test "unrelated operator role cannot read or decide the community queue" do
          submission = create_submission(@profile, @representative)
          volunteer_operator = create(:user, :confirmed, organization: @organization)
          create_operator_role(volunteer_operator, "volunteer_reviewer")
          sign_in volunteer_operator

          get "/admin/bih/community-contributions"
          assert_response :redirect

          post "/admin/bih/community-contributions/projects/#{submission.id}/request-changes",
               params: { rejection_reason: "Ne smije odlučiti" }

          assert_response :redirect
          assert_equal "submitted", submission.reload.review_status
        end

        test "scoped project finder refuses another tenant id without auditing it" do
          foreign = create_foreign_submission("Tuđi projekat")
          sign_in @operator

          assert_no_difference -> { OperatorAuditEvent.count } do
            post "/admin/bih/community-contributions/projects/#{foreign.id}/approve",
                 params: { campaign_key: "foreign-project" }
          end

          assert_response :redirect
          assert_equal "submitted", foreign.reload.review_status
          assert_nil foreign.project
        end

        test "approval form requires an existing active campaign without a fabricated key" do
          submission = create_submission(@profile, @representative)
          sign_in @operator
          get "/admin/bih/community-contributions"

          assert_response :success
          assert_select "form[action='/admin/bih/community-contributions/projects/#{submission.id}/approve'] input[name='campaign_key'][value='']"
          assert_includes response.body, I18n.t("decidim.bih.admin.community_contributions.index.existing_campaign_help")
        end

        test "community reviewer approves a project into the configured native budget" do
          submission = create_submission(@profile, @representative, title: "Nova biblioteka", amount: 8_000)
          sign_in @operator
          provider = Object.new
          tenant = @organization
          provider.define_singleton_method(:campaign_ready?) { |key, organization:| key == "nova-biblioteka" && organization == tenant }

          Decidim::Bih.stub(:donations_provider_for, provider) do
            assert_difference -> { ProjectDonationLink.where(organization: @organization).count }, 1 do
              assert_difference -> { Decidim::Budgets::Project.where(budget: @budget).count }, 1 do
                post "/admin/bih/community-contributions/projects/#{submission.id}/approve",
                     params: { campaign_key: "nova-biblioteka" }
              end
            end
          end

          assert_response :redirect
          submission.reload
          assert_equal "approved", submission.review_status
          assert_equal @operator, submission.reviewer
          assert_equal @budget, submission.project.budget
          assert_equal 8_000, submission.project.budget_amount
          assert_equal "nova-biblioteka", submission.project_donation_link.campaign_key
          assert_equal @budget.projects.sum(:budget_amount), @budget.reload.total_budget
          assert OperatorAuditEvent.exists?(
            organization: @organization,
            event_type: "community_project_approved",
            resource_id: submission.id
          )
        end

        test "missing campaign capability preserves operator input and leaves the project private" do
          submission = create_submission(@profile, @representative)
          sign_in @operator

          Decidim::Bih.stub(:donations_provider_for, Object.new) do
            assert_no_difference -> { Decidim::Budgets::Project.where(budget: @budget).count } do
              assert_no_difference -> { ProjectDonationLink.count } do
                post "/admin/bih/community-contributions/projects/#{submission.id}/approve",
                     params: { campaign_key: "reviewed-campaign" }
              end
            end
          end

          assert_response :unprocessable_entity
          assert_select "form[action='/admin/bih/community-contributions/projects/#{submission.id}/approve'] input[name='campaign_key'][value='reviewed-campaign']"
          assert_includes response.body, I18n.t("decidim.bih.admin.community_contributions.flash.campaign_unverified")
          assert_equal "submitted", submission.reload.review_status
        end

        test "approval rechecks campaign activity before creating a public project" do
          submission = create_submission(@profile, @representative)
          sign_in @operator
          provider = Object.new
          calls = 0
          provider.define_singleton_method(:campaign_ready?) do |*|
            calls += 1
            calls == 1
          end

          Decidim::Bih.stub(:donations_provider_for, provider) do
            assert_no_difference -> { Decidim::Budgets::Project.where(budget: @budget).count } do
              post "/admin/bih/community-contributions/projects/#{submission.id}/approve",
                   params: { campaign_key: "reviewed-campaign" }
            end
          end

          assert_equal 2, calls
          assert_response :unprocessable_entity
          assert_equal "submitted", submission.reload.review_status
          assert_nil submission.project
        end

        test "invalid campaign key retains the typed value and produces no approval" do
          submission = create_submission(@profile, @representative)
          sign_in @operator

          assert_no_difference -> { ProjectDonationLink.count } do
            post "/admin/bih/community-contributions/projects/#{submission.id}/approve",
                 params: { campaign_key: "INVALID KEY!" }
          end

          assert_response :unprocessable_entity
          assert_equal "submitted", submission.reload.review_status
          assert_select "form[action='/admin/bih/community-contributions/projects/#{submission.id}/approve'] input[name='campaign_key'][value='INVALID KEY!']"
        end

        test "community reviewer requests changes and rejects projects with visible reasons" do
          changes = create_submission(@profile, @representative, title: "Dopuna")
          rejected = create_submission(@profile, @representative, title: "Odbijanje")
          sign_in @operator

          post "/admin/bih/community-contributions/projects/#{changes.id}/request-changes",
               params: { rejection_reason: "Dodajte troškovnik" }
          assert_response :redirect
          assert_equal "changes_requested", changes.reload.review_status
          assert_equal "Dodajte troškovnik", changes.rejection_reason

          post "/admin/bih/community-contributions/projects/#{rejected.id}/reject",
               params: { rejection_reason: "Nije u javnom interesu" }
          assert_response :redirect
          assert_equal "rejected", rejected.reload.review_status
          assert_equal "Nije u javnom interesu", rejected.rejection_reason

          assert OperatorAuditEvent.exists?(event_type: "community_project_changes_requested")
          assert OperatorAuditEvent.exists?(event_type: "community_project_rejected")
        end

        test "need approval and rejection are permission gated and organization scoped" do
          approved_need = create_need(@profile, @representative, title: "Alat")
          rejected_need = create_need(@profile, @representative, title: "Prevoz")
          foreign_need = create_foreign_need
          sign_in @operator

          post "/admin/bih/community-contributions/needs/#{approved_need.id}/approve"
          assert_response :redirect
          assert_equal "approved", approved_need.reload.review_status
          assert approved_need.published_at.present?

          post "/admin/bih/community-contributions/needs/#{rejected_need.id}/reject",
               params: { rejection_reason: "Potrebna je dopuna" }
          assert_response :redirect
          assert_equal "rejected", rejected_need.reload.review_status
          assert_equal "Potrebna je dopuna", rejected_need.rejection_reason

          post "/admin/bih/community-contributions/needs/#{foreign_need.id}/approve"
          assert_response :redirect
          assert_equal "pending", foreign_need.reload.review_status
        end

        private

        def create_operator_role(user, role)
          OperatorRole.create!(
            organization: @organization,
            user:,
            created_by: @admin,
            role:,
            expires_at: 30.days.from_now
          )
        end

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

        def create_membership(profile, user)
          profile.memberships.create!(
            organization: profile.organization,
            user:,
            role: "owner",
            status: "accepted",
            accepted_at: Time.current
          )
        end

        def create_submission(profile, representative, title: "Projekat za pregled", amount: 5_000)
          PartnerProjectSubmission.create!(
            organization: profile.organization,
            partner_profile: profile,
            representative:,
            title:,
            description: "Detaljan opis projekta za pregled",
            budget_amount: amount,
            review_status: "submitted",
            submitted_at: Time.current
          )
        end

        def create_need(profile, author, title:)
          ContributionNeed.create!(
            organization: profile.organization,
            partner_profile: profile,
            author:,
            need_type: "equipment",
            title:,
            description: "Detaljan opis nefinansijske potrebe",
            quantity: 3,
            unit: "komada",
            review_status: "pending",
            fulfillment_status: "open"
          )
        end

        def create_foreign_submission(title)
          organization = create_organization
          representative = create(:user, :confirmed, organization:)
          profile = create_partner_profile(organization, "Strani partner")
          create_membership(profile, representative)
          create_submission(profile, representative, title:)
        end

        def create_foreign_need
          organization = create_organization
          author = create(:user, :confirmed, organization:)
          profile = create_partner_profile(organization, "Strana potreba")
          create_membership(profile, author)
          create_need(profile, author, title: "Tuđa potreba")
        end
      end
    end
  end
end
