# frozen_string_literal: true

require_relative "synthetic_event_source_registry"
require_relative "synthetic_weather_region"

# A published test placement with real FK/membership relationships and wholly
# invented weather/source/community data. No publisher or provider is called.
module SyntheticWeatherBoard
  def self.included(base)
    base.include SyntheticEventSourceRegistry
    base.include SyntheticWeatherRegion
  end

  def setup_synthetic_weather_board
    @original_weather_source_provider = Decidim::Bih.komsiluk_notice_public_source_provider
    @weather_now = Time.utc(2040, 9, 19, 8)
    travel_to @weather_now
    @organization = create_organization
    yield @organization if block_given?
    @weather_area = Decidim::Bih::LocalArea.create!(organization: @organization, kind: "komsiluk",
      slug: "authored-weather-board", name: { sr: "Autorski komšiluk" })
    @weather_viewer = FactoryBot.create(:user, :confirmed, organization: @organization)
    @weather_admin = FactoryBot.create(:user, :confirmed, :admin, organization: @organization)
    Decidim::Bih::CitizenProfile.for_user(@weather_viewer, organization: @organization).assign_komsiluk!(@weather_area, source: "dropdown")
    Decidim::Authorization.create!(user: @weather_viewer, name: "sms", granted_at: Time.current, unique_id: SecureRandom.uuid)
    install_synthetic_weather_region
    restore_weather_board_review
    source = DecidimApp::Bijeljina::CityServiceSources.fetch("weather_warnings")
    info = { language: "sr", event: "AUTORSKI TESTNI DOGAĐAJ", severity: "Severe", onset: @weather_now.iso8601,
             expires: (@weather_now + 4.hours).iso8601,
             area: [{ areaDesc: "Autorski provider region", geocode: [{ valueName: "EMMA_ID", value: "TEST-REGION-A" }] }] }
    body = JSON.generate(warnings: [{ alert: { sender: "weather-authority.example.invalid", identifier: "authored-board-a",
      sent: (@weather_now - 1.hour).iso8601, status: "Actual", scope: "Public", msgType: "Alert", info: [info] } }])
    @weather_event = DecidimApp::Bijeljina::CityServiceEventIngestor.new(organization: @organization).ingest(source_key: "weather_warnings", html: body, fetched_at: @weather_now).events.sole
    @weather_event.update!(title: "AUTORSKO VREMENSKO UPOZORENJE", summary: "AUTORSKI SADRŽAJ VREMENSKOG POSTA.",
      targeting_level: "komsiluk", affected_area_slugs: [@weather_area.slug], target_komsiluk_slugs: [@weather_area.slug])
    revision = DecidimApp::Bijeljina::CityServiceIncidentIdentity.revision(@weather_event)
    @weather_event.update!(state: "board_published", reviewer: @weather_admin, reviewed_at: @weather_now,
      reviewed_content_version: @weather_event.content_version,
      extraction_metadata: @weather_event.extraction_metadata.merge("publication_revision" => revision))
    @weather_post = Decidim::Bih::KomsilukPost.create!(organization: @organization, komsiluk: @weather_area,
      origin: "city_service", status: "open", category: "safety", publication_key: SecureRandom.uuid,
      title: @weather_event.title, body: @weather_event.summary, published_at: @weather_now, expires_at: @weather_event.ends_at,
      details: { "source" => DecidimApp::Bijeljina::CityServiceBoardMetadata.for_event(@weather_event) })
    @weather_event.update!(komsiluk_post_ids: [@weather_post.id])
    Decidim::Bih.komsiluk_notice_public_source_provider = DecidimApp::Bijeljina::KomsilukNoticePublicSource
  end

  def restore_weather_board_review(**changes)
    write_synthetic_weather_region(**{ organization_host: @organization.host,
      source_url: DecidimApp::Bijeljina::CityServiceSources.fetch("weather_warnings").fetch(:source_url) }.merge(changes))
  end

  def teardown_synthetic_weather_board
    if instance_variable_defined?(:@original_weather_source_provider)
      Decidim::Bih.komsiluk_notice_public_source_provider = @original_weather_source_provider
    end
    restore_synthetic_weather_region if @synthetic_weather_region_root
    travel_back
  end
end
