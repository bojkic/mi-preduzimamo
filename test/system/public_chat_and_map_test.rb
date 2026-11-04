# frozen_string_literal: true

require "application_system_test_case"
require "uri"

class PublicChatAndMapTest < ApplicationSystemTestCase
  setup do
    @prior_map_center = Decidim::Bih.map_default_center
    @prior_map_zoom = Decidim::Bih.map_default_zoom
    Decidim::Bih.map_default_center = [0.15, 0.15]
    Decidim::Bih.map_default_zoom = 12
    @organization = create_organization
    use_organization_host!(@organization)
    @previous_concierge_org_host = ENV.fetch("DECIDIM_CONCIERGE_ORG_HOST", nil)
    ENV["DECIDIM_CONCIERGE_ORG_HOST"] = @organization.host

    Decidim::Bih::Config.reset!
    DecidimApp::Bijeljina::WebConcierge.reset!
    DecidimApp::Bijeljina::Concierge.reset!
  end

  teardown do
    Decidim::Bih.map_default_center = @prior_map_center
    Decidim::Bih.map_default_zoom = @prior_map_zoom
    DecidimApp::Bijeljina::WebConcierge.reset!
    DecidimApp::Bijeljina::Concierge.reset!
    Decidim::Bih::Config.reset!
    if @previous_concierge_org_host.nil?
      ENV.delete("DECIDIM_CONCIERGE_ORG_HOST")
    else
      ENV["DECIDIM_CONCIERGE_ORG_HOST"] = @previous_concierge_org_host
    end
  end

  test "floating chat opens, focuses, sends, and renders an offline-safe reply" do
    visit "/biceriseno/mapa"
    accept_data_consent!

    assert_no_chat_panel_assets_loaded

    find(".mi-chat-loader__bubble").click

    assert_selector "#mi-chat-panel", visible: :visible
    assert_selector ".mi-chat__name", text: "Komšinica Milica"
    greeting_image = find(".mi-chat__sticker img[src='/mi/milica/wave.gif']")
    assert_equal I18n.t("decidim.bih.concierge.widget.greeting_media_alt"), greeting_image["alt"]
    assert_chat_panel_assets_loaded
    assert_equal find(".mi-chat__field").native, page.driver.browser.switch_to.active_element

    fill_in I18n.t("decidim.bih.concierge.widget.input_placeholder"), with: "kad se odvozi smece Izmišljeno polje"
    find(".mi-chat__send").click

    assert_selector ".mi-chat__row.is-out", text: "kad se odvozi smece Izmišljeno polje"
    assert_selector ".mi-chat__row.is-in", minimum: 2
    assert_no_selector ".mi-chat__typing", wait: 5

    find(".mi-chat__close").click
    assert_selector ".mi-chat__bubble-label",
                    text: I18n.t("decidim.bih.concierge.widget.bubble_label"),
                    visible: :visible
  end

  test "floating chat submits signed answer feedback and stores the rated exchange" do
    visit "/biceriseno/mapa"
    accept_data_consent!
    page.execute_script(<<~JS)
      window.__miFeedbackRequests = [];
      window.__miOriginalFetch = window.fetch;
      window.fetch = function(url, options) {
        if (String(url).indexOf("/biceriseno/chat/feedback") !== -1) {
          window.__miFeedbackRequests.push({
            url: String(url),
            body: options && options.body
          });
        }
        return window.__miOriginalFetch.apply(this, arguments);
      };
    JS

    find(".mi-chat-loader__bubble").click
    fill_in I18n.t("decidim.bih.concierge.widget.input_placeholder"), with: "kad se odvozi smece Izmišljeno polje"
    find(".mi-chat__send").click

    assert_no_selector ".mi-chat__typing", wait: 5
    assert_selector ".mi-chat__feedback", minimum: 1
    reply_text = all(".mi-chat__row.is-in .mi-chat__bubble-msg").last.text

    assert_difference -> { Decidim::Bih::ConciergeFeedback.count }, 1 do
      find(".mi-chat__feedback-button", text: I18n.t("decidim.bih.concierge.widget.feedback.helpful")).click
      assert_selector ".mi-chat__feedback-status", text: I18n.t("decidim.bih.concierge.widget.feedback.thanks")
    end

    record = Decidim::Bih::ConciergeFeedback.order(:created_at).last
    assert_nil record.user
    assert_equal "kad se odvozi smece Izmišljeno polje", record.citizen_message
    assert_equal reply_text.squish, record.bot_reply_text.squish

    requests = page.evaluate_script("window.__miFeedbackRequests")
    assert_equal 1, requests.size
    assert_equal "/biceriseno/chat/feedback", URI.parse(requests.first.fetch("url")).path

    body = JSON.parse(requests.first.fetch("body"))
    assert_equal %w(reply_id token value), body.keys.sort
    assert_equal "helpful", body.fetch("value")
    assert_match Decidim::Bih::ConciergeFeedback::REPLY_ID_FORMAT, body.fetch("reply_id")
    assert body.fetch("token").present?
    assert_not_includes requests.first.fetch("body"), "kad se odvozi smece Izmišljeno polje"
    assert_not_includes requests.first.fetch("body"), reply_text
    assert page.evaluate_script("document.querySelector('#mi-chat-panel').scrollWidth <= document.querySelector('#mi-chat-panel').clientWidth")
  end

  test "floating chat stays expanded across page changes until minimized" do
    visit "/biceriseno/mapa"
    accept_data_consent!

    find(".mi-chat-loader__bubble").click
    assert_selector "#mi-chat.mi-chat.is-open", wait: 10

    visit "/"
    assert_selector "#mi-chat.mi-chat.is-open", wait: 10
    assert_selector "#mi-chat-panel", visible: :visible

    find(".mi-chat__close").click
    assert_no_selector "#mi-chat.mi-chat.is-open"

    visit "/biceriseno/mapa"
    assert_selector ".mi-chat-loader__bubble", visible: :visible
    assert_no_selector "#mi-chat.mi-chat.is-open", wait: 1
  end

  test "the help reply renders tappable civic shortcut chips" do
    visit "/biceriseno/mapa"
    accept_data_consent!

    find(".mi-chat-loader__bubble").click
    assert_selector "#mi-chat-panel", visible: :visible
    # Mark the welcome group so unchanged greeting chips cannot satisfy the reply check.
    find(".mi-chat__quick").execute_script("this.setAttribute('data-test-welcome-quick', 'true')")

    # A short, non-actionable message routes to the help/fallback reply, which
    # carries the civic-shortcut chips.
    fill_in I18n.t("decidim.bih.concierge.widget.input_placeholder"), with: "hej"
    find(".mi-chat__send").click

    # The report entry is split: "Obrazac sa fotografijom" is the chip that
    # navigates to the intake form ("Opiši problem Milici" talks to the bot).
    report_label = I18n.t("decidim.bih.concierge.widget.quick.report_form", locale: "sr")
    donate_label = I18n.t("decidim.bih.concierge.widget.quick.donate", locale: "sr")

    # The completed help reply replaces the welcome menu with one group.
    # Count actionable buttons inside it, not accumulated menu containers.
    assert_selector ".mi-chat__row.is-in", minimum: 2, wait: 5
    assert_no_selector ".mi-chat__typing", wait: 5
    assert_no_selector ".mi-chat__quick[data-test-welcome-quick]", wait: 5
    assert_selector ".mi-chat__quick", count: 1
    help_chips = find(".mi-chat__quick")
    assert_selector ".mi-chat__quick button.mi-chat__chip[type='button']", minimum: 2
    report_chip = help_chips.find_button(report_label, exact: true, disabled: false)
    donate_chip = help_chips.find_button(donate_label, exact: true, disabled: false)
    assert_equal "navigate", report_chip["data-mi-chat-action"]
    assert_equal "/biceriseno/prijave/new", report_chip["data-mi-chat-value"]
    assert_equal "navigate", donate_chip["data-mi-chat-action"]
    assert_equal "/biceriseno/projekti", donate_chip["data-mi-chat-value"]

    # Tapping the "report a problem" chip navigates to the report intake form.
    report_chip.click
    assert_current_path(%r{/biceriseno/prijave/new}, wait: 5)
  end

  test "mobile chat closes before shortcut navigation" do
    citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
    sign_in_user! citizen
    page.driver.browser.manage.window.resize_to(390, 844)

    visit "/biceriseno/mapa"
    accept_data_consent!

    find(".mi-mobile-bottom-nav [data-mi-bot-open]").click
    assert_selector "#mi-chat.mi-chat.is-open", wait: 10
    assert_selector "#mi-chat-panel", visible: :visible
    # Mark the welcome group so unchanged greeting chips cannot satisfy the reply check.
    find(".mi-chat__quick").execute_script("this.setAttribute('data-test-welcome-quick', 'true')")

    fill_in I18n.t("decidim.bih.concierge.widget.input_placeholder"), with: "hej"
    find(".mi-chat__send").click

    donate_label = I18n.t("decidim.bih.concierge.widget.quick.donate", locale: "sr")
    assert_selector ".mi-chat__row.is-in", minimum: 2, wait: 5
    assert_no_selector ".mi-chat__typing", wait: 5
    assert_no_selector ".mi-chat__quick[data-test-welcome-quick]", wait: 5
    assert_selector ".mi-chat__quick", count: 1
    assert_selector ".mi-chat__quick button.mi-chat__chip[type='button']", minimum: 2
    find(".mi-chat__quick").find_button(donate_label, exact: true, disabled: false).click

    assert_current_path "/biceriseno/projekti", wait: 5
    assert_no_selector "#mi-chat.mi-chat.is-open", wait: 5
  end

  test "reports map renders marker data and popup status link without external services" do
    report = Decidim::Bih::Report.create!(
      organization: @organization,
      description: "Rupa na putu",
      latitude: 0.15,
      longitude: 0.15
    )

    visit "/biceriseno/mapa"
    accept_data_consent!

    assert_selector "#bih-reports-map"
    assert_selector ".leaflet-container"
    assert_selector ".leaflet-interactive", wait: 5

    find(".leaflet-interactive", match: :first).click
    assert_selector ".leaflet-popup-content", text: report.reference
    popup_uri = URI.parse(find(".leaflet-popup-content a")[:href])
    assert_equal "/biceriseno/prijave/#{report.reference}", popup_uri.path
    assert_equal({ "locale" => "sr" }, Rack::Utils.parse_query(popup_uri.query))
    assert_equal URI.parse(page.current_url).host, popup_uri.host
    assert_equal URI.parse(page.current_url).port, popup_uri.port
  end

  test "report intake map click stores hidden coordinates" do
    visit "/biceriseno/prijave/new"
    accept_data_consent!

    assert_selector "#bih-report-location-map.leaflet-container[data-initialized='true']", wait: 5

    find_by_id("bih-report-location-map").click

    assert_selector "#bih-report-location-status",
                    text: I18n.t("decidim.bih.reports.new.location.selected", locale: "sr")
    assert_report_coordinate_field "#report_latitude", 0.0..0.3
    assert_report_coordinate_field "#report_longitude", 0.0..0.3
  end

  private

  def loaded_resource_urls
    page.evaluate_script("performance.getEntriesByType('resource').map(function(e) { return e.name; })")
  end

  def assert_no_chat_panel_assets_loaded
    urls = loaded_resource_urls
    assert urls.none? { |url| url.include?("/mi/mi-chat.css") }, "expected full chat CSS to be lazy-loaded"
    assert urls.none? { |url| url.include?("/mi/mi-chat.js") }, "expected full chat JS to be lazy-loaded"
  end

  def assert_chat_panel_assets_loaded
    assert loaded_resource_urls.any? { |url| url.include?("/mi/mi-chat.css") }, "expected full chat CSS after click"
    assert loaded_resource_urls.any? { |url| url.include?("/mi/mi-chat.js") }, "expected full chat JS after click"
  end

  def assert_report_coordinate_field(selector, range)
    value = page.evaluate_script("document.querySelector('#{selector}').value").to_f

    assert_includes range, value, "expected #{selector} to be inside the configured authored community map bounds"
  end
end
