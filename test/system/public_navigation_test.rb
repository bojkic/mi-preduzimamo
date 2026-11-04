# frozen_string_literal: true

require "application_system_test_case"

class PublicNavigationTest < ApplicationSystemTestCase
  setup do
    @organization = create_organization
    create(:content_block, organization: @organization, scope_name: :homepage, manifest_name: :global_menu, weight: 10)
    use_organization_host!(@organization)
    # Same reason as chat_asset_loading_test: this file describes the
    # STEADY-STATE navigation, and "Odlučuj" leaves the mobile bottom bar for
    # the trka komšiluka between 6.9.2026 and 14.10.2026 20:00 — the window the
    # suite itself runs inside. Pin the mode off so these expectations do not
    # depend on the day the suite is run; the launch-mode bar is covered by
    # test/integration/launch_mode_navigation_test.rb.
    Decidim::Bih::Setting.put(@organization, "launch", "mode", "off")
  end

  test "homepage exposes the civic navigation links" do
    visit "/"
    accept_data_consent!

    within ".home__menu" do
      assert_selector "a[href='/biceriseno/prijave/new?locale=sr']", text: I18n.t("decidim.bih.menu.reports")
      assert_selector "a[href='/biceriseno/volontiranje?locale=sr']", text: I18n.t("decidim.bih.menu.volunteer_action")
      assert_selector "a[href='/biceriseno/projekti?locale=sr']", text: I18n.t("decidim.bih.menu.donate_action")
      assert_selector "a[href='/processes']", text: I18n.t("decidim.bih.menu.decide")
      assert_selector "a[href='/biceriseno/mi-bot?locale=sr']", text: I18n.t("decidim.bih.menu.mi_bot_short")
      assert_selector "a[href='/biceriseno/zajednistvo?locale=sr']", text: I18n.t("decidim.bih.menu.community")
      assert_selector "a[href='/biceriseno/komsiluk-board?locale=sr']", text: I18n.t("decidim.bih.menu.komsiluk")
    end
  end

  test "mobile viewport keeps civic navigation reachable" do
    page.driver.browser.manage.window.resize_to(390, 844)

    visit "/"
    accept_data_consent!

    assert_no_selector "#main-bar", visible: :visible
    assert_selector ".mi-mobile-bottom-nav a[href='/sr/users/sign_in']", text: I18n.t("decidim.bih.mobile_nav.login")
    assert_no_selector ".main-bar__logo", visible: :visible
    assert_no_selector "#main-dropdown-summary-mobile", visible: :visible
    assert_no_horizontal_overflow!
    assert_selector ".mi-mobile-bottom-nav a[href='/biceriseno/prijave/new']", text: I18n.t("decidim.bih.mobile_nav.report")
    assert_selector ".mi-mobile-bottom-nav a[href='/processes']", text: I18n.t("decidim.bih.mobile_nav.decide")
    assert_selector ".mi-mobile-bottom-nav a.mi-mobile-bottom-nav__item--bot[data-mi-bot-open][href='/biceriseno/mi-bot']", text: I18n.t("decidim.bih.mobile_nav.bot")

    find(".mi-mobile-bottom-nav [data-mi-bot-open]").click

    assert_current_path "/sr/"
    assert_selector "#mi-chat.mi-chat.is-open", wait: 10
    find(".mi-chat__close").click

    find("[data-mi-mobile-more-open]").click

    assert_selector "#mi-mobile-more-sheet", visible: :visible
    assert_selector "#mi-mobile-more-sheet a[href='/']", text: I18n.t("decidim.bih.mobile_nav.home")
    assert_selector "a[href='/biceriseno/volontiranje']", text: I18n.t("decidim.bih.menu.volunteer_action")
    assert_selector "a[href='/biceriseno/projekti']", text: I18n.t("decidim.bih.menu.donate_action")
    assert_selector "a[href='/biceriseno/zajednistvo']", text: I18n.t("decidim.bih.menu.community")
    assert_selector "a[href='/biceriseno/komsiluk-board']", text: I18n.t("decidim.bih.menu.komsiluk")
    assert_selector "a[href='/biceriseno/uticaj']", text: I18n.t("decidim.bih.menu.impact_public")
  end

  test "mobile unread avatar and more menu lead to notifications" do
    citizen = create(:user, :confirmed, organization: @organization)
    Decidim::Notification.create!(
      user: citizen, resource: citizen, event_name: "decidim.events.bih.operator_message",
      event_class: "Decidim::Bih::OperatorMessageEvent",
      extra: { subject: "Test", body: "Test message" }
    )
    sign_in_user! citizen
    page.driver.browser.manage.window.resize_to(320, 740)
    visit "/"
    accept_data_consent!
    avatar_link = find("nav a.mi-mobile-bottom-nav__item--unread", text: "Nova poruka")
    ring = page.evaluate_script("getComputedStyle(document.querySelector('.mi-mobile-bottom-nav__avatar')).boxShadow")
    assert_includes ring, "rgb(198, 40, 40)"
    assert_no_horizontal_overflow!
    avatar_link.click
    assert_current_path "/sr/notifications"
    assert_selector "nav .mi-mobile-bottom-nav__item--unread"
    find("[data-mi-mobile-more-open]").click
    within ".mi-mobile-more-sheet__links" do
      assert_selector "a[href='/sr/notifications']", text: "Obavještenja"
      assert_selector "a[href='/biceriseno/moj-nalog']"
    end
  end

  test "signed-in header shows the citizen identity without restoring the mobile hamburger" do
    citizen = FactoryBot.create(:user, :confirmed, organization: @organization, name: "Mila Gradjanka")
    sign_in_user! citizen

    page.driver.browser.manage.window.resize_to(1400, 900)
    visit "/"
    accept_data_consent!

    assert_selector "#trigger-dropdown-account .mi-main-bar-account__name", text: "Mila Gradjanka"
    assert_selector ".home__menu a[data-mi-bot-open][href='/biceriseno/mi-bot?locale=sr']", text: I18n.t("decidim.bih.menu.mi_bot_short")

    page.driver.browser.manage.window.resize_to(390, 844)
    visit "/"

    assert_no_selector "#main-bar", visible: :visible
    assert_selector ".mi-mobile-bottom-nav a[href='/biceriseno/moj-nalog']", text: I18n.t("decidim.bih.mobile_nav.account")
    assert_no_selector "#main-dropdown-summary-mobile", visible: :visible
    assert_selector ".mi-mobile-bottom-nav [data-mi-bot-open][href='/biceriseno/mi-bot']", text: I18n.t("decidim.bih.mobile_nav.bot")

    find(".mi-mobile-bottom-nav [data-mi-bot-open]").click

    assert_current_path "/sr/"
    assert_selector "#mi-chat.mi-chat.is-open", wait: 10
    assert_selector "#mi-chat-panel", visible: :visible
    assert_no_horizontal_overflow!
  end
end
