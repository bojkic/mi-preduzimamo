# frozen_string_literal: true

require "application_system_test_case"

class OpenSourcePageSystemTest < ApplicationSystemTestCase
  setup do
    @organization = create_organization
    use_organization_host!(@organization)
    @release_environment = %w(MI_OPEN_SOURCE_PUBLISHED MI_OPEN_SOURCE_APP_URL MI_OPEN_SOURCE_ENGINE_URL).index_with { |key| ENV.fetch(key, nil) }
    ENV["MI_OPEN_SOURCE_PUBLISHED"] = "false"
  end

  teardown do
    @release_environment.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  test "mobile preparation page exposes contact and footer navigation without overflow" do
    page.driver.browser.manage.window.resize_to(390, 844)
    visit "/otvoreni-kod"
    accept_data_consent!
    within 'article[lang="sr-Latn"]' do
      assert_selector "h1", text: "Pokrenite MI preduzimamo u svojoj zajednici"
      assert_selector "h2", text: "Priprema javnog izdanja"
      assert_selector 'a[href^="mailto:office@fondacijabijeljina.com"]', text: "Kontaktirajte Fondaciju za ponudu"
      assert_no_selector 'a[href^="https://github.com/"]'
    end
    assert_no_horizontal_overflow!
    assert_operator page.evaluate_script("parseFloat(getComputedStyle(document.querySelector('.mi-open-source')).paddingLeft)"), :>=, 16
    assert_operator page.evaluate_script("parseFloat(getComputedStyle(document.querySelector('.mi-open-source h1')).fontSize)"), :>=, 30
    page.driver.browser.manage.window.resize_to(320, 740)
    assert_no_horizontal_overflow!
    find('a[href*="/otvoreni-kod"]', text: "Otvoreni kod").click
    assert_selector "h1", text: "Pokrenite MI preduzimamo u svojoj zajednici"
    save_screenshot Rails.root.join("tmp/screenshots/open-source-mobile.png") # rubocop:disable Lint/Debugger -- Authored page review artifact.
  end

  test "published desktop page exposes both repositories and independent paid assistance" do
    ENV["MI_OPEN_SOURCE_PUBLISHED"] = "true"
    ENV["MI_OPEN_SOURCE_APP_URL"] = "https://github.com/bojkic/mi-preduzimamo"
    ENV["MI_OPEN_SOURCE_ENGINE_URL"] = "https://github.com/bojkic/mi-preduzimamo-engine"
    visit "/otvoreni-kod"
    accept_data_consent!
    within 'article[lang="sr-Latn"]' do
      assert_selector 'a[href="https://github.com/bojkic/mi-preduzimamo"]', text: "Aplikacija"
      assert_selector 'a[href="https://github.com/bojkic/mi-preduzimamo-engine"]', text: "Zajednički engine"
      assert_text "Plaćena pomoć nije uslov za samostalno korišćenje softvera prema licenci."
      assert_selector 'a[href="mailto:bojan@fondacijabijeljina.com"]'
    end
    assert_no_horizontal_overflow!
    save_screenshot Rails.root.join("tmp/screenshots/open-source-desktop.png") # rubocop:disable Lint/Debugger -- Authored page review artifact.
  end
end
