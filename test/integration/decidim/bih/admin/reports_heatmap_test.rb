# frozen_string_literal: true

require "test_helper"
require "capybara"

module Decidim
  module Bih
    module Admin
      # The admin reports index also surfaces the PII-free per-MZ problem
      # heatmap (reusing Decidim::Bih::ReportHeatmap). Operators get a
      # community-level view alongside the per-report triage queue.
      class ReportsHeatmapTest < ActionDispatch::IntegrationTest
        include ::Devise::Test::IntegrationHelpers

        setup do
          @organization = create_organization
          host! @organization.host
          @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)

          @mz = Decidim::Bih::LocalArea.create!(
            organization: @organization, kind: "mz", slug: "mz-centar",
            name: { "sr" => "Centar", "en" => "Centre" }
          )

          2.times do
            Decidim::Bih::Report.create!(
              organization: @organization,
              description: "Rupa #{SecureRandom.hex(4)}",
              category: "putevi",
              mz_slug: "mz-centar"
            )
          end
        end

        test "admin index renders the per-MZ heatmap section with counts" do
          sign_in @admin
          get "/admin/bih/reports", params: { tab: "insights" }

          assert_response :success
          assert_includes response.body, "admin-reports-heatmap"
          assert_includes response.body, "Centar"
          assert_includes response.body, "2"
        end

        test "admin heatmap does not leak report PII" do
          Decidim::Bih::Report.create!(
            organization: @organization,
            description: "Tajni admin opis koji ne smije iscuriti",
            category: "putevi",
            mz_slug: "mz-centar",
            reporter_email: "tajni@example.org"
          )

          sign_in @admin
          get "/admin/bih/reports"

          assert_response :success
          assert_not_includes response.body, "Tajni admin opis koji ne smije iscuriti"
          assert_not_includes response.body, "tajni@example.org"
        end
      end
    end
  end
end
