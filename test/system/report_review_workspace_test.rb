# frozen_string_literal: true

require "application_system_test_case"

class ReportReviewWorkspaceTest < ApplicationSystemTestCase
  test "one conditional decision workspace supports drafts replies and mobile review" do
    old_protection = ActionController::Base.allow_forgery_protection
    old_origin = ActionController::Base.forgery_protection_origin_check
    ActionController::Base.allow_forgery_protection = true
    ActionController::Base.forgery_protection_origin_check = true
    organization = create_organization
    use_organization_host!(organization)
    admin = FactoryBot.create(:user, :admin, :confirmed, organization:)
    Decidim::Bih::Setting.put(organization, "sistem48_routing", "central_intake", "intake@example.org")
    report = Decidim::Bih::Report.create!(organization:, description: "Broken lamp near school", address: "Test street")
    Decidim::Bih::Setting.put(organization, "report_review", "case_agent", "shadow")
    proposal = report.review_proposals.create!(input_digest: Decidim::Bih::Ai::ReportReviewContext.new(report).digest,
                                               prompt_version: Decidim::Bih::Ai::CaseAgent::PROMPT_VERSION,
                                               state: "ready", model: "browser-fixture", proposal: {
                                                 "proposed_action" => "ask", "routing" => { "category" => "rasvjeta" }, "rationale" => "Check the crossing",
                                                 "facts" => [{ "text" => "Lamp near school", "source_id" => "original", "quote" => "Broken lamp near school" }],
                                                 "uncertainties" => ["Which crossing?"], "location_text" => "Test street", "location_source_id" => "location",
                                                 "citizen_message" => { "composed_text" => "Which crossing?" }, "forwarding_note" => "", "duplicate_reference" => "",
                                                 "duplicate_against" => "", "collection_id" => 0
                                               })
    sign_in_user! admin
    visit "/admin/bih/reports/#{report.reference}"
    accept_data_consent!
    w = "decidim.bih.review_workspace"
    assert_selector "#report-decision-form[data-ready='1']"
    assert_equal "", find("select[name='decision[category]']").value
    assert_equal "", find("select[name='decision[severity]']").value
    assert_selector "[data-category-missing]"
    within "#report-ai-proposal" do
      click_button I18n.t("#{w}.ai.adopt")
    end
    assert_text I18n.t("#{w}.draft_saved")
    assert_nil report.reload.reviewed_at
    assert_nil proposal.reload.decided_by_id
    assert_equal "rasvjeta", find("select[name='decision[category]']").value
    assert_equal "", find("select[name='decision[severity]']").value
    assert_equal 0, report.case_messages.count
    assert_selector "fieldset[data-actions='resolve']", visible: false
    assert_no_selector "fieldset[data-actions='resolve']", visible: true
    select I18n.t("#{w}.actions.ask"), from: "decision_action"
    # Adoption prefills the AI wording; staff replace it with their own. Clear and type
    # in one keystroke sequence: Capybara's default JS select() loses its selection if
    # focus moves before typing, and the driver then appends to the adopted text.
    assert_field "decision[body]", with: "Which crossing?"
    edited = "Which crossing exactly?"
    find_field("decision[body]").click
    fill_in "decision[body]", with: edited, fill_options: { clear: [[:control, "a"], :backspace] }
    assert_field "decision[body]", with: edited
    click_button I18n.t("#{w}.actions.save_draft")
    assert_text I18n.t("#{w}.draft_saved")
    assert_equal "ask", report.reload.review_draft.dig("values", "draft_action")
    assert_equal edited, report.review_draft.dig("values", "body")
    assert_equal 0, report.case_messages.count
    assert_selector "textarea[name='decision[body]']", text: edited
    assert_field "decision[body]", with: edited
    check "confirm_decision"
    click_button I18n.t("#{w}.apply_decision")
    assert_text I18n.t("#{w}.saved")
    assert_equal "needs_information", report.reload.review_state
    assert_nil report.severity
    assert_equal 1, report.case_messages.count
    assert_equal edited, report.case_messages.last.body
    assert_includes proposal.reload.changed_fields, "body"

    Decidim::Bih::ReportCaseWorkflow.new(report, nil).reply(body: "At the school crossing")
    visit "/admin/bih/reports/#{report.reference}"
    assert_text I18n.t("#{w}.new_reply")
    assert_text "At the school crossing"
    FileUtils.mkdir_p(Rails.root.join("tmp/report-review-ui"))
    page.save_screenshot(Rails.root.join("tmp/report-review-ui/desktop.png")) # rubocop:disable Lint/Debugger
    page.current_window.resize_to(390, 844)
    visit "/admin/bih/reports/#{report.reference}"
    assert_selector "#report-decision-form[data-ready='1']"
    assert_no_horizontal_overflow!
    page.execute_script("document.getElementById('report-case-review').scrollIntoView()")
    page.save_screenshot(Rails.root.join("tmp/report-review-ui/mobile.png")) # rubocop:disable Lint/Debugger

    candidate = Decidim::Bih::Report.create!(organization:, description: "Different lamp issue", address: "Test street", category: "rasvjeta")
    select I18n.t("#{w}.actions.duplicate"), from: "decision_action"
    within "#duplicate-candidates" do
      find("summary", text: candidate.reference).click
      click_button I18n.t("#{w}.select_candidate", reference: candidate.reference)
    end
    assert_field "decision[duplicate_reference]", with: candidate.reference
    assert_equal "primljeno", report.reload.status

    select I18n.t("#{w}.actions.send"), from: "decision_action"
    click_button I18n.t("#{w}.preview_send")
    assert_text I18n.t("#{w}.confirm_send")
    assert_text "intake@example.org"
    assert_equal 0, report.dispatches.count
    Decidim::Bih::ReportCaseWorkflow.new(report, nil).reply(body: "One more detail before sending")
    check "confirm_decision"
    click_button I18n.t("#{w}.approve_send")
    assert_text I18n.t("#{w}.errors.stale")
    assert_equal 0, report.dispatches.count
  ensure
    ActionController::Base.allow_forgery_protection = old_protection
    ActionController::Base.forgery_protection_origin_check = old_origin
  end
  test "keyboard action selection skips hidden fields and saves a private note" do
    organization = create_organization
    use_organization_host!(organization)
    admin = FactoryBot.create(:user, :admin, :confirmed, organization:)
    report = Decidim::Bih::Report.create!(organization:, description: "Keyboard review fixture", address: "Test street", category: "rasvjeta")
    sign_in_user! admin
    visit "/admin/bih/reports/#{report.reference}"
    accept_data_consent!
    assert_selector "#report-decision-form[data-ready='1']"
    action = find_by_id("decision_action")
    note_index = action.all("option").map(&:value).index("note")
    assert note_index
    action.send_keys(:home, *Array.new(note_index, :arrow_down), :tab)
    assert_equal "note", action.value
    assert_equal "decision[body]", page.evaluate_script("document.activeElement.name")
    assert_selector "fieldset[data-actions='resolve'] textarea:disabled", visible: :all
    assert_no_selector "fieldset[data-actions='resolve']", visible: true
    page.driver.browser.action.send_keys("Keyboard private note", :tab).perform
    assert_equal "after_decision", page.evaluate_script("document.activeElement.id")
    page.driver.browser.action.send_keys(:tab).perform
    assert page.evaluate_script("document.activeElement.hasAttribute('data-decision-submit')")
    page.driver.browser.action.send_keys(:enter).perform
    assert_text I18n.t("decidim.bih.review_workspace.saved")
    assert_includes report.reload.internal_note, "Keyboard private note"
    assert_empty report.case_messages
    assert_empty report.dispatches
    visit "/biceriseno/prijave/#{report.reference}"
    assert_no_text "Keyboard private note"
  end
end
