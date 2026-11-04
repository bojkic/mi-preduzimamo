# frozen_string_literal: true

require "application_system_test_case"

class GoodwillAdminDashboardTest < ApplicationSystemTestCase
  setup do
    @organization = create_organization
    use_organization_host!(@organization)
    @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
    @citizen = FactoryBot.create(:user, :confirmed, organization: @organization, name: "Mila Admin QA")
    @ledger = Decidim::Bih::Goodwill::Ledger.new

    create_pending_volunteer_log!
    create_pending_volunteer_opportunity!
    create_reward_fulfillment!
    create_approved_match_request!
    create_forwarding_failure!
  end

  test "admin goodwill dashboard renders live operational queues" do
    sign_in_user! @admin

    visit "/admin/bih/goodwill"
    accept_data_consent!

    assert_selector "#goodwill-stats"
    assert_selector "#goodwill-stats[data-goodwill-active-tab='rewards']"
    assert_selector "#goodwill-workflow-nav a[aria-current='page'][href='/sr/admin/bih/goodwill?tab=rewards']"
    assert_selector "#goodwill-workflow-nav a[href='/sr/admin/bih/goodwill?tab=overview']"
    assert_selector "#goodwill-workflow-nav a[href='/sr/admin/bih/goodwill?tab=matched_giving']"
    assert_selector "#goodwill-workflow-nav a[href='/sr/admin/bih/goodwill?tab=reports']"
    assert_selector "#goodwill-workflow-nav a[href='/sr/admin/bih/goodwill?tab=ledger']"
    assert_selector "a[href='/sr/admin/bih/volunteering']"
    assert_selector "#goodwill-reward-fulfillments", text: "Majica zajednice"
    assert_selector "#goodwill-reward-fulfillments", text: "Zatraženo"
    assert_selector "#goodwill-reward-fulfillments", text: "preuzimanje"
    assert_selector "#goodwill-reward-fulfillments select[name='reward_fulfillment_status']"
    assert_selector "#goodwill-reward-fulfillments select[name='reward_key']"
    assert_selector "#goodwill-reward-fulfillment-batch"
    assert_selector "a[href*='reward-fulfillments/export']"
    assert_no_selector "#goodwill-match-requests"
    assert_no_selector "#goodwill-report-forwarding-failures"
    assert_no_selector "#goodwill-transactions"
    assert_no_horizontal_overflow!
    assert_no_browser_console_errors!

    visit "/admin/bih/goodwill?tab=matched_giving"
    assert_selector "#goodwill-stats[data-goodwill-active-tab='matched_giving']"
    assert_selector "#goodwill-match-requests", text: "Udruzenje browser"
    assert_selector "#goodwill-match-requests input[name='payout_amount_minor_units']"
    assert_selector "#goodwill-match-requests input[name='payout_reference']"
    assert_no_selector "#goodwill-reward-fulfillments"
    assert_no_selector "#goodwill-report-forwarding-failures"
    assert_no_horizontal_overflow!
    assert_no_browser_console_errors!

    visit "/admin/bih/goodwill?tab=reports"
    assert_selector "#goodwill-stats[data-goodwill-active-tab='reports']"
    assert_selector "#goodwill-report-forwarding-failures", text: @failed_report.reference
    assert_selector "#goodwill-report-forwarding-failures a[href='/sr/admin/bih/reports/#{@failed_report.reference}']"
    assert_no_selector "#goodwill-match-requests"
    assert_no_selector "#goodwill-reward-fulfillments"
    assert_no_selector "#goodwill-report-forwarding-failures", text: "StandardError"
    assert_no_selector "#goodwill-report-forwarding-failures", text: "smtp_421"
    assert_no_selector "#goodwill-report-forwarding-failures", text: "[email]"
    assert_no_selector "#goodwill-report-forwarding-failures", text: "[phone]"
    assert_no_text "gradjanin@example.org"
    assert_no_text "+387 65 123 456"
    assert_no_horizontal_overflow!
    assert_no_browser_console_errors!

    visit "/admin/bih/goodwill?tab=overview"
    assert_selector "#goodwill-stats[data-goodwill-active-tab='overview']"
    assert_selector "#goodwill-volunteering-handoff"
    assert_selector "a[href='/sr/admin/bih/volunteering?subqueue=pending_opportunities']"
    assert_selector "a[href='/sr/admin/bih/volunteering?subqueue=pending_logs']"
    assert_selector "#goodwill-metrics"
    assert_selector "#goodwill-top-earners"
    assert_no_selector "#goodwill-pending-opportunities"
    assert_no_selector "#goodwill-pending-logs"
    assert_no_text "Sadnja drveca"
    assert_no_text "Ciscenje igralista"
    assert_no_horizontal_overflow!
    assert_no_browser_console_errors!
  end

  private

  def create_pending_volunteer_log!
    opportunity = Decidim::Bih::VolunteerOpportunity.create!(
      organization: @organization,
      title: "Ciscenje igralista",
      active: true
    )
    zone = Time.find_zone!("Europe/Sarajevo")
    work_date = 2.days.ago.in_time_zone(zone).to_date
    worked_from_at = zone.parse("#{work_date.iso8601} 09:00")
    Decidim::Bih::VolunteerLog.create!(
      organization: @organization,
      opportunity:,
      user: @citizen,
      work_date:,
      worked_from_at:,
      worked_until_at: worked_from_at + 2.hours,
      hours: 2,
      status: "pending"
    )
  end

  def create_pending_volunteer_opportunity!
    profile = create_volunteer_partner_profile!
    Decidim::Bih::VolunteerOpportunity.create!(
      organization: @organization,
      author: @citizen,
      title: "Sadnja drveca",
      category: "environment",
      partner_profile: profile,
      partner_name: profile.display_name,
      active: false,
      review_status: "pending"
    )
  end

  def create_volunteer_partner_profile!
    Decidim::Bih::PartnerProfile.create!(
      organization: @organization,
      display_name: "Udruzenje dashboard",
      slug: "udruzenje-dashboard",
      kind: "association",
      verification_status: "verified",
      verified_at: Time.current
    )
  end

  def create_reward_fulfillment!
    @ledger.award(@citizen, 600, reason: "proposal")
    Decidim::Bih::Goodwill::RedeemReward.call(@citizen, "majica")
  end

  def create_approved_match_request!
    group = FactoryBot.create(:user, :confirmed,
                              organization: @organization,
                              name: "Udruzenje browser",
                              extended_data: { "group" => true })
    Decidim::Bih::Goodwill::MatchRequest.create!(
      organization: @organization,
      owner: group,
      points: 150,
      status: "approved",
      created_by: @admin,
      decided_by: @admin,
      decided_at: 1.hour.ago
    )
  end

  def create_forwarding_failure!
    @failed_report = Decidim::Bih::Report.create!(
      organization: @organization,
      description: "Rupa ispred skole",
      address: "Vidovdanska 3",
      reporter_email: "gradjanin@example.org",
      reporter_phone: "+387 65 123 456"
    )
    @failed_report.record_forwarding_failure!(
      StandardError.new(
        'SMTP failed for gradjanin@example.org +387 65 123 456 address: "Vidovdanska 3" description: "Rupa ispred skole"'
      ),
      code: "smtp_421"
    )
  end
end
