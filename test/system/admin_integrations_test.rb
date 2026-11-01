# frozen_string_literal: true

require "application_system_test_case"

class AdminIntegrationsTest < ApplicationSystemTestCase
  setup do
    @organization = create_organization
    use_organization_host!(@organization)
    @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
    @original_city_data_freshness_provider = Decidim::Bih.city_data_freshness_provider
    @original_city_data_preview_provider = Decidim::Bih.city_data_preview_provider
    Decidim::Bih.city_data_freshness_provider = fake_city_data_provider
    Decidim::Bih.city_data_preview_provider = fake_city_data_preview_provider
  end

  teardown do
    Decidim::Bih.city_data_freshness_provider = @original_city_data_freshness_provider
    Decidim::Bih.city_data_preview_provider = @original_city_data_preview_provider
  end

  test "admin integrations page renders city-data freshness without raw fields" do
    sign_in_user! @admin

    visit "/admin/bih/integrations"
    accept_data_consent!

    assert_selector "#admin-integrations-header"
    assert_selector "#admin-integrations-runbook"
    assert_selector "#admin-integrations-list"
    assert_selector "#admin-city-data-freshness", text: "Waste schedule"
    assert_selector "#admin-city-data-freshness", text: "Elektro Bijeljina planned outages"
    assert_selector "#admin-city-data-freshness", text: "Local areas"
    assert_no_text "script/mi_city_service_source_probe electricity_outages"
    within "#admin-city-data-freshness tr", text: "Elektro Bijeljina planned outages" do
      find("details").click
      assert_text "script/mi_city_service_source_probe electricity_outages"
    end
    assert_selector "#admin-city-data-preview", text: "Waste schedule"
    assert_selector "#admin-city-data-preview", text: "Budget snapshot"
    assert_selector "#admin-city-data-preview", text: "Dvorovi"
    assert_selector "#admin-city-data-preview", text: "Centar za socijalni rad"
    assert_selector "[data-city-data-status='ok']"
    assert_selector "[data-city-data-status='warn']"
    assert_no_text "Private raw source text"
    assert_no_horizontal_overflow!
    assert_no_browser_console_errors!
  end

  private

  def fake_city_data_provider
    Class.new do
      def self.statuses(organization:)
        [
          {
            key: "waste_schedule",
            label: "Waste schedule",
            status: "ok",
            last_updated_on: "2026-06-07",
            refresh_command: "bin/refresh-city-data.sh",
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
            metadata: "source_year=2026 covered_entries=100",
            rows: [{ label: "Dvorovi", value: "ponedjeljak, četvrtak", raw_source_text: "Private raw source text" }]
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
