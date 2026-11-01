# frozen_string_literal: true

require "test_helper"
require "capybara"

module Decidim
  module Bih
    module Admin
      # R13 — admin records and decides matched-giving requests from the
      # goodwill dashboard. The actual grant stays a manual step.
      class MatchRequestDashboardTest < ActionDispatch::IntegrationTest
        include ::Devise::Test::IntegrationHelpers

        setup do
          @organization = create_organization
          host! @organization.host
          @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
          @group = FactoryBot.create(:user, :confirmed, organization: @organization,
                                                        extended_data: { "group" => true })
          hex = SecureRandom.hex(2)
          @group.update!(name: "Udruženje #{hex}", nickname: "udr_#{hex}")
          @profile = Decidim::Bih::PartnerProfile.create!(
            organization: @organization,
            display_name: @group.name,
            slug: @group.nickname,
            kind: "association",
            verification_status: "verified",
            legacy_user_group: @group,
            verified_at: Time.current
          )
        end

        test "an admin records a match request" do
          sign_in @admin
          post "/admin/bih/goodwill/match-request", params: { owner_name: @profile.display_name, points: 120 }

          assert_response :redirect
          req = Decidim::Bih::Goodwill::MatchRequest.last
          assert_equal @profile, req.owner
          assert_equal 120, req.points
          assert_equal "pending", req.status
          assert_equal @admin.id, req.created_by_id
        end

        test "invalid points record nothing" do
          sign_in @admin
          assert_no_difference "Decidim::Bih::Goodwill::MatchRequest.count" do
            post "/admin/bih/goodwill/match-request", params: { owner_name: @profile.display_name, points: 0 }
          end
          assert_response :redirect
        end

        test "an admin approves a pending request" do
          req = Decidim::Bih::Goodwill::MatchRequest.create!(
            organization: @organization, owner: @group, points: 50,
            status: "pending", created_by: @admin
          )
          sign_in @admin
          post "/admin/bih/goodwill/match-request/#{req.id}/decide", params: { decision: "approved" }

          assert_response :redirect
          assert_equal "approved", req.reload.status
          assert_equal @admin.id, req.decided_by_id
        end

        test "an admin records a payout reference for an approved request" do
          req = Decidim::Bih::Goodwill::MatchRequest.create!(
            organization: @organization, owner: @group, points: 50,
            status: "approved", created_by: @admin, decided_by: @admin,
            decided_at: 1.hour.ago
          )

          sign_in @admin
          post "/admin/bih/goodwill/match-request/#{req.id}/payout",
               params: {
                 payout_amount_minor_units: 12_500,
                 payout_currency: "bam",
                 payout_paid_on: "2026-06-17",
                 payout_reference: "ODOO-BILL-42",
                 payout_note: "Paid from June campaign"
               }

          assert_redirected_to "/admin/bih/goodwill?tab=matched_giving#goodwill-match-requests"
          req.reload
          assert_equal "paid", req.payout_status
          assert_equal 12_500, req.payout_amount_minor_units
          assert_equal "BAM", req.payout_currency
          assert_equal Date.new(2026, 6, 17), req.payout_paid_on
          assert_equal "ODOO-BILL-42", req.payout_reference
          assert_equal "Paid from June campaign", req.payout_note
          assert_equal @admin.id, req.payout_recorded_by_id
          assert req.payout_recorded_at.present?
          assert_equal "ODOO-BILL-42", req.metadata.fetch("payout_events").last.fetch("reference")
        end

        test "payout reference requires an approved unpaid request" do
          req = Decidim::Bih::Goodwill::MatchRequest.create!(
            organization: @organization, owner: @group, points: 50,
            status: "pending", created_by: @admin
          )

          sign_in @admin
          post "/admin/bih/goodwill/match-request/#{req.id}/payout",
               params: { payout_amount_minor_units: 12_500, payout_reference: "ODOO-BILL-42" }

          assert_response :redirect
          assert_equal "unpaid", req.reload.payout_status
          assert_nil req.payout_reference
        end

        test "payout reference is organization scoped" do
          other = create_organization
          other_admin = FactoryBot.create(:user, :admin, :confirmed, organization: other)
          req = Decidim::Bih::Goodwill::MatchRequest.create!(
            organization: other, owner: other_admin, points: 50,
            status: "approved", created_by: other_admin, decided_by: other_admin,
            decided_at: 1.hour.ago
          )

          sign_in @admin
          post "/admin/bih/goodwill/match-request/#{req.id}/payout",
               params: { payout_amount_minor_units: 12_500, payout_reference: "ODOO-BILL-42" }

          assert_response :redirect
          assert_equal "unpaid", req.reload.payout_status
          assert_nil req.payout_reference
        end

        test "payout reference rejects missing CSRF token when forgery protection is enabled" do
          req = Decidim::Bih::Goodwill::MatchRequest.create!(
            organization: @organization, owner: @group, points: 50,
            status: "approved", created_by: @admin, decided_by: @admin,
            decided_at: 1.hour.ago
          )

          sign_in @admin
          with_forgery_protection do
            post "/admin/bih/goodwill/match-request/#{req.id}/payout",
                 params: { payout_amount_minor_units: 12_500, payout_reference: "ODOO-BILL-42" }
          end

          assert_response :unprocessable_entity
          assert_equal "unpaid", req.reload.payout_status
        end

        test "the dashboard lists pending match requests" do
          Decidim::Bih::Goodwill::MatchRequest.create!(
            organization: @organization, owner: @group, points: 77,
            status: "pending", created_by: @admin
          )
          sign_in @admin
          get "/admin/bih/goodwill", params: { tab: "matched_giving" }

          assert_response :success
          assert_select "#goodwill-stats[data-goodwill-active-tab='matched_giving']"
          assert_includes response.body, "77"
        end

        test "the dashboard lists approved payouts and recent paid references" do
          approved = Decidim::Bih::Goodwill::MatchRequest.create!(
            organization: @organization, owner: @group, points: 88,
            status: "approved", created_by: @admin, decided_by: @admin,
            decided_at: 1.hour.ago
          )
          paid = Decidim::Bih::Goodwill::MatchRequest.create!(
            organization: @organization, owner: @group, points: 99,
            status: "approved", created_by: @admin, decided_by: @admin,
            decided_at: 2.hours.ago, payout_status: "paid",
            payout_amount_minor_units: 9_900, payout_currency: "BAM",
            payout_paid_on: Date.current, payout_reference: "BANK-99",
            payout_note: "June transfer", payout_recorded_by: @admin,
            payout_recorded_at: 30.minutes.ago
          )

          sign_in @admin
          get "/admin/bih/goodwill", params: { tab: "matched_giving" }

          assert_response :success
          assert_select "#goodwill-stats[data-goodwill-active-tab='matched_giving']"
          assert_includes response.body, "88"
          assert_includes response.body, "99"
          assert_includes response.body, "BANK-99"
          assert_select "form[action=?]", "/admin/bih/goodwill/match-request/#{approved.id}/payout"
          assert_select "form[action=?]", "/admin/bih/goodwill/match-request/#{paid.id}/payout", count: 0
        end

        test "a non-admin cannot record a match request" do
          citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
          sign_in citizen
          assert_no_difference "Decidim::Bih::Goodwill::MatchRequest.count" do
            post "/admin/bih/goodwill/match-request", params: { owner_name: @group.name, points: 50 }
          end
          assert_response :redirect
        end

        private

        def with_forgery_protection
          previous = ActionController::Base.allow_forgery_protection
          ActionController::Base.allow_forgery_protection = true
          yield
        ensure
          ActionController::Base.allow_forgery_protection = previous
        end
      end
    end
  end
end
