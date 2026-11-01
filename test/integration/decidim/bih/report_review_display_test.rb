# frozen_string_literal: true

require "test_helper"
require "capybara"

class ReportReviewDisplayTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  setup do
    @organization = create_organization
    host! @organization.host
  end

  test "waiting for information is a current public step without pretending the city received it" do
    report = create_report(review_state: "needs_information", reviewed_at: 1.day.ago)
    before = report.attributes.slice("status", "status_history", "forwarded_at", "review_state")
    get "/biceriseno/prijave/#{report.reference}"
    assert_response :success
    assert_includes response.body, "Čekamo dopunu"
    history = Decidim::Bih::ReportServiceRequest.new(report).update_history
    assert_equal "received", history.first[:public_status]
    assert_not history.first[:current]
    assert_equal "needs_information", history.find { |stage| stage[:current] }[:public_status]
    assert_not history.find { |stage| stage[:public_status] == "sent_to_service" }[:reached]
    assert_equal before, report.reload.attributes.slice(*before.keys)
  end

  test "filters distinguish new reports, review work, and completed reviews" do
    received = create_report
    waiting = create_report(review_state: "needs_information", reviewed_at: Time.current)
    reviewing = create_report(review_state: "pending", reviewed_at: Time.current)
    reviewed = create_report(review_state: "validated", reviewed_at: Time.current)
    { "primljeno" => received, "needs_information" => waiting, "under_review" => reviewing, "reviewed" => reviewed }.each do |status, report|
      get "/biceriseno/prijave", params: { status: }
      assert_response :success
      assert_select "a[href=?]", "/biceriseno/prijave/#{report.reference}"
      [received, waiting, reviewing, reviewed].reject { |other| other == report }.each do |other|
        assert_select "a[href=?]", "/biceriseno/prijave/#{other.reference}", count: 0
      end
    end
    counts = Decidim::Bih::PublicReportSummary.new(@organization).call
    assert_equal 4, counts[:open]
    assert_equal({ "primljeno" => 1, "needs_information" => 1, "under_review" => 1, "reviewed" => 1 }, counts[:status_counts])
  end

  test "sent and planned lifecycles take precedence over review metadata" do
    sent = create_report(status: "proslijedjeno", review_state: "validated", forwarded_at: Time.current)
    planned = create_report(status: "planirano", review_state: "validated")
    assert_equal "Poslato službi", Decidim::Bih::ReportStatusPresenter.label(sent, locale: :sr)
    planned_history = Decidim::Bih::ReportServiceRequest.new(planned).update_history
    assert_equal "planned", planned_history.find { |stage| stage[:current] }[:public_status]
    assert_not planned_history.find { |stage| stage[:public_status] == "resolved" }[:current]
  end

  test "feed and map expose review progress consistently" do
    create_report(review_state: "needs_information", reviewed_at: Time.current, latitude: 44.75, longitude: 19.21)
    I18n.with_locale(:sr) do
      assert_includes Decidim::Bih::HomepageActivity.new(@organization).call.first.title, "Čekamo dopunu"
      map = Decidim::Bih::ReportMapFeatures.new(@organization, url_builder: ->(ref) { "/biceriseno/prijave/#{ref}" }).call
      assert_equal "needs_information", map[:features].first[:properties][:status]
    end
  end

  test "approved and uncertain sending remain separate from confirmed public delivery" do
    report = create_report(review_state: "validated", reviewed_at: Time.current, category: "rasvjeta", forwarding_recipient: "intake@example.org")
    admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
    Decidim::Bih::Setting.put(@organization, "sistem48_routing", "central_intake", "intake@example.org")
    dispatch = Decidim::Bih::ReportDispatching.queue!(report:, actor: admin, digest: Decidim::Bih::ReportCaseWorkflow.digest(report))
    %w(queued sending unknown).each do |state|
      dispatch.update!(state:)
      projection = Decidim::Bih::ReportServiceRequest.new(report.reload)
      action = state == "unknown" ? "checking_delivery" : "sending"
      assert_equal action, projection.current_action
      assert_equal "reviewed", projection.public_status
      assert_nil report.forwarded_at
      get "/biceriseno/prijave/#{report.reference}"
      assert_response :success
      assert_select "#report-current-action", text: /#{Regexp.escape(projection.current_action_label)}/
      assert_not_includes response.body, "Private description"
      assert_not_includes response.body, "intake@example.org"
    end
    report.update!(status: "proslijedjeno", forwarded_at: Time.current)
    dispatch.update!(state: "queued")
    projection = Decidim::Bih::ReportServiceRequest.new(report.reload)
    assert_equal "sending_update", projection.current_action
    assert_equal "sent_to_service", projection.public_status
  end

  test "new reply on a sent report shows pending platform work without resetting its city lifecycle" do
    report = create_report(status: "proslijedjeno", forwarded_at: 1.day.ago, review_state: "validated", reviewed_at: 1.day.ago)
    Decidim::Bih::ReportCaseWorkflow.new(report, nil).reply(body: "Private new evidence")
    projection = Decidim::Bih::ReportServiceRequest.new(report.reload)
    assert_equal "under_review", projection.public_status
    assert_equal "review_forwarded", projection.current_action
    assert_equal "review_forwarded", projection.to_h[:current_action]
    get "/biceriseno/prijave/#{report.reference}"
    assert_response :success
    assert_select "#report-current-action", text: /#{Regexp.escape(projection.current_action_label)}/
    assert_not_includes response.body, "Private new evidence"
    assert_equal "proslijedjeno", report.reload.status
  end

  test "terminal reports show no misleading next action" do
    %w(rijeseno odbijeno).each do |status|
      report = create_report(status:)
      assert_nil Decidim::Bih::ReportServiceRequest.new(report).current_action
      get "/biceriseno/prijave/#{report.reference}"
      assert_select "#report-current-action", count: 0
    end
  end

  test "asking and replying update the main status filters and history for every active lifecycle" do
    admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
    Decidim::Bih::Setting.put(@organization, "sistem48_routing", "central_intake", "intake@example.org")
    presenter = Decidim::Bih::ReportStatusPresenter
    %w(primljeno proslijedjeno u_obradi planirano).each do |lifecycle|
      forwarded_at = %w(proslijedjeno u_obradi).include?(lifecycle) ? 1.day.ago : nil
      report = create_report(status: lifecycle, forwarded_at:, category: "rasvjeta", review_state: "validated")
      decision = Decidim::Bih::ReportDecision.new(report, admin)
      version = Decidim::Bih::ReportReviewVersion.digest(report)
      decision.call(action: "ask", values: { body: "Which crossing?" }, version:, confirmed: true)
      scope = Decidim::Bih::Report.where(id: report.id)
      assert_equal "needs_information", presenter.status_key(report.reload)
      assert_equal({ "needs_information" => 1 }, presenter.status_counts(scope))
      assert_equal [report.id], presenter.filter(scope, "needs_information").ids
      assert_empty presenter.filter(scope, lifecycle)
      assert_equal "needs_information", report.events.find_by!(event_type: "case_decision_applied").metadata["display_status"]
      get "/biceriseno/prijave/#{report.reference}"
      assert_response :success
      assert_includes response.body, "Čekamo dopunu"
      assert_not_includes response.body, "Which crossing?"
      history = Decidim::Bih::ReportServiceRequest.new(report).update_history
      assert_equal "needs_information", history.select { |stage| stage[:reached] }.last[:public_status]
      assert_equal lifecycle, report.status
      if forwarded_at
        assert_equal forwarded_at.to_i, report.forwarded_at.to_i
      else
        assert_nil report.forwarded_at
      end
      assert_empty report.dispatches
      sign_in admin
      get "/admin/bih/reports/#{report.reference}"
      assert_response :success
      assert_select "h1", text: /Čekamo dopunu/
      assert_select "#admin-report-events", text: /Čekamo dopunu/
      sign_out admin

      Decidim::Bih::ReportCaseWorkflow.new(report, nil).reply(body: "Near the school")
      assert_equal "under_review", presenter.status_key(report.reload)
      assert_equal({ "under_review" => 1 }, presenter.status_counts(scope))
      assert_empty presenter.filter(scope, "needs_information")
      assert_equal lifecycle, report.status
      assert_equal "review", Decidim::Bih::ReportWorkQueue.waiting_on(report)
      report.update!(review_state: "validated")
      assert_equal(lifecycle == "primljeno" ? "reviewed" : lifecycle, presenter.status_key(report))
    end
  end

  test "legacy reply without a review timestamp still changes the main status to under review" do
    report = create_report
    admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
    workflow = Decidim::Bih::ReportCaseWorkflow.new(report, admin)
    workflow.message(body: "Which crossing?", question: true, response_due_at: 2.days.from_now.iso8601)
    workflow.reply(body: "Near the school")
    assert_nil report.reload.reviewed_at
    I18n.with_locale(:sr) do
      assert_includes Decidim::Bih::HomepageActivity.new(@organization).call.first.title,
                      Decidim::Bih::ReportStatusPresenter.label("under_review")
    end
    assert_equal "under_review", Decidim::Bih::ReportStatusPresenter.status_key(report)
    assert_equal({ "under_review" => 1 }, Decidim::Bih::ReportStatusPresenter.status_counts(Decidim::Bih::Report.where(id: report.id)))
  end

  test "closed reports never revert to waiting because of old review metadata" do
    %w(rijeseno odbijeno).each do |status|
      report = create_report(status:, review_state: "needs_information", reviewed_at: Time.current)
      assert_equal status, Decidim::Bih::ReportStatusPresenter.status_key(report)
      assert_equal({ status => 1 }, Decidim::Bih::ReportStatusPresenter.status_counts(Decidim::Bih::Report.where(id: report.id)))
    end
  end

  private

  def create_report(**attributes)
    Decidim::Bih::Report.create!(organization: @organization, description: "Private description", **attributes)
  end
end
