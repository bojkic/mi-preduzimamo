# frozen_string_literal: true

require "test_helper"
require "capybara"
require "decidim/participatory_processes/test/factories"

class LayoutUpgradeCompatibilityTest < ActionDispatch::IntegrationTest
  setup do
    @organization = create_organization
    host! @organization.host
    @process = create(:participatory_process, organization: @organization, published_at: Time.current,
                      promoted: true, slug: DecidimApp::Bijeljina::RaceProjectSelection::PROCESS_SLUG,
                      title: @organization.available_locales.index_with { "Synthetic community projects" })
  end

  test "localized process routes retain campaign and help styles in every locale" do
    %w(sr sr-Cyrl bs hr).each do |locale|
      get "/#{locale}/processes/#{@process.slug}"
      assert_response :success
      assert_select "main.mi-project-choice", count: 1
      assert_select ".mi-mobile-bottom-nav a[aria-current=page][href*=processes]", count: 1
      assert_select "link[rel='stylesheet'][href^='/mi/project-choice.css?']", count: 1
      assert_select "link[rel='stylesheet'][href^='/mi/process-help.css?']", count: 1
      assert_select "#breadcrumb-main-dropdown-desktop.mi-navigation-panel--desktop", count: 1
      assert_select "#breadcrumb-main-dropdown-desktop .card__highlight", count: 1
      assert_select "#main-dropdown-summary[data-controller='dropdown'][data-auto-close='true']", count: 1
      assert_select "#main-dropdown-summary[onmouseenter]", count: 0
      assert_select "#main-dropdown-menu a[href*='prijave/new']", minimum: 1
    end
  end

  test "ordinary process pages use current Core access-mode markup" do
    @process.update!(slug: "synthetic-ordinary-process")
    get "/sr/processes/#{@process.slug}"
    assert_response :success
    assert_select ".participatory-space__container", count: 1
    assert_select "link[href^='/mi/project-choice.css?']", count: 0
    assert_select "link[href^='/mi/process-help.css?']", count: 1
  end

  test "restored menu activity shows public activity without exposing a restricted process" do
    actor = create(:user, :confirmed, organization: @organization)
    create(:action_log, user: actor, organization: @organization, action: "publish", visibility: "public-only",
                        resource: @process, participatory_space: @process, component: nil)
    restricted = create(:participatory_process, organization: @organization, published_at: Time.current,
                        access_mode: :restricted,
                        title: @organization.available_locales.index_with { "Restricted activity example" })
    create(:action_log, user: actor, organization: @organization, action: "publish", visibility: "public-only",
                        resource: restricted, participatory_space: restricted, component: nil)
    get "/sr/processes/#{@process.slug}"
    assert_response :success
    assert_select "#main-dropdown-menu .mi-menu-activity", count: 1
    assert_select "#main-dropdown-menu .mi-menu-activity" do |activity|
      assert_includes activity.first.text, "Synthetic community projects"
      assert_not_includes activity.first.text, "Restricted activity example"
    end
  end

  test "unpublished restricted and foreign highlights never enter the guest menu" do
    create(:participatory_process, organization: @organization, published_at: Time.current,
           promoted: true, access_mode: :restricted, weight: -100,
           title: @organization.available_locales.index_with { "Restricted synthetic process" })
    foreign = create_organization
    create(:participatory_process, organization: foreign, published_at: Time.current, promoted: true,
           title: foreign.available_locales.index_with { "Foreign synthetic process" })
    get "/sr/processes/#{@process.slug}"
    assert_response :success
    assert_select "#main-dropdown-menu" do |menus|
      assert_includes menus.first.text, "Synthetic community projects"
      assert_not_includes menus.first.text, "Restricted synthetic process"
      assert_not_includes menus.first.text, "Foreign synthetic process"
    end
  end
end
