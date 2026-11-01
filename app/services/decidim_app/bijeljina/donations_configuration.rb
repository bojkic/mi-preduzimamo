# frozen_string_literal: true

require "json"
require "uri"
require "date"

module DecidimApp
  module Bijeljina
    # Public installation data only. Odoo credentials remain in its own runtime
    # environment; this file never accepts credentials or donor records.
    class DonationsConfiguration
      FIELDS = %w(product_ids donate_url organization_host cache_namespace donation_presets confirmed_states date_from).freeze
      attr_reader :product_ids, :donate_url, :organization_host, :cache_namespace,
                  :donation_presets, :confirmed_states, :date_from

      def self.load(path = ENV.fetch("MI_DONATIONS_CONFIG_PATH", ""))
        new(path.to_s.empty? ? {} : JSON.parse(File.read(path)))
      rescue JSON::ParserError
        raise ArgumentError, "Donation configuration must be valid JSON"
      end

      def initialize(data)
        raise ArgumentError, "Donation configuration must be an object with supported fields" unless data.is_a?(Hash) && (data.keys - FIELDS).empty?

        ids = data.fetch("product_ids", [])
        unless ids.is_a?(Array) && ids.all? { |id| id.is_a?(Integer) && id.positive? }
          raise ArgumentError, "Donation product_ids must be positive integer identifiers"
        end
        @product_ids = ids.uniq.freeze
        @donate_url = string(data.fetch("donate_url", ""), "donate_url").freeze
        @organization_host = string(data.fetch("organization_host", ""), "organization_host").downcase.freeze
        unless @organization_host.empty? || @organization_host.match?(/\A[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?\z/)
          raise ArgumentError, "Donation organization_host must be a host without scheme or path"
        end
        validate_checkout_url!
        required = [@product_ids.any?, !@donate_url.empty?, !@organization_host.empty?]
        raise ArgumentError, "Donation products, checkout URL and organization host must be configured together" if required.any? && !required.all?

        namespace = string(data.fetch("cache_namespace", "default"), "cache_namespace")
        raise ArgumentError, "Donation cache_namespace must be a nonempty simple identifier" unless namespace.match?(/\A[a-zA-Z0-9_.-]+\z/)
        @cache_namespace = "community_donations/#{namespace}/#{@organization_host}".freeze
        presets = data.fetch("donation_presets", [10, 25, 50, 100, 250])
        unless presets.is_a?(Array) && presets.all? { |n| (n.is_a?(Integer) || (n.is_a?(Float) && n.finite?)) && n.positive? }
          raise ArgumentError, "Donation presets must be positive finite amounts"
        end
        @donation_presets = presets.uniq.freeze
        states = data.fetch("confirmed_states", %w(sale done))
        unless states.is_a?(Array) && states.any? && states.all? { |state| state.is_a?(String) && !state.strip.empty? }
          raise ArgumentError, "Donation confirmed_states must be a nonempty array of names"
        end
        @confirmed_states = states.map { |state| state.strip.freeze }.uniq.freeze
        raw_date = data["date_from"]
        @date_from = nil
        unless raw_date.nil? || raw_date == ""
          value = string(raw_date, "date_from")
          raise ArgumentError, "Donation date_from must use YYYY-MM-DD" unless value.match?(/\A\d{4}-\d{2}-\d{2}\z/)

          @date_from = Date.iso8601(value).iso8601.freeze
        end
        freeze
      end

      def configured?
        product_ids.any? && !donate_url.empty? && !organization_host.empty?
      end

      private

      def string(value, field)
        raise ArgumentError, "Donation #{field} must be a string" unless value.is_a?(String)

        value.strip
      end

      def validate_checkout_url!
        return if @donate_url.empty?

        url = URI.parse(@donate_url)
        return if url.scheme == "https" && url.host && !url.host.empty? && url.userinfo.nil?

        raise ArgumentError, "Donation checkout URL must be HTTPS without userinfo"
      rescue URI::InvalidURIError
        raise ArgumentError, "Donation checkout URL is invalid"
      end
    end
  end
end
