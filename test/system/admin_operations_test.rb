# frozen_string_literal: true

require "application_system_test_case"

class AdminOperationsTest < ApplicationSystemTestCase
  setup do
    @organization = create_organization
    use_organization_host!(@organization)
    @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
  end

  test "operations dashboard separates work areas and keeps diagnostics secondary" do
    sign_in_user! @admin
    visit "/admin/bih/operations"
    accept_data_consent!

    assert_selector "[data-mi-admin-surface].form-defaults"
    assert_selector "[data-admin-primary-workflows]"
    assert_selector "[data-admin-primary-item='reports']"
    assert_no_selector "#admin-all-tools[open]"
    find("#admin-all-tools summary").click
    assert_selector "[data-admin-navigation-group='daily']"
    assert_selector "[data-admin-navigation-group='daily'] [data-admin-navigation-item='partner_profiles']"
    assert_selector "[data-admin-navigation-group='settings']"
    assert_selector "[data-admin-navigation-group='governance']"
    assert_selector "[data-admin-navigation-item='reports'] .mi-admin-nav__metric"
    assert_selector "[data-admin-navigation-item='analytics'] .mi-admin-nav__metric--neutral"
    assert_no_selector "#admin-operator-handoffs[open]"
    find("#admin-operator-handoffs summary").click
    assert_selector "[data-admin-handoff='release_restart'] a[href$='#governance-release_restart']"
    assert_selector "[data-admin-handoff='release_restart'] details:not([open])"
    assert_no_text "script/mi_restore_drill"

    within "[data-admin-handoff='backup_restore']" do
      find("summary").click
      assert_text "script/mi_restore_drill"
    end

    assert_no_selector ".translation_missing"
    assert_no_horizontal_overflow!
    assert_no_browser_console_errors!
  end

  test "mobile destination navigation keeps the current task above a destination wall" do
    page.driver.browser.manage.window.resize_to(390, 844)
    sign_in_user! @admin
    visit "/admin/bih/goodwill"
    accept_data_consent!

    assert_selector "[data-admin-breadcrumb='goodwill']"
    assert_no_selector "#admin-related-tools[open]"
    find("#admin-related-tools summary").click
    assert_selector "[data-admin-navigation-current-area='community']"
    assert_selector "[data-admin-navigation-item='goodwill']"
    assert_no_selector "[data-admin-navigation-item='reports']"
    assert_selector "#admin-bih-navigation"
    assert_no_horizontal_overflow!
    assert_no_browser_console_errors!
  end
end
