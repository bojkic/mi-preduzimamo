# frozen_string_literal: true
require "date"
require "json"
require_relative "gazette_source_identity"

module DecidimApp
  module Bijeljina
    # Lokalni indeks nije dio izvornog koda; zajednica dodaje svoj pregled izvora.
    module GazetteData
      SNAPSHOT_PATH = ENV.fetch("MI_GAZETTE_DATA_PATH", "").freeze
      SNAPSHOT = (SNAPSHOT_PATH.empty? ? { "entries" => [] } : JSON.parse(File.read(SNAPSHOT_PATH))).freeze
      BASE = SNAPSHOT.fetch("source_url", "").freeze
      SOURCE_CAPTURED_ON = SNAPSHOT["source_checked_on"] && Date.iso8601(SNAPSHOT.fetch("source_checked_on"))
      LEGACY_ENTRIES = [].freeze
      ENTRIES = SNAPSHOT.fetch("entries").map { |row| row.deep_symbolize_keys.freeze }.freeze

      def self.bound_to?(source_url)
        expected = GazetteSourceIdentity.for_url(source_url)
        expected && GazetteSourceIdentity.for_url(BASE) == expected
      end

      def self.entries_for_source(source_url)
        bound_to?(source_url) ? ENTRIES : []
      end

      def self.checked_on_for_source(source_url)
        SOURCE_CAPTURED_ON if bound_to?(source_url)
      end

      def self.metadata_for(number)
        entry = ENTRIES.find { |candidate| candidate.fetch(:number) == number }
        return unless entry

        { source_checked_on: entry[:source_checked_on], published_on: entry[:published_on],
          source_pdf_pages: entry.fetch(:source_pdf_pages, []), summary_provenance: entry.fetch(:summary_provenance, "issue_metadata_only"),
          summary_source_url: entry[:summary_source_url], content_hash: entry[:content_hash], full_text_indexed: false,
          archive_year: entry.fetch(:number).split("/").last.to_i }
      end
    end
  end
end
