# frozen_string_literal: true

require "application_system_test_case"
class AdminUpgradeLocalizationSystemTest < ApplicationSystemTestCase
  setup do
    @organization = create_organization
    use_organization_host!(@organization)
    @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization, admin_terms_accepted_at: Time.current)
    sign_in_user!(@admin)
  end

  %w(sr sr-Cyrl bs hr).each do |locale|
    test "#{locale} actual admin dashboard and calendar" do
      visit "/#{locale}/admin"
      assert_selector "h1", text: I18n.t("decidim.admin.dashboard.show.title", locale:)
      visit "/#{locale}/admin/participatory_processes/new"
      assert_selector ".datepicker__datepicker-row", minimum: 2
      assert_selector ".datepicker__help-date", text: I18n.t("date.formats.help.date_format", locale:)
      original = find("input[data-controller~='date-picker']", match: :first, visible: :all)
      field = find("##{original[:id]}_date")
      field.fill_in with: "15.12.2026"
      field.send_keys(:tab)
      assert_equal "2026-12-15", find("##{original[:id]}", visible: :all).value
      row = find("##{original[:id]}_datepicker_row")
      button = row.find(".datepicker__calendar-button")
      assert button["aria-label"].present?
      assert_no_match(/undefined|translation missing/i, button["aria-label"])
      button.click
      assert_selector ".datepicker__container wc-datepicker"
      if locale == "sr"
        assert_selector "wc-datepicker[locale='sr-Latn']"
      else
        assert_selector "wc-datepicker[locale='#{locale}']"
      end
      assert_selector ".datepicker__close-calendar", text: I18n.t("date.buttons.close", locale:)
      row.find(".datepicker__close-calendar").click
      assert_no_selector ".datepicker__container wc-datepicker"
      assert_no_selector ".translation_missing"
      assert_no_text "translation_missing"
    end
  end
end
