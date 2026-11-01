# frozen_string_literal: true

require "test_helper"
# Integration tests that render a Decidim layout need Capybara loaded:
# Decidim::UrlOptionResolver reads Capybara.server_port for default url options.
require "capybara"

# "Režim lansiranja" (spec §6), navigation half.
#
# While the race window is open the main menu — `:menu`, rendered in the footer
# by Decidim::MenuHelper#footer_menu and in the mobile nav by :mobile_menu —
# must carry the three launch destinations and drop the long tail. After the
# 14.10.2026 20:00 freeze the ordinary menu must be back WITHOUT a deploy in
# between, which is why this test travels in time instead of reloading
# initializers: the switch has to be a per-request decision, not boot state.
#
# The footer is asserted rather than the header because Decidim's
# layouts/decidim/_wrapper skips the header menu on the homepage
# (`unless controller_name == "homepage"`) while always rendering the footer.
class LaunchModeNavigationTest < ActionDispatch::IntegrationTest
  include ::Devise::Test::IntegrationHelpers

  setup do
    @organization = create_organization
    host! @organization.host
  end

  test "mobile avatar follows unread notifications and returns to the account after reading" do
    user = create(:user, :confirmed, organization: @organization)
    sign_in user
    get "/"
    assert_response :success
    assert_select "nav.mi-mobile-bottom-nav a[href='/biceriseno/moj-nalog']"
    assert_select "nav .mi-mobile-bottom-nav__item--unread", count: 0
    assert_select ".mi-mobile-more-sheet__links a[href='/notifications']", text: "Obavještenja"
    assert_select ".mi-mobile-more-sheet__links a[href='/biceriseno/moj-nalog']"

    notification = Decidim::Notification.create!(
      user: user, resource: user, event_name: "decidim.events.bih.operator_message",
      event_class: "Decidim::Bih::OperatorMessageEvent",
      extra: { subject: "Test", body: "Test message" }
    )
    get "/"
    assert_response :success
    assert_select "nav a.mi-mobile-bottom-nav__item--unread[href='/notifications']", text: /Nova poruka/
    get "/notifications"
    assert_response :success
    assert_select "nav a.mi-mobile-bottom-nav__item--unread[href='/notifications']"

    delete "/notifications/#{notification.id}", xhr: true
    assert_response :success
    get "/"
    assert_select "nav .mi-mobile-bottom-nav__item--unread", count: 0
    assert_select "nav.mi-mobile-bottom-nav a[href='/biceriseno/moj-nalog']"
  end

  test "private conversations use the existing inbox when there are no notifications" do
    user = create(:user, :confirmed, organization: @organization)
    sender = create(:user, :confirmed, organization: @organization)
    conversation = Decidim::Messaging::Conversation.start!(originator: sender, interlocutors: [user], body: "Test message")
    sign_in user
    get "/"
    assert_response :success
    assert_select "nav a.mi-mobile-bottom-nav__item--unread[href='/conversations']", text: /Nova poruka/

    notification = Decidim::Notification.create!(
      user: user, resource: user, event_name: "decidim.events.bih.operator_message",
      event_class: "Decidim::Bih::OperatorMessageEvent",
      extra: { subject: "Test", body: "Test message" }
    )
    get "/"
    assert_select "nav a.mi-mobile-bottom-nav__item--unread[href='/notifications']"
    notification.destroy!
    conversation.mark_as_read(user)
    get "/"
    assert_select "nav .mi-mobile-bottom-nav__item--unread", count: 0
  end

  test "anonymous mobile menu does not expose private destinations" do
    get "/"
    assert_select ".mi-mobile-more-sheet__links a[href='/notifications']", count: 0
    assert_select ".mi-mobile-more-sheet__links a[href='/biceriseno/moj-nalog']", count: 0
    assert_select "nav .mi-mobile-bottom-nav__item--unread", count: 0
  end

  def in_launch_window(&) = travel_to(Time.utc(2026, 9, 17, 12, 0, 0), &)

  def after_freeze(&) = travel_to(Time.utc(2026, 10, 20, 12, 0, 0), &)

  test "main menu in launch mode carries the launch pages and drops the long tail" do
    in_launch_window do
      get "/"

      assert_response :success
      # The 17.9. event page was retired (20560f77); /trka carries the
      # standings now. Its URL still resolves as a 302 for the posters and
      # SMS that carry it, but nothing links to it any more.
      assert_select "footer a[href='/lansiranje']", count: 0
      assert_select "footer a[href='/trka']"
      assert_select "footer a[href='/biceriseno/mi-bot']"
      assert_select "footer a[href='/biceriseno/volontiranje']", count: 0
      assert_select "footer a[href='/biceriseno/projekti']", count: 0
      assert_select "footer a[href='/biceriseno/uticaj']", count: 0
    end
  end

  test "the launch menu items carry the campaign labels" do
    in_launch_window do
      get "/"

      assert_response :success
      assert_select "footer a[href='/trka']", text: "Trka komšiluka"
    end
  end

  test "main menu after the freeze is the full one again" do
    after_freeze do
      get "/"

      assert_response :success
      assert_select "footer a[href='/biceriseno/volontiranje']"
      assert_select "footer a[href='/biceriseno/projekti']"
      assert_select "footer a[href='/biceriseno/uticaj']"
      assert_select "footer a[href='/lansiranje']", count: 0
      assert_select "footer a[href='/trka']", count: 1
    end
  end

  # :mobile_menu is a SEPARATE registry from :menu and only renders off the
  # homepage, so build it directly against the request's view context instead
  # of hunting for the mobile dropdown markup. Without this, a swap applied to
  # :menu alone would look fully covered.
  test "the mobile menu gets the same swap" do
    in_launch_window do
      get "/"

      menu = Decidim::Menu.new(:mobile_menu)
      menu.build_for(@controller.view_context)
      urls = menu.items.map(&:url)

      assert_not_includes urls, "/lansiranje"
      assert_includes urls, "/trka"
      assert_includes urls, "/biceriseno/mi-bot"
      assert_not_includes urls, "/biceriseno/volontiranje"
      assert_not_includes urls, "/biceriseno/projekti"
      assert_not_includes urls, "/biceriseno/uticaj"
    end
  end

  # An operator can force the mode off mid-window (DecidimApp::LaunchMode reads
  # Setting(launch, mode)); the menu must follow that on the very next request.
  test "an operator switching the mode off restores the ordinary menu inside the window" do
    Decidim::Bih::Setting.put(@organization, "launch", "mode", "off")

    in_launch_window do
      get "/"

      assert_response :success
      assert_select "footer a[href='/biceriseno/volontiranje']"
      assert_select "footer a[href='/lansiranje']", count: 0
    end
  end

  test "the launch menu labels are translated in every citizen locale" do
    {
      sr: ["Događaj zajednice", "Trka komšiluka"],
      bs: ["Događaj zajednice", "Trka komšiluka"],
      hr: ["Događaj zajednice", "Trka komšiluka"],
      "sr-Cyrl": ["Догађај заједнице", "Трка комшилука"]
    }.each do |locale, (launch_event, race)|
      assert_equal launch_event, I18n.t("decidim.bih.menu.launch_event", locale:)
      assert_equal race, I18n.t("decidim.bih.menu.race", locale:)
    end
  end

  # The three surfaces below are asserted on the homepage because
  # layouts/decidim/header/_main renders _main_links_desktop, and the layout
  # renders both MI partials, on EVERY page — unlike the header menu, which
  # _wrapper deliberately skips on the homepage.
  #
  # `assert_response :success` is not decoration: two of these tests assert a
  # `count: 0`, which a 500 error page would satisfy for the wrong reason.
  test "header in launch mode shows register and ask-Milica, hides meetings and activity" do
    in_launch_window do
      get "/"

      assert_response :success
      assert_select "a.main-bar__links-desktop__item[href='/registracija']", text: /Registruj se/
      assert_select "a.main-bar__links-desktop__item[data-mi-bot-open]"
      assert_select "a.main-bar__links-desktop__item[href='/last_activities']", count: 0
    end
  end

  # 2026-09-07: the quick-action bar above the header is gone; the header
  # carries the actions itself, in this order: Početna (since 9.9.2026, when
  # the DDI logo took the top-left) · Pitaj Milicu · Registruj se ·
  # Uloguj se · Pomoć.
  test "header in launch mode orders home, Milica, register, log in, help and has no quick-action bar" do
    in_launch_window do
      get "/"

      assert_response :success
      assert_select "nav.mi-action-launcher--desktop", count: 0
      hrefs = css_select("nav.main-bar__links-desktop a.main-bar__links-desktop__item").map { |a| a["href"] }
      assert_equal ["/", "/biceriseno/mi-bot", "/registracija", "/users/sign_in", "/biceriseno/vodic"], hrefs
      assert_select "a.mi-main-bar-pill--home[href='/']", text: /Početna/
      assert_select "a.mi-main-bar-pill--milica[data-mi-bot-open]"
      assert_select "a.mi-main-bar-pill--register[href='/registracija']"
      assert_select "a.mi-main-bar-pill--login[href='/users/sign_in']", text: /Uloguj se/
    end
  end

  test "mobile bottom nav in launch mode swaps decide for the race" do
    in_launch_window do
      get "/"

      assert_response :success
      assert_select "nav.mi-mobile-bottom-nav a[href='/trka']"
      assert_select "nav.mi-mobile-bottom-nav a[href='/processes']", count: 0
    end
  end

  # The register CTA in launch_ctas has href: :registration, which the engine's
  # mi_hero cell already swaps to the account page for a signed-in citizen
  # (decidim-bih commit 32cffae); without a matching signed_in_label_key the
  # button kept its "Registruj se" label and invited an already-registered
  # citizen to sign up again.
  test "the hero register CTA carries a signed-in label for a citizen who already has an account" do
    create(:content_block, organization: @organization, scope_name: :homepage, manifest_name: :mi_hero, weight: 1)
    sign_in create(:user, :confirmed, organization: @organization)

    in_launch_window do
      get "/"

      assert_response :success
      assert_select ".mi-hero__ctas a[href='/biceriseno/moj-doprinos']",
                    text: I18n.t("decidim.bih.content_blocks.mi_hero.register.signed_in_cta", locale: :sr)
      assert_select ".mi-hero__ctas a",
                    text: I18n.t("decidim.bih.content_blocks.mi_hero.launch_ctas.register", locale: :sr),
                    count: 0
    end
  end

  test "outside launch mode there is still no quick-action bar" do
    after_freeze do
      get "/"

      assert_response :success
      assert_select "nav.mi-action-launcher--desktop", count: 0
      assert_select "a.main-bar__links-desktop__item[href='/last_activities']"
    end
  end

  # The mobile toolbar is the whole mobile navigation since 2026-09-07, so it
  # renders on every public page — the root launch pages, the sign-in page and
  # the report form included — and steps aside only for admin/system/api.
  test "a root launch page keeps the mobile nav visible" do
    get "/trka"

    assert_response :success
    assert_select "nav.mi-mobile-bottom-nav"
  end

  test "the sign-in page and the report form keep the mobile nav visible" do
    get "/users/sign_in"

    assert_response :success
    assert_select "nav.mi-mobile-bottom-nav"
    assert_select ".mi-mobile-more-sheet a[href='/']", text: I18n.t("decidim.bih.mobile_nav.home")

    get "/biceriseno/prijave/new"

    assert_response :success
    assert_select "nav.mi-mobile-bottom-nav"
  end
end
