# frozen_string_literal: true

require "digest"
require "json"
require "yaml"

module DecidimApp
  module Bijeljina
    # Turns currently authorized prepared timetable cells into a compact public
    # search snapshot. The source reader remains responsible for eligibility.
    class TransportSnapshotBuilder
      TRANSFERS_PATH = ENV.fetch("MI_TRANSPORT_TRANSFERS_PATH", "").freeze
      CACHE_LIMIT = 2
      @mutex = Mutex.new
      @cache = {}

      class << self
        def call(catalog:, service_date:)
          transfer_bytes = TRANSFERS_PATH.empty? ? "transfers: []\n" : File.binread(TRANSFERS_PATH)
          revision = Digest::SHA256.hexdigest([catalog.fetch(:revision), transfer_bytes, "journey-v1"].join("|"))
          key = [revision, service_date.iso8601]
          @mutex.synchronize do
            return @cache.fetch(key) if @cache.key?(key)
          end
          built = new(catalog:, service_date:, revision:, transfer_bytes:).build
          @mutex.synchronize do
            @cache[key] ||= built
            @cache.shift while @cache.size > CACHE_LIMIT
            @cache.fetch(key)
          end
        end
      end

      def initialize(catalog:, service_date:, revision:, transfer_bytes:)
        @catalog = catalog
        @service_date = service_date
        @revision = revision
        @transfer_config = YAML.safe_load(transfer_bytes, permitted_classes: [], aliases: false).fetch("transfers")
        @zone = ActiveSupport::TimeZone[PublicTransportTimetable::SERVICE_TIME_ZONE]
      end

      def build
        kind = ReviewedTransportTimetables.calendar_kind(@service_date)
        return unless %w(school_day school_break saturday).include?(kind)

        stops = {}
        trips = []
        @catalog.fetch(:routes).each do |route|
          route.directions.each do |direction|
            next unless direction.calendar && direction.calendar["kind"] == kind

            rows = direction.stops
            rows.each do |row|
              point = stop_record(route, direction, row)
              stops[point.fetch(:id)] ||= point
            end
            count = rows.map { |row| Array(row.times).size }.max.to_i
            count.times do |column|
              calls = trip_calls(rows, route, direction, column)
              next if calls.size < 2

              trips << { id: trip_id(route, direction, column), route_code: route.code, source_url: route.source_url,
                         direction: direction.name, calendar: direction.calendar, source_column_index: column,
                         calls: calls }
            end
          end
        end
        Decidim::Bih::Transport::TimetableSnapshot.new(revision: @revision, service_date: @service_date.iso8601,
                                                         stops: stops.values, trips:, transfers: transfer_links(stops))
      end

      private

      def trip_calls(rows, route, direction, column)
        return [] unless ReviewedTransportTimetables.trip_available?(direction.calendar, column, @zone.local(@service_date.year, @service_date.month, @service_date.day, 12))

        previous = nil
        rollover = 0
        rows.filter_map do |row|
          clock = Array(row.times)[column]
          next if clock.nil? || clock.to_s.empty?

          hour, minute = clock.split(":").map(&:to_i)
          candidate = @zone.local(@service_date.year, @service_date.month, @service_date.day, hour, minute) + rollover.days
          if previous && candidate < previous
            rollover += 1
            candidate += 1.day
          end
          previous = candidate
          { stop_id: point_id(route, direction, row), at: candidate, source_row_index: row.index }
        end
      end

      def stop_record(route, direction, row)
        { id: point_id(route, direction, row), public_id: legacy_stop_id(row), station_id: station_id(row),
          label: row.label, latitude: row.latitude, longitude: row.longitude,
          coordinate_accuracy: row.coordinates_accuracy, coordinate_source: row.coordinates_source,
          route_code: route.code, direction: direction.name }
      end

      def point_id(route, direction, row)
        "transport_point:#{Digest::SHA256.hexdigest(JSON.generate([route.code, direction.name, row.index, row.label, row.latitude, row.longitude]))[0, 20]}"
      end

      def legacy_stop_id(row)
        identity = [row.label, format("%.6f,%.6f", row.latitude, row.longitude)].join("|")
        "transport_stop:#{Digest::SHA256.hexdigest(identity)[0, 12]}"
      end

      def station_id(row)
        return unless row.normalized_label == "bijeljina nas"

        "transport_station:#{Digest::SHA256.hexdigest(row.normalized_label)[0, 12]}"
      end

      def trip_id(route, direction, column)
        "trip:#{Digest::SHA256.hexdigest(JSON.generate([@revision, @service_date.iso8601, route.code, direction.name, column]))[0, 24]}"
      end

      def transfer_links(stops)
        @transfer_config.flat_map do |entry|
          members = stops.values.select { |stop| stop[:station_id] == entry.fetch("station_id") }
          members.product(members).filter_map do |from, to|
            next if from.fetch(:id) == to.fetch(:id)

            { from_stop_id: from.fetch(:id), to_stop_id: to.fetch(:id),
              walk_seconds: entry.fetch("walk_seconds"), margin_seconds: entry.fetch("margin_seconds"),
              estimate_kind: entry.fetch("estimate_kind"), accessibility_status: entry.fetch("accessibility_status") }
          end
        end
      end
    end
  end
end
