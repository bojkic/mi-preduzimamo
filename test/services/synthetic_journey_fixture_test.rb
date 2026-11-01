# frozen_string_literal: true
require "test_helper"
require_relative "../support/synthetic_journey_scenarios"

class SyntheticJourneyFixtureTest < ActiveSupport::TestCase
  include SyntheticJourneyScenarios

  def test_toy_journey_street_and_transport_configuration_are_restored
    host = DecidimApp::Bijeljina
    owner = host::LocalStreetRegistry
    path = owner::DATA_PATH
    sources = host::CityServiceSources::SOURCES
    caches = %i(@stamp @dataset @name_index).map { |name| [name, owner.instance_variable_defined?(name), owner.instance_variable_get(name)] }
    stops = ENV["MI_TRANSPORT_STOPS_PATH"]
    2.times do
      begin
        install_synthetic_journey_scenarios
        assert owner::DATA_PATH.file?
        assert owner.dataset.fetch("features").any?
      ensure
        restore_synthetic_journey_scenarios
      end
      assert_same path, owner::DATA_PATH
      assert_same sources, host::CityServiceSources::SOURCES
      caches.each do |name, present, value|
        assert_equal present, owner.instance_variable_defined?(name)
        assert_same value, owner.instance_variable_get(name) if present
      end
      if stops.nil?
        assert_nil ENV["MI_TRANSPORT_STOPS_PATH"]
      else
        assert_equal stops, ENV["MI_TRANSPORT_STOPS_PATH"]
      end
    end
  end
end
