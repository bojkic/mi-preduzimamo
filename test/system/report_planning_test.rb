# frozen_string_literal: true

require "application_system_test_case"

class ReportPlanningSystemTest < ApplicationSystemTestCase
  test "operator edits a street section and prepares one collective request" do
    old_protection = ActionController::Base.allow_forgery_protection
    old_origin = ActionController::Base.forgery_protection_origin_check
    ActionController::Base.allow_forgery_protection = true
    ActionController::Base.forgery_protection_origin_check = true
    organization = create_organization
    use_organization_host!(organization)
    admin = FactoryBot.create(:user, :admin, :confirmed, organization: organization)
    report = Decidim::Bih::Report.create!(organization: organization, description: "Speeding", address: "Račanska", category: "saobracaj", severity: "visok")
    collection = Decidim::Bih::ReportCollection.create!(organization: organization, title: "Traffic safety", topic: "Signage", assigned_to: admin,
                                                        review_due_at: 2.weeks.from_now, summary: "Please assess the listed locations.")
    workspace = "decidim.bih.review_workspace"
    coordinates = {}
    sign_in_user! admin
    visit "/admin/bih/reports/#{report.reference}"
    accept_data_consent!
    assert_selector "#report-decision-form[data-ready='1']"
    within "#report-decision-form" do
      select I18n.t("#{workspace}.actions.review"), from: "decision_action"
      find("summary", text: I18n.t("decidim.bih.report_planning.location_title"), exact_text: true).click
      fill_in "decision[address]", with: "Račanska, Beogradska to Nestro"
      select I18n.t("decidim.bih.report_planning.location_kinds.segment"), from: "decision[location_kind]"
      assert_selector "#report-case-location-map.leaflet-container[data-ready='1']"
      find_by_id("report-case-location-map").click(x: 140, y: 80)
      select I18n.t("decidim.bih.report_planning.end"), from: "report-location-target"
      find_by_id("report-case-location-map").click(x: 240, y: 40)
      find("summary", text: I18n.t("#{workspace}.coordinates"), exact_text: true).click
      %w(latitude longitude location_end_latitude location_end_longitude).each do |field|
        coordinates[field] = find("[name='decision[#{field}]']").value
        assert_not_empty coordinates[field]
      end
      assert_not_equal coordinates.values_at("latitude", "longitude"), coordinates.values_at("location_end_latitude", "location_end_longitude")
      assert_checked_field "decision[edit_location]"
      check "confirm_decision"
      click_button I18n.t("#{workspace}.apply_decision")
    end
    assert_text I18n.t("#{workspace}.saved")
    assert_equal "segment", report.reload.location_kind
    assert_equal "Račanska, Beogradska to Nestro", report.address
    assert_equal "Račanska", report.original_location["address"]
    assert_equal admin, report.location_reviewed_by
    coordinates.each { |field, value| assert_in_delta value.to_f, report.public_send(field).to_f, 0.000001 }
    assert_selector "#report-decision-form[data-ready='1']"
    within "#report-decision-form" do
      select I18n.t("#{workspace}.actions.plan"), from: "decision_action"
      select "Traffic safety", from: "decision[report_collection_id]"
      fill_in "decision[report_subtype]", with: "Signalizacija"
      fill_in "decision[forwarding_note]", with: "Assess traffic calming on this street section."
      check "confirm_decision"
      click_button I18n.t("#{workspace}.apply_decision")
    end
    assert_text I18n.t("#{workspace}.saved")
    assert_equal "planirano", report.reload.status
    assert_equal "validated", report.review_state
    assert_equal collection, report.report_collection
    assert_equal "Signalizacija", report.report_subtype
    assert_equal "Assess traffic calming on this street section.", report.forwarding_note
    assert_equal admin, report.assigned_to
    assert_equal collection.review_due_at, report.response_due_at
    assert_no_selector "#decision_action option[value='send']", visible: :all
    assert_empty report.dispatches
    page.current_window.resize_to(390, 844)
    page.execute_script("document.getElementById('report-case-review').scrollIntoView({block: 'start'})")
    assert_no_horizontal_overflow!
    FileUtils.mkdir_p(Rails.root.join("tmp/planning-ui"))
    page.save_screenshot(Rails.root.join("tmp/planning-ui/report-mobile.png")) # rubocop:disable Lint/Debugger
    visit "/admin/bih/report-collections/#{collection.id}"
    click_button I18n.t("decidim.bih.report_planning.ready")
    assert_text I18n.t("decidim.bih.report_planning.states.ready")
    assert_equal "ready", collection.reload.state
    assert_link I18n.t("decidim.bih.report_planning.export"), href: "/admin/bih/report-collections/#{collection.id}/export"
    assert_nil report.reload.forwarded_at
    assert_empty report.dispatches
    assert_no_horizontal_overflow!
    page.execute_script("document.querySelector('h1').scrollIntoView({block: 'start'})")
    page.save_screenshot(Rails.root.join("tmp/planning-ui/collection-mobile.png")) # rubocop:disable Lint/Debugger
  ensure
    ActionController::Base.allow_forgery_protection = old_protection
    ActionController::Base.forgery_protection_origin_check = old_origin
  end
end
