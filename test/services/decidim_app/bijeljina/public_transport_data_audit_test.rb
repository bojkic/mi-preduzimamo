# frozen_string_literal: true

require "test_helper"
require "ostruct"

module DecidimApp
  module Bijeljina
    class PublicTransportDataAuditTest < ActiveSupport::TestCase
      test "summarizes timetable stop coordinate coverage and line references" do
        audit = PublicTransportDataAudit.call(
          notices: [],
          timetable: FakeTimetable.new(
            [
              route(
                "P1",
                "P1 Nova AS-Centar-Dvorovi",
                [
                  stop("Bijeljina (NAS)", latitude: 44.765174, longitude: 19.212140, accuracy: "provided", source: "operator"),
                  stop("Dvorovi (Globus)", latitude: 44.805824, longitude: 19.259981, accuracy: "assumed", source: "estimate"),
                  stop("Trnjaci (ulaz)")
                ]
              )
            ]
          ),
          registry_entries: [
            registry("Bijeljina (NAS)", 44.765174, 19.212140),
            registry("Dvorovi (Globus)", 44.805824, 19.259981, accuracy: "assumed"),
            registry("Unused stop", 44.8, 19.2),
            registry("Alias stop", 44.765174, 19.212140)
          ]
        )

        assert_equal 1, audit.summary.fetch(:routes)
        assert_equal 1, audit.summary.fetch(:directions)
        assert_equal 3, audit.summary.fetch(:stop_instances)
        assert_equal 3, audit.summary.fetch(:unique_stops)
        assert_equal 1, audit.summary.fetch(:provided_or_verified_coordinates)
        assert_equal 1, audit.summary.fetch(:assumed_coordinates)
        assert_equal 1, audit.summary.fetch(:missing_coordinates)
        assert_equal 4, audit.summary.fetch(:registry_entries)
        assert_equal 2, audit.summary.fetch(:unused_registry_entries)

        missing = issue(audit, "missing_coordinates")
        assert_equal "warn", missing.status
        assert_includes missing.detail, "Trnjaci (ulaz)"

        assumed = issue(audit, "assumed_coordinates")
        assert_equal "warn", assumed.status
        assert_includes assumed.detail, "Dvorovi (Globus)"

        priority = issue(audit, "priority_coordinate_gaps")
        assert_equal "warn", priority.status
        assert_includes priority.detail, "Dvorovi (Globus) (assumed; P1)"
        assert_includes priority.detail, "Trnjaci (ulaz) (missing; P1)"

        duplicates = issue(audit, "duplicate_registry_coordinates")
        assert_equal "warn", duplicates.status
        assert_includes duplicates.detail, "Bijeljina (NAS)"
        assert_includes duplicates.detail, "Alias stop"

        nas = audit.stops.find { |row| row.label == "Bijeljina (NAS)" }
        assert_equal "44.765174,19.212140", nas.coordinate_text
        assert_equal "ok", nas.status
        assert_equal ["P1 P1 Nova AS-Centar-Dvorovi"], nas.line_refs
        assert_equal ["P1:A"], nas.direction_refs
      end

      test "flags duplicate and invalid registry entries" do
        audit = PublicTransportDataAudit.call(
          notices: [],
          timetable: FakeTimetable.new([]),
          registry_entries: [
            registry("Bijeljina (NAS)", 44.765174, 19.212140),
            registry("Bijeljina (NAS)", 44.765175, 19.212141),
            { label: "", latitude: 99, longitude: "bad" }
          ]
        )

        duplicate_labels = issue(audit, "duplicate_registry_labels")
        assert_equal "fail", duplicate_labels.status
        assert_includes duplicate_labels.detail, "Bijeljina (NAS)"

        invalid = issue(audit, "invalid_registry_entries")
        assert_equal "fail", invalid.status
        assert_includes invalid.detail, "missing_label"
        assert_includes invalid.detail, "invalid_latitude"
        assert_includes invalid.detail, "invalid_longitude"
      end

      test "does not warn for documented same-coordinate aliases" do
        audit = PublicTransportDataAudit.call(
          notices: [],
          timetable: FakeTimetable.new([]),
          registry_entries: [
            registry("Bijeljina (AMD)", 44.760756, 19.223864),
            registry("Bijeljina (AMK)", 44.760756, 19.223864, same_as: "Bijeljina (AMD)")
          ]
        )

        duplicates = issue(audit, "duplicate_registry_coordinates")
        assert_equal "ok", duplicates.status
        assert_equal 0, duplicates.value
      end

      private

      class FakeTimetable
        def initialize(routes)
          @routes = routes
        end

        def matrix(notices:)
          notices
          @routes
        end
      end

      def issue(audit, metric)
        audit.issues.find { |row| row.metric == metric } || flunk("missing issue #{metric}")
      end

      def registry(label, latitude, longitude, accuracy: "provided", same_as: nil)
        { label:, latitude:, longitude:, accuracy:, same_as:, source: "test registry" }.compact
      end

      def route(code, title, stops)
        PublicTransportTimetable::Route.new(
          code:,
          title:,
          directions: [
            PublicTransportTimetable::Direction.new(
              route: OpenStruct.new(title:, url: "https://source.example/#{code.downcase}.pdf"),
              name: "A",
              stops:
            )
          ],
          source_url: "https://source.example/#{code.downcase}.pdf"
        )
      end

      def stop(label, latitude: nil, longitude: nil, accuracy: nil, source: nil)
        PublicTransportTimetable::StopRow.new(
          label:,
          normalized_label: Decidim::Bih::Text.fold(label),
          times: ["10:00"],
          index: 0,
          latitude:,
          longitude:,
          coordinates_accuracy: accuracy,
          coordinates_source: source
        )
      end
    end
  end
end
