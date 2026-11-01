# frozen_string_literal: true

require "application_system_test_case"

class AdminPrivacyRetentionTest < ApplicationSystemTestCase
  setup do
    @organization = create_organization
    use_organization_host!(@organization)
    @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
    create_private_retention_source!
    create_retention_run!
  end

  test "admin privacy retention page renders aggregate counts without private source data" do
    sign_in_user! @admin

    visit "/admin/bih/privacy-retention"
    accept_data_consent!

    assert_selector "#admin-privacy-retention-header"
    assert_selector "#admin-privacy-retention-approval"
    assert_selector "#admin-privacy-retention-current"
    assert_selector "#admin-privacy-retention-last-run"
    assert_selector "#admin-privacy-retention-history"
    assert_selector "[data-retention-bucket='report_contacts']"
    assert_selector "[data-retention-bucket='report_coordinates']"
    assert_selector "[data-retention-run-status='ok']"
    assert_selector "[data-retention-history-count='report_contacts']"
    assert_selector "[data-retention-status='warn']"
    assert_no_text "Private browser retention report"
    assert_no_text "browser-retention-private@example.org"
    assert_no_text "+387 65 444 555"
    assert_no_horizontal_overflow!
    assert_no_browser_console_errors!
  end

  private

  def create_private_retention_source!
    Decidim::Bih::Report.create!(
      organization: @organization,
      description: "Private browser retention report",
      reporter_email: "browser-retention-private@example.org",
      reporter_phone: "+387 65 444 555",
      latitude: 44.756123,
      longitude: 19.214987,
      created_at: 4.years.ago
    )
  end

  def create_retention_run!
    Decidim::Bih::Privacy::RetentionRun.create!(
      organization: @organization,
      status: "ok",
      dry_run: false,
      source: "test",
      started_at: 1.hour.ago,
      finished_at: 59.minutes.ago,
      counts: { "report_contacts" => 1, "report_coordinates" => 1 },
      total: 2,
      cutoffs: { "report_contact_before" => 3.years.ago.utc.iso8601 }
    )
  end
end
