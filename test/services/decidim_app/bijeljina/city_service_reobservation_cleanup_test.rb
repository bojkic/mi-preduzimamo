# frozen_string_literal: true

require "test_helper"

module DecidimApp
  module Bijeljina
    class CityServiceReobservationCleanupTest < ActiveSupport::TestCase
      setup do
        @organization = create_organization
        @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
        @cleanup = CityServiceReobservationCleanup.new(organization: @organization)
      end

      test "a dry run reports the collapse without touching a row" do
        rows = 3.times.map { |index| duplicate(fingerprint: "dup-#{index}") }

        result = @cleanup.call

        assert_equal 1, result.groups
        assert_equal [rows.first.id, rows.second.id], result.collapsed_ids
        assert_equal [rows.third.id], result.kept_ids
        assert(rows.all? { |row| row.reload.pending_review? })
      end

      test "applying supersedes every older row onto the newest" do
        rows = 3.times.map { |index| duplicate(fingerprint: "dup-#{index}") }

        @cleanup.call(apply: true)

        assert_equal([rows.third.id, rows.third.id], rows.first(2).map { |row| row.reload.superseded_by_id })
        assert rows.first(2).all?(&:superseded?)
        assert rows.third.reload.pending_review?
      end

      test "rows whose facts differ are left for the operator" do
        duplicate(fingerprint: "dup-a")
        duplicate(fingerprint: "dup-b", summary: "Drugaciji tekst")

        assert_equal 0, @cleanup.call(apply: true).groups
        assert_equal 2, CityServiceEvent.for_organization(@organization).pending_review.count
      end

      test "a reviewed or published row is never collapsed" do
        kept = duplicate(fingerprint: "dup-reviewed")
        kept.update!(reviewed_at: Time.current, reviewed_by_id: @admin.id)
        duplicate(fingerprint: "dup-published").update!(state: "published")
        duplicate(fingerprint: "dup-open")

        assert_equal 0, @cleanup.call(apply: true).groups
        assert_nil kept.reload.superseded_by_id
      end

      test "different occurrences are never merged" do
        duplicate(fingerprint: "dup-one", occurrence: "occurrence-one")
        duplicate(fingerprint: "dup-two", occurrence: "occurrence-two")

        assert_equal 0, @cleanup.call(apply: true).groups
      end

      private

      def duplicate(fingerprint:, occurrence: "occurrence-shared", summary: "Dvorovi 09:00-12:00")
        CityServiceEvent.create!(
          organization: @organization,
          source_key: "road_conditions",
          source_fingerprint: fingerprint,
          source_occurrence_id: occurrence,
          event_type: "road_closure",
          severity: "service_outage",
          targeting_level: "unknown",
          title: "Saobracajno obavjestenje",
          summary:,
          source_url: "https://example.test/roads",
          parser_version: "test",
          state: "pending_review",
          extraction_metadata: { "source_quotation" => "Zbog radova na mostu." }
        )
      end
    end
  end
end
