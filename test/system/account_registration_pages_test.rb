# frozen_string_literal: true

require "application_system_test_case"

class AccountRegistrationPagesTest < ApplicationSystemTestCase
  setup do
    @organization = create_organization
    use_organization_host!(@organization)
    @citizen = FactoryBot.create(:user, :confirmed, organization: @organization, name: "Mila Gradjanka")
  end

  # Isporuka D: /users/sign_up now redirects to the one-step form, and the old
  # two-step page (with its benefits panel) is no longer rendered anywhere. The
  # surface worth measuring is the form a citizen actually fills in.
  test "the one-step registration form fits without horizontal overflow" do
    page.driver.browser.manage.window.resize_to(1200, 900)

    visit "/registracija"
    accept_data_consent!

    assert_selector "form#mi-registration-form"
    assert_selector "#mi-registration-phone"
    assert_no_selector "#mi-registration-komsiluk"
    assert_no_element_overflow!(".mi-registration-form")
    assert_no_horizontal_overflow!
    assert_no_browser_console_errors!
  end

  test "mobile registration fits its primary action and sign in while login keeps code before resend" do
    page.driver.browser.manage.window.resize_to(390, 844)
    visit "/registracija"
    accept_data_consent!

    assert_no_selector "#mi-registration-newsletter"
    assert page.evaluate_script(<<~JS)
      document.querySelector('#mi-registration-form button[type=submit]').getBoundingClientRect().bottom <= window.innerHeight &&
        document.querySelector('.mi-registration-login').getBoundingClientRect().bottom <= window.innerHeight
    JS
    assert_no_horizontal_overflow!
    within ".mi-registration-login" do
      click_link I18n.t("decidim.bih.registrations.new.have_account_link")
    end
    assert_current_path "/users/sign_in"
    within "#mi-auth-phone-form" do
      fill_in "phone", with: "065 999 999"
      click_button I18n.t("decidim.bih.phone_sessions.new.submit")
    end
    assert_selector "#mi-auth-code-form"
    assert_current_path "/users/sign_in"
    assert page.evaluate_script(<<~JS)
      document.querySelector('#mi-auth-code').getBoundingClientRect().bottom <=
        document.querySelector('#mi-auth-phone-title').getBoundingClientRect().top
    JS
    assert_no_horizontal_overflow!
  end

  test "registration code entry is centered and precedes resend on mobile and desktop" do
    visit "/registracija"
    accept_data_consent!
    fill_in "mi-registration-name", with: "Test Građanin"
    fill_in "mi-registration-phone", with: "065 999 998"
    check "mi-registration-tos"
    find("#mi-registration-form button[type=submit]").click
    assert_selector "#mi-verification-code"
    [[390, 844], [1200, 900]].each do |width, height|
      page.driver.browser.manage.window.resize_to(width, height)
      assert page.evaluate_script(<<~JS)
        (() => {
        const panel = document.querySelector('.mi-phone-verification').getBoundingClientRect();
        const code = document.querySelector('#mi-verification-code').getBoundingClientRect();
        const actions = document.querySelector('.mi-phone-verification__actions').getBoundingClientRect();
        return Math.abs(panel.left - (document.documentElement.clientWidth - panel.right)) < 3 && code.bottom < actions.top;
        })()
      JS
      assert_no_horizontal_overflow!
    end
  end

  test "account overview shows setup steps for a signed-in citizen" do
    Decidim::Bih::Goodwill::Ledger.new.award(@citizen, 100, reason: "report")
    Decidim::Authorization.create!(
      user: @citizen,
      name: "postal_letter",
      granted_at: nil,
      verification_metadata: {
        "verification_code" => "123456",
        "letter_sent_at" => Time.current.iso8601
      }
    )
    sign_in_user! @citizen
    page.driver.browser.manage.window.resize_to(1200, 900)

    visit "/biceriseno/moj-nalog"
    accept_data_consent!

    assert_selector ".mi-account-overview", text: "Moj nalog"
    assert_no_selector ".mi-account-hero .mi-eyebrow"
    assert_selector ".mi-account-settings", text: "Profil i postavke naloga"
    assert_selector ".mi-account-activity", text: "Praćene teme"
    assert_selector ".mi-account-activity", text: "Odgovori"
    assert_selector ".mi-account-activity a[href='/profiles/#{@citizen.nickname}/following']"
    assert_selector ".mi-account-activity a[href='/profiles/#{@citizen.nickname}/activity']"
    assert_no_selector ".mi-account-dashboard", text: "Sedmični niz"
    assert_selector ".mi-setup-list", text: "Izaberi Komšiluk"
    assert_selector ".mi-setup-list", text: "Potvrdi adresu pismom"
    assert_selector ".mi-verification-options", text: "Pismo na adresu"
    assert_selector ".mi-verification-actions a[href='/postal_letter/authorizations/edit']", text: "Upiši kod"
    assert_account_settings_precede_activity!
    assert_account_form_labels_are_vertical!
    assert_selector ".mi-account-activity__section", count: 5
    assert_no_element_overflow!(".mi-account-settings")
    assert_no_element_overflow!(".mi-account-activity")
    assert_no_horizontal_overflow!
    assert_no_browser_console_errors!
  end

  private

  def assert_no_element_overflow!(selector)
    overflow = page.evaluate_script(<<~JS)
      (function() {
        var el = document.querySelector("#{selector}");
        if (!el) return 9999;
        return el.scrollWidth - el.clientWidth;
      })();
    JS

    assert_operator overflow, :<=, 2, "expected #{selector} not to overflow horizontally"
  end

  def assert_account_settings_precede_activity!
    positions = page.evaluate_script(<<~JS)
      (function() {
        var settings = document.querySelector(".mi-account-settings");
        var activity = document.querySelector(".mi-account-activity");
        if (!settings || !activity) return [9999, 0];
        return [settings.getBoundingClientRect().top, activity.getBoundingClientRect().top];
      })();
    JS

    assert_operator positions.first, :<, positions.last, "expected account settings before current activity"
  end

  def assert_account_form_labels_are_vertical!
    display = page.evaluate_script(<<~JS)
      (function() {
        var label = document.querySelector(".mi-account-form-grid label");
        return label ? window.getComputedStyle(label).display : null;
      })();
    JS

    assert_equal "grid", display
  end
end
