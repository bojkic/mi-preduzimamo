# frozen_string_literal: true

require "test_helper"
require "capybara"

module Decidim
  module Bih
    module Admin
      class PrivacyRetentionControllerTest < ActionDispatch::IntegrationTest
        include ::Devise::Test::IntegrationHelpers

        setup do
          @organization = create_organization
          host! @organization.host
          @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
          @citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
        end

        test "admin can view aggregate privacy retention status" do
          create_private_retention_source!
          create_retention_run!

          sign_in @admin
          get "/admin/bih/privacy-retention"

          assert_response :success
          assert_includes response.body, "admin-privacy-retention-header"
          assert_includes response.body, "admin-privacy-retention-current"
          assert_includes response.body, "admin-privacy-retention-history"
          assert_includes response.body, "admin-privacy-retention-approval"
          assert_includes response.body, "docs/operations/privacy-retention-sweeps.md"
          assert_includes response.body, "script/mi_monthly_maintenance_readiness_smoke"
          assert_includes response.body, 'data-retention-bucket="report_contacts"'
          assert_includes response.body, 'data-retention-bucket="report_coordinates"'
          assert_includes response.body, 'data-retention-run-status="ok"'
          assert_includes response.body, 'data-retention-history-count="report_contacts"'
          assert_includes response.body, 'data-retention-status="warn"'
          assert_no_private_values response.body
        end

        test "non-admin is denied privacy retention access" do
          sign_in @citizen
          get "/admin/bih/privacy-retention"

          assert_response :redirect
        end

        private

        def create_private_retention_source!
          Decidim::Bih::Report.create!(
            organization: @organization,
            description: "Private retention report description",
            reporter_email: "retention-page-private@example.org",
            reporter_phone: "+387 65 222 333",
            latitude: 44.756123,
            longitude: 19.214987,
            created_at: 4.years.ago
          )
        end

        def create_retention_run!
          Decidim::Bih::Privacy::RetentionRun.create!(
            organization: @organization,
            status: "ok",
            dry_run: false,
            source: "test",
            started_at: 1.hour.ago,
            finished_at: 59.minutes.ago,
            counts: { "report_contacts" => 1, "report_coordinates" => 1 },
            total: 2,
            cutoffs: { "report_contact_before" => 3.years.ago.utc.iso8601 }
          )
        end

        def assert_no_private_values(body)
          assert_not_includes body, "Private retention report description"
          assert_not_includes body, "retention-page-private@example.org"
          assert_not_includes body, "+387 65 222 333"
          assert_not_includes body, "44.756123"
          assert_not_includes body, "19.214987"
        end
      end
    end
  end
end
