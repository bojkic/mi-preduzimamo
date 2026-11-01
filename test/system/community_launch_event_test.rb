# frozen_string_literal: true

require "application_system_test_case"
require_relative "../support/synthetic_launch_event"

class CommunityLaunchEventSystemTest < ApplicationSystemTestCase
  include SyntheticLaunchEvent

  setup do
    assert_equal "1", ENV["DECIDIM_TEST_COMPILED_ASSETS"], "launch browser checks require compiled candidate assets"
    travel_to Time.utc(2040, 9, 19, 17)
    @organization = create_organization
    use_organization_host! @organization
    install_synthetic_launch_event(organization: @organization,
      opens_at: "2040-09-19T00:00:00+02:00", closes_at: "2040-09-20T00:00:00+02:00")
    @citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
    @admin = FactoryBot.create(:user, :confirmed, :admin, organization: @organization)
    phone = "+12025550101"
    Decidim::Authorization.create!(user: @citizen, name: "sms", granted_at: Time.current,
      unique_id: Decidim::Bih::SmsAuthorization.unique_id_for(phone))
    Decidim::Bih::VerifiedPhone.synchronize!(user: @citizen, organization: @organization, phone:)
  end
  teardown do
    restore_synthetic_launch_event
    travel_back
  end

  test "desktop operator sees own dates and stale confirmation queues no message" do
    page.driver.browser.manage.window.resize_to(1400, 1000)
    sign_in_user! @admin
    DecidimApp::LaunchEvent.stub(:channels_for, ["viber"]) do
      visit "/admin/lansiranje?locale=sr"
      accept_data_consent!
      assert_selector "h1", text: "AUTORSKI DAN ZAJEDNICE"
      assert_text "19.09.2040."
      assert_no_text "17. septembar"
      assert_no_text "Bojan"
      first_form = find("form[action='/admin/lansiranje/posalji']", match: :first)
      previous = first_form.find("input[name=event_key]", visible: :all).value
      write_synthetic_launch_event(title: "DRUGI AUTORSKI DOGAĐAJ")
      assert_not_equal previous, DecidimApp::LaunchEvent.event_key(@organization)
      within first_form do
        check "confirm"
        find("button[type=submit]").click
      end
      assert_text I18n.t("mi_launch_event.changed", locale: :sr)
      assert_selector "h1", text: "DRUGI AUTORSKI DOGAĐAJ"
      assert_equal 0, DecidimApp::LaunchEventDelivery.where(organization: @organization).count
    end
    assert_no_horizontal_overflow!
    FileUtils.mkdir_p Rails.root.join("tmp/screenshots")
    save_screenshot Rails.root.join("tmp/screenshots/community-launch-admin-stale-desktop.png")
  end

  test "mobile poll stops stale background updates and submits a refreshed event exactly once" do
    page.driver.browser.manage.window.resize_to(390, 844)
    sign_in_user! @citizen
    visit "/lansiranje/anketa?locale=sr"
    accept_data_consent!
    assert_selector "form[data-event-vote]"
    old_key = find("form[data-event-vote] input[name=event_key]", visible: :all).value
    write_synthetic_launch_event(title: "DRUGI AUTORSKI DOGAĐAJ")
    assert_selector "[data-vote-status]", text: I18n.t("mi_launch_event.changed", locale: :sr), wait: 8
    assert_no_selector "form[data-event-vote]", visible: true
    assert_equal 0, DecidimApp::LaunchEventVote.where(organization: @organization).count
    visit "/lansiranje/anketa?locale=sr"
    accept_data_consent!
    fresh_key = find("form[data-event-vote] input[name=event_key]", visible: :all).value
    assert_not_equal old_key, fresh_key
    within "form[data-event-vote]" do
      choose "Rasvjeta"
      click_button "Glasaj"
    end
    assert_selector "[data-vote-status]", text: I18n.t("mi_launch_event.recorded", locale: :sr)
    assert_equal 1, DecidimApp::LaunchEventVote.where(organization: @organization, event_key: fresh_key).count
    assert_equal 0, DecidimApp::LaunchEventVote.where(organization: @organization, event_key: old_key).count
    [390, 320].each do |width|
      page.driver.browser.manage.window.resize_to(width, 844)
      assert_no_horizontal_overflow!
    end
    FileUtils.mkdir_p Rails.root.join("tmp/screenshots")
    save_screenshot Rails.root.join("tmp/screenshots/community-launch-poll-mobile.png")
  end
end
