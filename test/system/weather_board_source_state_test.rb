# frozen_string_literal: true

require "application_system_test_case"
require_relative "../support/synthetic_weather_board"

class WeatherBoardSourceStateSystemTest < ApplicationSystemTestCase
  include SyntheticWeatherBoard

  setup do
    assert_equal "1", ENV["DECIDIM_TEST_COMPILED_ASSETS"], "weather rendering requires compiled candidate assets"
    setup_synthetic_weather_board { |organization| use_organization_host!(organization) }
    sign_in_user! @weather_viewer
  end
  teardown { teardown_synthetic_weather_board }

  def visit_weather_post(locale: "sr")
    visit "/biceriseno/komsiluk-board/#{@weather_post.id}?locale=#{locale}"
    accept_data_consent!
  end

  def assert_updated_weather_card(locale:)
    within "#post-#{@weather_post.id}" do
      assert_selector "h1", text: I18n.t("decidim.bih.boards.source_update.title", locale:)
      assert_no_text @weather_post.title
      assert_no_text @weather_post.body
      assert_no_selector ".mi-board-source, .mi-board-photo", visible: :all
      assert_no_selector "a[href='#{@weather_event.source_url}']", visible: :all
    end
    assert_no_horizontal_overflow!
  end

  test "desktop current weather becomes neutral after review changes across all four locales" do
    page.driver.browser.manage.window.resize_to(1400, 1000)
    visit_weather_post
    assert_selector "#post-#{@weather_post.id} h1", text: @weather_post.title
    assert_selector "#post-#{@weather_post.id} .mi-board-source"
    retained = @weather_post.attributes.slice("title", "body", "details", "status")
    restore_weather_board_review(region_label: "Druga autorska pregledana regija")
    %w(sr sr-Cyrl bs hr).each do |locale|
      visit_weather_post(locale:)
      assert_updated_weather_card(locale:)
    end
    assert_equal retained, @weather_post.reload.attributes.slice("title", "body", "details", "status")
    FileUtils.mkdir_p Rails.root.join("tmp/screenshots")
    save_screenshot Rails.root.join("tmp/screenshots/weather-review-changed-desktop.png")
  end

  test "mobile list keeps a usable neutral link when the source review is missing" do
    ENV.delete("MI_WEATHER_REGION_CONFIG_PATH")
    [390, 320].each do |width|
      page.driver.browser.manage.window.resize_to(width, 844)
      visit "/biceriseno/komsiluk-board?locale=sr"
      accept_data_consent!
      within "#post-#{@weather_post.id}" do
        assert_no_text @weather_post.title
        assert_no_text @weather_post.body
        assert_no_selector ".mi-board-source", visible: :all
        find("h2 a", text: I18n.t("decidim.bih.boards.source_update.title", locale: :sr)).click
      end
      assert_current_path %r{\A/biceriseno/komsiluk-board/#{@weather_post.id}(?:\?.*)?\z}, ignore_query: false
      assert_updated_weather_card(locale: :sr)
    end
    FileUtils.mkdir_p Rails.root.join("tmp/screenshots")
    save_screenshot Rails.root.join("tmp/screenshots/weather-review-missing-mobile.png")
  end
end
