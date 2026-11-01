# frozen_string_literal: true

require "application_system_test_case"

class ReportReviewMetricsBrowserTest < ApplicationSystemTestCase
  test "one queue and secondary statistics remain readable on desktop and mobile" do
    organization = create_organization
    use_organization_host!(organization)
    admin = FactoryBot.create(:user, :admin, :confirmed, organization:)
    report = Decidim::Bih::Report.create!(organization:, description: "PRIVATE OPERATOR EVIDENCE", address: "Test street", category: "rasvjeta", created_at: 2.hours.ago)
    Decidim::Bih::ReportDecision.new(report, admin).call(action: "review", values: {}, version: Decidim::Bih::ReportReviewVersion.digest(report), confirmed: true)
    collection = Decidim::Bih::ReportCollection.create!(organization:, title: "Lighting collection", topic: "Lamps", assigned_to: admin, review_due_at: 2.weeks.from_now)
    sign_in_user! admin
    visit "/admin/bih/reports"
    accept_data_consent!
    assert_selector "#admin-reports-list"
    assert_no_selector "#admin-reports-workflow-tabs a[href*='tab=attention']"
    within "#admin-reports-workflow-tabs" do
      click_link I18n.t("decidim.bih.admin.reports.index.tabs.insights")
    end
    assert_selector "#report-review-metrics"
    assert_equal "rgb(255, 255, 255)", page.evaluate_script("getComputedStyle(document.querySelector('#admin-reports-workflow-tabs .button__secondary')).color")
    assert_no_selector "#admin-reports-list"
    assert_no_text "PRIVATE OPERATOR EVIDENCE"
    FileUtils.mkdir_p(Rails.root.join("tmp/report-review-ui"))
    page.save_screenshot(Rails.root.join("tmp/report-review-ui/metrics-desktop.png")) # rubocop:disable Lint/Debugger
    page.current_window.resize_to(390, 844)
    assert_selector ".layout-nav", visible: :all do
      page.evaluate_script("document.querySelector('.layout-nav').getBoundingClientRect().right <= 1")
    end
    assert_no_horizontal_overflow!
    page.save_screenshot(Rails.root.join("tmp/report-review-ui/metrics-mobile.png")) # rubocop:disable Lint/Debugger
    visit "/admin/bih/reports?view=planning"
    within "#report-planning-collections" do
      find("summary").click
      assert_link collection.title
    end
    assert_selector "#admin-reports-list"
    visit "/admin/bih/reports?view=all"
    assert_selector "#admin-reports-list tbody tr"
    assert_no_horizontal_overflow!
    page.save_screenshot(Rails.root.join("tmp/report-review-ui/queue-mobile.png")) # rubocop:disable Lint/Debugger
  end
end
