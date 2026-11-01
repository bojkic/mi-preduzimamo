# frozen_string_literal: true

require "test_helper"
require_relative "support/shakapacker_manifest_stub"
require "erb"
require "warden/test/helpers"

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  include Warden::Test::Helpers

  driven_by :selenium, using: :headless_chrome, screen_size: [1400, 1400] do |options|
    options.add_argument("--no-sandbox")
    options.add_argument("--disable-dev-shm-usage")
    options.add_option("goog:loggingPrefs", browser: "ALL")
  end

  setup do
    WebMock.disable_net_connect!(allow_localhost: true) if defined?(WebMock)
    Capybara.always_include_port = true
    reset_browser_runtime_cache!
  end

  teardown do
    Warden.test_reset!
    quit_browser!
    Capybara.app_host = nil
    WebMock.allow_net_connect! if defined?(WebMock)
  end

  def use_organization_host!(organization)
    Decidim::Organization.where(host: "127.0.0.1").where.not(id: organization.id).find_each do |existing|
      existing.update!(host: "system-test-old-#{existing.id}.lvh.me")
    end

    organization.update!(host: "127.0.0.1")
    Capybara.app_host = "http://127.0.0.1"
  end

  def accept_data_consent!
    value = ERB::Util.url_encode(
      { essential: true, preferences: true, analytics: true, marketing: true }.to_json
    )

    page.execute_script(<<~JS)
      document.cookie = "#{Decidim.consent_cookie_name}=#{value}; path=/; SameSite=Lax";
      var banner = document.getElementById("dc-dialog-wrapper");
      if (banner) banner.hidden = true;
      var modal = document.getElementById("dc-modal");
      if (modal) {
        modal.hidden = true;
        modal.setAttribute("aria-hidden", "true");
        modal.classList.add("hidden");
      }
      document.body.classList.remove("overflow-hidden");
    JS
  end

  def sign_in_user!(user)
    login_as user, scope: :user
  end

  def assert_no_horizontal_overflow!
    overflow = page.evaluate_script(
      "document.documentElement.scrollWidth - document.documentElement.clientWidth"
    )
    offenders = page.evaluate_script(<<~JS)
      Array.from(document.querySelectorAll("body *"))
        .map(function (element) {
          var bounds = element.getBoundingClientRect();
          return {
            selector: element.tagName.toLowerCase() +
              (element.id ? "#" + element.id : "") +
              (element.classList.length ? "." + Array.from(element.classList).slice(0, 3).join(".") : ""),
            left: Math.round(bounds.left),
            right: Math.round(bounds.right),
            width: Math.round(bounds.width),
            scrollWidth: element.scrollWidth
          };
        })
        .filter(function (item) {
          return item.left < -2 || item.right > document.documentElement.clientWidth + 2;
        })
        .sort(function (left, right) {
          return (right.right - document.documentElement.clientWidth) -
            (left.right - document.documentElement.clientWidth);
        })
        .slice(0, 12);
    JS
    detail = offenders.map do |item|
      "#{item.fetch("selector")} left=#{item.fetch("left")} right=#{item.fetch("right")} " \
        "width=#{item.fetch("width")} scrollWidth=#{item.fetch("scrollWidth")}"
    end.join("\n")

    assert_operator overflow, :<=, 2, "expected page not to have horizontal overflow\n#{detail}"
  end

  def assert_no_browser_console_errors!
    errors = browser_console_entries.select { |entry| entry.level.to_s == "SEVERE" }
    messages = errors.map { |entry| "[#{entry.level}] #{entry.message}" }

    assert_empty messages, "expected no severe browser console errors, got:\n#{messages.join("\n")}"
  end

  def reset_browser_runtime_cache!
    browser = page.driver.browser
    return unless browser.respond_to?(:execute_cdp)

    server = Capybara.current_session.server
    server.boot if server.respond_to?(:boot)
    origin = "http://127.0.0.1:#{server.port}" if server&.port

    if origin
      browser.execute_cdp("ServiceWorker.enable")
      browser.execute_cdp("ServiceWorker.unregister", scopeURL: "#{origin}/")
      browser.execute_cdp("Storage.clearDataForOrigin", origin: origin, storageTypes: "all")
    end

    browser.execute_cdp("Network.enable")
    browser.execute_cdp("Network.clearBrowserCache")
    browser.execute_cdp("Network.clearBrowserCookies")
    browser.execute_cdp("ServiceWorker.disable")
  rescue StandardError
    # Keep system tests portable across Selenium/Chrome versions.
  end

  def quit_browser!
    Capybara.current_session.driver.quit
  rescue StandardError
    # Capybara will create a new browser session for the next system test.
  end

  def browser_console_entries
    page.driver.browser.manage.logs.get(:browser)
  rescue StandardError
    []
  end
end
