# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    class CityServiceNoticesDryRun
      def initialize(organization:, fetcher: nil)
        @organization = organization
        @fetcher = fetcher || method(:fetch_source)
      end

      def call(keys: [ElectricityOutageParser::SOURCE_KEY])
        Array(keys).flat_map { |key| rows_for(key.to_s) }
      end

      def self.format(rows)
        header = %w(source fingerprint starts_at ends_at areas title summary)
        ([header] + rows.map { |row| row_values(row) }).map { |values| values.join("\t") }.join("\n")
      end

      def self.row_values(row)
        [
          row.source_key,
          row.source_fingerprint,
          row.starts_at&.iso8601,
          row.ends_at&.iso8601,
          Array(row.affected_area_slugs).join(","),
          row.title,
          row.summary
        ]
      end

      private

      attr_reader :organization, :fetcher

      def rows_for(source_key)
        source = CityServiceSources.fetch(source_key)
        response = fetcher.call(source)
        raise "source returned HTTP #{response.fetch(:http_status)}" unless successful_response?(response)

        CityServiceEventIngestor.new(organization:).dry_run(
          source_key:,
          html: response.fetch(:body),
          source_url: response.fetch(:final_url, source.fetch(:source_url)),
          fetched_at: Time.current
        )
      end

      def successful_response?(response)
        response.fetch(:http_status, 200).to_i.between?(200, 299)
      end

      def fetch_source(source)
        CityServiceNoticeCollector.send(
          :fetch_source,
          source:,
          timeout: CityServiceNoticeCollector::DEFAULT_TIMEOUT,
          max_bytes: CityServiceNoticeCollector::DEFAULT_MAX_BYTES,
          user_agent: CityServiceNoticeCollector::DEFAULT_USER_AGENT
        )
      end
    end
  end
end
