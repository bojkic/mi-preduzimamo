# frozen_string_literal: true

require "test_helper"
require "capybara"

class ReportDuplicateDisplayTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  setup do
    @organization = create_organization
    host! @organization.host
    @main = report(status: "proslijedjeno", reporter_email: "private-main@example.org")
    @duplicate = report(status: "odbijeno", duplicate_of: @main, status_note: "OLD REJECTION TEXT")
    @rejected = report(status: "odbijeno", status_note: "Outside municipal responsibility")
  end

  test "duplicate detail links the main public tracker and keeps its lifecycle separate" do
    before = @duplicate.attributes.slice("status", "status_history", "review_state", "updated_at")
    get "/biceriseno/prijave/#{@duplicate.reference}"
    assert_response :success
    assert_select "[data-report-duplicate]" do
      assert_select "a[href=?]", "/biceriseno/prijave/#{@main.reference}", text: @main.reference
      assert_select "p", text: /Status glavne prijave:/
    end
    assert_includes response.body, "Duplikat — povezana prijava"
    assert_not_includes response.body, "OLD REJECTION TEXT"
    assert_not_includes response.body, "private-main@example.org"
    assert_not_includes response.body, @main.status_token
    assert_equal before, @duplicate.reload.attributes.slice(*before.keys)
    history = Decidim::Bih::ReportServiceRequest.new(@duplicate).update_history
    assert_equal "duplicate", history.find { |stage| stage[:current] }[:public_status]

    get "/biceriseno/prijave/#{@rejected.reference}"
    assert_response :success
    assert_select "[data-report-duplicate]", count: 0
    assert_includes response.body, @rejected.status_note
  end

  test "list filters and counts distinguish duplicate records from rejected records" do
    get "/biceriseno/prijave", params: { status: "duplicate" }
    assert_response :success
    assert_select "a[href=?]", "/biceriseno/prijave/#{@duplicate.reference}"
    assert_select "a[href=?]", "/biceriseno/prijave/#{@rejected.reference}", count: 0
    get "/biceriseno/prijave", params: { status: "odbijeno" }
    assert_response :success
    assert_select "a[href=?]", "/biceriseno/prijave/#{@rejected.reference}"
    assert_select "a[href=?]", "/biceriseno/prijave/#{@duplicate.reference}", count: 0

    counts = Decidim::Bih::PublicReportSummary.new(@organization).call
    assert_equal 3, counts[:total]
    assert_equal 1, counts[:open]
    assert_equal({ "duplicate" => 1, "odbijeno" => 1, "proslijedjeno" => 1 }, counts[:status_counts])
  end

  test "homepage uses linking wording and future email explains the preserved submission" do
    I18n.with_locale(:sr) do
      entry = Decidim::Bih::HomepageActivity.new(@organization).call.find { |item| item.path.end_with?(@duplicate.reference) }
      assert_equal "Prijava #{@duplicate.reference} povezana je s prijavom #{@main.reference}.", entry.title
    end
    @duplicate.reporter_email = "duplicate@example.org"
    mail = Decidim::Bih::ReporterMailer.status_update(@duplicate, locale: "sr", host: @organization.host)
    assert_includes mail.subject, "Duplikat — povezana prijava"
    assert_includes mail.body.to_s, @main.reference
    assert_includes mail.body.to_s, "Vaša prijava i dopune su sačuvane."
    assert_not_includes mail.body.to_s, "OLD REJECTION TEXT"
    assert_not_includes mail.body.to_s, "private-main@example.org"
    assert_not_includes mail.body.to_s, @main.status_token
  end

  test "a main report outside the organization is never exposed" do
    other = Decidim::Bih::Report.create!(organization: create_organization, description: "Private other report")
    @duplicate.update_column(:duplicate_of_report_id, other.id) # rubocop:disable Rails/SkipsModelValidations
    get "/biceriseno/prijave/#{@duplicate.reference}"
    assert_response :success
    assert_select "[data-report-duplicate] a", count: 0
    assert_not_includes response.body, other.reference
    assert_nil Decidim::Bih::ReportServiceRequest.new(@duplicate.reload).to_h.dig(:duplicate_cluster, :duplicate_of_reference)
  end

  test "clearing a duplicate link restores the stored status presentation" do
    @duplicate.update!(duplicate_of: nil)
    assert_equal "odbijeno", @duplicate.status
    assert_equal "not_actionable", Decidim::Bih::ReportStatusPresenter.public_status(@duplicate)
    assert_equal 2, Decidim::Bih::ReportStatusPresenter.filter(Decidim::Bih::Report.where(organization: @organization), "odbijeno").count
  end

  test "map and analytics expose a separate duplicate bucket" do
    @duplicate.update!(latitude: 44.75, longitude: 19.21)
    map = Decidim::Bih::ReportMapFeatures.new(@organization, url_builder: ->(reference) { "/biceriseno/prijave/#{reference}" }).call
    properties = map[:features].first[:properties]
    assert_equal "duplicate", properties[:status]
    assert_equal "duplicate", properties[:public_status]
    assert_equal false, properties[:resolved_recently]
    csv = Decidim::Bih::Admin::AnalyticsSummary.new(organization: @organization).csv_for("reports")
    rows = CSV.parse(csv, headers: true)
    assert_equal 1, rows.find { |row| row["status"] == "duplicate" }["count"].to_i
    assert_equal 1, rows.find { |row| row["status"] == "odbijeno" }["count"].to_i
  end

  test "admin queue filters both status and review decision without treating duplicates as rejection" do
    sign_in FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
    @duplicate.update!(review_state: "rejected")
    @rejected.update!(review_state: "rejected")
    get "/admin/bih/reports"
    assert_response :success
    assert_select "select[name='status']", count: 1
    assert_select "select[name='case_state']", count: 0
    [{ status: "duplicate" }, { case_state: "duplicate" }].each do |filter|
      get "/admin/bih/reports", params: filter
      assert_response :success
      assert_select "#admin-reports-list a[href^=?]", "/admin/bih/reports/#{@duplicate.reference}"
      assert_select "#admin-reports-list a[href^=?]", "/admin/bih/reports/#{@rejected.reference}", count: 0
    end
    get "/admin/bih/reports", params: { case_state: "rejected" }
    assert_response :success
    assert_select "#admin-reports-list a[href^=?]", "/admin/bih/reports/#{@rejected.reference}"
    assert_select "#admin-reports-list a[href^=?]", "/admin/bih/reports/#{@duplicate.reference}", count: 0
  end

  test "linked duplicates do not remain actionable review work" do
    @duplicate.update!(needs_review: true)
    rows = Decidim::Bih::Admin::ReportTriageSummary.new(organization: @organization).report_rows(bucket: "pending_review")
    assert_nil rows.find { |row| row[:reference] == @duplicate.reference }
    assert_equal "duplicate", Decidim::Bih::ReportStatusPresenter.status_key(@duplicate)
  end

  private

  def report(**attributes)
    Decidim::Bih::Report.create!(organization: @organization, description: "Private report body", **attributes)
  end
end
