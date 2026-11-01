# frozen_string_literal: true

require "application_system_test_case"

class AdminReportsTest < ApplicationSystemTestCase
  setup do
    @organization = create_organization
    use_organization_host!(@organization)
    @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)

    Decidim::Bih::LocalArea.create!(
      organization: @organization,
      kind: "mz",
      slug: "mz-centar",
      name: { "sr" => "Centar", "en" => "Centre" }
    )

    @report = Decidim::Bih::Report.create!(
      organization: @organization,
      description: "Rupa ispred skole",
      address: "Vidovdanska 3",
      category: "putevi",
      mz_slug: "mz-centar",
      internal_note: "Provjeriti sa komunalnim timom"
    )
    @report.record_event!(
      "status_changed",
      actor: @admin,
      metadata: { from_status: "primljeno", to_status: "proslijedjeno" }
    )
    @old_report = Decidim::Bih::Report.create!(
      organization: @organization,
      description: "Stara prijava za SLA",
      address: "Vidovdanska 5",
      category: "putevi",
      mz_slug: "mz-centar",
      created_at: 3.days.ago,
      updated_at: 3.days.ago
    )
  end

  test "admin reports page renders triage filters and detail tools" do
    sign_in_user! @admin

    visit "/admin/bih/reports?mz_slug=mz-centar&age=recent_7"
    accept_data_consent!

    assert_selector "#admin-reports-header"
    assert_selector "#admin-reports-workflow-tabs"
    assert_selector "#admin-reports-list", text: @report.reference
    assert_no_selector "#admin-reports-sla"
    assert_no_selector "#admin-reports-escalation"
    assert_no_selector "#admin-reports-heatmap"
    find("summary", text: I18n.t("decidim.bih.review_workspace.advanced_filters"), exact_text: true).click
    assert_selector :select, "mz_slug", selected: "Centar"
    assert_selector :select, "age", selected: I18n.t("decidim.bih.admin.reports.index.age_filters.recent_7")
    assert_selector :select, "attention"
    assert_no_field "decision[duplicate_reference]"
    assert_no_field "decision[body]"
    within "#admin-reports-list" do
      assert_no_selector "form"
      assert_no_selector "button[type='submit']"
      assert_no_field "duplicate_reference"
      assert_no_field "internal_note"
      assert_text "Centar"
      assert_no_text @report.description
      assert_no_text @report.address
      assert_no_text @report.internal_note
    end

    within ".mi-admin-filter" do
      select I18n.t("decidim.bih.admin.reports.index.attention_filters.received_over_sla"), from: "attention"
      click_button I18n.t("decidim.bih.admin.reports.index.filter_apply")
    end
    assert_selector "#admin-reports-list", text: @old_report.reference
    assert_selector "#admin-reports-list", text: I18n.t("decidim.bih.review_workspace.overdue")
    assert_no_text @report.reference
    assert_no_selector "#admin-reports-escalation"

    within "#admin-reports-workflow-tabs" do
      click_link I18n.t("decidim.bih.admin.reports.index.tabs.insights")
    end
    assert_selector "#report-review-metrics", text: I18n.t("decidim.bih.review_workspace.metrics.title")
    assert_selector "#admin-reports-heatmap", text: "Centar"
    assert_no_selector "#admin-reports-list"
    within "#admin-reports-handoffs" do
      find("summary", text: I18n.t("decidim.bih.admin.reports.index.handoffs.title"), exact_text: true).click
      assert_link I18n.t("decidim.bih.admin.reports.index.handoffs.export")
    end
    within "#admin-reports-sla" do
      find("summary", text: I18n.t("decidim.bih.review_workspace.metrics.task_details"), exact_text: true).click
    end
    [@report, @old_report].each do |report|
      assert_no_text report.reference
      assert_no_text report.description
      assert_no_text report.address
    end
    assert_no_text @report.internal_note
    within "#admin-reports-sla tbody tr", text: I18n.t("decidim.bih.admin.reports.index.sla.buckets.received_over_sla") do
      assert_selector "td:nth-child(2)", exact_text: "1"
      assert_text I18n.t("decidim.bih.admin.reports.index.sla.priorities.high")
      assert_text I18n.t("decidim.bih.admin.reports.index.sla.review_actions.forward_received_report")
      click_link I18n.t("decidim.bih.admin.reports.index.sla.view")
    end
    assert_selector "#admin-reports-list", text: @old_report.reference
    assert_no_selector "#admin-reports-escalation"
    assert_no_text @report.reference

    visit "/admin/bih/reports?mz_slug=mz-centar&age=recent_7"
    within "#admin-reports-list" do
      click_link @report.reference
    end
    assert_selector ".report-workspace > header h1", text: @report.reference
    within "#report-private-evidence" do
      assert_text @report.description
      assert_text @report.address
    end
    assert_selector "#report-case-review", text: I18n.t("decidim.bih.review_workspace.decision")
    within "#report-decision-form[data-ready='1']" do
      select I18n.t("decidim.bih.review_workspace.actions.duplicate"), from: "decision_action"
      assert_field "decision[duplicate_reference]", disabled: false
      select I18n.t("decidim.bih.review_workspace.actions.note"), from: "decision_action"
      assert_field "decision[body]", with: "", disabled: false
      assert_text I18n.t("decidim.bih.review_workspace.private_note_help")
      assert_no_field "decision[duplicate_reference]"
    end
    within "#report-case-conversation" do
      find("summary", text: I18n.t("decidim.bih.admin.reports.index.internal_note"), exact_text: true).click
      assert_text @report.internal_note
    end
    within "#admin-report-events" do
      find("summary", text: I18n.t("decidim.bih.admin.reports.show.events_title"), exact_text: true).click
      assert_text I18n.t("decidim.bih.admin.reports.events.types.status_changed")
      assert_text @admin.name
      assert_text I18n.t("decidim.bih.reports.statuses.primljeno")
      assert_text I18n.t("decidim.bih.reports.statuses.proslijedjeno")
    end
    within ".report-workspace > header" do
      public_status_link = find_link(I18n.t("decidim.bih.admin.reports.show.public_status"))
      decoded_href = Rack::Utils.unescape(public_status_link[:href])
      assert_match %r{/biceriseno/prijave/#{Regexp.escape(@report.reference)}(\z|\?)}, decoded_href
      assert_equal "_blank", public_status_link[:target]
      assert_includes public_status_link[:rel].split, "noopener"
      assert_includes public_status_link[:rel].split, "noreferrer"
      click_link I18n.t("decidim.bih.review_workspace.queue")
    end
    assert_selector "#admin-reports-list", text: @report.reference
    queue_params = Rack::Utils.parse_query(URI.parse(current_url).query)
    assert_equal "mz-centar", queue_params["mz_slug"]
    assert_equal "recent_7", queue_params["age"]
    assert_equal "review", queue_params["view"]
    assert_no_browser_console_errors!
  end
end
