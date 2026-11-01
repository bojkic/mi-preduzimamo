# frozen_string_literal: true

require "yaml"

module DecidimApp
  module Bijeljina
    # Read-only quality report for the Bijeljina public transport timetable
    # matrix and local stop-coordinate registry.
    class PublicTransportDataAudit
      DEFAULT_REGISTRY_PATH = PublicTransportTimetable::STOP_REGISTRY_PATH
      COORDINATE_PRECISION = 6

      RegistryEntry = Struct.new(
        :label,
        :normalized_label,
        :latitude,
        :longitude,
        :accuracy,
        :source,
        :same_as,
        :errors,
        keyword_init: true
      )

      Issue = Struct.new(:metric, :value, :status, :detail, keyword_init: true)

      Stop = Struct.new(
        :label,
        :latitude,
        :longitude,
        :accuracy,
        :source,
        :line_refs,
        :direction_refs,
        :status,
        keyword_init: true
      ) do
        def coordinate_text
          return "missing" if latitude.nil? || longitude.nil?

          "#{format("%.6f", latitude)},#{format("%.6f", longitude)}"
        end
      end

      Result = Struct.new(:summary, :issues, :stops, keyword_init: true) do
        def warning?
          issues.any? { |issue| %w(warn fail).include?(issue.status.to_s) } ||
            stops.any? { |stop| %w(warn fail).include?(stop.status.to_s) }
        end
      end

      def self.call(...)
        new(...).call
      end

      def initialize(notices:, timetable: nil, registry_path: nil, registry_entries: nil)
        @notices = notices
        @timetable = timetable || PublicTransportTimetable.new
        @registry_path = registry_path || default_registry_path
        @raw_registry_entries = registry_entries
        @registry_load_error = nil
      end

      def call
        routes = timetable.matrix(notices:)
        registry = normalized_registry_entries
        stops = stop_rows(routes)

        Result.new(
          summary: summary(routes, stops, registry),
          issues: issues(stops, registry, routes),
          stops:
        )
      end

      private

      attr_reader :notices, :timetable, :registry_path, :raw_registry_entries

      def summary(routes, stops, registry)
        {
          routes: routes.size,
          directions: routes.sum { |route| route.directions.size },
          stop_instances: routes.sum { |route| route.directions.sum { |direction| direction.stops.size } },
          unique_stops: stops.size,
          provided_or_verified_coordinates: stops.count { |stop| %w(provided verified).include?(stop.accuracy.to_s) },
          assumed_coordinates: stops.count { |stop| stop.accuracy == "assumed" },
          missing_coordinates: stops.count { |stop| stop.latitude.nil? || stop.longitude.nil? },
          registry_entries: registry.size,
          invalid_registry_entries: registry.count { |entry| entry.errors.any? },
          unused_registry_entries: unused_registry_entries(stops, registry).size
        }
      end

      def issues(stops, registry, routes)
        [
          registry_load_issue,
          count_issue("missing_coordinates", missing_coordinate_stops(stops), "warn"),
          count_issue("assumed_coordinates", assumed_coordinate_stops(stops), "warn"),
          priority_coordinate_gap_issue(stops),
          count_issue("unused_registry_entries", unused_registry_entries(stops, registry), "warn"),
          duplicate_label_issue(registry),
          invalid_registry_issue(registry),
          duplicate_coordinate_issue(registry),
          place_mapping_issue(stops, routes)
        ].compact
      end

      def place_mapping_issue(stops, routes)
        reviewed_codes = ReviewedTransportTimetables.manifest.fetch("routes").map { |entry| entry.fetch("code") }.sort
        return unless routes.map(&:code).sort == reviewed_codes

        labels = stops.map(&:label)
        entries = PublicTransportPlaces.entries
        problems = entries.flat_map do |entry|
          issues = []
          members = entry.fetch("member_labels")
          issues << "#{entry.fetch('id')}: default not a member" unless members.include?(entry.fetch("default_label"))
          issues << "#{entry.fetch('id')}: default not in timetable" unless labels.include?(entry.fetch("default_label"))
          missing = members - labels
          issues << "#{entry.fetch('id')}: orphaned #{missing.join(', ')}" if missing.any?
          issues
        end
        duplicates = entries.flat_map { |entry| [entry.fetch("name"), *entry.fetch("aliases")].map { |name| [name.downcase, entry.fetch("id")] } }
                            .group_by(&:first).select { |_name, rows| rows.map(&:last).uniq.size > 1 }
        problems.concat(duplicates.keys.map { |name| "duplicate place alias #{name}" })
        Issue.new(metric: "place_stop_mappings", value: problems.size, status: problems.empty? ? "ok" : "fail", detail: problems.first(30).join("; "))
      end

      def registry_load_issue
        return nil unless @registry_load_error

        Issue.new(
          metric: "registry_load",
          value: "failed",
          status: "fail",
          detail: "#{@registry_load_error.class}: #{@registry_load_error.message}"
        )
      end

      def count_issue(metric, rows, warning_status)
        status = rows.empty? ? "ok" : warning_status
        Issue.new(metric:, value: rows.size, status:, detail: labels_detail(rows))
      end

      def duplicate_label_issue(registry)
        duplicate_labels = registry
                           .group_by(&:normalized_label)
                           .select { |label, rows| label.present? && rows.size > 1 }
                           .values
        Issue.new(
          metric: "duplicate_registry_labels",
          value: duplicate_labels.size,
          status: duplicate_labels.empty? ? "ok" : "fail",
          detail: duplicate_labels.map { |rows| rows.map(&:label).join(" / ") }.join("; ")
        )
      end

      def invalid_registry_issue(registry)
        invalid = registry.select { |entry| entry.errors.any? }
        Issue.new(
          metric: "invalid_registry_entries",
          value: invalid.size,
          status: invalid.empty? ? "ok" : "fail",
          detail: invalid.map { |entry| "#{entry.label || "(blank)"}: #{entry.errors.join(",")}" }.join("; ")
        )
      end

      def duplicate_coordinate_issue(registry)
        duplicate_coordinates = registry
                                .select { |entry| entry.latitude && entry.longitude }
                                .group_by { |entry| coordinate_key(entry.latitude, entry.longitude) }
                                .select { |_coordinate, rows| rows.size > 1 }
                                .reject { |_coordinate, rows| documented_coordinate_alias_group?(rows) }
        Issue.new(
          metric: "duplicate_registry_coordinates",
          value: duplicate_coordinates.size,
          status: duplicate_coordinates.empty? ? "ok" : "warn",
          detail: duplicate_coordinates.map { |coordinate, rows| "#{coordinate}: #{rows.map(&:label).join(" / ")}" }.join("; ")
        )
      end

      def documented_coordinate_alias_group?(rows)
        alias_rows = rows.select { |entry| entry.same_as.present? }
        return false if alias_rows.empty?

        canonical_labels = rows.reject { |entry| entry.same_as.present? }.map(&:label)
        return false if canonical_labels.empty?

        alias_rows.all? do |entry|
          entry.same_as.blank? || canonical_labels.include?(entry.same_as)
        end
      end

      def priority_coordinate_gap_issue(stops)
        gaps = stops
               .select { |stop| stop.status == "warn" }
               .sort_by { |stop| [-stop.line_refs.size, normalized_label(stop.label)] }
        Issue.new(
          metric: "priority_coordinate_gaps",
          value: gaps.size,
          status: gaps.empty? ? "ok" : "warn",
          detail: gaps.first(30).map { |stop| priority_gap_detail(stop) }.join("; ")
        )
      end

      def priority_gap_detail(stop)
        line_codes = stop.line_refs.map { |line| line.split.first }.uniq.join(",")
        "#{stop.label} (#{stop.accuracy || "missing"}; #{line_codes})"
      end

      def missing_coordinate_stops(stops)
        stops.select { |stop| stop.latitude.nil? || stop.longitude.nil? }
      end

      def assumed_coordinate_stops(stops)
        stops.select { |stop| stop.accuracy == "assumed" }
      end

      def unused_registry_entries(stops, registry)
        used_labels = stops.to_set { |stop| normalized_label(stop.label) }
        registry.reject { |entry| used_labels.include?(entry.normalized_label) }
      end

      def labels_detail(rows)
        labels = rows.map(&:label).compact_blank.first(30)
        return nil if labels.empty?

        labels.join("; ")
      end

      def stop_rows(routes)
        routes
          .flat_map { |route| route_stop_rows(route) }
          .group_by { |row| row.fetch(:normalized_label) }
          .filter_map { |_normalized_label, rows| stop_row(rows) }
          .sort_by { |stop| normalized_label(stop.label) }
      end

      def route_stop_rows(route)
        route.directions.flat_map do |direction|
          direction.stops.map do |stop|
            {
              route:,
              direction:,
              stop:,
              normalized_label: normalized_label(stop.label)
            }
          end
        end
      end

      def stop_row(rows)
        representative = rows.find { |row| row.fetch(:stop).latitude && row.fetch(:stop).longitude } || rows.first
        stop = representative.fetch(:stop)
        line_refs = rows.map { |row| line_ref(row.fetch(:route)) }.uniq.sort
        direction_refs = rows.map { |row| "#{row.fetch(:route).code}:#{row.fetch(:direction).name}" }.uniq.sort

        Stop.new(
          label: stop.label,
          latitude: stop.latitude,
          longitude: stop.longitude,
          accuracy: stop.coordinates_accuracy,
          source: stop.coordinates_source,
          line_refs:,
          direction_refs:,
          status: stop_status(stop)
        )
      end

      def stop_status(stop)
        return "warn" if stop.latitude.nil? || stop.longitude.nil?
        return "warn" if stop.coordinates_accuracy == "assumed"

        "ok"
      end

      def line_ref(route)
        [route.code, route.title].compact.join(" ").squish
      end

      def normalized_registry_entries
        raw_entries.map { |entry| normalized_registry_entry(entry) }
      end

      def raw_entries
        return Array(raw_registry_entries) unless raw_registry_entries.nil?
        return [] if registry_path.blank? || !File.exist?(registry_path)

        payload = YAML.safe_load_file(registry_path, permitted_classes: [], aliases: false) || {}
        Array(payload.fetch("stops", []))
      rescue Psych::Exception => e
        @registry_load_error = e
        []
      end

      def normalized_registry_entry(entry)
        label = entry_value(entry, :label).to_s.squish.presence
        latitude = coordinate(entry_value(entry, :latitude), -90, 90)
        longitude = coordinate(entry_value(entry, :longitude), -180, 180)
        errors = []
        errors << "missing_label" if label.blank?
        errors << "invalid_latitude" if latitude.nil?
        errors << "invalid_longitude" if longitude.nil?

        RegistryEntry.new(
          label:,
          normalized_label: normalized_label(label),
          latitude:,
          longitude:,
          accuracy: entry_value(entry, :accuracy).to_s.presence || "verified",
          source: entry_value(entry, :source).presence,
          same_as: entry_value(entry, :same_as).to_s.squish.presence,
          errors:
        )
      end

      def entry_value(entry, key)
        return entry.public_send(key) if entry.respond_to?(key)
        return nil unless entry.respond_to?(:[])

        entry[key] || entry[key.to_s]
      end

      def coordinate(value, min, max)
        numeric = Float(value)
        numeric.between?(min, max) ? numeric : nil
      rescue ArgumentError, TypeError
        nil
      end

      def coordinate_key(latitude, longitude)
        "#{format("%.#{COORDINATE_PRECISION}f", latitude)},#{format("%.#{COORDINATE_PRECISION}f", longitude)}"
      end

      def normalized_label(label)
        Decidim::Bih::Text.fold(label.to_s).squish
      end

      def default_registry_path
        return nil unless defined?(Rails) && Rails.respond_to?(:root)

        Rails.root.join(DEFAULT_REGISTRY_PATH)
      end
    end
  end
end
