# frozen_string_literal: true

require "date"
require "digest"
require "json"
require "uri"

module DecidimApp
  module Bijeljina
    # Reviewed transcription of the city's image-only September timetable.
    # Images and their hashes travel with the data. A changed upstream image
    # requires another review; scheduled refresh never runs OCR.
    module ReviewedTransportTimetables
      DATA_PATH = ENV.fetch("MI_REVIEWED_TRANSPORT_PATH", "").freeze
      CALENDAR_ID = ENV.fetch("MI_TRANSPORT_CALENDAR_ID", "unconfigured").freeze

      module_function

      def manifest
        return { "routes" => [] } if DATA_PATH.empty?

        @manifest ||= JSON.parse(File.read(File.join(DATA_PATH, "manifest.json")))
      end

      def entry_for(url)
        manifest.fetch("routes").find { |entry| entry.dig("timetable", "url") == url.to_s }
      end

      def asset_for(url)
        manifest.fetch("routes").flat_map { |entry| entry.values_at("timetable", "map") }.find { |asset| asset.fetch("url") == url.to_s }
      end

      def stop_locations
        return [] if DATA_PATH.empty?

        @stop_locations ||= begin
          asset = manifest.fetch("stop_locations")
          bytes = File.binread(File.join(DATA_PATH, asset.fetch("file")))
          raise ArgumentError, "reviewed stop locations checksum mismatch" unless Digest::SHA256.hexdigest(bytes) == asset.fetch("sha256")

          JSON.parse(bytes).fetch("rows")
        end
      end

      def stop_location_for(code, direction, label)
        @stop_location_index ||= stop_locations.index_by { |row| row.values_at("line", "direction", "label") }
        @stop_location_index.fetch([code, direction, label])
      end

      def data_for(entry)
        bytes = File.binread(File.join(DATA_PATH, entry.fetch("data_file")))
        raise ArgumentError, "reviewed timetable data checksum mismatch" unless Digest::SHA256.hexdigest(bytes) == entry.fetch("data_sha256")

        JSON.parse(bytes)
      end

      def gallery_entries(document)
        expected = gallery_asset_paths
        raise ArgumentError, "published transport gallery changed; review required" unless gallery_paths(document) == expected

        manifest.fetch("routes")
      end

      def gallery_document?(document)
        gallery_paths(document).any?
      end

      def gallery_asset_paths
        manifest.fetch("routes").flat_map { |entry| %w(timetable map).map { |kind| URI.parse(entry.fetch(kind).fetch("url")).path } }.uniq.sort
      end

      def gallery_paths(document)
        # Only explicitly configured asset directories belong to this gallery.
        # Other page imagery is ignored; a new/missing gallery asset needs review.
        directories = gallery_asset_paths.map { |path| File.dirname(path) }.uniq
        paths = document.css("img[src], [data-src]").flat_map { |node| [node["src"], node["data-src"]] }.compact
        paths.filter_map do |path|
          parsed = URI.parse(path).path
          parsed if parsed && directories.include?(File.dirname(parsed))
        rescue URI::InvalidURIError
          nil # Unrelated malformed page imagery is outside the asset manifest.
        end.uniq.sort
      end

      def calendar_kind(value)
        return "unreviewed" if DATA_PATH.empty?

        date = service_date(value)
        config = manifest.fetch("calendar")
        return "unreviewed" if date.iso8601 < manifest.fetch("effective_from") || date.iso8601 > config.fetch("reviewed_until")
        return "holiday" if config.fetch("unsupported_dates").include?(date.iso8601)
        return "sunday" if date.sunday?
        return "saturday" if date.saturday?

        %w(school_day school_break).find do |kind|
          config.fetch("#{kind}_ranges").any? { |first, last| date.iso8601.between?(first, last) }
        end || "unreviewed"
      end

      def service_date(value)
        value.respond_to?(:in_time_zone) ? value.in_time_zone("Europe/Sarajevo").to_date : Date.parse(value.to_s)
      end

      def trip_available?(calendar, index, value)
        rule = calendar.fetch("seasonal_columns", {})[index.to_s]
        return true unless rule

        value.in_time_zone("Europe/Sarajevo").strftime("%m-%d").between?(rule.fetch("from"), rule.fetch("through"))
      end

      def calendar_metadata(direction, entry)
        { "kind" => direction.fetch("calendar"), "source_heading" => direction.fetch("source_heading"),
          "source_url" => entry.dig("timetable", "url"), "source_map_url" => entry.dig("map", "url"),
          "source_table_index" => direction.fetch("source_table_index"), "status" => "available", "warnings" => [],
          "reviewed_school_calendar" => CALENDAR_ID, "effective_from" => manifest.fetch("effective_from"),
          "seasonal_columns" => direction.fetch("seasonal_columns", {}) }
      end

      # The older textual reader receives exactly the same filtered columns.
      def text_for(payload, at:)
        kind = calendar_kind(at)
        directions = Array(payload["directions"]).select { |direction| direction.dig("calendar", "kind") == kind }
        return if directions.empty?

        directions.map do |direction|
          rows = direction.fetch("stops").map do |stop|
            times = stop.fetch("times").each_with_index.map do |time, index|
              trip_available?(direction.fetch("calendar"), index, at) ? (time || "/") : "/"
            end
            "#{stop.fetch("label")}  #{times.join(" ")}"
          end
          ["Smjer #{direction.fetch("name")}", *rows].join("\n")
        end.join("\n")
      end
    end
  end
end
