# frozen_string_literal: true

require "application_system_test_case"

class RegistrationSimplificationTest < ApplicationSystemTestCase
  setup do
    @organization = create_organization
    use_organization_host!(@organization)
    travel_to Time.utc(2026, 10, 7, 12)
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 390, height: 844, deviceScaleFactor: 1, mobile: true)
    @screenshots = ENV.fetch("MI_REGISTRATION_SCREENSHOTS_DIR", Rails.root.join("tmp/registration-simplification-screenshots").to_s)
    FileUtils.mkdir_p(@screenshots)
  end

  teardown do
    travel_back
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end

  test "race offer and compact signup are usable in the first 390 by 844 viewport" do
    visit "/trka"
    assert_selector ".mi-trka__registration-offer", text: "3.000 KM"
    assert_selector ".mi-trka__registration-offer", text: "1 bod"
    assert_primary_in_view!(".mi-trka__hero--registration .mi-action-row a.mi-btn--primary")
    save_screenshot File.join(@screenshots, "trka-390x844.png") # rubocop:disable Lint/Debugger -- Required mobile acceptance screenshot.
    find(".mi-trka__hero--registration .mi-action-row a.mi-btn--primary").click
    assert_current_path "/registracija?izvor=trka"
    assert_no_selector "#mi-registration-email, #mi-registration-komsiluk, #mi-registration-newsletter"
    assert_selector "#mi-registration-name"
    assert_selector "#mi-registration-phone"
    assert_primary_in_view!("#mi-registration-form button[type=submit]")
    assert page.evaluate_script("document.querySelector('.mi-registration-login').getBoundingClientRect().bottom <= window.innerHeight")
    save_screenshot File.join(@screenshots, "registracija-390x844.png") # rubocop:disable Lint/Debugger -- Required mobile acceptance screenshot.
    accept_data_consent!
    assert_no_horizontal_overflow!
    assert_no_browser_console_errors!
  end

  test "required komsiluk opens the map before address and list and continues to member home" do
    citizen = FactoryBot.create(:user, :confirmed, organization: @organization, email: "", extended_data: { "mi_phone_only_registration" => true })
    area = Decidim::Bih::LocalArea.create!(organization: @organization, kind: "komsiluk", zona: "grad", slug: "mobile-centar", name: { "sr" => "Centar" })
    Decidim::Authorization.create!(user: citizen, name: "sms", unique_id: SecureRandom.hex(12), granted_at: Time.current)
    sign_in_user! citizen
    visit "/biceriseno/komsiluk?setup=1"
    accept_data_consent!
    assert_selector ".mi-komsiluk-setup #bih-komsiluk-select[required]"
    assert_selector ".mi-komsiluk-setup details[open] #bih-komsiluk-map"
    assert page.evaluate_script(<<~JS)
      Boolean(document.querySelector('#bih-komsiluk-map').compareDocumentPosition(document.querySelector('#bih-address-suggest')) & Node.DOCUMENT_POSITION_FOLLOWING)
    JS
    save_screenshot File.join(@screenshots, "komsiluk-390x844.png") # rubocop:disable Lint/Debugger -- Required mobile acceptance screenshot.
    within ".mi-komsiluk-setup" do
      select "Centar", from: "bih-komsiluk-select"
      click_button I18n.t("decidim.bih.komsiluk.edit.dropdown_save")
    end
    assert_current_path "/biceriseno/moj-nalog"
    assert_equal area.id, Decidim::Bih::CitizenProfile.find_by!(decidim_user_id: citizen.id).komsiluk_id
    assert_no_selector "#potvrda-emaila"
    assert_no_horizontal_overflow!
  end

  test "smaller iPhone and Android viewports allow scrolling and larger text without clipping" do
    [[375, 812, "iphone"], [412, 915, "android"]].each do |width, height, device|
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: width, height: height, deviceScaleFactor: 1, mobile: true)
      visit "/registracija"
      accept_data_consent!
      assert_no_horizontal_overflow!
      find("#mi-registration-form button[type=submit]").scroll_to(:center)
      assert_selector "#mi-registration-form button[type=submit]"
      save_screenshot File.join(@screenshots, "registracija-#{device}-#{width}x#{height}.png") # rubocop:disable Lint/Debugger -- Required mobile acceptance screenshot.
    end
    page.execute_script("document.documentElement.style.fontSize = '200%'")
    find_by_id("mi-registration-name").fill_in(with: "Мила Грађанка")
    assert_equal "Мила Грађанка", find_by_id("mi-registration-name").value
    assert_no_horizontal_overflow!
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 390, height: 480, deviceScaleFactor: 1, mobile: true)
    find_by_id("mi-registration-phone").click
    find("#mi-registration-form button[type=submit]").scroll_to(:center)
    assert_selector "#mi-registration-form button[type=submit]"
    assert_no_horizontal_overflow!
  end

  private

  def assert_primary_in_view!(selector)
    result = page.evaluate_script(<<~JS, selector)
      (function(selector) {
      const element = document.querySelector(selector);
      const bounds = element.getBoundingClientRect();
      const center = document.elementFromPoint(bounds.left + bounds.width / 2, bounds.top + bounds.height / 2);
      return {width: window.innerWidth, height: window.innerHeight,
        top: bounds.top, bottom: bounds.bottom, unobscured: center === element || element.contains(center)};
      })(arguments[0])
    JS
    assert_equal 390, result.fetch("width")
    assert_equal 844, result.fetch("height")
    assert_operator result.fetch("top"), :>=, 0
    assert_operator result.fetch("bottom"), :<=, 844
    assert result.fetch("unobscured"), "primary action is covered by another surface: #{result.inspect}"
  end
end
