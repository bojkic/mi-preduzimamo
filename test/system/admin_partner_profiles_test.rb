# frozen_string_literal: true

require "application_system_test_case"

class AdminPartnerProfilesTest < ApplicationSystemTestCase
  setup do
    @organization = create_organization
    use_organization_host!(@organization)
    @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
    @member = FactoryBot.create(:user, :confirmed, organization: @organization, name: "Ana Članica", nickname: "ana-clanica")
    @candidate = FactoryBot.create(:user, :confirmed, organization: @organization, name: "Milan Kandidat", nickname: "milan-kandidat")
    @profile = Decidim::Bih::PartnerProfile.create!(
      organization: @organization,
      display_name: "Udruženje Browser",
      legal_name: "Udruženje Browser Bijeljina",
      slug: "udruzenje-browser",
      kind: "association",
      verification_status: "verified",
      verified_by: @admin,
      verified_at: Time.current,
      private_contact_name: "Privatni kontakt"
    )
    Decidim::Bih::PartnerMembership.create!(
      organization: @organization,
      partner_profile: @profile,
      user: @member,
      invited_by: @admin,
      role: "owner",
      status: "accepted",
      accepted_at: Time.current
    )
  end

  test "organization review and metadata edit are distinct labeled workflows" do
    sign_in_user! @admin
    visit "/admin/bih/organizations/#{@profile.id}/edit"
    accept_data_consent!

    assert_selector "#admin-partner-profile-edit", text: @profile.display_name
    assert_selector "[data-admin-breadcrumb='step_0']", text: @profile.display_name
    assert_selector "[data-admin-breadcrumb='step_1']"
    assert_selector "form.form-defaults.mi-admin-form"
    assert_no_selector "label label"
    assert_field I18n.t("decidim.bih.admin.partner_profiles.form.display_name")
    assert_field I18n.t("decidim.bih.admin.partner_profiles.form.private_contact_phone")
    assert_selector "input#partner_profile_slug[disabled]"
    assert_selector "button.button__secondary[type='submit']"
    assert_selector "a.button__transparent-secondary", text: I18n.t("decidim.bih.admin.partner_profiles.form.cancel")
    assert_no_selector ".translation_missing"

    click_link I18n.t("decidim.bih.admin.partner_profiles.edit.review")
    assert_selector "#admin-partner-profile-review", text: @profile.display_name
    assert_text I18n.t("decidim.bih.admin.partner_profiles.show.private_title")
    assert_selector "#partner-profile-verification-actions"
    assert_no_field I18n.t("decidim.bih.admin.partner_profiles.form.display_name")
    assert_no_browser_console_errors!
  end

  test "mobile membership management starts with intentional search and keeps table labels" do
    page.driver.browser.manage.window.resize_to(390, 844)
    sign_in_user! @admin
    visit "/admin/bih/organizations/#{@profile.id}/memberships"
    accept_data_consent!

    assert_selector "#admin-partner-profile-memberships", text: @profile.display_name
    assert_no_selector "select#partner_membership_decidim_user_id"
    assert_selector "#admin-partner-memberships-list td[data-label]", minimum: 5

    visit "/admin/bih/organizations/#{@profile.id}/memberships?member_q=Milan"
    assert_selector "select[name='partner_membership[decidim_user_id]'] option", text: "Milan Kandidat (@milan-kandidat)"
    assert_no_text "Privatni kontakt"
    assert_no_selector ".translation_missing"
    assert_no_browser_console_errors!
  end
end
