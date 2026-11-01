# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/synthetic_event_source_registry"

module DecidimApp
  module Bijeljina
    class CityServiceTypedCheckHealthTest < ActiveSupport::TestCase
      include SyntheticEventSourceRegistry
      test "successful typed evidence retains incomplete extraction health without replacing last good snapshot" do
        organization = create_organization
        source = CityServiceSources.fetch("road_conditions")
        now = Time.current
        notice = CityServiceNoticeCollector::Notice.new(source_key: source.fetch(:key), source_label: source.fetch(:label),
                                                        provider: source.fetch(:provider), title: "Saobraćaj testne zajednice", body: "Privremena obustava",
                                                        url: source.fetch(:source_url),
                                                        fingerprint: "typed-1", fetched_at: now,
                                                        metadata: { "kind" => "road_condition", "affected_area_text" => "Testna zajednica",
                                                                    "source_quotation" => "Privremena obustava" })
        good = CityServiceNoticeCollector::SourceCheckResult.new(source_key: source.fetch(:key), status: :ok, notices: [notice], checked_at: now)
        store = CityServiceSourceCheckStore.new
        store.record(check: good, source:, attempted_at: now)
        snapshot = DecidimApp::CityServiceSourceSnapshot.find_by!(source_key: source.fetch(:key))
        previous_good = snapshot.last_good_payload.deep_dup
        fallback = CityServiceNoticeCollector::SourceCheckResult.new(source_key: source.fetch(:key), status: :unreviewed,
                                                                     notices: [], checked_at: now, error_code: :partial_source_coverage)
        scraper = CityServiceSourceScrape.new(organization:, now:)
        check = CityServiceNoticeCollector.stub(:check, [good]) do
          scraper.send(:typed_source_check, source, response: { body: "partial document", http_status: 200 }, fallback:)
        end
        assert_equal :partial_source_coverage, check.error_code
        assert_equal :unreviewed, check.status
        assert_equal notice.metadata, check.notices.sole.metadata
        store.record(check:, source:, attempted_at: now + 1.minute)
        snapshot.reload
        assert_equal "partial_source_coverage", snapshot.check_payload["error_code"]
        assert_equal "partial", snapshot.check_payload.dig("collection", "outcome")
        assert_equal false, snapshot.check_payload.dig("collection", "complete")
        assert_equal notice.metadata.stringify_keys, snapshot.check_payload.dig("notices", 0, "metadata")
        assert_equal previous_good, snapshot.last_good_payload
        assert_equal now.to_i, snapshot.last_success_at.to_i
      end
    end
  end
end
