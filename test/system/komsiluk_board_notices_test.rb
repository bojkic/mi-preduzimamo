# frozen_string_literal: true

require "application_system_test_case"
require "fileutils"

class KomsilukBoardNoticesTest < ApplicationSystemTestCase
  setup do
    @organization = create_organization
    use_organization_host!(@organization)
    @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization, locale: "sr")
    @mz = Decidim::Bih::LocalArea.create!(organization: @organization, kind: "mz", slug: "browser-notice-mz", name: { sr: "Browser MZ" })
    @north = area("north", "Browser Sjever", district: @mz)
    @south = area("south", "Browser Jug", district: @mz)
    @outside = area("outside", "Browser Zapad")
    @members = [@north, @south, @outside].map do |board|
      FactoryBot.create(:user, :confirmed, organization: @organization).tap do |member|
        Decidim::Bih::CitizenProfile.for_user(member, organization: @organization).assign_komsiluk!(board, source: "map")
      end
    end
    sign_in_user! @admin
  end

  test "desktop operator searches overlapping destinations previews and publishes one durable notice" do
    page.current_window.resize_to(1440, 1000)
    compose_notice(title: "Browser objava za dvije table", body: "Tačan sažetak za članove dva komšiluka.")
    search_and_select(@mz)
    search_and_select(@north)
    assert_selected_areas(@mz, @north)
    screenshot("new-desktop", selector: "#board-notice-compose")
    publish_and_review(title: "Browser objava za dvije table", body: "Tačan sažetak za članove dva komšiluka.", viewport: "desktop")
  end

  test "mobile operator keeps selected boards visible during search and completes publication by keyboard" do
    page.current_window.resize_to(390, 844)
    compose_notice(title: "Mobilna objava fondacije", body: "Sadržaj koji ostaje dostupan na obje izabrane table.")
    search_and_select(@north, keyboard: true)
    search_and_select(@south, keyboard: true)
    assert_selected_areas(@north, @south)
    assert_no_horizontal_overflow!
    screenshot("new-mobile", selector: "[data-board-area-picker]")
    find(:button, copy("preview"), exact: true).send_keys(:enter)
    review_and_confirm(title: "Mobilna objava fondacije", body: "Sadržaj koji ostaje dostupan na obje izabrane table.", viewport: "mobile")
  end

  test "optional phone preview shows exact candidates and provider blocker without confirming a send" do
    page.current_window.resize_to(390, 844)
    compose_notice(title: "Provjera telefonskog pregleda", body: "Sintetička objava za pregled bez slanja.")
    search_and_select(@north)
    find("summary", text: copy("optional_phone"), exact_text: true).send_keys(:enter)
    assert_selector "details[open] input[name='notice[channels][]'][value=viber]"
    find("input[name='notice[channels][]'][value=viber]").check
    find("input[name='notice[channels][]'][value=whatsapp]").check
    fill_in "notice_text", with: "Tačan telefon tekst za sintetički pregled."
    assert_no_selector "input[name='notice[channels][]'][value=sms]:checked"
    assert_no_horizontal_overflow!
    screenshot("optional-phone-mobile", selector: "details[open]")
    assert_no_difference ["Decidim::Bih::KomsilukPost.count", "Decidim::Bih::KomsilukPhoneDelivery.count"] do
      # The server thread observes this scoped readiness fixture. No provider
      # method is called, no send is confirmed and no phone job is created.
      Decidim::Bih::Komsiluk::NoticePhonePolicy.stub(:readiness, ["provider_unconfigured"]) do
        click_button copy("preview")
        assert_selector "#board-notice-preview"
        within "#board-notice-preview" do
          assert_text "Tačan telefon tekst za sintetički pregled."
          assert_text "Viber → WhatsApp"
          assert_text copy("reasons.provider_unconfigured")
          assert_no_selector "form[action$='/board-notices/confirm']"
          @members.each { |member| assert_no_text member.email }
        end
      end
    end
    assert_no_horizontal_overflow!
    screenshot("phone-blocked-preview-mobile", selector: "#board-notice-preview")
    assert_no_browser_console_errors!
  end

  test "mobile delivery tab discovers stalled work and opens its notice without exposing members" do
    page.current_window.resize_to(390, 844)
    post = Decidim::Bih::KomsilukPost.create!(organization: @organization, komsiluk: @north, origin: "staff",
                                              publication_key: SecureRandom.uuid, title: "Objava za pregled isporuke", body: "Sintetički sadržaj.",
                                              category: "general", expires_at: 1.day.from_now, published_at: Time.current)
    receipt = Decidim::Bih::PlatformDelivery.for!(user: @members.first, identity: "browser-ops:#{post.id}", expires_at: 1.day.from_now)
    receipt.update!(komsiluk_post: post, created_at: 20.minutes.ago)
    assert_no_difference ["Decidim::Bih::KomsilukPost.count", "Decidim::Bih::KomsilukPhoneDelivery.count"] do
      visit "/admin/bih/komsiluk-posts"
      accept_data_consent!
      click_link I18n.t("decidim.bih.admin.board_delivery_operations.title", locale: :sr), exact: true
      assert_selector "#komsiluk-delivery-operations [data-board-delivery-post-id='#{post.id}']"
      within "#komsiluk-delivery-operations" do
        assert_text I18n.t("decidim.bih.admin.board_delivery_operations.issues.inbox_stalled", locale: :sr)
        assert_no_selector "form"
        @members.each { |member| assert_no_text member.email }
      end
      assert_no_selector "#board-delivery-counts[open]"
      action_rect = page.evaluate_script(<<~JS)
        (() => {
          const rect = document.querySelector("[data-board-delivery-post-id] > a.button").getBoundingClientRect();
          return { top: rect.top, bottom: rect.bottom, height: window.innerHeight, scroll: window.scrollY };
        })()
      JS
      assert_equal 0, action_rect.fetch("scroll"), "Measure the first action before any scrolling"
      assert_operator action_rect.fetch("top"), :>=, 0
      assert_operator action_rect.fetch("bottom"), :<=, action_rect.fetch("height"), "First delivery action must be fully visible on arrival"
      assert_no_horizontal_overflow!
      screenshot("delivery-operations-mobile", selector: "body")
      find("#board-delivery-counts summary").send_keys(:enter)
      assert_selector "#board-delivery-counts[open] dl dt", count: 9
      assert_text I18n.t("decidim.bih.admin.board_delivery_operations.thresholds", locale: :sr)
      find("#board-delivery-counts summary").send_keys(:enter)
      click_link I18n.t("decidim.bih.admin.board_delivery_operations.review", locale: :sr), exact: true
      assert_selector ".mi-board-admin-detail h1", text: post.title
      assert_selector "#notice-delivery"
    end
    assert_no_browser_console_errors!
  end

  private

  def area(slug, name, district: nil)
    Decidim::Bih::LocalArea.create!(organization: @organization, kind: "komsiluk", slug: "browser-notice-#{slug}", name: { sr: name }, primary_mz_slug: district&.slug)
  end

  def copy(key)
    I18n.t("decidim.bih.admin.board_notices.#{key}", locale: :sr)
  end

  def compose_notice(title:, body:)
    visit "/admin/bih/board-notices/new"
    accept_data_consent!
    assert_selector "#board-notice-compose"
    assert_selector "[data-board-area-picker][data-initialized=true]"
    assert_selector "select#notice_category option:checked", text: copy("categories.general"), exact_text: true
    fill_in "notice_title", with: title
    fill_in "notice_body", with: body
    assert_no_selector "input[name='notice[channels][]']:checked", visible: :all
    assert_no_horizontal_overflow!
  end

  def search_and_select(area, keyboard: false)
    within "[data-board-area-picker]" do
      fill_in "notice-board-area-search", with: area.translated_name
      assert_selector "[data-area-option]:not([hidden])", count: 1
      input = find("#notice_board_area_#{area.id}")
      keyboard ? input.send_keys(:space) : input.check
      assert input.checked?
    end
  end

  def assert_selected_areas(*areas)
    within "[data-board-area-picker]" do
      assert_selector "[data-area-selection-count]", text: areas.length.to_s, exact_text: true
      areas.each { |area| assert_selector "[data-area-selected]", text: area.translated_name }
      fill_in "notice-board-area-search", with: @outside.translated_name
      assert_selector "[data-area-option]:not([hidden])", count: 1
      areas.each { |area| assert_selector "[data-area-selected]", text: area.translated_name }
    end
  end

  def publish_and_review(title:, body:, viewport:)
    click_button copy("preview")
    review_and_confirm(title:, body:, viewport:)
  end

  def review_and_confirm(title:, body:, viewport:)
    assert_selector "#board-notice-preview"
    within "#board-notice-preview" do
      assert_text title
      assert_text body
      assert_text @north.translated_name
      assert_text @south.translated_name
      assert_no_text @outside.translated_name
      assert_text copy("platform_push")
      audience = find("dt", text: copy("audience"), exact_text: true).find(:xpath, "following-sibling::dd[1]")
      assert_equal "2", audience.text
      @members.each { |member| assert_no_text member.email }
    end
    assert_empty Decidim::Bih::KomsilukPost.where(organization: @organization)
    assert_no_horizontal_overflow!
    screenshot("preview-#{viewport}", selector: "#board-notice-preview")
    click_button copy("confirm_publication")
    assert_selector ".mi-board-admin-detail h1", text: title
    posts = Decidim::Bih::KomsilukPost.where(organization: @organization, title:).order(:id).to_a
    assert_equal 2, posts.length
    assert_equal [@north.id, @south.id].sort, posts.map(&:komsiluk_id).sort
    assert_equal 1, posts.map(&:publication_key).uniq.length
    assert(posts.all? { |post| post.body == body && post.origin == "staff" })
    reviewed_post = posts.find { |post| current_path == "/sr/admin/bih/komsiluk-posts/#{post.id}" }
    assert reviewed_post, "Expected the detail page of one of this publication's two confirmed board placements"
    assert_current_path "/sr/admin/bih/komsiluk-posts/#{reviewed_post.id}"
    assert_text body
    assert_selector "#notice-delivery"
    assert_link copy("phone_preview"), href: "/sr/admin/bih/board-notices/#{reviewed_post.id}/phone"
    assert_empty Decidim::Bih::KomsilukPhoneDelivery.where(organization: @organization)
    assert_equal 2, Decidim::Bih::PlatformDelivery.where(komsiluk_post_id: posts.map(&:id)).count
    assert_no_horizontal_overflow!
    screenshot("detail-#{viewport}", selector: ".mi-board-admin-detail")
    visit current_path
    assert_selector ".mi-board-admin-detail h1", text: title
    assert_text body
    assert_no_browser_console_errors!
  end

  def screenshot(name, selector:)
    return unless ENV["DECIDIM_TEST_COMPILED_ASSETS"] == "1"

    directory = Rails.root.join("tmp/komsiluk-boards-browser")
    FileUtils.mkdir_p(directory)
    page.execute_script("document.querySelector(arguments[0]).scrollIntoView({block: 'start'})", selector)
    page.save_screenshot(directory.join("staff-#{name}.png")) # rubocop:disable Lint/Debugger -- synthetic final browser evidence
  end
end
