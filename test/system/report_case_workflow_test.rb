# frozen_string_literal: true

require "application_system_test_case"

class ReportCaseWorkflowTest < ApplicationSystemTestCase
  test "staff review and private citizen reply work on desktop and mobile" do
    old_protection = ActionController::Base.allow_forgery_protection
    old_origin_check = ActionController::Base.forgery_protection_origin_check
    ActionController::Base.allow_forgery_protection = true
    ActionController::Base.forgery_protection_origin_check = true
    organization = create_organization
    use_organization_host!(organization)
    admin = FactoryBot.create(:user, :admin, :confirmed, organization: organization)
    report = Decidim::Bih::Report.create!(organization: organization, description: "Speeding near the school", address: "Račanska", category: "saobracaj", severity: "visok")
    Decidim::Bih::Setting.put(organization, "sistem48_routing", "central_intake", "intake@example.org")
    Decidim::Bih::Setting.put(organization, "sistem48_routing", "saobracaj", "traffic@example.org")
    workspace = "decidim.bih.review_workspace"
    sign_in_user! admin
    visit "/admin/bih/reports/#{report.reference}"
    accept_data_consent!
    assert_selector "#report-private-evidence", text: report.description
    assert_selector "#report-decision-form[data-ready='1']"
    within "#report-decision-form" do
      select I18n.t("#{workspace}.actions.review"), from: "decision_action"
      select "intake@example.org", from: "decision[forwarding_recipient]"
      check "confirm_decision"
      click_button I18n.t("#{workspace}.apply_decision")
    end
    assert_text I18n.t("#{workspace}.saved")
    assert_equal "validated", report.reload.review_state
    assert_equal admin, report.reviewed_by
    assert_equal "intake@example.org", report.forwarding_recipient
    assert_nil report.forwarded_at
    assert_empty report.dispatches
    FileUtils.mkdir_p(Rails.root.join("tmp/report-case-ui"))
    page.execute_script("document.getElementById('report-case-review').scrollIntoView({behavior: 'instant', block: 'start'})")
    page.save_screenshot(Rails.root.join("tmp/report-case-ui/admin-desktop.png")) # rubocop:disable Lint/Debugger
    page.current_window.resize_to(390, 844)
    assert_equal 390, page.evaluate_script("window.innerWidth")
    page.find("#report-case-review h2").scroll_to(:center)
    page.execute_script("document.getElementById('report-case-review').scrollIntoView({behavior: 'instant', block: 'start'})")
    page.find("#report-case-review h2").scroll_to(:center)
    page.save_screenshot(Rails.root.join("tmp/report-case-ui/admin-mobile.png")) # rubocop:disable Lint/Debugger
    assert page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth + 2")
    response_due_at = 2.days.from_now.change(sec: 0)
    assert_selector "#report-decision-form[data-ready='1']"
    within "#report-decision-form" do
      select I18n.t("#{workspace}.actions.ask"), from: "decision_action"
      fill_in "decision[body]", with: "Which intersection?"
      find("details[data-actions~='ask'] > summary").click
      page.execute_script("arguments[0].value = arguments[1]", find("input[name='decision[response_due_at]']"), response_due_at.strftime("%Y-%m-%dT%H:%M"))
      check "confirm_decision"
      click_button I18n.t("#{workspace}.apply_decision")
    end
    assert_text I18n.t("#{workspace}.saved")
    assert_selector "#report-case-conversation", text: "Which intersection?"
    question = report.case_messages.order(:id).last
    assert_equal "Which intersection?", question.body
    assert_equal "question", question.kind
    assert_equal "staff", question.actor_role
    assert_equal admin, question.actor
    assert_equal "needs_information", report.reload.review_state
    assert_equal response_due_at, report.response_due_at
    logout(:user)
    visit report.tokenized_status_path
    assert_selector "#report-private-conversation", text: "Which intersection?"
    within "#report-private-conversation" do
      fill_in "case_message[body]", with: "At the school crossing"
      click_button I18n.t("decidim.bih.report_case.reply")
    end
    assert_selector "#report-private-conversation", text: "At the school crossing"
    reply = report.case_messages.order(:id).last
    assert_equal "At the school crossing", reply.body
    assert_equal "reply", reply.kind
    assert_equal "citizen", reply.actor_role
    assert_nil reply.actor
    assert_equal "pending", report.reload.review_state
    page.execute_script("document.getElementById('report-private-conversation').scrollIntoView({behavior: 'instant', block: 'start'})")
    page.save_screenshot(Rails.root.join("tmp/report-case-ui/citizen-mobile.png")) # rubocop:disable Lint/Debugger
  ensure
    ActionController::Base.allow_forgery_protection = old_protection
    ActionController::Base.forgery_protection_origin_check = old_origin_check
  end
end
