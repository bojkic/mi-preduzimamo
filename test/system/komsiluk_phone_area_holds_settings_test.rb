# frozen_string_literal: true

require "application_system_test_case"
require "fileutils"

class KomsilukPhoneAreaHoldsSettingsTest < ApplicationSystemTestCase
  setup do
    @organization = create_organization
    use_organization_host!(@organization)
    @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization, locale: "sr")
    @areas = 92.times.map do |index|
      Decidim::Bih::LocalArea.create!(organization: @organization, kind: "komsiluk", slug: "phone-hold-#{index + 1}",
                                      name: { sr: "Komšiluk #{index + 1}" })
    end
    sign_in_user! @admin
  end

  test "mobile administrator searches all boards keeps selections visible and saves phone holds" do
    page.current_window.resize_to(390, 844)
    visit "/admin/bih/board-notices/settings"
    accept_data_consent!
    find("#board-area-holds-details > summary").click
    assert_selector "#board-phone-area-settings [data-board-area-picker][data-initialized=true]"
    within "#board-phone-area-settings" do
      assert_selector "[data-area-option]", count: 92
      fill_in "phone_policy-board-area-search", with: "Komšiluk 92"
      assert_selector "[data-area-option]:not([hidden])", count: 1
      find("#phone_policy_board_area_#{@areas.last.id}").send_keys(:space)
      assert_selector "[data-area-selection-count]", text: "1", exact_text: true
      assert_selector "[data-area-selected]", text: "Komšiluk 92"
      fill_in "phone_policy-board-area-search", with: "Komšiluk 1"
      assert_selector "[data-area-selected]", text: "Komšiluk 92"
    end
    assert_no_horizontal_overflow!
    assert_no_difference ["Decidim::Bih::KomsilukPost.count", "Decidim::Bih::KomsilukPhoneDelivery.count"] do
      click_button I18n.t("decidim.bih.admin.phone_area_holds.save", locale: :sr)
      assert_text I18n.t("decidim.bih.admin.phone_area_holds.saved", locale: :sr)
    end
    assert_equal [@areas.last.id], Decidim::Bih::Komsiluk::PhoneAreaHolds.snapshot(@organization)[:komsiluk_ids]
    find("#board-area-holds-details > summary").click
    within "#board-phone-area-settings" do
      assert_selector "[data-area-selection-count]", text: "1", exact_text: true
      assert_selector "[data-area-selected]", text: "Komšiluk 92"
      fill_in "phone_policy-board-area-search", with: "Komšiluk 92"
      assert find("#phone_policy_board_area_#{@areas.last.id}").checked?
    end
    capture_settings_evidence!
    assert_no_horizontal_overflow!
    assert_no_browser_console_errors!
  end

  private

  def capture_settings_evidence!
    return unless ENV["DECIDIM_TEST_COMPILED_ASSETS"] == "1"

    directory = Rails.root.join("tmp/komsiluk-boards-browser")
    FileUtils.mkdir_p(directory)
    page.execute_script("document.querySelector('#board-phone-area-settings').scrollIntoView({block: 'start'})")
    page.save_screenshot(directory.join("phone-area-holds-mobile.png")) # rubocop:disable Lint/Debugger -- synthetic final browser evidence
  end
end
