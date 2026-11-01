# frozen_string_literal: true

require "application_system_test_case"

class AdminVolunteeringRosterTest < ApplicationSystemTestCase
  setup do
    @organization = create_organization
    use_organization_host!(@organization)
    @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
    @citizen = FactoryBot.create(:user, :confirmed, organization: @organization,
                                 name: "Mila Roster Browser", email: "mila-browser@example.org")
    @applicant = FactoryBot.create(:user, :confirmed, organization: @organization,
                                   name: "Niko Browser")
    @opportunity = Decidim::Bih::VolunteerOpportunity.create!(
      organization: @organization, title: "Browser akcija park", active: true,
      review_status: "approved", starts_at: 3.days.ago, ends_at: 3.days.from_now,
      category: "environment", series_key: "browser-series", series_position: 1,
      series_total: 2, capacity: 2
    )
    @future = Decidim::Bih::VolunteerOpportunity.create!(
      organization: @organization, title: "Browser akcija park", active: true,
      review_status: "approved", starts_at: 4.days.from_now, ends_at: 5.days.from_now,
      category: "environment", series_key: "browser-series", series_position: 2,
      series_total: 2, capacity: 2
    )
    Decidim::Bih::VolunteerSignup.create!(organization: @organization, opportunity: @opportunity,
                                          user: @citizen, status: "going", review_status: "approved",
                                          review_source: "admin", reviewer: @admin, reviewed_at: Time.current)
    Decidim::Bih::VolunteerSignup.create!(organization: @organization, opportunity: @future,
                                          user: @applicant, status: "pending", review_status: "pending",
                                          review_source: "application", first_session_at: @future.starts_at)
    zone = Time.find_zone!("Europe/Sarajevo")
    work_start = 1.day.ago.in_time_zone(zone).change(hour: 10, min: 0, sec: 0)
    Decidim::Bih::VolunteerLog.create!(organization: @organization, opportunity: @opportunity,
                                       user: @citizen, status: "pending", work_date: work_start.to_date,
                                       worked_from_at: work_start, worked_until_at: work_start + 2.hours,
                                       hours: 2)
  end

  test "three work areas keep the proposal list compact and link to the decision detail" do
    sign_in_user! @admin
    visit "/admin/bih/volunteering"
    accept_data_consent!

    assert_selector "#admin-volunteering-header"
    assert_selector "#admin-volunteering-list tbody tr", count: 1
    assert_selector "#volunteer-opportunity-#{@future.id}", text: "Browser akcija park"
    assert_no_text @citizen.name
    assert_no_text @applicant.name
    assert_no_text @citizen.email
    assert_no_horizontal_overflow!

    within "#volunteer-opportunity-#{@future.id}" do
      click_link I18n.t("decidim.bih.admin.volunteering.workspace.review", locale: :sr)
    end
    assert_selector "#terms"
    assert_selector "#applications", text: @citizen.name
    assert_selector "#applications", text: @applicant.name
    assert_selector "#hours", text: "2 h"
    assert_no_text @citizen.email

    visit "/admin/bih/volunteering?tab=applications&task=review"
    assert_selector "#admin-volunteering-list tbody tr", count: 1
    assert_selector "#admin-volunteering-list", text: @applicant.name
    assert_no_text @citizen.name

    visit "/admin/bih/volunteering?tab=hours&status=pending"
    assert_selector "#admin-volunteering-list tbody tr", count: 1
    assert_selector "#admin-volunteering-list", text: @citizen.name
    assert_no_text @applicant.name
    assert_no_browser_console_errors!
  end

  test "390px admin view has a reachable first review action and no horizontal overflow" do
    sign_in_user! @admin
    page.driver.browser.manage.window.resize_to(390, 844)
    visit "/admin/bih/volunteering"
    accept_data_consent!

    assert_selector "#admin-volunteering-list tbody tr a.button", count: 1
    assert_no_horizontal_overflow!
    action_bottom = page.evaluate_script(
      "document.querySelector('#admin-volunteering-list tbody tr a.button').getBoundingClientRect().bottom"
    )
    assert_operator action_bottom, :<=, 844, "first review action should be visible without scrolling"
    assert_no_browser_console_errors!
  end
end
