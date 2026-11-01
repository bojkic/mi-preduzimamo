# frozen_string_literal: true

require "application_system_test_case"
require "uri"

class MilicaChatSafetyTest < ApplicationSystemTestCase
  setup do
    @organization = create_organization
    use_organization_host!(@organization)
    @previous_concierge_org_host = ENV.fetch("DECIDIM_CONCIERGE_ORG_HOST", nil)
    ENV["DECIDIM_CONCIERGE_ORG_HOST"] = @organization.host
    Decidim::Bih::Config.reset!
    DecidimApp::Bijeljina::WebConcierge.reset!
    DecidimApp::Bijeljina::Concierge.reset!
  end

  teardown do
    DecidimApp::Bijeljina::WebConcierge.reset!
    DecidimApp::Bijeljina::Concierge.reset!
    Decidim::Bih::Config.reset!
    if @previous_concierge_org_host.nil?
      ENV.delete("DECIDIM_CONCIERGE_ORG_HOST")
    else
      ENV["DECIDIM_CONCIERGE_ORG_HOST"] = @previous_concierge_org_host
    end
  end

  test "renders hostile reply text without executable markup and keeps approved links" do
    visit "/biceriseno/mapa"
    accept_data_consent!
    find(".mi-chat-loader__bubble").click

    page.execute_script(<<~JS)
      window.fetch = function(url) {
        if (String(url).indexOf("/biceriseno/chat") !== -1) {
          return Promise.resolve({
            ok: true,
            json: function() {
              return Promise.resolve({
                reply: '<img src=x onerror=alert(1)> <script>alert(2)</script> ' +
                  'https://example.com/put?q=ћирилица). /biceriseno/prijave/new?foo=1 ' +
                  '//evil.example javascript:alert(3)',
                quick_replies: []
              });
            }
          });
        }
        return Promise.reject(new Error("unexpected request"));
      };
    JS

    outgoing_text = %q{citizen says "<span title='x' onmouseover='alert(1)'>провјери</span>"}
    fill_in I18n.t("decidim.bih.concierge.widget.input_placeholder"), with: outgoing_text
    find(".mi-chat__send").click

    assert_no_selector ".mi-chat__typing", wait: 5
    outgoing = all(".mi-chat__row.is-out .mi-chat__bubble-msg").last
    assert_equal outgoing_text, outgoing.text
    assert_empty outgoing.all("[onmouseover]")
    message = all(".mi-chat__row.is-in .mi-chat__bubble-msg").last
    assert_includes message.text, "<img src=x onerror=alert(1)>"
    assert_includes message.text, "<script>alert(2)</script>"
    assert_equal 2, message.all("a").length
    hrefs = message.all("a").map { |anchor| anchor["href"] }
    assert(hrefs.any? { |href| href.start_with?("https://example.com/put?q=") })
    report_href = hrefs.find { |href| URI.parse(href).path == "/biceriseno/prijave/new" }
    assert_not_nil report_href
    current_uri = URI.parse(page.current_url)
    report_uri = URI.parse(report_href)
    assert_equal [current_uri.scheme, current_uri.host, current_uri.port],
                 [report_uri.scheme, report_uri.host, report_uri.port]
    assert_equal "/biceriseno/prijave/new", report_uri.path
    assert_equal "foo=1", report_uri.query
    assert_equal "#{current_uri.scheme}://#{current_uri.host}:#{current_uri.port}/biceriseno/prijave/new?foo=1", report_uri.to_s
    assert_no_selector ".mi-chat__bubble-msg img"
    assert_no_selector ".mi-chat__bubble-msg script"
    assert_empty message.all("[onerror]")
    assert_no_selector ".mi-chat__bubble-msg a[href^='javascript:']"
  end

  test "does not render a late timed-out reply after the next turn succeeds" do
    visit "/biceriseno/mapa"
    accept_data_consent!
    find(".mi-chat-loader__bubble").click

    page.execute_script(<<~JS)
      window.__miRealSetTimeout = window.setTimeout.bind(window);
      window.setTimeout = function(callback, delay) {
        return window.__miRealSetTimeout(callback, delay === 10000 ? 20 : delay);
      };
      window.__miChatCalls = 0;
      window.AbortController = undefined;
      window.fetch = function(url) {
        if (String(url).indexOf("/biceriseno/chat") === -1) {
          return Promise.reject(new Error("unexpected request"));
        }
        window.__miChatCalls += 1;
        if (window.__miChatCalls === 1) {
          return Promise.resolve({ ok: true, json: function() {
            return new Promise(function(resolve) {
              window.__miRealSetTimeout(function() { resolve({ reply: "late first", quick_replies: [] }); }, 100);
            });
          } });
        }
        return Promise.resolve({ ok: true, json: function() {
          return Promise.resolve({ reply: "second turn", quick_replies: [] });
        } });
      };
    JS

    fill_in I18n.t("decidim.bih.concierge.widget.input_placeholder"), with: "first turn"
    find(".mi-chat__send").click
    assert_no_selector ".mi-chat__typing", wait: 5
    fill_in I18n.t("decidim.bih.concierge.widget.input_placeholder"), with: "second turn"
    find(".mi-chat__send").click
    assert_no_selector ".mi-chat__typing", wait: 5
    page.execute_script("window.__miRealSetTimeout(function() {}, 150)")
    assert_selector ".mi-chat__row.is-in .mi-chat__bubble-msg", text: "second turn", wait: 2
    late_first = page.evaluate_script(
      "Array.from(document.querySelectorAll('.mi-chat__row.is-in .mi-chat__bubble-msg')).some(" \
      "function(n) { return n.textContent === 'late first'; })"
    )
    assert_not late_first
  end

  test "requests location only for an explicit current-location turn" do
    visit "/biceriseno/mapa"
    accept_data_consent!
    find(".mi-chat-loader__bubble").click

    page.execute_script(<<~JS)
      window.__miChatRequests = [];
      navigator.geolocation.getCurrentPosition = function(success) {
        // Real GeolocationPosition includes the acquisition time used by the freshness guard.
        success({ coords: { latitude: 44.7561, longitude: 19.2144, accuracy: 12 }, timestamp: Date.now() });
      };
      window.fetch = function(url, options) {
        if (String(url).indexOf("/biceriseno/chat") !== -1) {
          window.__miChatRequests.push(JSON.parse(options.body));
          return Promise.resolve({ ok: true, json: function() {
            return Promise.resolve({ reply: "У реду", quick_replies: [] });
          } });
        }
        return Promise.reject(new Error("unexpected request"));
      };
    JS

    find(".mi-chat__locate").click
    assert_selector ".mi-chat__locate.is-active", wait: 5

    fill_in I18n.t("decidim.bih.concierge.widget.input_placeholder"), with: "status"
    find(".mi-chat__send").click
    assert_no_selector ".mi-chat__typing", wait: 5
    assert_nil page.evaluate_script("window.__miChatRequests[0].location")

    fill_in I18n.t("decidim.bih.concierge.widget.input_placeholder"), with: "šta ima odavde?"
    find(".mi-chat__send").click
    assert_no_selector ".mi-chat__typing", wait: 5
    location = page.evaluate_script("window.__miChatRequests[1].location")
    assert_equal 44.7561, location["latitude"]
    assert_equal 19.2144, location["longitude"]
    assert_equal 12, location["accuracy"]
    assert_equal "current_location", location["purpose"]
    assert_equal true, location["consent"]
    assert_equal "browser_geolocation", location["provenance"]
  end

  test "restores the message after a failed request and acknowledges feedback only after save" do
    visit "/biceriseno/mapa"
    accept_data_consent!
    find(".mi-chat-loader__bubble").click

    page.execute_script(<<~JS)
      window.fetch = function(url) {
        if (String(url).indexOf("/biceriseno/chat/feedback") !== -1) {
          return Promise.resolve({ ok: true, status: 200, json: function() {
            return Promise.resolve({ status: "error" });
          } });
        }
        if (String(url).indexOf("/biceriseno/chat") !== -1) {
          return Promise.reject(new Error("offline"));
        }
        return Promise.reject(new Error("unexpected request"));
      };
    JS

    text = "ne šalji dok nema mreže"
    fill_in I18n.t("decidim.bih.concierge.widget.input_placeholder"), with: text
    find(".mi-chat__send").click
    assert_no_selector ".mi-chat__typing", wait: 5
    assert_equal text, find(".mi-chat__field").value

    # Replace the stub with a successful chat response carrying feedback, then
    # prove a failed feedback save does not show the success acknowledgement.
    page.execute_script(<<~JS)
      window.fetch = function(url) {
        if (String(url).indexOf("/biceriseno/chat/feedback") !== -1) {
          return Promise.resolve({ ok: true, status: 200, json: function() {
            return Promise.resolve({ status: "error" });
          } });
        }
        return Promise.resolve({ ok: true, json: function() {
          return Promise.resolve({ reply: "Одговор", feedback: {
            id: "r-20260905-000001", token: "signed", url: "/biceriseno/chat/feedback"
          }, quick_replies: [] });
        } });
      };
    JS

    find(".mi-chat__send").click
    assert_selector ".mi-chat__feedback", wait: 5
    find(".mi-chat__feedback-button", text: I18n.t("decidim.bih.concierge.widget.feedback.helpful")).click
    assert_selector ".mi-chat__feedback-status", text: I18n.t("decidim.bih.concierge.widget.feedback.error"), wait: 5
    assert_not_includes all(".mi-chat__feedback-status").last.text, I18n.t("decidim.bih.concierge.widget.feedback.thanks")
    assert_selector ".mi-chat__feedback-button:not([disabled])", minimum: 2
  end

  test "host and packaged chat assets both carry the renderer safety contract" do
    host_asset = Rails.public_path.join("mi/mi-chat.js").to_s
    engine_asset = Decidim::Bih.required_public_asset_source_path("mi/mi-chat.js").to_s

    [host_asset, engine_asset].each do |path|
      source = File.read(path)
      assert_includes source, "appendSafeText"
      assert_includes source, "validatedLink"
      assert_includes source, "purpose: \"current_location\""
      assert_includes source, "provenance: \"browser_geolocation\""
      assert_not_includes source, "msg.innerHTML"
      assert_not_includes source, "linkify(escapeHtml"
    end
  end
end
