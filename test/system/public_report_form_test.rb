# frozen_string_literal: true

require "application_system_test_case"

class PublicReportFormTest < ApplicationSystemTestCase
  setup do
    @organization = create_organization
    use_organization_host!(@organization)
  end

  test "citizen submits a report from the accessible mobile form" do
    page.driver.browser.manage.window.resize_to(1365, 900)
    visit "/biceriseno/prijave/new"
    accept_data_consent!

    assert_no_horizontal_overflow!

    page.driver.browser.manage.window.resize_to(390, 844)
    assert_no_horizontal_overflow!

    fill_in I18n.t("decidim.bih.reports.new.labels.description", locale: :sr),
            with: "Rupa na putu kod skole"
    fill_in I18n.t("decidim.bih.reports.new.labels.address", locale: :sr),
            with: "Karadjordjeva 1"

    assert_selector "#bih-report-location-map.leaflet-container[data-initialized='true']", wait: 5
    find_by_id("bih-report-location-map").click
    assert_selector "#bih-report-location-status", text: I18n.t("decidim.bih.reports.new.location.selected", locale: :sr)

    before_count = Decidim::Bih::Report.count
    click_on I18n.t("decidim.bih.reports.new.submit", locale: :sr)

    assert_current_path(%r{\A/biceriseno/prijave/BR-\d{4}-\d+/status/[A-Za-z0-9_-]{32,}\z}, wait: 5)
    reference = page.current_path.split("/")[-3]
    report = Decidim::Bih::Report.find_by!(organization: @organization, reference:)
    assert_equal before_count + 1, Decidim::Bih::Report.count
    assert_text report.reference
    assert_equal report.status_token, page.current_path.split("/").last
  end
end
