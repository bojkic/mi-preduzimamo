# frozen_string_literal: true

require "application_system_test_case"
require "fileutils"

class KomsilukBoardWorkspaceBrowserTest < ApplicationSystemTestCase
  setup do
    assert_equal "1", ENV.fetch("DECIDIM_TEST_COMPILED_ASSETS", nil),
                 "Run with DECIDIM_TEST_COMPILED_ASSETS=1 after shakapacker:compile"
    @organization = create_organization
    use_organization_host!(@organization)
    @area = Decidim::Bih::LocalArea.create!(organization: @organization, kind: "komsiluk", slug: "browser-board", name: { "sr" => "Komšiluk" })
    @citizen = FactoryBot.create(:user, :confirmed, organization: @organization,
                                                    name: "Test član table", nickname: "test_tabla_clan", email: "tabla-browser@example.test")
    Decidim::Bih::CitizenProfile.for_user(@citizen, organization: @organization).assign_komsiluk!(@area, source: "dropdown")
    Decidim::Authorization.create!(user: @citizen, name: "sms", granted_at: Time.current, unique_id: SecureRandom.uuid)
    @notice = Decidim::Bih::KomsilukPost.create!(organization: @organization, komsiluk: @area, category: "general", title: "Aktuelno obavještenje",
                                                 body: "Kratko obavještenje za komšiluk.")
    sign_in_user! @citizen
  end

  test "mobile member sees notices before composing and personal tab has a working return" do
    page.current_window.resize_to(1400, 1000)
    visit "/biceriseno/komsiluk-board"
    accept_data_consent!
    assert_selector "#post-#{@notice.id}"
    capture_board_evidence!("citizen-board-desktop")
    page.current_window.resize_to(390, 844)
    visit "/biceriseno/komsiluk-board"
    accept_data_consent!
    assert_selector "#post-#{@notice.id}"
    assert_no_selector "#komsiluk-compose[open]"
    assert_no_selector "#mi-install-banner"
    assert_operator page.evaluate_script("document.querySelector('.mi-board-card').getBoundingClientRect().top"), :<, 844
    assert_no_horizontal_overflow!
    capture_board_evidence!("citizen-board-mobile")
    click_link I18n.t("decidim.bih.komsiluk_board.index.my_posts", locale: :sr)
    assert_no_selector "#post-#{@notice.id}"
    click_link I18n.t("decidim.bih.komsiluk_board.index.all_categories", locale: :sr), exact: true
    assert_selector "#post-#{@notice.id}"
    click_link @notice.title
    assert_text @notice.body
    assert_no_horizontal_overflow!
    capture_board_evidence!("citizen-notice-mobile")
  end

  test "a bounded tab draft survives navigation and can be discarded with the keyboard" do
    page.current_window.resize_to(1400, 1000)
    visit "/biceriseno/komsiluk-board?compose=1"
    accept_data_consent!
    fill_in "komsiluk_post_title", with: "Nacrt za kasnije"
    fill_in "komsiluk_post_body", with: "Sadržaj nacrta"
    visit "/biceriseno/komsiluk-board"
    assert_selector "#komsiluk-compose[open]"
    assert_field "komsiluk_post_title", with: "Nacrt za kasnije"
    assert_field "komsiluk_post_body", with: "Sadržaj nacrta"
    assert_no_selector "#mi-install-banner"
    capture_board_evidence!("citizen-composer-desktop")
    button = find("[data-board-discard]")
    button.send_keys(:enter)
    assert_field "komsiluk_post_title", with: ""
    assert_field "komsiluk_post_body", with: ""
    assert_no_horizontal_overflow!
    assert_no_browser_console_errors!
  end

  private

  def capture_board_evidence!(name)
    directory = Rails.root.join("tmp/komsiluk-boards-browser")
    FileUtils.mkdir_p(directory)
    page.save_screenshot(directory.join("#{name}.png")) # rubocop:disable Lint/Debugger -- synthetic-account browser evidence
    assert_no_browser_console_errors!
  end
end
