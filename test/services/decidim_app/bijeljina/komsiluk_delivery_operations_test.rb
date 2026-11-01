# frozen_string_literal: true

require "test_helper"

module DecidimApp
  module Bijeljina
    class KomsilukDeliveryOperationsTest < ActiveSupport::TestCase
      setup do
        @organization = create_organization
        @actor = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
        @member = FactoryBot.create(:user, :confirmed, organization: @organization)
      end

      test "source summary uses canonical workflow and requires source management permission" do
        failed = event("failed", state: "failed")
        expired = event("expired", starts_at: 2.hours.ago, ends_at: 1.hour.ago)
        CityServiceEffect.create!(event: failed, kind: "board", identity: "fixture-operations", payload: {},
                                  error_code: "PrivateProviderError", created_at: 20.minutes.ago, last_attempt_at: 20.minutes.ago)
        other = create_organization
        event("other", organization: other, state: "failed")
        groups = KomsilukDeliveryOperations.call(organization: @organization, actor: @actor).index_by { |group| group[:kind] }
        assert_equal 1, groups.fetch("source_failed")[:count]
        assert_equal 1, groups.fetch("source_stalled")[:count]
        assert_not_includes groups.to_json, "PrivateProviderError"
        assert_equal [failed.id], (groups.fetch("source_failed")[:links].map { |link| link[:id] })
        assert_includes groups.fetch("source_failed")[:links].sole[:path], "event_id=#{failed.id}"
        assert_equal [expired.id], (groups.fetch("source_expired")[:links].map { |link| link[:id] })
        assert_includes groups.fetch("source_expired")[:links].sole[:path], "tab=done"
        assert_empty KomsilukDeliveryOperations.call(organization: @organization, actor: @member)
        assert_empty KomsilukDeliveryOperations.call(organization: other, actor: @actor)
      end

      private

      def event(fingerprint, **attributes)
        CityServiceEvent.create!({ organization: @organization, source_key: "electricity_outages", source_label: "Služba",
                                   source_fingerprint: fingerprint, source_url: "https://example.test/#{fingerprint}",
                                   event_type: "planned_outage", severity: "service_outage", targeting_level: "unknown",
                                   affected_area_slugs: [], affected_text: "Nepotvrđeno područje", title: "Obavještenje", summary: "Sažetak",
                                   starts_at: 1.hour.from_now, ends_at: 3.hours.from_now, state: "pending_review", lifecycle: "scheduled",
                                   parser_version: "fixture", content_version: "v1", extraction_metadata: {} }.merge(attributes))
      end
    end
  end
end
