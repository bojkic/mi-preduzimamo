# frozen_string_literal: true

require "application_system_test_case"
require "decidim/participatory_processes/test/factories"

class LayoutUpgradeBrowserTest < ApplicationSystemTestCase
  setup do
    @organization = create_organization
    use_organization_host!(@organization)
    @process = create(:participatory_process, organization: @organization, published_at: Time.current,
                      promoted: true, slug: DecidimApp::Bijeljina::RaceProjectSelection::PROCESS_SLUG,
                      title: @organization.available_locales.index_with { "Synthetic community projects" })
  end

  test "compiled campaign and desktop navigation remain usable after the upgrade" do
    page.driver.browser.manage.window.resize_to(1440, 1100)
    visit "/sr-Cyrl/processes/#{@process.slug}"
    accept_data_consent!
    assert_selector "main.mi-project-choice"
    assert_equal "grid", page.evaluate_script("getComputedStyle(document.querySelector('.mi-project-choice__cards')).display")
    find("#main-dropdown-summary").click
    assert_selector "#main-dropdown-menu[aria-hidden=false]"
    assert_selector "#main-dropdown-menu .card__highlight"
    assert_selector "#main-dropdown-menu a[href*='prijave/new']"
    bounds = page.evaluate_script("(() => { const r=document.getElementById('main-dropdown-menu').getBoundingClientRect();return [r.left,r.right,innerWidth]; })()")
    assert_operator bounds[0], :>=, 0
    assert_operator bounds[1], :<=, bounds[2]
    find("#main-dropdown-summary").send_keys(:escape)
    assert_no_selector "#main-dropdown-menu[aria-hidden=false]"
    assert_no_horizontal_overflow!
  end

  test "native footer language form works in every platform language on a phone" do
    page.driver.browser.manage.window.resize_to(390, 844)
    visit "/otvoreni-kod?locale=sr"
    accept_data_consent!
    %w(sr-Cyrl bs hr sr).each do |locale|
      form = find("#mi-footer-language-form")
      form.find("option[value='#{locale}']").select_option
      form.find("button[type=submit], input[type=submit]").click
      assert_selector ".mi-open-source[lang='#{locale == 'sr' ? 'sr-Latn' : locale}']"
      assert_equal locale, find("#mi-footer-language", visible: :all).value
      assert_no_text "translation_missing"
      assert_no_horizontal_overflow!
    end
    find("[data-mi-mobile-more-open]").click
    assert_selector "[data-mi-mobile-more-close]"
  end
end
