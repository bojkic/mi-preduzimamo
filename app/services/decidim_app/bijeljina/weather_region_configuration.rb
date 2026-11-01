# frozen_string_literal: true

require "date"
require "digest"
require "json"
require "uri"

module DecidimApp
  module Bijeljina
    # An operator-reviewed association of one provider region and one community.
    # This records a review; it does not calculate geometry or establish street,
    # MZ, household or current warning coverage. No region is shipped by default.
    class WeatherRegionConfiguration
      class InvalidConfiguration < StandardError; end
      ERROR = "Weather region review is missing, invalid or outside its validity period"
      MAX_BYTES = 16_384
      FIELDS = %w(version organization_host source_url provider_area_code region_label community_label
                  evidence_url reviewed_on valid_until review_state).freeze
      attr_reader :organization_host, :source_url, :provider_area_code, :region_label,
                  :community_label, :evidence_url, :reviewed_on, :valid_until, :identity

      def self.load(day:, path: ENV.fetch("MI_WEATHER_REGION_CONFIG_PATH", ""))
        return nil if path == ""
        raise InvalidConfiguration, ERROR, cause: nil unless path.is_a?(String)

        body = File.binread(path, MAX_BYTES + 1).force_encoding(Encoding::UTF_8)
        raise InvalidConfiguration, ERROR, cause: nil unless body.bytesize <= MAX_BYTES && body.valid_encoding?

        new(JSON.parse(body, max_nesting: 20), day:)
      rescue JSON::ParserError, SystemCallError, EncodingError, ArgumentError, TypeError
        raise InvalidConfiguration, ERROR, cause: nil
      end

      def self.for_source(source_url:, day:, path: ENV.fetch("MI_WEATHER_REGION_CONFIG_PATH", ""))
        config = load(day:, path:)
        unless config && config.bound_to?(organization_host: config.organization_host, source_url:)
          raise InvalidConfiguration, ERROR, cause: nil
        end
        config
      end

      # Keep acquisition tied to the same immutable review. Checking only the
      # current file at record time could relabel old or empty provider data.
      def self.assert_current!(review, source_url:, day:, organization_host: nil)
        unless review.is_a?(self) && review.valid_on?(day) &&
               review.bound_to?(organization_host: organization_host || review.organization_host, source_url:)
          raise InvalidConfiguration, ERROR, cause: nil
        end
        current = for_source(source_url:, day:)
        raise InvalidConfiguration, ERROR, cause: nil unless current.identity == review.identity

        review
      end

      def initialize(data, day:)
        invalid! unless data.is_a?(Hash) && data.keys.sort == FIELDS.sort
        invalid! unless data["version"].instance_of?(Integer) && data["version"] == 1 && data["review_state"] == "reviewed"
        host = text(data["organization_host"], limit: 253).downcase
        invalid! unless self.class.valid_host?(host)
        @organization_host = host.freeze
        @source_url = self.class.canonical_url(data["source_url"])
        @evidence_url = self.class.canonical_url(data["evidence_url"], strip_fragment: false)
        invalid! unless @source_url && @evidence_url
        @source_url.freeze
        @evidence_url.freeze
        @provider_area_code = text(data["provider_area_code"], limit: 64).freeze
        invalid! unless /\A[a-z0-9][a-z0-9_-]{0,63}\z/i.match?(@provider_area_code)
        @region_label = text(data["region_label"], limit: 200).freeze
        @community_label = text(data["community_label"], limit: 200).freeze
        @reviewed_on = date(data["reviewed_on"]).freeze
        @valid_until = date(data["valid_until"]).freeze
        invalid! unless @valid_until >= @reviewed_on && @valid_until <= @reviewed_on + 365 && valid_on?(day)
        normalized = { "version" => 1, "review_state" => "reviewed", "organization_host" => @organization_host,
                       "source_url" => @source_url, "evidence_url" => @evidence_url,
                       "provider_area_code" => @provider_area_code, "region_label" => @region_label,
                       "community_label" => @community_label, "reviewed_on" => @reviewed_on.iso8601,
                       "valid_until" => @valid_until.iso8601 }
        @identity = Digest::SHA256.hexdigest(JSON.generate(normalized.sort.to_h)).freeze
        freeze
      rescue ArgumentError, TypeError, EncodingError
        invalid!
      end

      def valid_on?(day)
        day.is_a?(Date) && reviewed_on <= day && day <= valid_until
      end

      def bound_to?(organization_host:, source_url:)
        organization_host.is_a?(String) && self.class.valid_host?(organization_host) &&
          self.organization_host == organization_host.downcase && self.source_url == self.class.canonical_url(source_url)
      end

      def metadata
        { "weather_region_review_id" => identity, "weather_organization_host" => organization_host,
          "provider_area_code" => provider_area_code, "reviewed_region_label" => region_label,
          "relevant_city" => community_label, "coverage_status" => "operator_reviewed_region_coverage",
          "area_evidence_url" => evidence_url, "area_evidence_checked_on" => reviewed_on.iso8601.freeze,
          "area_review_valid_until" => valid_until.iso8601.freeze }.freeze
      end

      def matches_metadata?(values, organization_host:, source_url:, day:)
        valid_on?(day) && bound_to?(organization_host:, source_url:) && values.is_a?(Hash) &&
          metadata.all? { |key, expected| values[key] == expected }
      end

      def display_label
        "#{region_label} (#{community_label})"
      end

      def self.canonical_url(value, strip_fragment: true)
        return unless value.is_a?(String) && value.valid_encoding? && value.bytesize <= 2_000

        uri = URI.parse(value)
        return unless uri.is_a?(URI::HTTPS) && valid_host?(uri.host) && uri.port == 443 && uri.userinfo.nil?

        uri.host = uri.host.downcase
        uri.path = "/" if uri.path.empty?
        uri.fragment = nil if strip_fragment
        uri.to_s
      rescue URI::InvalidURIError, EncodingError, ArgumentError
        nil
      end

      def self.valid_host?(value)
        value.is_a?(String) && value.valid_encoding? && !value.empty? && value.length <= 253 &&
          value.encode(Encoding::UTF_8).split(".", -1).all? { |label| /\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/i.match?(label) }
      rescue EncodingError, ArgumentError
        false
      end

      private

      def invalid!
        raise InvalidConfiguration, ERROR, cause: nil
      end

      def text(value, limit:)
        invalid! unless value.is_a?(String) && value.valid_encoding?
        clean = value.encode(Encoding::UTF_8)
        invalid! if clean.empty? || clean != clean.strip || clean.length > limit || clean.match?(/[[:cntrl:]]/)
        clean
      end

      def date(value)
        invalid! unless value.is_a?(String) && /\A\d{4}-\d{2}-\d{2}\z/.match?(value)
        Date.iso8601(value)
      end
    end
  end
end
