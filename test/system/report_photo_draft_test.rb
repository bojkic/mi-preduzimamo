# frozen_string_literal: true

require "application_system_test_case"

class ReportPhotoDraftBrowserTest < ApplicationSystemTestCase
  test "a citizen confirms a different problem without uploading their photo twice" do
    organization = create_organization
    use_organization_host!(organization)
    Decidim::Bih::Report.create!(organization:, description: "Existing private description", latitude: 44.756, longitude: 19.216)
    visit "/biceriseno/prijave/new?lat=44.7561&lng=19.2161"
    accept_data_consent!
    fill_in "report_description", with: "Different problem with a photograph"
    attach_file "report_photo", Rails.root.join("test/fixtures/files/chat_photo.jpg"), make_visible: true
    find(".mi-report-form__submit").click
    assert_text I18n.t("decidim.bih.photo_draft.saved")
    assert_no_text "Existing private description"
    assert_no_selector "input[type=file]"
    page.current_window.resize_to(390, 844)
    assert_no_horizontal_overflow!
    FileUtils.mkdir_p(Rails.root.join("tmp/report-review-ui"))
    page.save_screenshot(Rails.root.join("tmp/report-review-ui/photo-draft-mobile.png")) # rubocop:disable Lint/Debugger
    click_button I18n.t("decidim.bih.reports.duplicate.submit_anyway")
    assert_current_path %r{/biceriseno/prijave/BR-[^/]+/status/}
    report = Decidim::Bih::Report.order(:id).last
    assert_equal "Different problem with a photograph", report.description
    assert report.photo.attached?
    assert_selector "#report-current-action", text: I18n.t("decidim.bih.reports.current_action.review")
    assert_no_horizontal_overflow!
    page.execute_script("document.querySelector('#report-current-action').scrollIntoView({behavior: 'instant', block: 'center'})")
    page.save_screenshot(Rails.root.join("tmp/report-review-ui/current-action-mobile.png")) # rubocop:disable Lint/Debugger
  end
  test "saved photo removal can be selected with the keyboard" do
    organization = create_organization
    use_organization_host!(organization)
    Decidim::Bih::Report.create!(organization:, description: "Existing", latitude: 44.756, longitude: 19.216)
    visit "/biceriseno/prijave/new?lat=44.7561&lng=19.2161"
    accept_data_consent!
    fill_in "report_description", with: "Different without a photograph"
    attach_file "report_photo", Rails.root.join("test/fixtures/files/chat_photo.jpg"), make_visible: true
    find(".mi-report-form__submit").click
    control = find_by_id("report_remove_saved_photo")
    control.send_keys(:space)
    assert control.checked?
    control.send_keys(:tab)
    assert page.evaluate_script("document.activeElement.matches('button[type=submit], input[type=submit]')")
    assert_equal I18n.t("decidim.bih.reports.duplicate.submit_anyway"), page.evaluate_script("document.activeElement.textContent.trim() || document.activeElement.value")
    page.driver.browser.action.send_keys(:enter).perform
    assert_current_path %r{/biceriseno/prijave/BR-[^/]+/status/}
    assert_not Decidim::Bih::Report.order(:id).last.photo.attached?
  end
end
