# frozen_string_literal: true

require "application_system_test_case"

class ReportReviewBatchBrowserTest < ApplicationSystemTestCase
  test "batch review preserves independent consent stale checks and draft editing on mobile" do
    old_protection = ActionController::Base.allow_forgery_protection
    old_origin = ActionController::Base.forgery_protection_origin_check
    ActionController::Base.allow_forgery_protection = true
    ActionController::Base.forgery_protection_origin_check = true
    organization = create_organization
    use_organization_host!(organization)
    admin = FactoryBot.create(:user, :admin, :confirmed, organization:)
    Decidim::Bih::Setting.put(organization, "sistem48_routing", "central_intake", "intake@example.org")
    reports = %w(send review ask).map do |action|
      report = Decidim::Bih::Report.create!(organization:, description: "Broken lamp near school", address: "Test street", category: "rasvjeta", severity: "normalan")
      Decidim::Bih::ReportDecision.new(report, admin).call(action: "save_draft", values: { draft_action: action, body: "Which crossing?" },
                                                           version: Decidim::Bih::ReportReviewVersion.digest(report))
      report
    end
    sign_in_user! admin
    visit "/admin/bih/reports/batch?return_to=%2Fadmin%2Fbih%2Freports%3Fview%3Dall"
    accept_data_consent!
    w = "decidim.bih.review_workspace"
    assert_text I18n.t("#{w}.batch.title")
    assert_no_selector "input[type=checkbox]:checked"
    reports.first(2).each { |report| check I18n.t("#{w}.batch.include", reference: report.reference) }
    click_button I18n.t("#{w}.batch.preview")
    assert_current_path "/admin/bih/reports/batch/preview", ignore_query: true
    assert_text I18n.t("#{w}.batch.confirm_title")
    assert_text "intake@example.org"
    assert_text "Broken lamp near school"
    assert_no_selector "input[type=checkbox]:checked"
    FileUtils.mkdir_p(Rails.root.join("tmp/report-review-ui"))
    page.save_screenshot(Rails.root.join("tmp/report-review-ui/batch-preview.png")) # rubocop:disable Lint/Debugger
    Decidim::Bih::ReportCaseWorkflow.new(reports.first, nil).reply(body: "The location changed")
    reports.first(2).each { |report| check I18n.t("#{w}.batch.approve", reference: report.reference) }
    click_button I18n.t("#{w}.batch.apply")
    assert_current_path "/admin/bih/reports/batch/confirm", ignore_query: true
    assert_text I18n.t("#{w}.batch.results")
    assert_text I18n.t("#{w}.errors.stale")
    assert_equal 0, reports.first.dispatches.count
    assert_equal admin, reports.second.reload.reviewed_by
    assert_nil reports.last.reload.reviewed_at
    click_link I18n.t("#{w}.batch.back")
    within "#batch-report-#{reports.last.id}" do
      click_link I18n.t("#{w}.batch.edit")
    end
    assert_selector "#report-decision-form[data-ready='1']"
    fill_in "decision[body]", with: "Which school crossing?"
    click_button I18n.t("#{w}.actions.save_draft")
    assert_text I18n.t("#{w}.draft_saved")
    within ".report-workspace header" do
      click_link I18n.t("#{w}.queue")
    end
    assert_text I18n.t("#{w}.batch.title")
    assert_text "Which school crossing?"
    page.current_window.resize_to(390, 844)
    assert_selector ".layout-nav", visible: :all do
      page.evaluate_script("document.querySelector('.layout-nav').getBoundingClientRect().right <= 1")
    end
    assert_no_horizontal_overflow!
    page.save_screenshot(Rails.root.join("tmp/report-review-ui/batch-mobile.png")) # rubocop:disable Lint/Debugger
  ensure
    ActionController::Base.allow_forgery_protection = old_protection
    ActionController::Base.forgery_protection_origin_check = old_origin
  end
end
