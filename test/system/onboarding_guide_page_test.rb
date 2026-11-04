# frozen_string_literal: true

require "application_system_test_case"

class OnboardingGuidePageTest < ApplicationSystemTestCase
  setup do
    @organization = create_organization
    use_organization_host!(@organization)
  end

  test "guide capability index is usable on desktop and mobile" do
    [
      [1440, 1000],
      [390, 844]
    ].each do |width, height|
      page.driver.browser.manage.window.resize_to(width, height)
      visit "/biceriseno/vodic"
      accept_data_consent!

      assert_selector ".mi-guide", text: "Šta mogu ovdje?"
      assert_selector ".mi-guide-account a[href='/registracija']", text: "Registruj se"
      assert_selector ".mi-guide-action[href='/biceriseno/prijave/new?locale=sr']", text: "Nova prijava"
      assert_selector ".mi-guide-action[href='/biceriseno/mi-bot?locale=sr']", text: "Pitaj Milicu"
      assert_selector ".mi-guide-action[href='/biceriseno/mapa?locale=sr']", text: "Mapa prijava"
      assert_selector ".mi-guide-action[href='/biceriseno/komsiluk-board?locale=sr']", text: "Komšiluk tabla"
      assert_no_horizontal_overflow!
      assert_no_browser_console_errors!
    end
  end
end
