# frozen_string_literal: true

require "test_helper"
require "support/synthetic_release_policy"
require "capybara"

module Decidim
  module Bih
    module Admin
      # The custom admin sidebar should expose only daily/top-level MI entries.
      # Lower-frequency routes remain discoverable through the grouped MI
      # operations hub.
      class AdminMenuTest < ActionDispatch::IntegrationTest
        include SyntheticReleasePolicy
        include ::Devise::Test::IntegrationHelpers

        setup do
          @organization = create_organization
          host! @organization.host
          @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
          sign_in @admin
          # Render an admin page so @controller.view_context carries the admin
          # chrome (route proxies, current_user, helpers).
          get "/admin/bih/goodwill"
          assert_response :success
        end

        def admin_menu_items
          menu = Decidim::Menu.new(:admin_menu)
          menu.build_for(@controller.view_context)
          menu.items
        end

        def admin_menu_urls
          admin_menu_items.map(&:url)
        end

        test "admin_menu exposes only the daily/top-level BIH surfaces" do
          expected = %w(
            /admin/bih/operations
            /admin/bih/goodwill
            /admin/bih/reports
            /admin/bih/komsiluk-posts
            /admin/bih/city-alerts
          )

          expected.each { |url| assert_includes admin_menu_urls, url }

          demoted = %w(
            /admin/bih/rewards
            /admin/bih/citizens
            /admin/bih/volunteering
            /admin/bih/board-notices/new
            /admin/bih/integrations
            /admin/bih/analytics
            /admin/bih/privacy-retention
            /admin/bih/governance
            /admin/bih/goodwill-settings
            /admin/bih/local-areas
            /admin/bih/sistem48-settings
          )

          demoted.each { |url| assert_not_includes admin_menu_urls, url }
        end

        test "top-level operator items carry a non-blank label" do
          urls = %w(
            /admin/bih/operations
            /admin/bih/goodwill
            /admin/bih/reports
            /admin/bih/komsiluk-posts
            /admin/bih/city-alerts
          )
          items = admin_menu_items.select { |i| urls.include?(i.url) }
          assert_equal urls.size, items.size
          items.each { |i| assert i.label.present?, "menu item #{i.url} has a blank label" }
        end

        test "operations hub links the demoted admin surfaces" do
          get "/admin/bih/operations"
          assert_response :success

          %w(
            /admin/bih/rewards
            /admin/bih/citizens
            /admin/bih/volunteering
            /admin/bih/board-notices/new
            /admin/bih/integrations
            /admin/bih/analytics
            /admin/bih/privacy-retention
            /admin/bih/governance
            /admin/bih/goodwill-settings
            /admin/bih/local-areas
            /admin/bih/sistem48-settings
            /admin/bih/city-alerts
          ).each do |url|
            assert_includes response.body, url
          end
        end

        test "operations hub ignores unavailable navigation entries" do
          original_groups = Decidim::Bih::Admin::Navigation.method(:groups)
          Decidim::Bih::Admin::Navigation.define_singleton_method(:groups) do |view_context:|
            [
              nil,
              {
                id: "daily",
                label: "Daily work",
                items: [
                  nil,
                  {},
                  {
                    id: "reports",
                    label: "Citizen reports",
                    url: view_context.decidim_admin_bih.admin_bih_reports_path,
                    description: "Review citizen reports.",
                    permission: :reports_read
                  }
                ]
              },
              {
                id: "empty",
                label: "Empty",
                items: [nil]
              }
            ]
          end

          get "/admin/bih/operations"
          assert_response :success
          assert_select "[data-admin-navigation-group='daily']"
          assert_select "[data-admin-navigation-group='empty']", false
          assert_select "[data-admin-navigation-item='reports']"
        ensure
          Decidim::Bih::Admin::Navigation.define_singleton_method(:groups) do |view_context:|
            original_groups.call(view_context:)
          end
        end

        test "admin bih root opens the operations dashboard" do
          get "/admin/bih"
          assert_response :success

          assert_select "#admin-bih-navigation"
          assert_select "[data-admin-navigation-group='alerts']"
          assert_select "[data-admin-navigation-group='governance']"
          assert_select "[data-admin-handoff='privacy_retention']"
          assert_select "[data-admin-navigation-item='komsiluk_posts']"
          assert_select "[data-admin-navigation-item='staff_publication']"
          assert_select "[data-admin-navigation-item='broadcasts']", false
          assert_select "[data-admin-navigation-item='city_alerts']"
          assert_select "[data-admin-navigation-item='governance']"
          assert_select "[data-admin-navigation-item='volunteering']"
          assert_select "[data-admin-navigation-access='reports']"
          assert_select "[data-admin-navigation-access='city_alerts']"
          assert_includes response.body, "/admin/bih/goodwill"
        end

        test "decidim admin dashboard keeps core route and links MI operations" do
          get "/admin/"
          assert_response :success

          assert_select "h1", text: /Dashboard|Kontrolna|Administr/
          assert_select "#admin-bih-dashboard-entry[data-admin-dashboard-bih-entry='operations']"
          assert_select "a[href='/admin/bih/operations'][data-admin-dashboard-bih-entry-link='operations']"
        end

        test "destination navigation shows breadcrumbs and current area siblings" do
          get "/admin/bih/goodwill"
          assert_response :success

          assert_select "[data-admin-breadcrumb='operations']"
          assert_select "[data-admin-breadcrumb='area_community']"
          assert_select "[data-admin-breadcrumb='goodwill']"
          assert_select "[data-admin-navigation-current-area='community']"
          assert_select "[data-admin-navigation-item='rewards']"
          assert_select "[data-admin-navigation-item='reports']", false
        end

        test "host city alerts and postal verification resolve to their workflow areas" do
          get "/admin/bih/city-alerts"
          assert_response :success
          assert_select "[data-admin-breadcrumb='area_alerts']"
          assert_select "[data-admin-navigation-current-area='alerts']"
          assert_select "[data-admin-navigation-item='city_alerts']"

          get "/admin/postal_letter/pending_authorizations"
          assert_response :success
          assert_select "[data-admin-breadcrumb='area_daily']"
          assert_select "[data-admin-navigation-current-area='daily']"
          assert_select "[data-admin-navigation-item='postal_queue']"
        end

        test "governance page exposes approval handoffs without shell history" do
          get "/admin/bih/governance"
          assert_response :success

          assert_select "#admin-governance-readiness"
          assert_select "[data-admin-breadcrumb='area_governance']"
          assert_select "[data-admin-navigation-current-area='governance']"
          assert_select "[data-governance-row='viber_launch']"
          assert_select "[data-governance-row='external_chat_launch']"
          assert_select "[data-governance-row='release_restart']"
          assert_select "[data-governance-row='backup_restore']"
          assert_select "[data-governance-row='cron_maintenance']"
          assert_select "[data-governance-row='privacy_retention']"
          assert_select "[data-governance-latest='release_restart']"
          assert_select "form[action='/admin/bih/governance/release_restart/approvals']"
          assert_includes response.body, "docs/operations/release-approval-policy.md"
          assert_not_includes response.body, "TOKEN"
          assert_not_includes response.body, "PASSWORD"
        end
      end
    end
  end
end
