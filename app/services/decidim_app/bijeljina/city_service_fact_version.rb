# frozen_string_literal: true

require "digest"

module DecidimApp
  module Bijeljina
    # The one formula for "have this notice's reviewed facts changed?".
    #
    # It hashes the notice's own extraction and nothing else. Hashing the
    # document that carried it instead made a live aggregate feed mint a new
    # version, and so a new review row, on every fetch.
    #
    # The parser computes this from a fresh extraction and the backfill
    # computes it from a stored row; they MUST agree exactly, which is why they
    # share this code rather than each hashing its own field list.
    module CityServiceFactVersion
      module_function

      # rubocop:disable Metrics/ParameterLists
      # -- the list IS the contract. Every fact that can change a review is
      # named here; collapsing them into one opaque hash is how the parser and
      # the backfill would quietly start hashing different things.
      def digest(parser_version:, quotation:, event_type:, severity:, lifecycle:, targeting_level:,
                 area_slugs:, starts_at:, ends_at:, precision:, temporal_status:, complete:,
                 recurrence:, raw_from:, raw_to:, source_date:)
        Digest::SHA256.hexdigest(
          [
            parser_version, quotation, event_type, severity, lifecycle, targeting_level,
            Array(area_slugs).sort.join(","), starts_at&.utc&.iso8601, ends_at&.utc&.iso8601,
            precision, temporal_status.presence || "resolved", complete != false,
            recurrence, raw_from, raw_to, source_date
          ].map(&:to_s).join("\u0000")
        )
      end
      # rubocop:enable Metrics/ParameterLists

      # Recomputes the version a stored row would get today. Every input is a
      # column or a retained extraction fact, so this never re-reads a source.
      def for_record(event)
        metadata = event.extraction_metadata.to_h
        digest(
          parser_version: event.parser_version, quotation: metadata["source_quotation"],
          event_type: event.event_type, severity: event.severity, lifecycle: event.lifecycle,
          targeting_level: event.targeting_level, area_slugs: event.affected_area_slugs,
          starts_at: event.starts_at, ends_at: event.ends_at,
          precision: metadata["temporal_precision"], temporal_status: metadata["temporal_status"],
          complete: metadata["complete"], recurrence: metadata["recurrence"],
          raw_from: metadata["raw_from"], raw_to: metadata["raw_to"], source_date: metadata["source_date"]
        )
      end
    end
  end
end
