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
    test "#{locale} native editor update phases and publication use native translations" do
      page.driver.browser.manage.window.resize_to(1440, 1100)
      title = { "sr" => "Probni proces", "sr-Cyrl" => "Пробни процес", "bs" => "Probni proces", "hr" => "Probni proces" }
      process = FactoryBot.create(:participatory_process, :with_steps, organization: @organization, published_at: nil, title:)
      edit_path = "/#{locale}/admin/participatory_processes/#{process.slug}/edit"
      visit edit_path
      update_label = I18n.t("decidim.admin.participatory_processes.edit.update", locale:)
      steps_label = I18n.t("decidim.admin.menu.participatory_processes_submenu.steps", locale:)
      bold_label = I18n.t("editor.toolbar.control.bold", locale:)
      heading_label = I18n.t("editor.toolbar.textStyle.heading", locale:).gsub("%level%", "2")
      assert_button update_label
      assert_link steps_label
      slug_key = "decidim.participatory_processes.admin.participatory_processes.form.slug_help_html"
      assert I18n.exists?(slug_key, locale, fallback: false)
      assert_text I18n.t(slug_key, locale:, url: "").strip
      assert_no_text "URL slugs are used"
      assert_selector "button[data-editor-type='bold'][aria-label='#{bold_label}']", minimum: 1
      assert_selector "select[data-editor-type='heading'] option[value='2']", text: heading_label, visible: :all
      assert_no_selector "[data-editor-type][aria-label='Bold'], [data-editor-type][aria-label='Text style']", visible: :all
      FileUtils.mkdir_p(Rails.root.join("tmp/screenshots"))
      page.save_screenshot(Rails.root.join("tmp/screenshots/admin-editor-#{locale}.png")) # rubocop:disable Lint/Debugger -- native locale acceptance evidence
      click_button update_label
      assert_text I18n.t("decidim.admin.participatory_processes.update.success", locale:)
      click_link steps_label
      assert_selector "#steps h1", text: I18n.t("decidim.participatory_processes.admin.participatory_process_steps.index.title", locale:)
      %w(title start_date end_date actions).each do |field|
        assert_selector "#steps thead th", text: I18n.t("decidim.admin.models.participatory_process_step.fields.#{field}", locale:)
      end
      assert_no_selector "#steps thead th", text: /\A(?:Title|Start date|End date|Actions)\z/
      visit "/#{locale}/admin/participatory_processes"
      find("button[data-target='actions-process-#{process.id}']").click
      within "#actions-process-#{process.id}" do
        click_link I18n.t("decidim.admin.actions.publish", locale:)
      end
      assert_text I18n.t("decidim.admin.participatory_process_publications.create.success", locale:)
      assert process.reload.published?
      assert_no_selector ".translation_missing"
      page.save_screenshot(Rails.root.join("tmp/screenshots/admin-publish-#{locale}.png")) # rubocop:disable Lint/Debugger -- native locale acceptance evidence
    end

    test "#{locale} admin terms review and refusal are translated" do
      @organization.update!(admin_terms_of_service_body: { locale => "Test admin terms" })
      @admin.update!(admin_terms_accepted_at: nil)
      visit "/#{locale}/admin"
      # A user without accepted terms is redirected directly to the review page.
      assert_text I18n.t("decidim.admin.admin_terms_of_service.required_review.callout", locale:)
      assert_text I18n.t("decidim.admin.admin_terms_of_service.actions.title", locale:)
      assert_link I18n.t("decidim.admin.admin_terms_of_service.actions.refuse", locale:)
      assert_no_text "Refuse the admin terms"
      assert_no_text "Please take a moment to review"
    end

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
      picker_label = { "sr" => "Izaberi datum", "sr-Cyrl" => "Изабери датум", "bs" => "Odaberi datum", "hr" => "Odaberi datum" }.fetch(locale)
      assert_selector "wc-datepicker [role='group'][aria-label='#{picker_label}']"
      assert_no_selector "wc-datepicker [aria-label='Choose date'], wc-datepicker [aria-label='Previous month'], wc-datepicker [aria-label='Select year']"
      if locale == "bs"
        assert_selector "wc-datepicker select[name='month'] option", text: "decembar", visible: :all
        assert_selector "wc-datepicker th[abbr='ponedjeljak'] span", text: "pon"
        assert_no_selector "wc-datepicker select[name='month'] option", text: /M\d{2}/, visible: :all
      end
      assert_selector ".datepicker__close-calendar", text: I18n.t("date.buttons.close", locale:)
      row.find(".datepicker__close-calendar").click
      assert_no_selector ".datepicker__container wc-datepicker"
      assert_no_selector ".translation_missing"
      assert_no_text "translation_missing"
    end
  end
end
