# frozen_string_literal: true

require "application_system_test_case"

class HomepageRegistrationCtaTest < ApplicationSystemTestCase
  setup do
    @organization = create_organization
    use_organization_host!(@organization)
    create(:content_block, organization: @organization, scope_name: :homepage, manifest_name: :mi_hero, weight: 1)
    # Same reason as menu_registration_test: this file describes the ordinary
    # hero. Between 6.9.2026 and 14.10.2026 20:00 the suite runs inside the
    # trka komšiluka window, where config/initializers/decidim_bih_launch_mode.rb
    # feeds the cell its own launch buttons and a stat threshold. Pin the mode
    # off so these expectations do not depend on the day the suite is run.
    Decidim::Bih::Setting.put(@organization, "launch", "mode", "off")
  end

  test "public activity is visible and usable on desktop and mobile" do
    report = Decidim::Bih::Report.create!(organization: @organization, description: "Private report body")
    opportunity = Decidim::Bih::VolunteerOpportunity.create!(organization: @organization, title: "Volonterska akcija u gradu")

    [[1400, 900], [390, 844]].each do |width, height|
      page.driver.browser.manage.window.resize_to(width, height)
      visit "/"
      accept_data_consent!
      assert_selector ".mi-ticker", text: /#{Regexp.escape(I18n.t("decidim.bih.homepage_activity.title", locale: :sr))}/i
      assert_selector ".mi-ticker a[href='/biceriseno/prijave/#{report.reference}']"
      assert_selector ".mi-ticker a[href='/biceriseno/volontiranje#volunteer-opportunity-#{opportunity.id}']"
      assert_no_horizontal_overflow!
      assert_no_browser_console_errors!
    end
  end

  test "homepage shows registration benefits in the desktop first viewport" do
    page.driver.browser.manage.window.resize_to(1400, 900)

    visit "/"
    accept_data_consent!

    assert_selector ".mi-hero-register", text: "Registruj se i preuzmi svoj dio platforme."
    assert_selector ".mi-hero-register a[href='/registracija']", text: "Registruj se"
    assert_selector ".mi-hero-register", text: "Bodovi i nagrade za doprinos"
    assert_no_selector ".mi-action-launcher--desktop"
    assert_no_horizontal_overflow!
    assert_no_browser_console_errors!
  end

  # On a phone the hero's registration panel is hidden (2026-09-07): the
  # toolbar at the top of every page carries the account entry instead, and
  # the live ticker takes the panel's place under the CTAs.
  test "homepage keeps the account entry reachable on mobile without the hero panel" do
    page.driver.browser.manage.window.resize_to(390, 844)

    visit "/"
    accept_data_consent!

    assert_no_selector ".mi-hero-register", visible: :visible
    assert_selector ".mi-mobile-bottom-nav a[href='/sr/users/sign_in']"
    assert_no_selector ".mi-action-launcher--mobile"
    assert_selector ".mi-mobile-bottom-nav a[href='/biceriseno/prijave/new']", text: "Problem"
    assert_selector ".mi-mobile-bottom-nav a[href='/biceriseno/mi-bot']", text: "Milica"
    assert_selector ".mi-mobile-more-sheet a[href='/biceriseno/volontiranje']", visible: :all
    assert_no_horizontal_overflow!
    assert_no_browser_console_errors!
  end

  test "mobile invitation stays joined to the homepage after scroll and resize" do
    user = create(:user, :confirmed, organization: @organization)
    Decidim::Authorization.create!(user:, name: "sms", granted_at: Time.current)
    Decidim::Bih::Setting.put(@organization, "launch", "mode", "on")
    sign_in_user!(user)
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 390, height: 844, deviceScaleFactor: 1, mobile: true)
    visit "/"
    accept_data_consent!
    assert_selector ".mi-invite-nudge", visible: true
    page.execute_script('window.scrollTo(0, 220); window.dispatchEvent(new Event("resize"));')
    assert_equal "0px", page.evaluate_script('getComputedStyle(document.getElementById("menu-bar-container")).marginTop')
    gap = page.evaluate_script(<<~JS)
      document.getElementById("content").getBoundingClientRect().top -
        document.querySelector("header[role=banner]").getBoundingClientRect().bottom
    JS
    assert_operator gap.abs, :<=, 2
    assert_no_horizontal_overflow!
  end
end
