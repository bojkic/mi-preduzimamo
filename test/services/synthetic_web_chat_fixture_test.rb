# frozen_string_literal: true
require "test_helper"
require_relative "../support/synthetic_web_chat_data"
require_relative "../support/native_milica_provider"

class SyntheticWebChatFixtureTest < ActiveSupport::TestCase
  include SyntheticWebChatData
  include NativeMilicaProvider

  def test_combined_fixture_restores_constants_caches_and_stop_configuration
    host = DecidimApp::Bijeljina
    owners = [host::CityServiceSources, host::CityServicesData, host::ParkingZones, host::DirectoryServiceFacts,
              host::CivicDomainFacts, host::WasteSchedule, host::ReviewedTransportTimetables, host::PublicTransportPlaces]
    constants = owners.flat_map { |owner| owner.constants(false).map { |name| [owner, name, owner.const_get(name, false)] } }
    cache_keys = [[host::CityDirectory, :@directory], [host::ParkingZones, :@default], [host::DirectoryServiceFacts, :@data],
                  [host::ServiceProcedures, :@all], [host::CitizenReferenceCatalog, :@default], [host::CivicDomainFacts, :@cache],
                  [host::WasteSchedule, :@default], *%i(@manifest @stop_locations @stop_location_index).map { |name| [host::ReviewedTransportTimetables, name] }]
    caches = cache_keys.map { |owner, name| [owner, name, owner.instance_variable_defined?(name), owner.instance_variable_get(name)] }
    stops = ENV["MI_TRANSPORT_STOPS_PATH"]
    2.times do
      begin
        install_synthetic_web_chat_data
        assert host::CityDirectory.find(:policija)
        assert host::ReviewedTransportTimetables.manifest.fetch("routes").any?
        assert_equal "Izmišljeni parking", host::CityDirectory.find(:parking).fetch(:title)
      ensure
        restore_synthetic_web_chat_data
      end
      constants.each { |owner, name, value| assert_same value, owner.const_get(name, false), "#{owner}::#{name}" }
      caches.each do |owner, name, present, value|
        assert_equal present, owner.instance_variable_defined?(name), "#{owner} #{name} presence"
        assert_same value, owner.instance_variable_get(name), "#{owner} #{name} value" if present
      end
      assert_equal stops, ENV["MI_TRANSPORT_STOPS_PATH"]
    end
  end

  def test_native_provider_opt_in_restores_the_original_resolver
    previous = Decidim::Bih.concierge_resolver
    begin
      install_native_provider
      assert_instance_of Proc, Decidim::Bih.concierge_resolver
      assert_same DecidimApp::Bijeljina::WebConcierge, Decidim::Bih.concierge_resolver.call
    ensure
      uninstall_native_provider
    end
    assert_same previous, Decidim::Bih.concierge_resolver
  end
end
