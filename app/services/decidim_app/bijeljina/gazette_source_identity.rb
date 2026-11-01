# frozen_string_literal: true

require "digest"
require "json"
require "uri"

module DecidimApp
  module Bijeljina
    # One source contract for producer, readers and health. A URL fragment is
    # not sent to a publisher; path and query changes identify different feeds.
    module GazetteSourceIdentity
      module_function

      def canonical_url(value)
        return unless value.is_a?(String) && !value.empty? && value.length <= 2_000

        uri = URI.parse(value)
        return unless uri.scheme == "https" && uri.port == 443 && uri.userinfo.nil? && uri.host && !uri.host.empty?

        uri.host = uri.host.downcase
        uri.path = "/" if uri.path.empty?
        uri.fragment = nil
        uri.to_s
      rescue URI::InvalidURIError
        nil
      end

      def for_url(value)
        canonical = canonical_url(value)
        Digest::SHA256.hexdigest(JSON.generate(["gazette-source-v1", 2026, canonical])) if canonical
      end

      def matches_payload?(payload, source_url:)
        expected = for_url(source_url)
        expected && payload.is_a?(Hash) && payload["source_identity"] == expected &&
          for_url(payload["source_url"]) == expected
      end
    end
  end
end
