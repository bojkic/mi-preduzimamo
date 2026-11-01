# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/synthetic_weather_board"

class WeatherBoardSourceStateTest < ActionDispatch::IntegrationTest
  include ::Devise::Test::IntegrationHelpers
  include SyntheticWeatherBoard

  setup do
    setup_synthetic_weather_board
    host! @organization.host
    sign_in @weather_viewer
  end
  teardown { teardown_synthetic_weather_board }

  def source_state(post = @weather_post)
    DecidimApp::Bijeljina::KomsilukNoticePublicSource.call(organization: @organization, post:)
  end

  def assert_weather_source_updating(path = decidim_bih.komsiluk_board_path(@weather_post))
    get path
    assert_response :success
    assert_includes response.body, I18n.t("decidim.bih.boards.source_update.title", locale: @organization.default_locale)
    assert_not_includes response.body, @weather_post.title
    assert_not_includes response.body, @weather_post.body
    assert_select ".mi-board-source", count: 0
    assert_select "a[href=?]", @weather_event.source_url, count: 0
  end

  test "current reviewed weather remains readable to a regular member without broadcast privileges" do
    assert_not Decidim::Bih::OperatorAuthorization.allowed?(@weather_viewer, :broadcast_preview, organization: @organization)
    assert_equal({ updating: false, url: nil }, source_state)
    get decidim_bih.komsiluk_board_path(@weather_post)
    assert_response :success
    assert_includes response.body, @weather_post.title
    assert_includes response.body, @weather_post.body
    assert_select ".mi-board-source"
  end

  test "changed review neutralizes detail list and publication title without rewriting the stored placement" do
    retained = @weather_post.attributes.slice("title", "body", "details", "content_revision", "status")
    restore_weather_board_review(region_label: "Nova autorska regija")
    assert_equal({ updating: true, url: nil }, source_state)
    assert_weather_source_updating
    assert_weather_source_updating(decidim_bih.komsiluk_board_index_path)
    assert_weather_source_updating(decidim_bih.komsiluk_publication_path(@weather_post.publication_key))
    assert_equal retained, @weather_post.reload.attributes.slice("title", "body", "details", "content_revision", "status")
    assert @weather_event.reload.board_published?
  end

  test "missing and expired review keep retained weather wording out of the current page" do
    ENV.delete("MI_WEATHER_REGION_CONFIG_PATH")
    assert_weather_source_updating
    ENV["MI_WEATHER_REGION_CONFIG_PATH"] = @synthetic_weather_region_path
    restore_weather_board_review(valid_until: "2040-09-18")
    assert_weather_source_updating
  end

  test "durable incident projection supports the reviewed placement without a copied event id" do
    incident = @weather_event.incident || DecidimApp::Bijeljina::CityServiceIncident.create!(
      organization: @organization, identity_key: "authored-weather-incident", service: "weather")
    @weather_event.update!(incident: incident, komsiluk_post_ids: [])
    DecidimApp::Bijeljina::CityServiceProjection.create!(incident: incident, komsiluk: @weather_area,
      post: @weather_post, revision: @weather_event.publication_revision)
    details = @weather_post.details.deep_dup
    details["source"].delete("event_ids")
    @weather_post.update!(details: details)
    assert_equal({ updating: false, url: nil }, source_state)
    get decidim_bih.komsiluk_board_path(@weather_post)
    assert_response :success
    assert_includes response.body, @weather_post.title
    restore_weather_board_review(region_label: "Promijenjena autorska regija")
    assert_weather_source_updating
  end

  test "JSON event ids cannot authorize an unrelated placement even with a copied source revision" do
    forged = Decidim::Bih::KomsilukPost.create!(organization: @organization, komsiluk: @weather_area,
      origin: "city_service", status: "open", category: "safety", title: @weather_post.title, body: @weather_post.body,
      expires_at: @weather_post.expires_at, details: @weather_post.details.deep_dup)
    assert_equal({ updating: true, url: nil }, source_state(forged))
    assert_weather_source_updating(decidim_bih.komsiluk_board_path(forged))
    assert_equal({ updating: false, url: nil }, source_state)
  end

  test "review id publication revision and reviewed target all remain necessary" do
    original = @weather_post.details.deep_dup
    ["event_revision", "weather_region_review_id"].each do |key|
      changed = original.deep_dup
      changed["source"][key] = "f" * 64
      @weather_post.update!(details: changed)
      assert_equal({ updating: true, url: nil }, source_state)
    end
    @weather_post.update!(details: original)
    @weather_event.update!(target_komsiluk_slugs: [])
    assert_equal({ updating: true, url: nil }, source_state)
  end

  test "legacy severe weather without a review id and absent provider both fail closed" do
    original = @weather_post.details.deep_dup
    legacy = original.deep_dup
    legacy["source"].delete("revalidation_required")
    legacy["source"].delete("weather_region_review_id")
    @weather_post.update!(details: legacy)
    assert_weather_source_updating
    @weather_post.update!(details: original)
    Decidim::Bih.komsiluk_notice_public_source_provider = nil
    assert_weather_source_updating
  end

  test "cross tenant post lookup returns no source state and ordinary service posts keep their current display" do
    foreign = Struct.new(:origin, :decidim_organization_id).new("city_service", @organization.id + 1)
    assert_equal({ updating: true, url: nil }, source_state(foreign))
    other = Decidim::Bih::KomsilukPost.create!(organization: @organization, komsiluk: @weather_area,
      origin: "city_service", status: "open", category: "general", title: "AUTORSKA DRUGA USLUGA", body: "AUTORSKI DRUGI SADRŽAJ.",
      details: { "source" => { "event_type" => "planned_outage", "provider" => "Autorski drugi pružalac" } })
    get decidim_bih.komsiluk_board_path(other)
    assert_response :success
    assert_includes response.body, other.title
    assert_includes response.body, other.body
  end
end
