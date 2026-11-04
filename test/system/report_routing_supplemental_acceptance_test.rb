# frozen_string_literal: true

require "application_system_test_case"

class ReportRoutingSupplementalAcceptanceTest < ApplicationSystemTestCase
  setup do
    @organization = create_organization
    use_organization_host!(@organization)
    @admin = FactoryBot.create(:user, :confirmed, :admin, organization: @organization)
    Decidim::Bih::Setting.put(@organization, "sistem48_routing", "saobracaj", "reviewed@fixtures.invalid")
  end

  test "admin creates edits and deactivates tenant routing guidance with versioned approval" do
    other = create_organization
    outsider = Decidim::Bih::ReportRoutingGuide.create!(organization: other, key: "other-guide", title: "Other tenant guidance", body_sr: "Other tenant text")
    sign_in_user! @admin
    visit "/admin/bih/report-routing-guides"
    accept_data_consent!
    assert_no_text outsider.title
    within "form[action='/sr/admin/bih/report-routing-guides']" do
      fill_in "guide_key", with: "synthetic-parking"
      fill_in "guide_title", with: "Synthetic reviewed parking guidance"
      fill_in "guide_body_sr", with: "Enforcement and signage require distinct staff review."
      select "saobracaj", from: "guide_categories"
      select "saobracaj", from: "guide_approved_recipient_keys"
      assert_no_selector "#guide_approved_recipient_keys option[value='invented']", visible: :all
      check "guide_active"
      click_button I18n.t("decidim.bih.routing_guides.save", locale: :sr)
    end
    assert_selector "form input[name='_method'][value='patch']", visible: :all
    guide = Decidim::Bih::ReportRoutingGuide.find_by!(organization: @organization, key: "synthetic-parking")
    assert_equal 1, guide.version
    assert_equal @admin.id, guide.approved_by_id
    assert_equal ["saobracaj"], guide.approved_recipient_keys
    assert guide.active

    within "form[action='/sr/admin/bih/report-routing-guides/#{guide.id}']" do
      fill_in "guide_body_sr", with: "Updated reviewed guidance; never imply service receipt."
      click_button I18n.t("decidim.bih.routing_guides.save", locale: :sr)
    end
    assert_selector "textarea", text: "Updated reviewed guidance; never imply service receipt."
    assert_equal 2, guide.reload.version
    assert_equal @admin.id, guide.approved_by_id
    within "form[action='/sr/admin/bih/report-routing-guides/#{guide.id}']" do
      uncheck "guide_active"
      click_button I18n.t("decidim.bih.routing_guides.save", locale: :sr)
    end
    within "form[action='/sr/admin/bih/report-routing-guides/#{guide.id}']" do
      assert_unchecked_field "guide_active"
    end
    assert_not guide.reload.active
    assert_equal 3, guide.version
    assert_empty Decidim::Bih::ReportRoutingGuide.reviewed.where(id: guide.id)
    assert_equal "Other tenant text", outsider.reload.body_sr
  end

  test "ordinary member cannot reach routing editor or change guidance" do
    guide = Decidim::Bih::ReportRoutingGuide.create!(organization: @organization, key: "restricted", title: "Restricted guide", body_sr: "Protected text")
    member = FactoryBot.create(:user, :confirmed, organization: @organization)
    sign_in_user! member
    visit "/admin/bih/report-routing-guides"
    assert_no_selector "form[action='/sr/admin/bih/report-routing-guides']"
    assert_equal "Protected text", guide.reload.body_sr
    assert_equal 1, guide.version
    assert_nil guide.approved_by_id
  end
end
