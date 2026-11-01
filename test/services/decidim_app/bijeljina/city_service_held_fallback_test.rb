# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/synthetic_event_source_registry"

module DecidimApp
  module Bijeljina
    # A held outage notice is published to the
    # neighbourhoods it could be placed in when nobody reacts within an hour.
    class CityServiceHeldFallbackTest < ActiveSupport::TestCase
      include SyntheticEventSourceRegistry
      setup do
        @organization = create_organization
        @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
        @placed = Decidim::Bih::LocalArea.create!(organization: @organization, kind: "komsiluk", slug: "komsiluk-placed", name: { "sr" => "Placed" })
        source = CityServiceSources.fetch("water_service")
        check = CityServiceNoticeCollector::SourceCheckResult.new(source_key: "water_service", status: :unreviewed, notices: [], checked_at: Time.current)
        CityServiceSourceCheckStore.new.record(check:, source:)
        CityServiceAutomationPolicy.new(organization: @organization).update!(source_key: "water_service", mode: "automatic", actor: @admin)
        @event = water_event(clauses: ["Izmišljena ulica (Testni grad)", "Nepoznata testna ulica (Testni grad)"], board_slugs: [[@placed.slug], []])
        CityServiceAutomation.new(organization: @organization).evaluate!(@event)
      end

      test "a partly placed water notice stays held for an hour, then reaches the placed neighbourhood only" do
        assert_equal "pending_review", @event.reload.state
        assert_empty CityServiceHeldFallback.new(organization: @organization, now: 30.minutes.from_now).call
        assert_equal "pending_review", @event.reload.state

        published = CityServiceHeldFallback.new(organization: @organization, now: 61.minutes.from_now).call
        assert_equal [@event.id], published.map(&:id)
        assert_equal "board_published", @event.reload.state
        assert_equal [@placed.slug], @event.target_komsiluk_slugs
        assert_equal CityServiceHeldFallback::VERSION, @event.extraction_metadata.dig("automation_publication", "policy_version")
        assert_nil @event.reviewed_by_id
      end

      test "safety notices and notices with no placed neighbourhood still wait for a person" do
        @event.update!(severity: "safety")
        assert_empty CityServiceHeldFallback.new(organization: @organization, now: 2.hours.from_now).call
        @event.update!(severity: "service_outage")
        unplaced = water_event(clauses: ["Nepoznata testna ulica (Testni grad)"], board_slugs: [[]], fingerprint: "unplaced")
        CityServiceHeldFallback.new(organization: @organization, now: 2.hours.from_now).call
        assert_equal "pending_review", unplaced.reload.state
      end

      test "a notice a person already reviewed is left alone" do
        @event.update!(reviewed_at: Time.current, reviewer: @admin)
        assert_empty CityServiceHeldFallback.new(organization: @organization, now: 2.hours.from_now).call
      end

      private

      def water_event(clauses:, board_slugs:, fingerprint: "held")
        url = "https://water.example.invalid/v2/notices/vodosnabdijevanje-za-06-oktobar-2040-god/"
        rows = clauses.zip(board_slugs).map do |evidence, slugs|
          { "evidence" => evidence, "kind" => "street", "status" => slugs.any? ? "resolved" : "unresolved", "board_slugs" => slugs }
        end
        resolved = rows.count { |row| row["status"] == "resolved" }
        coverage = { "status" => if resolved == rows.size
                                   "resolved"
                                 else
                                   (resolved.positive? ? "partial" : "unknown")
end, "complete" => resolved == rows.size,
                     "scope" => "source_named_water_locations", "scope_precision" => "unspecified_street_segment", "board_placement" => "review_required",
                     "water_mixed_coverage_revision" => CityServiceWaterMixedCoverage.new(organization: @organization).revision, "source_content_version" => "v1",
                     "clause_count" => rows.size, "resolved_clause_count" => resolved, "unresolved_clause_count" => rows.size - resolved, "clauses" => rows,
                     "affected_places" => board_slugs.flatten.uniq.map { |slug| { "slug" => slug, "kind" => "komsiluk" } },
                     "unresolved_places" => rows.reject { |row| row["status"] == "resolved" }, "ambiguous_places" => [] }
        CityServiceEvent.create!(organization: @organization, source_key: "water_service", source_label: "Vodovod", source_fingerprint: fingerprint,
                                 source_url: url, event_type: "unplanned_interruption", severity: "service_outage", targeting_level: "unknown",
                                 affected_area_slugs: [], affected_text: clauses.join("; "), title: "Mogući prekidi vode — dio komšiluka",
                                 summary: "Prekid vode može zahvatiti dio komšiluka. #{clauses.join("; ")}",
                                 viber_text: "Prekid vode može zahvatiti dio komšiluka. #{clauses.join("; ")}",
                                 starts_at: 10.minutes.ago, ends_at: 6.hours.from_now, fetched_at: Time.current, state: "pending_review", lifecycle: "scheduled",
                                 parser_version: "fixture", content_version: "v1",
                                 extraction_metadata: { "source_snapshot_complete" => true, "canonical_article_url" => url,
                                                        "water_board_copy" => { "source_content_version" => "v1", "original" => { "title" => "Voda" } },
                                                        "coverage" => coverage, "confidence_by_field" => { "place" => "verified_water_location_geometry" } })
      end
    end
  end
end
