# frozen_string_literal: true

require "application_system_test_case"

class PwaInstallPromptTest < ApplicationSystemTestCase
  setup do
    @organization = create_organization
    use_organization_host!(@organization)
  end

  test "forced install prompt is usable on mobile" do
    page.driver.browser.manage.window.resize_to(390, 844)

    visit "/?app=1"
    accept_data_consent!
    dispatch_beforeinstallprompt!

    assert_selector "#mi-install-banner", text: I18n.t("decidim.bih.pwa.install_text", locale: :sr)
    assert_no_horizontal_overflow!

    click_button "Ne sada"
    assert_no_selector "#mi-install-banner"
    assert page.evaluate_script('JSON.parse(localStorage.getItem("miInstall")).snoozedUntil > Date.now()')
  end

  test "registration neighborhood handoff displays the install offer" do
    user = create(:user, :confirmed, organization: @organization)
    sign_in_user!(user)
    page.driver.browser.manage.window.resize_to(390, 844)
    visit "/biceriseno/komsiluk?setup=1&app=1"
    accept_data_consent!
    dispatch_beforeinstallprompt!
    assert_selector "#mi-install-banner"
    assert_selector ".mi-komsiluk-setup details[open] #bih-komsiluk-map"
    click_button I18n.t("decidim.bih.pwa.dismiss_label", locale: :sr)
    assert_no_selector "#mi-install-banner"
  end

  test "iPhone Chrome guidance survives navigation and leaves forms clear" do
    user = create(:user, :confirmed, organization: @organization)
    sign_in_user!(user)
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 390, height: 844, deviceScaleFactor: 1, mobile: true)
    page.driver.browser.execute_cdp("Emulation.setUserAgentOverride",
                                    userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 CriOS/140.0.0.0 Mobile/15E148 Safari/604.1")
    # Chrome still fires its native install event under a changed user agent;
    # iOS does not, so keep this emulation faithful to that lifecycle.
    page.driver.browser.execute_cdp("Page.addScriptToEvaluateOnNewDocument", source: 'window.addEventListener("beforeinstallprompt", event => event.stopImmediatePropagation());')
    visit "/"
    assert_selector "#dc-dialog-reject"
    assert_no_selector "#mi-install-banner"
    find_by_id("dc-dialog-reject").click
    assert_selector "#mi-install-banner.mi-install-card--ios"
    visit "/notifications"
    assert_current_path "/notifications"
    assert_selector "#mi-install-banner.mi-install-card--ios"
    visit "/account"
    assert_current_path "/biceriseno/moj-nalog"
    assert_no_selector "#mi-install-banner"
  end

  test "native install prompt requires its button and does not consume navigation" do
    page.driver.browser.execute_cdp("Page.addScriptToEvaluateOnNewDocument", source: <<~JS)
      sessionStorage.setItem("visitedPages", JSON.stringify(["/earlier-one", "/earlier-two"]));
      sessionStorage.removeItem("userChoice");
      localStorage.removeItem("pwaInstallPromptSeen");
    JS
    visit "/biceriseno/volontiranje?app=1"
    accept_data_consent!
    dispatch_beforeinstallprompt!
    assert_selector "#mi-install-banner"
    assert_equal "0", page.evaluate_script('sessionStorage.getItem("testNativeInstallCalls")')

    within ".mi-volunteer-tabs" do
      click_link I18n.t("decidim.bih.volunteer.index.tabs.dostupnost")
    end
    assert_current_path "/biceriseno/volontiranje?tab=dostupnost"
    assert_equal "0", page.evaluate_script('sessionStorage.getItem("testNativeInstallCalls")')

    visit "/?app=1"
    accept_data_consent!
    dispatch_beforeinstallprompt!
    assert_selector "#mi-install-banner"
    click_button I18n.t("decidim.bih.pwa.install_label", locale: :sr)
    assert_equal "1", page.evaluate_script('sessionStorage.getItem("testNativeInstallCalls")')
  end

  private

  def dispatch_beforeinstallprompt!
    page.execute_script(<<~JS)
      var event = new Event("beforeinstallprompt");
      sessionStorage.setItem("testNativeInstallCalls", "0");
      event.prompt = function () {
        sessionStorage.setItem("testNativeInstallCalls", String(Number(sessionStorage.getItem("testNativeInstallCalls")) + 1));
        return Promise.resolve();
      };
      event.userChoice = Promise.resolve({ outcome: "dismissed" });
      window.dispatchEvent(event);
    JS
  end
end
