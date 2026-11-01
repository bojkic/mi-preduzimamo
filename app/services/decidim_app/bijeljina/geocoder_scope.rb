# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    # Optional, operator-supplied bounds for this community. No local GIS or
    # city extrema are shipped. Resolved points still need polygon validation.
    module GeocoderScope
      VERSION = "community-address-bounded-v1"
      VIEWBOX = ENV.fetch("MI_GEOCODER_VIEWBOX", "").freeze
      COUNTRY_CODES = ENV.fetch("MI_GEOCODER_COUNTRY_CODES", "ba").freeze

      def self.query_params
        raw = VIEWBOX.to_s.strip
        return {} if raw.empty?

        parts = raw.split(",", -1).map { |part| Float(part.strip) }
        raise ArgumentError unless parts.size == 4 && parts.all?(&:finite?)

        west, north, east, south = parts
        raise ArgumentError unless [west, east].all? { |value| value.between?(-180, 180) } &&
                                   [north, south].all? { |value| value.between?(-90, 90) } && west < east && south < north

        countries = COUNTRY_CODES.to_s.strip.downcase
        raise ArgumentError unless /\A[a-z]{2}(?:,[a-z]{2})*\z/.match?(countries)

        { countrycodes: countries, viewbox: raw.split(",").map(&:strip).join(","), bounded: 1, layer: "address" }
      rescue ArgumentError, TypeError
        raise ArgumentError, "Configure MI_GEOCODER_VIEWBOX as west,north,east,south and valid MI_GEOCODER_COUNTRY_CODES"
      end

      private

      def connection
        params = GeocoderScope.query_params
        super.tap { |client| client.params.update(params) }
      end
    end
  end
end
