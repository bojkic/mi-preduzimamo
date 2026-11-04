# frozen_string_literal: true

require "application_system_test_case"

class KomsilukAdminBroadcastTest < ApplicationSystemTestCase
  setup do
    @organization = create_organization
    use_organization_host!(@organization)
    @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization, locale: "sr")
    @komsiluk = Decidim::Bih::LocalArea.create!(
      organization: @organization,
      kind: "komsiluk",
      slug: "legacy-broadcast-browser",
      name: { "sr" => "Browser komšiluk" }
    )
    sign_in_user! @admin
  end

  test "legacy broadcast bookmark redirects to the durable composer without creating delivery work" do
    assert_no_difference [
      "Decidim::Bih::Broadcast.count",
      "Decidim::Bih::KomsilukPost.count",
      "Decidim::Bih::KomsilukSendIntent.count",
      "Decidim::Bih::KomsilukPhoneDelivery.count"
    ] do
      visit "/admin/bih/broadcasts/new"
      accept_data_consent!
      assert_composer
      assert_no_selector "#broadcast-preview"
      assert_no_selector "form[action='/sr/admin/bih/broadcasts']"
      assert_no_selector "input[name='notice[channels][]']:checked", visible: :all

      click_link I18n.t("decidim.bih.admin.board_notices.back_to_boards", locale: :sr)
      assert_current_path "/sr/admin/bih/komsiluk-posts"
      within ".mi-board-admin-navigation" do
        click_link I18n.t("decidim.bih.admin.board_correction.publications", locale: :sr), href: "/sr/admin/bih/board-notices/new"
      end
      assert_composer
    end
    assert_no_horizontal_overflow!
    assert_no_browser_console_errors!
  end

  private

  def assert_composer
    assert_current_path "/sr/admin/bih/board-notices/new"
    assert_selector "#board-notice-compose"
    assert_selector "form[action='/sr/admin/bih/board-notices/preview']"
    assert_selector "[data-board-area-picker] input[value='#{@komsiluk.id}']"
  end
end
