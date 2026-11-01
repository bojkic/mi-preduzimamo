# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/synthetic_event_source_registry"

module DecidimApp
  module Bijeljina
    class CityServiceEvidenceConflictTest < ActiveSupport::TestCase
      include SyntheticEventSourceRegistry
      setup do
        @organization = create_organization
        @now = Time.utc(2040, 9, 9, 8)
        @area = Decidim::Bih::LocalArea.create!(organization: @organization, kind: "mz", slug: "mz-synthetic-field", name: { "sr" => "MZ Izmišljeno polje" }, boundary: {})
        @feed = CityServiceEventFeed.new(organization: @organization)
      end

      test "explicit occurrence revisions survive the twenty event query limit" do
        21.times { |index| event("earlier-#{index}", starts_at: @now - 2.hours + index.minutes) }
        pair = [event("revision-a", source_occurrence_id: "operator-outage-123"),
                event("revision-b", source_occurrence_id: "operator-outage-123", ends_at: @now + 3.hours)]

        assert_conflict query, pair
      end

      test "a collected pending review revision remains visible as conflicting unconfirmed evidence" do
        pair = [event("published", source_occurrence_id: "shared-provider-occurrence"),
                event("pending", source_occurrence_id: "shared-provider-occurrence", state: "pending_review", ends_at: @now + 3.hours)]
        assert_conflict query, pair
      end

      test "opposing whole area lifecycle assertions with exactly equal minute bounds conflict" do
        pair = [event("planned"), event("restored", lifecycle: "resolved", event_type: "restoration_update")]

        assert_conflict query, pair
      end

      test "opposing citywide assertions with exact bounds conflict without inventing local areas" do
        pair = [event("city-planned", targeting_level: "citywide", affected_area_slugs: []),
                event("city-restored", targeting_level: "citywide", affected_area_slugs: [], lifecycle: "resolved")]

        assert_conflict query, pair
      end

      {
        "another tenant" => -> { { organization: create_organization } },
        "dismissed notice" => -> { { state: "dismissed" } },
        "cancelled lifecycle" => -> { { lifecycle: "cancelled" } },
        "superseded lifecycle" => -> { { lifecycle: "superseded" } },
        "another area" => lambda {
          { affected_area_slugs: ["mz-janja"],
            extraction_metadata: metadata.merge("coverage" => { "status" => "resolved", "affected_places" => [{ "slug" => "mz-janja", "relation" => "whole" }] }) }
        },
        "outside requested time" => -> { { starts_at: @now + 2.days, ends_at: @now + 2.days + 1.hour } },
        "another source" => -> { { source_key: "water_service", event_type: "planned_interruption" } }
      }.each do |label, attributes|
        test "occurrence conflict excludes #{label} before detection" do
          visible = event("visible", source_occurrence_id: "shared-provider-occurrence")
          event("excluded", source_occurrence_id: "shared-provider-occurrence", ends_at: @now + 3.hours, **instance_exec(&attributes))

          result = query
          assert_equal :ok, result.status
          assert_equal [visible.id], result.events.map(&:id)
          assert_nil result.error_code
        end
      end

      {
        "part of an area" => -> { { extraction_metadata: metadata(relation: "partial") } },
        "missing whole-area relation" => -> { { extraction_metadata: metadata.merge("coverage" => { "status" => "resolved", "affected_places" => [{ "slug" => @area.slug }] }) } },
        "unknown coverage" => -> { { extraction_metadata: metadata.merge("coverage" => { "status" => "unknown" }) } },
        "date only precision" => -> { { extraction_metadata: metadata.merge("temporal_precision" => "day") } },
        "merely overlapping bounds" => -> { { starts_at: @now + 1.minute } },
        "the same lifecycle" => -> { { lifecycle: "scheduled" } }
      }.each do |label, attributes|
        test "similar articles do not conflict for #{label}" do
          first = event("first", source_occurrence_id: "")
          second = event("second", lifecycle: "resolved", source_occurrence_id: nil, **instance_exec(&attributes))

          result = query
          assert_equal :ok, result.status
          assert_equal [first.id, second.id].sort, result.events.map(&:id).sort
        end
      end

      test "notification overlap does not assert the same whole affected area" do
        first = event("local-planned")
        coverage = metadata
        coverage.fetch("coverage")["notification_candidates"] = [{ "slug" => @area.slug }]
        second = event("neighbor-restored", affected_area_slugs: ["komsiluk-99"], lifecycle: "resolved", extraction_metadata: coverage)

        result = query
        assert_equal :ok, result.status
        assert_equal [first.id, second.id], result.events.map(&:id)
      end

      test "service and neighborhood ReadPort retain both conflicting citations without fetching a source" do
        pair = [event("provider-planned"), event("provider-restored", lifecycle: "resolved")]
        checker = Object.new
        checker.define_singleton_method(:check) { |**| raise "Conflict must not trigger provider fallback" }
        port = Milica::ReadPort.new(organization: @organization, event_feed: @feed, source_checker: checker)

        %w(electricity neighborhood).each do |topic|
          result = port.call(action: "ask_information", topic:, entities: { "area_slug" => @area.slug }, context:, locale: "en")
          assert_equal "unreviewed", result.status, topic
          assert_equal(pair.map { |record| "service_event:#{record.id}" }, result.facts.map { |fact| fact.fetch("id") })
          assert_equal(pair.map(&:source_url), result.facts.map { |fact| fact.fetch("source_url") })
          assert_equal(%w(scheduled resolved), result.facts.map { |fact| fact.fetch("lifecycle") })
          assert_equal ["conflicting_current_facts"], result.warnings
        end
      end

      test "measurement conflict beyond eight candidates retains both readings and source evidence" do
        rows = 9.times.map { |index| reading(station: "Stanica #{index}") }
        rows.push(reading(station: "Izmišljeni senzor A", value: 17), reading(station: "Izmišljeni senzor A", value: 84))
        result = measurement_read(rows)

        assert_equal "unreviewed", result.fetch(:status)
        assert_equal([17, 84], result.fetch(:facts).map { |fact| fact.fetch("value") })
        assert_includes result.fetch(:warnings), "conflicting_current_facts"
        assert_equal 2, result.fetch(:facts).map { |fact| fact.fetch("id") }.uniq.size
        assert(result.fetch(:facts).all? { |fact| fact.fetch("source_url") == CityServiceSources.fetch("water_levels").fetch(:source_url) })
      end

      test "measurement station and day filtering precede conflict detection" do
        conflicting = [reading(station: "Izmišljeni senzor A", value: 17), reading(station: "Izmišljeni senzor A", value: 84)]
        clean = reading(station: "Izmišljeni senzor B", value: 11)
        station = measurement_read([*conflicting, clean], entities: { "area_query" => "Izmišljeni senzor B" })
        assert_equal "ok", station.fetch(:status)
        assert_equal([11], station.fetch(:facts).map { |fact| fact.fetch("value") })
        assert_not_includes station.fetch(:warnings), "conflicting_current_facts"

        historical = conflicting.map { |row| row.merge("observed_at" => (@now - 1.day).iso8601) }
        dated = measurement_read([*historical, clean], entities: { "date" => "2040-09-09" })
        assert_equal "ok", dated.fetch(:status)
        assert_equal [11], (dated.fetch(:facts).map { |fact| fact.fetch("value") })
        assert_not_includes dated.fetch(:warnings), "conflicting_current_facts"

        future = conflicting.map { |row| row.merge("observed_at" => (@now + 1.day).iso8601) }
        current = measurement_read([*future, clean])
        assert_equal "ok", current.fetch(:status)
        assert_equal([11], current.fetch(:facts).map { |fact| fact.fetch("value") })
        assert_not_includes current.fetch(:warnings), "conflicting_current_facts"
      end

      test "measurement values differing at other times stations units or pollutants are not competing observations" do
        baseline = reading(station: "Izmišljeni senzor A").merge("kind" => "water_level_observation")
        %w(station unit pollutant kind observed_at).each do |key|
          other = baseline.merge("value" => 50, key => "another #{key}")
          assert_empty SourceMeasurement.conflicting_observations([baseline, other]), key
        end
        assert_empty SourceMeasurement.conflicting_observations([baseline, baseline.merge("value" => 23.0)])
        assert_empty SourceMeasurement.conflicting_observations([baseline.except("observed_at"), baseline.except("observed_at").merge("value" => 50)])
      end

      private

      def query
        @feed.query(topic: "electricity", area_identifiers: [@area.slug], starts_at: @now - 3.hours, ends_at: @now + 12.hours, deadline: nil)
      end

      def assert_conflict(result, pair)
        assert_equal :conflict, result.status
        assert_equal :conflicting_current_facts, result.error_code
        assert_equal pair.map(&:id), result.events.map(&:id)
      end

      def metadata(relation: "whole")
        { "temporal_precision" => "minute", "coverage" => { "status" => "resolved", "affected_places" => [{ "slug" => @area.slug, "relation" => relation }] } }
      end

      def event(fingerprint, **attributes)
        source = CityServiceSources.fetch(attributes.fetch(:source_key, "electricity_outages"))
        CityServiceEvent.create!(organization: @organization, source_key: "electricity_outages", source_label: source.fetch(:provider),
                                 source_fingerprint: fingerprint, source_url: "#{source.fetch(:source_url)}#evidence-#{fingerprint}",
                                 event_type: "planned_outage", severity: "service_outage", targeting_level: "mz", affected_area_slugs: [@area.slug],
                                 title: "Planirano isključenje struje", summary: "Objavljena tvrdnja #{fingerprint}", starts_at: @now, ends_at: @now + 2.hours,
                                 fetched_at: @now - 1.minute, state: "published", lifecycle: "scheduled", parser_version: "test", extraction_metadata: metadata, **attributes)
      end

      def context
        Decidim::Bih::Concierge::Dialogue::Contracts::TrustedContext.new(
          organization_id: @organization.id, conversation_key: "a" * 64, capabilities: ["public_reads"], now: @now
        )
      end

      def reading(station:, value: 23)
        { "station" => station, "value" => value, "unit" => "cm", "observed_at" => (@now - 1.hour).iso8601 }
      end

      def measurement_read(rows, entities: {})
        source = CityServiceSources.fetch("water_levels")
        notice = CityServiceNoticeCollector::Notice.new(source_key: "water_levels", title: "Public reading", body: "Public data",
                                                        provider: source.fetch(:provider), url: source.fetch(:source_url), fingerprint: "measurements",
                                                        fetched_at: @now, metadata: { "readings" => rows })
        check = CityServiceNoticeCollector::SourceCheckResult.new(source_key: "water_levels", status: :ok, notices: [notice], checked_at: @now)
        checker = Object.new
        checker.define_singleton_method(:check) { |**| [check] }
        Milica::SourceRead.new(source_checker: checker).call(topic: "water_levels", context:, locale: "en", entities:)
      end
    end
  end
end
