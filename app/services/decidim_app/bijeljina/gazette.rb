# frozen_string_literal: true

require_relative "gazette_source_identity"

module DecidimApp
  module Bijeljina
    # Reference index over explicitly configured community issue metadata.
    # The public export ships no municipal archive or local source default.
    module Gazette
      DEFAULT_SOURCE_URL = "".freeze

      class << self
        # Explicit community URL; retain the legacy setting only when supplied.
        def source_url
          ENV.fetch("MI_GAZETTE_SOURCE_URL") { ENV.fetch("BIJELJINA_GAZETTE_URL", DEFAULT_SOURCE_URL) }
        end

        # Memoized index built from the locally held catalog, so search works
        # offline without scraping the portal.
        def current_source_url
          configured = source_url
          configured.empty? ? GazetteData::BASE : configured
        end

        def catalog_entries
          GazetteData.entries_for_source(current_source_url)
        end

        def index
          url = current_source_url
          row = snapshot_for_source(url)
          entries = row ? Array(row.last_good_payload.fetch("entries")).map(&:deep_symbolize_keys) : GazetteData.entries_for_source(url)
          revision = [GazetteSourceIdentity.for_url(url), row ? [row.content_hash, row.lock_version] : [:bundled, entries.hash]]
          if @index.nil? || @revision != revision
            @index = Decidim::Bih::City::GazetteIndex.new(entries)
            @revision = revision
          end
          @index
        end

        def acts
          url = current_source_url
          snapshot = snapshot_for_source(url)
          entries = snapshot ? Array(snapshot.last_good_payload.fetch("entries")).map(&:deep_symbolize_keys) : GazetteData.entries_for_source(url)
          entries.flat_map { |entry| GazetteActs.for_issue(number: entry.fetch(:number), content_hash: entry[:content_hash]) }
        end

        def index_checked_on
          url = current_source_url
          snapshot_for_source(url)&.last_success_at&.to_date || GazetteData.checked_on_for_source(url)
        end

        def metadata_for(number)
          url = current_source_url
          row = snapshot_for_source(url)
          entry = Array(row&.last_good_payload&.fetch("entries", [])).find { |candidate| candidate["number"] == number }
          unless entry
            return unless GazetteData.bound_to?(url)

            return GazetteData.metadata_for(number)
          end

          entry.deep_symbolize_keys.slice(:source_checked_on, :published_on, :source_pdf_pages, :summary_provenance,
                                          :summary_source_url, :content_hash, :full_text_indexed, :archive_year)
        end

        def prepared_snapshot
          snapshot_for_source(current_source_url)
        end

        # Resets the memoized index (used in tests).
        def reset!
          @index = nil
          @revision = nil
        end

        private

        def snapshot_for_source(url)
          return unless GazetteSourceIdentity.for_url(url)

          row = CityServiceSourceCheckStore.new.snapshot(source_key: CityReferenceRefresh::GAZETTE_KEY)
          return unless row && row.source_version == CityReferenceRefresh::VERSION &&
                        GazetteSourceIdentity.matches_payload?(row.last_good_payload, source_url: url) &&
                        row.last_good_payload["entries"].is_a?(Array)

          row
        rescue ActiveRecord::ActiveRecordError
          nil
        end
      end
    end
  end
end
