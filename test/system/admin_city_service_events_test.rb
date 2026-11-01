# frozen_string_literal: true

require "application_system_test_case"
require_relative "../support/synthetic_event_source_registry"

class AdminCityServiceEventsTest < ApplicationSystemTestCase
  include SyntheticEventSourceRegistry
  setup do
    page.driver.browser.manage.window.resize_to(1400, 1400)
    @original_infobip_env = %w(INFOBIP_BASE_URL INFOBIP_API_KEY INFOBIP_VIBER_BM_SENDER MI_CITY_SERVICE_VIBER_ALERTS_ENABLED)
                            .index_with { |key| ENV.fetch(key, nil) }
    ENV["MI_CITY_SERVICE_VIBER_ALERTS_ENABLED"] = "1"
    ENV["INFOBIP_BASE_URL"] = "https://infobip.example.test"
    ENV["INFOBIP_API_KEY"] = "browser-test-key"
    ENV["INFOBIP_VIBER_BM_SENDER"] = "BrowserTest"
    Decidim::Bih::Config.reset!
    Decidim::Bih::IntegrationHealth.instance = Decidim::Bih::IntegrationHealth.new(
      store: Decidim::Bih::IntegrationHealth::MemoryStore.new
    )
    # The Viber control requires observed provider health as well as credentials
    # and governance. This fixture records a local success; no provider is called.
    Decidim::Bih::IntegrationHealth.instance.record("decidim_bih.infobip.fixture", provider: "infobip", success: true)
    assert_equal :ok, Decidim::Bih::IntegrationHealth.instance.state(provider: "infobip").fetch(:status)
    @organization = create_organization
    use_organization_host!(@organization)
    @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
    create_viber_governance_approval
    create_event
  end

  teardown do
    @original_infobip_env.each do |key, value|
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
    Decidim::Bih::Config.reset!
    Decidim::Bih::IntegrationHealth.reset!
  end

  test "mobile queue is reachable before secondary controls and those controls remain usable" do
    page.driver.browser.manage.window.resize_to(390, 844)
    sign_in_user! @admin
    visit "/admin/bih/city-alerts"
    accept_data_consent!
    assert_selector ".city-alerts-summary-row"
    assert_operator page.evaluate_script("document.querySelector('.city-alerts-summary-row').getBoundingClientRect().top + scrollY"), :<, 844
    assert_no_selector "#admin-city-alert-filters", visible: true
    if ENV["DECIDIM_TEST_COMPILED_ASSETS"] == "1"
      page.save_screenshot(Rails.root.join("tmp/screenshots/city-notice-review-mobile-queue.png")) # rubocop:disable Lint/Debugger -- retained review evidence
    end
    find("summary", text: I18n.t("decidim_app.admin.city_service_events.ui_review.filters")).click
    assert_selector "#admin-city-alert-filters"
    assert_no_horizontal_overflow!
    if ENV["DECIDIM_TEST_COMPILED_ASSETS"] == "1"
      page.save_screenshot(Rails.root.join("tmp/screenshots/city-notice-review-mobile.png")) # rubocop:disable Lint/Debugger -- retained review evidence
    end
    page.driver.browser.manage.window.resize_to(1440, 1000)
    assert_selector "#admin-city-alert-filters"
    assert_equal "rgb(255, 255, 255)", page.evaluate_script("getComputedStyle(document.querySelector('#admin-city-alert-workflow-nav [aria-current=page]')).color")
    assert_no_browser_console_errors!
  end

  test "lazy map and keyboard list share destination selections without inventing a footprint" do
    area = Decidim::Bih::LocalArea.find_by!(organization: @organization, slug: "komsiluk-17")
    area.update!(boundary: { type: "Polygon", coordinates: [[[0.1, 0.1], [0.2, 0.1], [0.2, 0.2], [0.1, 0.2], [0.1, 0.1]]] })
    sign_in_user! @admin
    visit "/admin/bih/city-alerts"
    accept_data_consent!
    find("[data-city-alert-toggle='#{@event.id}']").click
    assert_no_selector ".leaflet-container"
    click_button I18n.t("decidim_app.admin.city_service_events.compact.open_map")
    assert_selector ".leaflet-container"
    assert_selector "[data-city-map-status]", text: I18n.t("decidim_app.admin.city_service_events.compact.unknown")
    input = find("[data-city-board-list] input[value='#{area.id}']")
    input.send_keys(:space)
    assert_not input.checked?
    assert_not page.evaluate_script("document.querySelector('select[name=\"city_service_event[area_ids][]\"]').selectedOptions.length === 7")
    find("[data-city-board-search]").set("Izmišljeni gaj")
    assert_selector "[data-city-board-list] label", count: 1
    find("[data-city-board-search]").set("")
    find(".leaflet-interactive").click
    assert input.checked?
    if ENV["DECIDIM_TEST_COMPILED_ASSETS"] == "1"
      page.execute_script("document.querySelector('[data-city-map-url]').scrollIntoView()")
      page.save_screenshot(Rails.root.join("tmp/screenshots/city-notices-map-desktop.png")) # rubocop:disable Lint/Debugger -- retained browser evidence
    end
    page.driver.browser.manage.window.resize_to(390, 844)
    if ENV["DECIDIM_TEST_COMPILED_ASSETS"] == "1"
      sidebar_hidden = page.evaluate_async_script(<<~JS)
        const done = arguments[0]; setTimeout(() => done(document.querySelector('.layout-nav').getBoundingClientRect().right <= 1), 350)
      JS
      assert sidebar_hidden, "Mobile sidebar must finish sliding outside the review area"
      page.execute_script("document.querySelector('[data-city-map-url]').scrollIntoView()")
      page.save_screenshot(Rails.root.join("tmp/screenshots/city-notices-map-mobile.png")) # rubocop:disable Lint/Debugger -- retained browser evidence
    end
    assert_no_horizontal_overflow!
    assert_no_browser_console_errors!
  end

  test "settings remain available without any configured reference source" do
    sources = DecidimApp::Bijeljina::CityServiceSources
    prior = sources::SOURCES
    sources.send(:remove_const, :SOURCES)
    sources.const_set(:SOURCES, [].freeze)
    sign_in_user! @admin
    visit "/admin/bih/city-alerts?tab=settings"
    accept_data_consent!
    assert_selector "#admin-city-alert-readiness"
    key = DecidimApp::Bijeljina::PublicCallsPreparation.snapshot_key(@organization)
    assert_selector "[data-prepared-reference='#{key}'][data-source-status='unavailable']"
    assert_no_browser_console_errors!
  ensure
    if prior
      sources.send(:remove_const, :SOURCES)
      sources.const_set(:SOURCES, prior)
    end
  end

  test "disabled source explains rejected publication without posts or dispatch effects" do
    sources = DecidimApp::Bijeljina::CityServiceSources
    prior = sources::SOURCES
    sources.send(:remove_const, :SOURCES)
    sources.const_set(:SOURCES, prior.map { |row| row.merge(enabled: false).freeze }.freeze)
    sign_in_user! @admin
    visit "/admin/bih/city-alerts"
    accept_data_consent!
    find("[data-city-alert-toggle='#{@event.id}']").click
    within "#city-alert-editor-#{@event.id} form.mi-admin-record-editor" do
      click_button I18n.t("decidim_app.admin.city_service_events.workflow_results.save_publish")
    end
    assert_text I18n.t("decidim_app.admin.city_service_events.workflow_results.source_disabled_by_owner")
    assert_equal "pending_review", @event.reload.state
    assert_empty @event.komsiluk_post_id_values
    assert_empty DecidimApp::Bijeljina::CityServiceEffect.where(event_id: @event.id)
    assert_no_browser_console_errors!
  ensure
    if prior
      sources.send(:remove_const, :SOURCES)
      sources.const_set(:SOURCES, prior)
    end
  end

  test "operator confirms aggregate fallback preview before combined publication" do
    recipient = create_fallback_recipient
    sign_in_user! @admin
    visit "/admin/bih/city-alerts"
    accept_data_consent!
    find("[data-city-alert-toggle='#{@event.id}']").click
    within "#city-alert-editor-#{@event.id} form.mi-admin-record-editor" do
      find("[data-city-fallback]").check
      assert_selector "[data-city-fallback-text][open]"
      click_button I18n.t("decidim_app.admin.city_service_events.compact.preview")
    end
    assert_selector ".city-approval-preview"
    within ".city-approval-preview" do
      assert_selector "input[type=hidden][name=fallback_confirmed][value='1']", visible: :hidden
      assert_not_empty find("input[name=fallback_token]", visible: :hidden).value
      assert_text I18n.t("decidim_app.admin.city_service_events.compact.phone_count", count: 1, default: "Podobni primaoci: %{count}")
      assert_button I18n.t("decidim_app.admin.city_service_events.compact.publish_fallback"), disabled: false
      assert_no_text recipient.email
    end
    if ENV["DECIDIM_TEST_COMPILED_ASSETS"] == "1"
      page.save_screenshot(Rails.root.join("tmp/screenshots/city-notices-fallback-preview.png")) # rubocop:disable Lint/Debugger -- retained browser evidence
    end
    assert_equal "pending_review", @event.reload.state
    assert_nil @event.reviewed_at
    assert_empty @event.komsiluk_post_ids
    assert_empty DecidimApp::Bijeljina::CityServiceEffect.where(event_id: @event.id)
    assert_text I18n.t("decidim_app.admin.city_service_events.compact.platform_first")
    within ".city-approval-preview" do
      click_button I18n.t("decidim_app.admin.city_service_events.compact.publish_fallback")
    end
    assert_current_path "/admin/bih/city-alerts?tab=review"
    assert_equal "published", @event.reload.state
    assert_not_empty @event.komsiluk_post_ids
    assert_equal 1, @event.viber_recipients_count
    fallback = DecidimApp::Bijeljina::CityServiceEffect.find_by!(event_id: @event.id, kind: "fallback")
    assert_equal @event.publication_revision, fallback.payload.fetch("event_revision")
    assert_equal ["viber"], fallback.payload.fetch("channels")
    assert_no_browser_console_errors!
  end

  test "admin reviews city-service events in browser" do
    sign_in_user! @admin

    visit "/admin/bih/city-alerts"
    accept_data_consent!

    assert_selector "#admin-city-service-events", text: "Gradska servisna obavještenja"
    assert_selector "#admin-city-service-events[data-city-alert-active-tab='review']"
    assert_selector "#admin-city-alert-workflow-nav a[aria-current='page'][href='/admin/bih/city-alerts?tab=review']"
    assert_selector "#admin-city-alert-workflow-nav a[href='/admin/bih/city-alerts?tab=automatic']"
    assert_selector "#admin-city-alert-workflow-nav a[href='/admin/bih/city-alerts?tab=done']"
    assert_selector "#city-alert-settings[href='/admin/bih/city-alerts?tab=settings']"
    assert_no_selector "#admin-city-alert-readiness"
    assert_selector "#admin-city-alert-state-summary"
    assert_selector "#admin-city-alert-filters"
    assert_selector "table.mi-admin-editor-table"
    assert_no_selector "form.mi-admin-record-editor"
    layout = page.execute_script(<<~JS)
      const row = document.querySelector('.city-alerts-summary-row');
      return {height: row.getBoundingClientRect().height,
        widths: Array.from(row.children).map(e => e.getBoundingClientRect().width)};
    JS
    assert_operator layout.fetch("height"), :<, 350
    assert_operator layout.fetch("widths").first, :<, 65
    assert_operator layout.fetch("widths").last, :>, 90
    assert_selector '[data-city-area-slug="komsiluk-17"]', text: "Komšiluk 17 · Izmišljeni gaj"
    find("[data-city-alert-toggle='#{@event.id}']").click
    assert_selector "#city-alert-editor-#{@event.id}:not([hidden])"
    assert_selector "[data-city-map-url]"
    assert_selector "[data-city-board-list] input[type=checkbox]"
    assert_equal "grid", page.evaluate_script(<<~JS.squish)
      window.getComputedStyle(document.querySelector("form.mi-admin-record-editor")).display
    JS
    assert_selector "#admin-city-alert-filters input[name='tab'][value='review']", visible: :hidden
    assert_selector "#admin-city-service-events", text: "Planirano isključenje struje: Izmišljeno polje"
    assert_selector "#admin-city-service-events", text: "Izmišljeni gaj"
    assert_no_selector "input[name='viber_review_confirmed']"
    assert_selector "#admin-city-service-events", text: I18n.t("decidim_app.admin.city_service_events.compact.platform_first")
    assert_no_text "viber-recipient"
    assert_no_horizontal_overflow!
    assert_no_browser_console_errors!

    find_by_id("city-service-select-page").check
    assert_selector ".city-service-bulk-selection:checked", count: 1
    find_by_id("city-service-select-page").uncheck
    assert_no_selector ".city-service-bulk-selection:checked"
    find_by_id("city-service-select-page").check
    within "#city-service-bulk-review" do
      fill_in "bulk_review_note", with: "Pregledano grupnom radnjom"
      click_button I18n.t("decidim_app.admin.city_service_events.index.bulk.review")
    end
    assert_current_path "/admin/bih/city-alerts?tab=review"
    assert_selector "#admin-city-service-events"
    assert_text I18n.t("decidim_app.admin.city_service_events.bulk_review.updated", count: 1)
    assert_equal @admin.id, @event.reload.reviewed_by_id
    assert_equal "Pregledano grupnom radnjom", @event.review_note
    assert @event.pending_review?
    assert_empty @event.komsiluk_post_ids
    assert_no_selector "form[action$='/approve-answers']"
    assert_no_selector "form[action$='/revoke-answers']"

    @event.update!(state: "failed")
    visit "/admin/bih/city-alerts?state=failed&tab=review"
    assert_selector "#admin-city-service-events[data-city-alert-active-tab='review']"
    find("[data-city-alert-toggle='#{@event.id}']").click
    assert_selector "#city-alert-editor-#{@event.id} form.mi-admin-record-editor"
    assert_equal "grid", page.evaluate_script(<<~JS.squish)
      window.getComputedStyle(document.querySelector("form.mi-admin-record-editor")).display
    JS
    assert_no_horizontal_overflow!
    assert_no_browser_console_errors!

    visit "/admin/bih/city-alerts?tab=settings"
    assert_selector "#admin-city-service-events[data-city-alert-active-tab='settings']"
    assert_selector "#admin-city-alert-readiness"
    assert_no_selector "#admin-city-alert-filters"
    assert_no_text "Planirano isključenje struje: Izmišljeno polje"
    assert_no_horizontal_overflow!
    assert_no_browser_console_errors!

    area = Decidim::Bih::LocalArea.find_by!(organization: @organization, slug: "komsiluk-17")
    board_post = Decidim::Bih::KomsilukPost.create!(organization: @organization, komsiluk: area, category: "safety", title: @event.title, body: @event.summary,
                                                    expires_at: @event.ends_at)
    @event.update!(state: "board_published", published_at: Time.current, komsiluk_post_ids: [board_post.id])
    visit "/admin/bih/city-alerts?tab=published"
    assert_selector "#admin-city-service-events[data-city-alert-active-tab='done']"
    assert_selector "#admin-city-service-events", text: "Planirano isključenje struje: Izmišljeno polje"
    find("[data-city-alert-toggle='#{@event.id}']").click
    assert_selector "a[href*='/notification-preview']"
    assert_no_selector "#admin-city-alert-readiness"
    assert_no_horizontal_overflow!
    assert_no_browser_console_errors!

    page.driver.browser.manage.window.resize_to(390, 844)
    visit "/admin/bih/city-alerts?tab=published"
    assert_selector ".city-alerts-summary-row"
    assert_no_horizontal_overflow!
    find("[data-city-alert-toggle='#{@event.id}']").click
    assert_selector "#city-alert-editor-#{@event.id}:not([hidden])"
    assert_no_horizontal_overflow!
    assert_no_browser_console_errors!
  end

  test "operator publishes entered edits then withdraws and republishes a correction on mobile" do
    sign_in_user! @admin
    page.driver.browser.manage.window.resize_to(390, 844)
    visit "/admin/bih/city-alerts"
    accept_data_consent!
    find("[data-city-alert-toggle='#{@event.id}']").click
    within "#city-alert-editor-#{@event.id} form.mi-admin-record-editor" do
      find("summary", text: I18n.t("decidim_app.admin.city_service_events.compact.edit_text")).click
      find_field("city_service_event_summary").click
      fill_in "city_service_event_summary", with: "Ispravljeno vrijeme iz izvora.", fill_options: { clear: [[:control, "a"], :backspace] }
      assert_field "city_service_event_summary", with: "Ispravljeno vrijeme iz izvora."
      click_button I18n.t("decidim_app.admin.city_service_events.workflow_results.save_publish")
    end
    assert_no_selector "#city-service-event-#{@event.id}"
    assert_current_path "/admin/bih/city-alerts?tab=review"
    assert_equal "board_published", @event.reload.state
    old_ids = @event.komsiluk_post_id_values
    old_revision = @event.publication_revision
    old_post_revisions = Decidim::Bih::KomsilukPost.where(id: old_ids).pluck(:id, :content_revision).to_h
    assert_includes Decidim::Bih::KomsilukPost.find(old_ids.first).body, "Ispravljeno vrijeme iz izvora."
    visit "/admin/bih/city-alerts?tab=done"
    find("[data-city-alert-toggle='#{@event.id}']").click
    within "#city-alert-editor-#{@event.id}" do
      assert_no_selector "[data-city-alert-withdraw][open]"
      find("[data-city-alert-withdraw] > summary").click
      assert_selector "[data-city-alert-withdraw][open]"
      within "[data-city-alert-withdraw] form[action$='/withdraw']" do
        fill_in "withdraw_note_#{@event.id}", with: "Izvor je ispravio podatke"
        click_button I18n.t("decidim_app.admin.city_service_events.workflow_results.correct")
      end
    end
    assert_current_path "/admin/bih/city-alerts?tab=review"
    assert_equal "pending_review", @event.reload.state
    assert_equal "Izvor je ispravio podatke", @event.review_note
    assert_not_equal old_revision, @event.publication_revision
    history = @event.extraction_metadata.fetch("publication_history").last
    assert_equal old_ids, history.fetch("post_ids")
    assert_equal old_revision, history.fetch("revision")
    assert_empty Decidim::Bih::KomsilukPost.visible.where(id: old_ids)
    find("[data-city-alert-toggle='#{@event.id}']").click
    within "#city-alert-editor-#{@event.id} form.mi-admin-record-editor" do
      find("summary", text: I18n.t("decidim_app.admin.city_service_events.compact.edit_text")).click
      find_field("city_service_event_summary").click
      fill_in "city_service_event_summary", with: "Nova ispravljena objava.", fill_options: { clear: [[:control, "a"], :backspace] }
      assert_field "city_service_event_summary", with: "Nova ispravljena objava."
      click_button I18n.t("decidim_app.admin.city_service_events.workflow_results.save_publish")
    end
    # The correction submits from this same URL. Wait for the rendered success
    # response before inspecting persistence; the path alone is already true.
    assert_text I18n.t("decidim_app.admin.city_service_events.workflow_results.board_published", posts: old_ids.size)
    assert_no_selector "#city-service-event-#{@event.id}"
    assert_current_path "/admin/bih/city-alerts?tab=review"
    assert_equal "board_published", @event.reload.state
    # Corrections retain incident placements; content/delivery revisions change.
    assert_equal old_ids.sort, @event.komsiluk_post_id_values.sort
    assert_not_equal old_revision, @event.publication_revision
    corrected_posts = Decidim::Bih::KomsilukPost.visible.where(id: old_ids).order(:id)
    assert_equal old_ids.sort, corrected_posts.pluck(:id)
    corrected_posts.each do |post|
      assert_includes post.body, "Nova ispravljena objava."
      assert_not_includes post.body, "Ispravljeno vrijeme iz izvora."
      assert_operator post.content_revision, :>, old_post_revisions.fetch(post.id)
      prior = post.revisions.find_by!(content_revision: old_post_revisions.fetch(post.id))
      assert_includes prior.snapshot.fetch("body"), "Ispravljeno vrijeme iz izvora."
    end
    assert_no_horizontal_overflow!
    assert_no_browser_console_errors!
  end

  test "source suggestions require an explicit area selection before publication" do
    area = Decidim::Bih::LocalArea.find_by!(organization: @organization, slug: "komsiluk-17")
    @event.update!(targeting_level: "unknown", affected_area_slugs: [], extraction_metadata: {
                     "coverage" => { "source_content_version" => @event.content_version, "complete" => false,
                                     "affected_places" => [{ "slug" => area.slug, "kind" => "komsiluk", "relation" => "possible_overlap" }] }
                   })
    sign_in_user! @admin
    page.driver.browser.manage.window.resize_to(390, 844)
    visit "/admin/bih/city-alerts#city-service-event-#{@event.id}"
    accept_data_consent!
    assert_selector "#city-alert-editor-#{@event.id}:not([hidden])"
    assert_selector "details[data-city-review-facts='#{@event.id}'][open]"
    assert_text I18n.t("decidim_app.admin.city_service_events.area_selection.none")
    assert_text I18n.t("decidim_app.admin.city_service_events.area_selection.suggestions")
    before_posts = Decidim::Bih::KomsilukPost.count
    within "#city-alert-editor-#{@event.id} form.mi-admin-record-editor" do
      areas = find("select[name='city_service_event[area_ids][]']", visible: :all)
      assert_equal [], areas.all("option").select(&:selected?).map(&:value).reject(&:empty?)
      click_button I18n.t("decidim_app.admin.city_service_events.workflow_results.save_publish")
      assert_selector "[data-city-manual-areas][open]"
      areas = find("select[name='city_service_event[area_ids][]']")
      assert_equal false, areas.evaluate_script("this.validity.valid")
      assert_equal before_posts, Decidim::Bih::KomsilukPost.count
      areas.find("option[value='#{area.id}']").select_option
      assert_equal "komsiluk", find("select[name='city_service_event[targeting_level]']").value
      find("input[name='city_service_event[facts_reviewed]']").check
      fill_in "city_service_event_review_note", with: "Provjerena lokacija za ovu objavu."
      click_button I18n.t("decidim_app.admin.city_service_events.workflow_results.save_publish")
    end
    assert_current_path "/admin/bih/city-alerts?tab=review"
    assert_equal [area.slug], @event.reload.area_slugs
    assert_equal before_posts + 1, Decidim::Bih::KomsilukPost.count
    assert_equal [area.id], Decidim::Bih::KomsilukPost.where(id: @event.komsiluk_post_id_values).pluck(:komsiluk_id)
    assert_no_horizontal_overflow!
    assert_no_browser_console_errors!
  end

  test "operator confirms adjusted suggestions without searching all areas" do
    area = Decidim::Bih::LocalArea.find_by!(organization: @organization, slug: "komsiluk-17")
    other = Decidim::Bih::LocalArea.create!(organization: @organization, kind: "komsiluk", slug: "komsiluk-18", name: { "sr" => "Drugi komšiluk" })
    mz = Decidim::Bih::LocalArea.create!(organization: @organization, kind: "mz", slug: "mz-authored-grove", name: { "sr" => "Izmišljeni gaj" })
    @event.update!(targeting_level: "unknown", affected_area_slugs: [], extraction_metadata: {
                     "coverage" => { "source_content_version" => @event.content_version, "complete" => false,
                                     "affected_places" => [area, other, mz].map { |place| { "slug" => place.slug, "relation" => "possible_overlap" } } }
                   })
    sign_in_user! @admin
    page.driver.browser.manage.window.resize_to(390, 844)
    visit "/admin/bih/city-alerts#city-service-event-#{@event.id}"
    accept_data_consent!
    within "#city-alert-editor-#{@event.id} form.mi-admin-record-editor" do
      assert_no_selector "[data-city-manual-areas][open]"
      assert_no_selector "select[name='city_service_event[area_ids][]']"
      assert_selector "[data-city-area-proposal]", count: 2
      find("[data-city-confirm-areas='komsiluk']").click
      find("[data-city-proposed-area][value='#{other.id}']").uncheck
      assert_equal [], find("select[name='city_service_event[area_ids][]']", visible: :all).value
      assert_not find("input[name='city_service_event[facts_reviewed]']").checked?
      find("[data-city-confirm-areas='komsiluk']").click
      assert_selector "[data-city-area-confirmation-status]", text: "Izmišljeni gaj"
      assert_equal [area.id.to_s], find("select[name='city_service_event[area_ids][]']", visible: :all).value
      assert find("input[name='city_service_event[facts_reviewed]']").checked?
      assert_equal I18n.t("decidim_app.admin.city_service_events.area_selection.confirmation_note"), find("[name='city_service_event[review_note]']").value
      click_button I18n.t("decidim_app.admin.city_service_events.workflow_results.save_publish")
    end
    assert_current_path "/admin/bih/city-alerts?tab=review"
    assert_equal [area.slug], @event.reload.area_slugs
    assert_equal [area.id], Decidim::Bih::KomsilukPost.where(id: @event.komsiluk_post_id_values).pluck(:komsiluk_id)
    assert_no_horizontal_overflow!
    assert_no_browser_console_errors!
  end

  private

  def create_fallback_recipient
    # Synthetic account/phone proof only; the browser confirms queued delivery,
    # never performs a provider job or calls a phone verification endpoint.
    recipient = FactoryBot.create(:user, :confirmed, organization: @organization)
    area = Decidim::Bih::LocalArea.find_by!(organization: @organization, slug: "komsiluk-17")
    Decidim::Bih::CitizenProfile.for_user(recipient, organization: @organization).assign_komsiluk!(area, source: "dropdown")
    Decidim::Bih::TopicPreferences.set!(recipient, topic: :neighborhood_info, enabled: true)
    phone = "+38765111001"
    Decidim::Authorization.create!(
      user: recipient, name: "sms", granted_at: Time.current,
      unique_id: Decidim::Bih::SmsAuthorization.unique_id_for(phone)
    )
    assert Decidim::Bih::VerifiedPhone.synchronize!(user: recipient, organization: @organization, phone:)
    recipient
  end

  def create_viber_governance_approval
    Decidim::Bih::GovernanceApproval.create!(
      organization: @organization,
      user: @admin,
      governance_kind: "viber_launch",
      approval_role: "admin",
      status: "approved",
      evidence_summary: "Browser workflow Viber readiness approved"
    )
  end

  def create_event
    Decidim::Bih::LocalArea.create!(
      organization: @organization,
      kind: "komsiluk",
      slug: "komsiluk-17",
      name: { "sr" => "Izmišljeni gaj" }
    )
    [20, 23, 28, 33, 40, 45].each do |number|
      Decidim::Bih::LocalArea.create!(organization: @organization, kind: "komsiluk", slug: "komsiluk-#{number}",
                                      name: { "sr" => "Dugačak naziv naselja #{number}" })
    end
    @event = DecidimApp::Bijeljina::CityServiceEvent.create!(
      organization: @organization,
      source_key: "electricity_outages",
      source_label: "Izmišljeni planirani prekidi",
      provider: "Izmišljeni pružalac struje",
      source_url: "https://example.test/outages",
      source_fingerprint: "browser-city-event",
      parser_version: "test", lifecycle: "scheduled", content_version: "browser-v1",
      event_type: "planned_outage",
      severity: "service_outage",
      targeting_level: "komsiluk",
      affected_area_slugs: %w(komsiluk-17 komsiluk-20 komsiluk-23 komsiluk-28 komsiluk-33 komsiluk-40 komsiluk-45),
      title: "Planirano isključenje struje: Izmišljeno polje",
      summary: "Izmišljeno polje će biti bez struje od 09:00 do 12:00.",
      viber_text: "Izmišljeno polje: struja 09-12.",
      starts_at: 1.hour.from_now,
      ends_at: 4.hours.from_now,
      confidence: 0.9,
      classifier_reasons: ["test"]
    )
  end
end
