# frozen_string_literal: true

require "application_system_test_case"

class KomsilukAdminModerationTest < ApplicationSystemTestCase
  setup do
    @organization = create_organization
    use_organization_host!(@organization)
    @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
    @author = FactoryBot.create(:user, :confirmed, organization: @organization)
    @areas = 92.times.map do |index|
      Decidim::Bih::LocalArea.create!(organization: @organization, kind: "komsiluk",
                                      slug: "board-system-#{index + 1}", name: { sr: "Komšiluk #{index + 1}" })
    end
    @post = Decidim::Bih::KomsilukPost.create!(
      organization: @organization, author: @author, komsiluk: @areas.first,
      category: "safety", origin: "citizen", review_state: "pending",
      title: "Objava za cijeli pregled", body: "#{"Duga objava za pregled. " * 35}Kraj punog sadržaja", flagged_count: 1
    )
    sign_in_user! @admin
  end

  test "mobile queue starts with work and full review preserves context" do
    page.current_window.resize_to(390, 844)
    visit "/admin/bih/komsiluk-posts?tab=review&q=Objava"
    accept_data_consent!
    assert_no_selector "#komsiluk-notification-policy"
    assert_selector "[data-board-post-id='#{@post.id}']"
    first_task_y = page.evaluate_script("document.querySelector('[data-board-post-id]').getBoundingClientRect().top")
    assert_operator first_task_y, :<, 844
    assert_no_selector ".mi-board-admin-filters[open]"
    assert_selector ".mi-board-admin-active-filters", text: "Objava"
    assert_equal "rgb(255, 255, 255)", page.evaluate_script("getComputedStyle(document.querySelector('.mi-board-admin-tabs [aria-current=page]')).color")
    assert_equal "rgb(255, 255, 255)", page.evaluate_script("getComputedStyle(document.querySelector('.mi-board-admin-header .button__secondary')).color")
    find(".mi-board-admin-filters summary").click
    assert_field "q", with: "Objava"
    find(".mi-board-admin-filters summary").click
    capture_admin_evidence!("mobile-queue")
    click_link I18n.t("decidim.bih.admin.board_review.review")
    assert_text "Kraj punog sadržaja"
    assert_selector "#board-review-history"
    capture_admin_evidence!("mobile-review")
    select I18n.t("decidim.bih.admin.board_review.actions.keep"), from: "board-review-action"
    select I18n.t("decidim.bih.admin.board_review.reasons.valid"), from: "board-review-reason"
    click_button I18n.t("decidim.bih.admin.board_review.save_decision")
    assert_no_selector "[data-board-post-id='#{@post.id}']"
    assert_equal "reviewed", @post.reload.review_state
    assert_equal "Objava", Rack::Utils.parse_nested_query(URI.parse(current_url).query)["q"]
    assert_no_horizontal_overflow!
    assert_no_browser_console_errors!
  end

  test "all ninety-two moderator areas are searchable and selected areas remain visible" do
    page.current_window.resize_to(390, 844)
    visit "/admin/bih/operator-roles"
    accept_data_consent!
    find("summary", text: I18n.t("decidim.bih.admin.board_review.choose_areas")).click
    assert_selector "[data-area-option]", count: 92
    within "[data-board-area-picker]" do
      fill_in "operator-board-area-search", with: "Komšiluk 92"
      assert_selector "[data-area-option]:not([hidden])", count: 1
      check "operator_board_area_#{@areas.last.id}"
      assert_selector "[data-area-selection-count]", text: "1"
      assert_selector "[data-area-selected]", text: "Komšiluk 92"
      fill_in "operator-board-area-search", with: "Komšiluk 1"
      assert_selector "[data-area-selected]", text: "Komšiluk 92"
    end
    assert_no_browser_console_errors!
  end

  private

  def capture_admin_evidence!(name)
    return unless ENV["DECIDIM_TEST_COMPILED_ASSETS"] == "1"

    directory = Rails.root.join("tmp/komsiluk-boards-browser")
    FileUtils.mkdir_p(directory)
    page.execute_script("window.scrollTo(0, 0)")
    page.save_screenshot(directory.join("admin-#{name}.png")) # rubocop:disable Lint/Debugger -- synthetic final browser evidence
  end
end
