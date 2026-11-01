# frozen_string_literal: true

require "application_system_test_case"
require_relative "../support/race_project_selection_fixture"

class RaceProjectSelectionSystemTest < ApplicationSystemTestCase
  include RaceProjectSelectionFixture

  setup do
    prepare_race_projects
    use_organization_host!(@organization)
  end
  teardown { travel_back }

  test "desktop and mobile lead to both proposal pages and retain the race inside the process" do
    [1400, 390].each do |width|
      page.driver.browser.manage.window.resize_to(width, 900)
      visit DecidimApp::Bijeljina::RaceProjectSelection.process_path
      accept_data_consent!
      [@city_component, @rural_component].each do |component|
        router = Decidim::EngineRouter.main_proxy(component)
        within(".mi-project-choice__cards") do
          assert_selector "a[href='#{router.root_path(locale: @organization.default_locale)}']"
          assert_selector "a[href='#{router.new_proposal_path(locale: @organization.default_locale)}']"
        end
        find(".mi-project-choice__cards a[href='#{router.root_path(locale: @organization.default_locale)}']").click
        assert_current_path router.root_path, ignore_query: true
        visit DecidimApp::Bijeljina::RaceProjectSelection.process_path
        accept_data_consent!
      end
      assert_no_horizontal_overflow!
      visit "/trka"
      assert_selector "[data-race-project-selection] a", minimum: 3
      assert_no_selector ".main-bar a[href='/trka'], footer a[href='/trka'], .mi-mobile-bottom-nav a[href='/trka']", visible: :all
      if width == 390
        find("[data-mi-mobile-more-open]").click
        assert_selector "#mi-mobile-more-sheet", visible: :visible
        assert_no_selector "#mi-mobile-more-sheet a[href='/trka']", visible: :all
      end
      visit Decidim::EngineRouter.main_proxy(@result[:archive]).root_path
      assert_selector "a[href='/trka']"
    end
  end

  test "verified citizen can reach each native proposal form" do
    sign_in_user!(@citizen)
    [@city_component, @rural_component].each do |component|
      visit Decidim::EngineRouter.main_proxy(component).new_proposal_path
      accept_data_consent!
      assert_selector "form input[name='proposal[title]']"
      assert_selector "form [name='proposal[body]']", visible: :all
      assert_no_horizontal_overflow!
    end
  end
end
