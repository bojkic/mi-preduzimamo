# frozen_string_literal: true

require "test_helper"
require "capybara"
require "cgi"

class ChatAssetLoadingTest < ActionDispatch::IntegrationTest
  include ::Devise::Test::IntegrationHelpers

  setup do
    @prior_flagship_process_slug = Decidim::Bih.flagship_process_slug
    Decidim::Bih.flagship_process_slug = "authored-participation"
    @organization = create_organization
    host! @organization.host
    # Pinned off so the header assertions describe the steady state; the
    # launch-mode header has its own coverage in
    # test/integration/launch_mode_navigation_test.rb.
    Decidim::Bih::Setting.put(@organization, "launch", "mode", "off")
  end

  teardown do
    Decidim::Bih.flagship_process_slug = @prior_flagship_process_slug
  end

  test "public pages emit only chat loader and non-executable config" do
    get "/"

    assert_response :success
    assert_lazy_chat_loader_present
    assert_select ".mi-main-bar-shortcuts", false
    assert_no_quick_action_bar
    assert_select ".mi-action-launcher--mobile", false
    assert_select ".mi-mobile-bottom-nav"
    assert_select ".mi-mobile-more-sheet"
    assert_select "script[src^='/mi/mi-mobile-nav.js']", 1
  end

  test "reports map emits only chat loader and non-executable config" do
    get "/biceriseno/mapa"

    assert_response :success
    assert_lazy_chat_loader_present
    assert_breadcrumb_menu_trigger_present
    assert_select ".mi-main-bar-shortcuts", false
    assert_no_quick_action_bar
    assert_select ".mi-action-launcher--mobile", false
    assert_select ".mi-mobile-bottom-nav"
    assert_select ".mi-mobile-more-sheet"
  end

  test "form-heavy entry pages suppress floating chat and install overlays but keep public shortcuts" do
    get "/biceriseno/prijave/new"

    assert_response :success
    assert_overlay_assets_suppressed
    assert_select ".mi-main-bar-shortcuts", false
    assert_no_quick_action_bar
    assert_select ".mi-mobile-bottom-nav"

    # /users/sign_up is a 302 to /registracija since isporuka D, so the
    # /users/* suppression rule is proved on the Devise surface that is still
    # rendered. (/registracija itself deliberately KEEPS the overlays — see
    # test/integration/decidim/bih/one_step_registration_test.rb.)
    get "/users/sign_in"

    assert_response :success
    assert_overlay_assets_suppressed
    assert_select ".mi-action-launcher", false
    assert_select ".mi-mobile-bottom-nav"

    get "/biceriseno/prijava"

    assert_redirected_to "/users/sign_in"
    follow_redirect!
    assert_response :success
    assert_overlay_assets_suppressed
    assert_select ".mi-main-bar-shortcuts", false
    assert_no_quick_action_bar
    assert_select ".mi-mobile-bottom-nav"
  end

  test "komsiluk picker has no quick-action bar either" do
    sign_in FactoryBot.create(:user, :confirmed, organization: @organization)

    get "/biceriseno/komsiluk"

    assert_response :success
    assert_select ".mi-main-bar-shortcuts", false
    assert_no_quick_action_bar
  end

  test "mi bot showcase keeps the lazy chat entrypoint without loading full chat assets" do
    get "/biceriseno/mi-bot"

    assert_response :success
    assert_select "link[href^='/mi/mi-bot.css']", 1
    assert_lazy_chat_loader_present
  end

  test "both shipped widgets expose the same configured quick reply actions" do
    paths = [Rails.public_path.join("mi/mi-chat.js"), Decidim::Bih::Engine.root.join("public/mi/mi-chat.js")]
    functions = paths.map { |path| File.read(path)[/  function addQuickReplies\(items\) \{.*?\n  \}/m] }
    assert functions.all?(&:present?)
    assert_equal functions.first, functions.last
    assert_includes functions.first, 'chip.setAttribute("data-mi-chat-action", target ? "navigate" : "send")'
    assert_includes functions.first, 'chip.setAttribute("data-mi-chat-value", target || payload)'
    assert_includes functions.first, "window.location.assign(target)"
    assert_includes functions.first, "submit(payload)"
  end

  private

  def assert_lazy_chat_loader_present
    assert_self_hosted_fonts_present
    assert_select "#main-dropdown-summary-mobile.mi-main-menu-mobile-trigger",
                  text: I18n.t("layouts.decidim.header.main_menu")
    assert_select "meta[name='mi-chat-config'][data-css-src^='/mi/mi-chat.css'][data-js-src^='/mi/mi-chat.js']", 1
    assert_select "script[src^='/mi/mi-chat-loader.js']", 1
    assert_select "script[src^='/mi/mi-chat.js']", false
    assert_select "link[href^='/mi/mi-chat.css']", false
    assert_not_includes response.body, "window.MI_CHAT"

    config = JSON.parse(CGI.unescapeHTML(css_select("meta[name='mi-chat-config']").first["content"]))
    assert_equal "/biceriseno/chat", config.fetch("endpoint")
    quick = config.fetch("quick")
    assert_not_empty quick
    assert(quick.all? { |chip| chip["label"].present? && (chip["url"].present? || chip["send"].present?) })
    assert_not(quick.any? { |chip| chip["url"] == "/" })
    quick_labels = quick.map { |chip| chip.fetch("label") }
    # The report entry is two chips: describe it to Milica (a canned message)
    # or open the form with a photo (a page).
    assert_includes quick_labels, "Opiši problem Milici"
    assert_includes quick_labels, I18n.t("decidim.bih.concierge.widget.quick.report_describe")
    assert_includes quick_labels, I18n.t("decidim.bih.concierge.widget.quick.report_form")
    assert_equal I18n.t("decidim.bih.concierge.widget.quick.report_describe_send"), quick.first.fetch("send")
    assert_equal "/biceriseno/prijave/new", quick.second.fetch("url")
    assert_equal I18n.t("decidim.bih.concierge.widget.feedback.prompt"), config.dig("i18n", "feedback", "prompt")
    assert_not config.fetch("i18n").fetch("feedback").has_key?("share_question")
    assert_equal I18n.t("decidim.bih.concierge.widget.feedback.shared"), config.dig("i18n", "feedback", "shared")
    assert_equal I18n.t("decidim.bih.concierge.widget.retry"), config.dig("i18n", "retry")
    assert_equal I18n.t("decidim.bih.concierge.widget.resumed"), config.dig("i18n", "resumed")
    assert_equal I18n.t("decidim.bih.concierge.widget.capabilities"), config.dig("i18n", "capabilities")
    assert_equal I18n.t("decidim.bih.concierge.widget.new_conversation"), config.dig("i18n", "new_conversation")
    assert_includes quick_labels, I18n.t("decidim.bih.concierge.widget.quick.idea")
    assert_includes quick_labels, I18n.t("decidim.bih.concierge.widget.quick.donate")
    assert_equal "/mi/milica/wave.jpg", config.fetch("avatarUrl")
    assert_equal "/mi/milica/wave.gif", config.fetch("greetingMediaUrl")
    assert_equal "/mi/milica/wave.jpg", config.fetch("greetingMediaStaticUrl")
    assert_equal I18n.t("decidim.bih.concierge.widget.greeting"), config.dig("i18n", "greeting")
    assert_equal I18n.t("decidim.bih.concierge.widget.return_greeting"), config.dig("i18n", "return_greeting")
    assert_equal I18n.t("decidim.bih.concierge.widget.loading"), config.dig("i18n", "loading")
    assert_equal I18n.t("decidim.bih.concierge.widget.long_loading"), config.dig("i18n", "long_loading")
    assert_equal I18n.t("decidim.bih.concierge.widget.greeting_media_alt"), config.dig("i18n", "greeting_media_alt")
    assert_equal I18n.t("decidim.bih.concierge.widget.feedback.helpful"), config.dig("i18n", "feedback", "helpful")
    assert_equal I18n.t("decidim.bih.concierge.widget.feedback.not_helpful"), config.dig("i18n", "feedback", "not_helpful")
  end

  def assert_breadcrumb_menu_trigger_present
    assert_select "#main-dropdown-summary.mi-menu-breadcrumb-trigger",
                  text: I18n.t("layouts.decidim.header.main_menu")
  end

  # The quick-action bar above the header was removed on 2026-09-07; the
  # header carries the actions itself.
  def assert_no_quick_action_bar
    assert_select ".mi-action-launcher", false
  end

  def assert_self_hosted_fonts_present
    # Readable, minified or (homepage) bundled sheet; exactly one carries the fonts.
    assert_select "link[rel='stylesheet'][href^='/mi/mi-fonts.css'], link[rel='stylesheet'][href^='/mi/mi-fonts.min.css'], " \
                  "link[rel='stylesheet'][href^='/mi/mi-home.min.css']", 1
    assert_not_includes response.body, "fonts.googleapis.com"
    assert_not_includes response.body, "fonts.gstatic.com"
  end

  def assert_overlay_assets_suppressed
    assert_self_hosted_fonts_present
    assert_select "meta[name='mi-chat-config']", false
    assert_select "script[src^='/mi/mi-chat-loader.js']", false
    assert_select "script[src^='/mi/mi-install.js']", false
  end
end
