# frozen_string_literal: true

require "test_helper"
require "capybara"

module Decidim
  module Bih
    module Admin
      # Round 25 / W4.5 — read-only integrations health page. Must render a
      # status row per integration (Gemini, Odoo, Infobip/Viber+SMS, SMTP) and
      # NEVER raise when an integration is unconfigured (the test env has none of
      # the integration ENV vars set), and must never print secrets.
      class IntegrationsControllerTest < ActionDispatch::IntegrationTest
        include ::Devise::Test::IntegrationHelpers

        setup do
          @organization = create_organization
          host! @organization.host
          @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
          @citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
          # Swap in an injected, in-memory-backed health instance so the live
          # state the page shows is deterministic and Redis-free.
          @store = Decidim::Bih::IntegrationHealth::MemoryStore.new
          Decidim::Bih::IntegrationHealth.instance =
            Decidim::Bih::IntegrationHealth.new(store: @store)
          @original_city_data_freshness_provider = Decidim::Bih.city_data_freshness_provider
          @original_city_data_preview_provider = Decidim::Bih.city_data_preview_provider
          Decidim::Bih.city_data_preview_provider = nil
        end

        teardown do
          Decidim::Bih::IntegrationHealth.reset!
          Decidim::Bih.city_data_freshness_provider = @original_city_data_freshness_provider
          Decidim::Bih.city_data_preview_provider = @original_city_data_preview_provider
        end

        test "admin can access the integrations health page" do
          sign_in @admin
          get "/admin/bih/integrations"
          assert_response :success
          assert_includes response.body, "admin-integrations-runbook"
          assert_includes response.body, "script/mi_ops_health_smoke"
        end

        test "non-admin is denied access" do
          sign_in @citizen
          get "/admin/bih/integrations"
          assert_response :redirect
        end

        test "the page renders a status row for each integration" do
          sign_in @admin
          get "/admin/bih/integrations"
          assert_response :success

          %w(gemini odoo infobip smtp).each do |key|
            assert_includes response.body,
                            I18n.t("decidim.bih.admin.integrations.providers.#{key}"),
                            "expected a status row for #{key}"
          end
        end

        test "does not 500 when every integration is unconfigured" do
          # The test env sets none of the integration ENV vars, so all providers
          # are "not configured". The page must render cleanly anyway.
          sign_in @admin
          get "/admin/bih/integrations"
          assert_response :success
          assert_includes response.body, I18n.t("decidim.bih.admin.integrations.not_configured")
        end

        # The live-state and warning copy are NEW i18n keys finalised by the
        # translator, so these assertions key off STABLE, locale-independent
        # markers the view emits (a per-row data-health attribute and a banner
        # id) rather than translated text.
        test "shows the live OK state when the subscriber has recorded a recent success" do
          Decidim::Bih::IntegrationHealth.instance.record(
            "decidim_bih.odoo.rpc",
            { provider: "odoo", success: true, http_status: 200 }
          )

          sign_in @admin
          get "/admin/bih/integrations"
          assert_response :success
          assert_includes response.body, 'data-health="ok"'
        end

        test "shows the live failing state with the http status when the last call failed" do
          Decidim::Bih::IntegrationHealth.instance.record(
            "decidim_bih.infobip.request",
            { provider: "infobip", success: false, http_status: 401, error_class: "Decidim::Bih::Infobip::Error" }
          )

          sign_in @admin
          get "/admin/bih/integrations"
          assert_response :success
          assert_includes response.body, 'data-health="failing"'
          # The scrubbed http status surfaces so the operator sees "(401)".
          assert_includes response.body, "401"
        end

        test "shows the unknown live state when nothing has been recorded yet" do
          sign_in @admin
          get "/admin/bih/integrations"
          assert_response :success
          assert_includes response.body, 'data-health="unknown"'
        end

        test "shows city-data freshness rows without raw provider fields" do
          Decidim::Bih.city_data_freshness_provider = fake_city_data_provider

          sign_in @admin
          get "/admin/bih/integrations"

          assert_response :success
          assert_includes response.body, "admin-city-data-freshness"
          assert_includes response.body, "Waste schedule"
          assert_includes response.body, "Elektro Bijeljina planned outages"
          assert_includes response.body, "2026-06-07"
          assert_includes response.body, "script/mi_city_data_refresh_readiness waste_schedule"
          assert_includes response.body, "script/mi_city_service_source_probe electricity_outages"
          assert_includes response.body, 'data-city-data-status="ok"'
          assert_includes response.body, 'data-city-data-status="warn"'
          assert_not_includes response.body, "Private raw source text"
        end

        test "shows admin-only city-data previews without raw provider fields" do
          Decidim::Bih.city_data_preview_provider = fake_city_data_preview_provider

          sign_in @admin
          get "/admin/bih/integrations", params: { city_waste_query: "Dvorovi", city_budget_query: "socijalni" }

          assert_response :success
          assert_includes response.body, "admin-city-data-preview"
          assert_includes response.body, "Waste schedule"
          assert_includes response.body, "Budget snapshot"
          assert_includes response.body, "Dvorovi"
          assert_includes response.body, "Centar za socijalni rad"
          assert_not_includes response.body, "Private raw source text"
        end

        test "renders the Gemini misrouted warning when api_key is set on the blocked AI Studio host" do
          previous_key = ENV.fetch("GEMINI_API_KEY", nil)
          previous_url = ENV.fetch("GEMINI_BASE_URL", nil)
          ENV["GEMINI_API_KEY"] = "abc123"
          ENV.delete("GEMINI_BASE_URL") # falls back to the blocked AI Studio default
          Decidim::Bih::Config.reset!

          sign_in @admin
          get "/admin/bih/integrations"
          assert_response :success
          assert_includes response.body, "admin-integrations-gemini-misrouted"
        ensure
          previous_key.nil? ? ENV.delete("GEMINI_API_KEY") : (ENV["GEMINI_API_KEY"] = previous_key)
          previous_url.nil? ? ENV.delete("GEMINI_BASE_URL") : (ENV["GEMINI_BASE_URL"] = previous_url)
          Decidim::Bih::Config.reset!
        end

        test "does not render the Gemini misrouted warning when correctly routed to Vertex" do
          previous_key = ENV.fetch("GEMINI_API_KEY", nil)
          previous_url = ENV.fetch("GEMINI_BASE_URL", nil)
          ENV["GEMINI_API_KEY"] = "abc123"
          ENV["GEMINI_BASE_URL"] = "https://aiplatform.googleapis.com"
          Decidim::Bih::Config.reset!

          sign_in @admin
          get "/admin/bih/integrations"
          assert_response :success
          assert_not_includes response.body, "admin-integrations-gemini-misrouted"
        ensure
          previous_key.nil? ? ENV.delete("GEMINI_API_KEY") : (ENV["GEMINI_API_KEY"] = previous_key)
          previous_url.nil? ? ENV.delete("GEMINI_BASE_URL") : (ENV["GEMINI_BASE_URL"] = previous_url)
          Decidim::Bih::Config.reset!
        end

        test "never prints a secret value even when one is configured" do
          previous = ENV.fetch("ODOO_API_KEY", nil)
          ENV["ODOO_API_KEY"] = "super-secret-odoo-key-123"
          Decidim::Bih::Config.reset!

          sign_in @admin
          get "/admin/bih/integrations"
          assert_response :success
          assert_not_includes response.body, "super-secret-odoo-key-123"
        ensure
          if previous.nil?
            ENV.delete("ODOO_API_KEY")
          else
            ENV["ODOO_API_KEY"] = previous
          end
          Decidim::Bih::Config.reset!
        end

        def fake_city_data_provider
          Class.new do
            def self.statuses(organization:)
              [
                {
                  key: "waste_schedule",
                  label: "Waste schedule",
                  status: "ok",
                  last_updated_on: "2026-06-07",
                  refresh_command: "script/mi_city_data_refresh_readiness waste_schedule",
                  detail: "source_year=2026 covered_entries=100",
                  raw_source_text: "Private raw source text"
                },
                {
                  key: "service_source.electricity_outages",
                  label: "Elektro Bijeljina planned outages",
                  status: "ok",
                  last_updated_on: "2026-06-19",
                  refresh_command: "script/mi_city_service_source_probe electricity_outages",
                  detail: "provider=Elektro Bijeljina delivery=viber_alert_candidate target=area_required"
                },
                {
                  key: "local_areas",
                  label: "Local areas",
                  status: "warn",
                  last_updated_on: "2026-06-16",
                  refresh_command: "rake decidim_bih:geo:validate[#{organization.host}]",
                  detail: "areas=2 integrity_issues=1"
                }
              ]
            end
          end
        end

        def fake_city_data_preview_provider
          Class.new do
            def self.previews(organization: nil, waste_query: nil, budget_query: nil, locale: I18n.locale)
              _organization = organization
              _locale = locale

              [
                {
                  key: "waste_schedule",
                  label: "Waste schedule",
                  query: waste_query,
                  query_param: "city_waste_query",
                  placeholder: "Area",
                  source_url: "https://example.test/waste",
                  metadata: "source_year=2026 covered_entries=2",
                  rows: [{ label: "Dvorovi", value: "ponedjeljak, četvrtak", raw: "Private raw source text" }]
                },
                {
                  key: "budget_snapshot",
                  label: "Budget snapshot",
                  query: budget_query,
                  query_param: "city_budget_query",
                  placeholder: "Category",
                  source_url: "https://example.test/budget",
                  metadata: "source_year=2026 line_items=33",
                  rows: [{ label: "Centar za socijalni rad", value: "1.780.000 KM" }]
                }
              ]
            end
          end
        end
      end
    end
  end
end
