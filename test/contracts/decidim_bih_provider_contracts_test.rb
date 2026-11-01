# frozen_string_literal: true

require "test_helper"

class DecidimBihProviderContractsTest < ActiveSupport::TestCase
  setup do
    @organization = create_organization
    @prior_city_preview_provider = Decidim::Bih.city_data_preview_provider
    # Wire the real optional host adapter explicitly; defaults stay disabled.
    Decidim::Bih.city_data_preview_provider = DecidimApp::Bijeljina::CityDataPreview
  end

  teardown do
    Decidim::Bih.city_data_preview_provider = @prior_city_preview_provider
  end

  test "Bijeljina host providers satisfy local engine contracts without live calls" do
    with_memory_cache do
      assert Decidim::Bih::ProviderContracts.validate_donations_provider!(DecidimApp::Bijeljina::Donations)
      assert Decidim::Bih::ProviderContracts.validate_city_data_freshness_provider!(
        DecidimApp::Bijeljina::CityDataFreshness,
        organization: @organization
      )
      assert Decidim::Bih::ProviderContracts.validate_city_data_preview_provider!(
        Decidim::Bih.city_data_preview_provider,
        organization: @organization,
        locale: :sr
      )
      assert Decidim::Bih::ProviderContracts.validate_admin_navigation_provider!(
        Decidim::Bih.admin_navigation_provider,
        view_context: Object.new
      )
      assert Decidim::Bih::ProviderContracts.validate_concierge_resolver!(
        -> { DecidimApp::Bijeljina::WebConcierge }
      )
    end
  end

  test "external provider clients expose method contracts without credentials" do
    assert Decidim::Bih::ProviderContracts.validate_methods!("geocoder_client", Decidim::Bih::Geo::Geocoder)
    assert Decidim::Bih::ProviderContracts.validate_methods!(
      "infobip_client",
      Decidim::Bih::Infobip::Client.new(base_url: nil, api_key: nil)
    )
    assert Decidim::Bih::ProviderContracts.validate_methods!(
      "gemini_client",
      Decidim::Bih::Ai::GeminiClient.new(api_key: nil)
    )
    assert Decidim::Bih::ProviderContracts.validate_methods!(
      "odoo_client",
      Decidim::Bih::Odoo::Client.new(base_url: nil, db: nil, login: nil, api_key: nil)
    )
    assert Decidim::Bih::ProviderContracts.validate_methods!(
      "sistem48_forwarder",
      Decidim::Bih::Sistem48::Forwarder.new
    )
    assert Decidim::Bih::ProviderContracts.validate_methods!(
      "sistem48_archive",
      Decidim::Bih::Sistem48::ArchiveScraper.new(archive_url: nil)
    )
  end

  test "host contract manifest includes provider contracts without provider secrets" do
    manifest = Decidim::Bih.host_contract_manifest
    provider_ids = manifest.fetch(:required_provider_contracts).map { |contract| contract.fetch(:id) }
    serialized = JSON.generate(manifest)

    assert_includes provider_ids, "donations_provider"
    assert_includes provider_ids, "city_data_freshness_provider"
    assert_includes provider_ids, "city_data_preview_provider"
    assert_includes provider_ids, "admin_navigation_provider"
    assert_includes provider_ids, "infobip_client"
    assert_not_includes serialized, "INFOBIP_API_KEY"
    assert_not_includes serialized, "ODOO_API_KEY"
    assert_not_includes serialized, "GEMINI_API_KEY"
  end

  private

  def with_memory_cache
    previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    yield
  ensure
    Rails.cache = previous_cache
  end
end
