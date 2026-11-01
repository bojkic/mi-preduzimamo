# frozen_string_literal: true

require "application_system_test_case"

# The one citizen communication page, in a real browser.
#
# What browser automation can prove here: the page is usable on a phone, every
# control is labelled and reachable by keyboard, and a rejected save comes back
# with what the citizen typed rather than what the database still holds.
#
# What it cannot prove: that any device ever displayed a notification. A stored
# push subscription is a server fact; delivery is not. iOS additionally requires
# the PWA on the Home Screen before the permission prompt exists at all, which
# no headless browser can exercise.
class CommunicationSettingsTest < ApplicationSystemTestCase
  PAGE = Decidim::Bih.public_path("moj-nalog/poruke")

  # The consent dialog is inserted by JS and can arrive AFTER
  # accept_data_consent! has run, so a later click lands on the overlay instead
  # of the control under test - which is how this file first failed, with the
  # cookie-settings modal on screen and no visible <html>. Setting the cookie
  # and then reloading renders the page without the dialog at all.
  def open_settings_page!
    visit PAGE
    accept_data_consent!
    visit PAGE
    page.execute_script(<<~JS)
      document.querySelectorAll("#dc-dialog-wrapper, #dc-modal, #mi-install-banner, [data-push-offer]")
        .forEach(function (element) { element.remove(); });
    JS
  end

  setup do
    @organization = create_organization
    use_organization_host!(@organization)
    @citizen = FactoryBot.create(:user, :confirmed, organization: @organization, name: "Mila Gradjanka")
    sign_in_user!(@citizen)
  end

  test "the page has no horizontal scroll at 360px and every checkbox has a label" do
    page.driver.browser.manage.window.resize_to(360, 720)
    open_settings_page!

    assert_selector "[data-setting-section=topics]"
    assert_no_horizontal_overflow!
    page.all("input[type=checkbox]", visible: true).each do |box|
      next if box[:id].to_s.empty?

      assert page.has_css?("label[for='#{box[:id]}']", visible: :all), "checkbox #{box[:id]} has no label"
    end
  end

  test "the save button is not covered by the mobile toolbar" do
    page.driver.browser.manage.window.resize_to(360, 720)
    open_settings_page!

    # Decidim's #sticky-header-container is fixed, top:0, z-40 below 768px.
    # Scroll the save button into view and ask the browser what is actually on
    # top of it - a CSS assertion would only prove the stylesheet, not the page.
    assert_selector "[data-communication-save]"
    covered = page.evaluate_script(<<~JS)
      (function () {
        var button = document.querySelector("[data-communication-save]");
        button.scrollIntoView({ block: "center" });
        var box = button.getBoundingClientRect();
        var top = document.elementFromPoint(box.left + (box.width / 2), box.top + (box.height / 2));
        return !(top === button || button.contains(top));
      })();
    JS
    assert_equal false, covered, "the save button is under another element on a phone"
  end

  test "the whole form is reachable by keyboard and focus is visible" do
    open_settings_page!

    12.times { page.send_keys(:tab) }
    assert_not_equal "BODY", page.evaluate_script("document.activeElement.tagName")
    outline = page.evaluate_script("getComputedStyle(document.activeElement).outlineStyle")
    assert_not_equal "none", outline
  end

  test "only four topic choices appear and an opt-out remains after saving" do
    open_settings_page!
    assert_selector "[data-communication-form] input[type=checkbox]", count: 4
    assert_selector "[data-communication-form] input[type=checkbox]:checked", count: 4
    assert_no_selector "input[type=radio]"
    uncheck "communication_settings_report_updates", allow_label_click: true
    find("[data-communication-save]").click
    assert_text I18n.t("decidim.bih.communication_settings.saved", locale: :sr)
    assert_no_selector "#communication_settings_report_updates:checked"
    assert_selector "#communication_settings_community_news:checked"
    assert_equal false, Decidim::Bih::TopicPreferences.enabled?(@citizen.reload, topic: :report_updates)
    assert_equal "all", @citizen.notification_types
  end

  test "push setup has no app off switch and connection setup remains reachable" do
    open_settings_page!
    assert_selector "[data-push-section]"
    assert_no_selector "[data-setting-section=inapp] input"
    assert_no_selector "[data-setting-requested], [data-setting-origin]"
    assert_selector "[data-setting-section=contact] a", minimum: 1
  end
end
