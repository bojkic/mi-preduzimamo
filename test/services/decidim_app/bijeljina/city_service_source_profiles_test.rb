# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/synthetic_event_source_registry"

module DecidimApp
  module Bijeljina
    class CityServiceSourceProfilesTest < ActiveSupport::TestCase
      include SyntheticEventSourceRegistry
      test "every configured source has a distinct contract and descriptive edits preserve snapshots" do
        assert_equal CityServiceSources.all.map { |source| source[:key] }.sort, CityServiceSourceProfiles::PROFILES.keys.sort
        source = CityServiceSources.fetch("water_service")
        version = CityServiceSourceCheckStore.new.version_for(source)
        profile = CityServiceSourceProfiles.fetch("water_service")
        profile[:claims] << "unsupported"
        assert_not_includes CityServiceSourceProfiles.fetch("water_service")[:claims], "unsupported"
        assert_equal version, CityServiceSourceCheckStore.new.version_for(source)
        assert_not_equal version, CityServiceSourceCheckStore.new.version_for(source.merge(source_url: "https://example.org/new"))
        assert_raises(KeyError) { CityServiceSourceProfiles.fetch("sava_his_candidate") }
      end

      test "capabilities expose claims without treating configured readers as ready records" do
        row = CityServiceCapabilities.rows.find { |item| item[:source_key] == "water_service" }
        assert_includes row.dig(:semantic_profile, :unknowns), "bill"
        assert_equal "not_checked", row.dig(:evidence_health, :status)
        assert_equal "requires_claim_time_place_and_review", row.dig(:evidence_health, :answer_readiness)
      end

      test "clock and warning parser identities invalidate only their own source snapshots" do
        store = CityServiceSourceCheckStore.new
        %w(water_levels weather_warnings).each do |key|
          source = CityServiceSources.fetch(key)
          old_identity = Digest::SHA256.hexdigest(JSON.generate([CityServiceSourceCheckStore::PARSER_VERSION, source]))
          assert_not_equal old_identity, store.version_for(source)
        end
        source = CityServiceSources.fetch("air_quality_realtime")
        assert_equal Digest::SHA256.hexdigest(JSON.generate([CityServiceSourceCheckStore::PARSER_VERSION, source])), store.version_for(source)
      end
    end
  end
end
