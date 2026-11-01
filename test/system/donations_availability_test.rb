# frozen_string_literal: true

require "application_system_test_case"

class DonationsAvailabilitySystemTest < ApplicationSystemTestCase
  Totals = Struct.new(:total, :count, :currency, :as_of, keyword_init: true) # rubocop:disable Lint/StructNewOverride -- domain count
  Provider = Struct.new(:totals, :currency_label, :project_mappings, keyword_init: true)

  setup do
    @organization = create_organization
    use_organization_host!(@organization)
    @original_provider = Decidim::Bih.donations_provider
  end

  teardown { Decidim::Bih.donations_provider = @original_provider }

  test "mobile unavailable total keeps project navigation without horizontal overflow" do
    Decidim::Bih.donations_provider = nil
    page.driver.browser.manage.window.resize_to(390, 844)
    visit "/biceriseno/donacije?locale=sr"
    accept_data_consent!
    within ".mi-donation-hero[data-donation-state='unavailable']" do
      assert_selector ".mi-donation-unavailable", text: I18n.t("decidim.bih.donations.show.total_unavailable", locale: :sr)
      assert_no_selector ".mi-donation-total, .mi-donation-count"
      assert_no_horizontal_overflow!
      find("a[href*='/biceriseno/projekti']").click
    end
    assert_current_path %r{\A/(?:biceriseno/)?projekti(?:\?.*)?\z}, ignore_query: false
    assert_selector "#community-projects-title"
    assert_no_horizontal_overflow!
    visit "/biceriseno/donacije?locale=sr"
    accept_data_consent!
    page.driver.browser.manage.window.resize_to(320, 740)
    assert_no_horizontal_overflow!
    save_screenshot Rails.root.join("tmp/screenshots/donations-unavailable-mobile.png")
  end

  test "desktop measured zero remains an amount rather than an unavailable total" do
    Decidim::Bih.donations_provider = Provider.new(
      totals: Totals.new(total: 0, count: 0, currency: "BAM", as_of: Time.current),
      currency_label: "KM", project_mappings: []
    )
    page.driver.browser.manage.window.resize_to(1400, 1000)
    visit "/biceriseno/donacije?locale=sr"
    accept_data_consent!
    within ".mi-donation-hero[data-donation-state='available']" do
      assert_selector ".mi-donation-total strong", exact_text: "0"
      assert_selector ".mi-donation-count"
      assert_no_selector ".mi-donation-unavailable"
      assert_selector "a[href*='/biceriseno/projekti']"
    end
    assert_no_horizontal_overflow!
    save_screenshot Rails.root.join("tmp/screenshots/donations-measured-zero-desktop.png")
  end
end
