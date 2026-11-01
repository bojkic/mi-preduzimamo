# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module Admin
      class VolunteeringControllerTest < ActionDispatch::IntegrationTest
        include ::Devise::Test::IntegrationHelpers

        setup do
          @organization = create_organization
          host! @organization.host
          @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
          @citizen = FactoryBot.create(:user, :confirmed, organization: @organization,
                                      name: "Mila Roster", email: "mila-roster@example.org")
          @applicant = FactoryBot.create(:user, :confirmed, organization: @organization,
                                        name: "Niko Applicant")
          @opportunity = VolunteerOpportunity.create!(
            organization: @organization, title: "Park programme", active: true,
            review_status: "approved", starts_at: 3.days.ago, ends_at: 3.days.from_now,
            series_key: "park-series", series_position: 1, series_total: 2,
            category: "environment", capacity: 2
          )
          @future = VolunteerOpportunity.create!(
            organization: @organization, title: "Park programme", active: true,
            review_status: "approved", starts_at: 4.days.from_now, ends_at: 5.days.from_now,
            series_key: "park-series", series_position: 2, series_total: 2,
            category: "environment", capacity: 2
          )
          @going = VolunteerSignup.create!(organization: @organization, opportunity: @opportunity,
                                           user: @citizen, status: "going", review_status: "approved",
                                           review_source: "admin", reviewer: @admin, reviewed_at: Time.current)
          @pending = VolunteerSignup.create!(organization: @organization, opportunity: @opportunity,
                                             user: @applicant, status: "pending", review_status: "pending",
                                             review_source: "application", first_session_at: 1.day.from_now)
          zone = Time.find_zone!("Europe/Sarajevo")
          @work_start = 1.day.ago.in_time_zone(zone).change(hour: 10, min: 0, sec: 0)
          @claim = VolunteerLog.create!(organization: @organization, opportunity: @opportunity,
                                        user: @citizen, status: "pending", work_date: @work_start.to_date,
                                        worked_from_at: @work_start, worked_until_at: @work_start + 2.hours,
                                        hours: 2)
        end

        test "partner confirmation is rejected after cancellation and repeated confirmation is not audited" do
          @opportunity.update!(partner_name: "Partner centre", cancelled_at: Time.current, active: false)
          sign_in @admin

          assert_no_difference -> { OperatorAuditEvent.where(event_type: "volunteering_partner_confirmed").count } do
            post "/admin/bih/volunteering/opportunity/#{@opportunity.id}/confirm-partner"
          end
          assert_nil @opportunity.reload.partner_confirmed_at

          @future.update!(partner_name: "Partner centre")
          assert_difference -> { OperatorAuditEvent.where(event_type: "volunteering_partner_confirmed").count }, 1 do
            post "/admin/bih/volunteering/opportunity/#{@future.id}/confirm-partner"
          end
          assert @future.reload.partner_confirmed?
          assert_no_difference -> { OperatorAuditEvent.where(event_type: "volunteering_partner_confirmed").count } do
            post "/admin/bih/volunteering/opportunity/#{@future.id}/confirm-partner"
          end
        end

        test "three compact areas render grouped proposals and keep names on detail" do
          sign_in @admin
          get "/admin/bih/volunteering"

          assert_response :success
          assert_select "#admin-volunteering-header"
          assert_select "#admin-volunteering-list tbody tr", count: 1
          assert_includes response.body, I18n.t("decidim.bih.admin.volunteering.workspace.tabs.opportunities", locale: :sr)
          assert_includes response.body, I18n.t("decidim.bih.admin.volunteering.workspace.tabs.applications", locale: :sr)
          assert_includes response.body, I18n.t("decidim.bih.admin.volunteering.workspace.tabs.hours", locale: :sr)
          assert_not_includes response.body, @citizen.name
          assert_not_includes response.body, @citizen.email
          assert_not_includes response.body, "admin-volunteering-subqueues"

          get "/admin/bih/volunteering/opportunities/#{@opportunity.id}"
          assert_response :success
          assert_includes response.body, @citizen.name
          assert_includes response.body, @applicant.name
          assert_includes response.body, @claim.hours.to_s
          assert_not_includes response.body, @citizen.email
        end

        test "application and work filters show only their own scoped task rows" do
          sign_in @admin
          get "/admin/bih/volunteering", params: { tab: "applications", task: "review" }
          assert_response :success
          assert_includes response.body, @applicant.name
          assert_not_includes response.body, @citizen.name

          get "/admin/bih/volunteering", params: { tab: "hours", status: "pending" }
          assert_response :success
          assert_includes response.body, @citizen.name
          assert_includes response.body, @work_start.to_date.strftime("%d")
          assert_not_includes response.body, @applicant.name
        end

        test "pending work remains in the hours queue when an opportunity is inactive" do
          @opportunity.update!(active: false)
          sign_in @admin
          get "/admin/bih/volunteering", params: { tab: "hours", status: "pending" }

          assert_response :success
          assert_includes response.body, @citizen.name
          assert_includes response.body, @opportunity.title
          assert_includes response.body, "/admin/bih/volunteering/opportunities/#{@opportunity.id}"
        end

        test "administrator approves an application before allocating a place" do
          sign_in @admin
          assert_equal "pending", @pending.status
          post "/admin/bih/volunteering/applications/#{@pending.id}/decide",
               params: { decision: "approve", tab: "applications", task: "review" }

          assert_response :redirect
          assert_equal "approved", @pending.reload.review_status
          assert_equal "going", @pending.status
          assert_match(/tab=applications/, response.location)
        end

        test "dated attendance creates its own evidence and leaves legacy timestamp untouched" do
          sign_in @admin
          assert_difference -> { VolunteerAttendance.where(opportunity: @opportunity, work_date: @work_start.to_date).count }, 1 do
            post "/admin/bih/volunteering/signup/#{@going.id}/confirm-attendance",
                 params: { work_date: @work_start.to_date.iso8601, attendance_status: "confirmed" }
          end

          assert_response :redirect
          evidence = VolunteerAttendance.find_by!(opportunity: @opportunity, user: @citizen,
                                                  work_date: @work_start.to_date)
          assert_equal "confirmed", evidence.status
          assert_equal @admin.id, evidence.confirmed_by_id
          assert_nil @going.reload.attendance_confirmed_at
          assert OperatorAuditEvent.where(event_type: "volunteering_dated_attendance_confirmed",
                                          resource_id: evidence.id).exists?
        end

        test "a whole pending proposal can be returned for correction" do
          proposed = create_pending_series!("Correction series")
          sign_in @admin
          post "/admin/bih/volunteering/opportunities/#{proposed.first.id}/return",
               params: { reason: "Please explain the meeting point" }

          assert_response :redirect
          assert_equal %w(needs_revision needs_revision), proposed.map { |term| term.reload.review_status }
          assert_equal "Please explain the meeting point", proposed.first.rejection_reason
        end

        test "publishing a grouped proposal records explicit partner agreement" do
          proposed = create_pending_series!("Approval series", partner_name: "Partner centre")
          sign_in @admin
          post "/admin/bih/volunteering/opportunities/#{proposed.first.id}/publish",
               params: { confirm_partner: "1" }

          assert_response :redirect
          assert_equal %w(approved approved), proposed.map { |term| term.reload.review_status }
          assert proposed.all?(&:partner_confirmed?)
          assert proposed.all?(&:active?)
        end

        test "management uses the displayed impact token and retains the proposal identity on republication" do
          sign_in @admin
          manager = VolunteerOpportunityManagement.new(
            organization: @organization, opportunity: @future, actor: @admin, action: "edit", scope: "term"
          )
          post "/admin/bih/volunteering/opportunities/#{@future.id}/manage",
               params: { operation: "edit", scope: "term", preview_token: manager.preview.token,
                         title: "Park programme revised", capacity: 3 }
          assert_response :redirect
          assert_equal "Park programme revised", @future.reload.title
          assert_equal 3, @future.capacity

          cancelled = VolunteerOpportunity.create!(organization: @organization, title: "Old term",
                                                   active: false, review_status: "approved", starts_at: 2.days.ago,
                                                   ends_at: 1.day.ago, cancelled_at: 1.day.ago,
                                                   cancellation_reason: "Weather", proposal_identity: "proposal:old-term")
          republisher = VolunteerOpportunityManagement.new(
            organization: @organization, opportunity: cancelled, actor: @admin,
            action: "republish", scope: "term", attributes: {
              starts_at: 7.days.from_now.in_time_zone("Europe/Sarajevo").strftime("%Y-%m-%dT%H:%M"),
              ends_at: 8.days.from_now.in_time_zone("Europe/Sarajevo").strftime("%Y-%m-%dT%H:%M")
            }, reason: "New date"
          )
          result = republisher.call(expected_token: republisher.preview.token)
          assert_equal :updated, result.status
          assert_equal cancelled.proposal_identity, result.terms.first.proposal_identity
          assert_equal "pending", result.terms.first.review_status
        end

        test "foreign and non-admin requests cannot read or decide this organization's work" do
          foreign = create_organization
          VolunteerOpportunity.create!(organization: foreign, title: "Foreign secret", active: true,
                                       review_status: "approved", starts_at: 1.day.from_now)
          sign_in @admin
          get "/admin/bih/volunteering"
          assert_response :success
          assert_not_includes response.body, "Foreign secret"

          sign_out @admin
          sign_in @citizen
          get "/admin/bih/volunteering"
          assert_response :redirect
          post "/admin/bih/volunteering/applications/#{@pending.id}/decide", params: { decision: "approve" }
          assert_response :redirect
          assert_equal "pending", @pending.reload.review_status
        end

        private

        def create_pending_series!(key, partner_name: nil)
          [1, 2].map do |position|
            VolunteerOpportunity.create!(
              organization: @organization, title: key, active: false, review_status: "pending",
              starts_at: (position + 5).days.from_now, ends_at: (position + 5).days.from_now + 2.hours,
              series_key: key.parameterize, series_position: position, series_total: 2,
              proposal_identity: "proposal:#{key.parameterize}", partner_name:
            )
          end
        end
      end
    end
  end
end
