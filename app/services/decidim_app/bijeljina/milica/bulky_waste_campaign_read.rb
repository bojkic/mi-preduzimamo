# frozen_string_literal: true

require "date"
require "json"
require "uri"

module DecidimApp
  module Bijeljina
    module Milica
      # Optional, operator-reviewed announcements for one community. This is a
      # dated source snapshot, never live collection status or address eligibility.
      # No network access; no inherited municipal recipients, dates or endpoints.
      class BulkyWasteCampaignRead
        MAX_BYTES = 65_536
        MAX_CAMPAIGNS = 8
        TOP_KEYS = %w(format organization_host campaigns).freeze
        ROW_KEYS = %w(id text coverage_text source_url source_on reviewed_on review_valid_until starts_on ends_on review_state publishable).freeze
        class InvalidConfig < StandardError; end

        def initialize(organization_host:, reviewed_hosts:, path: ENV.fetch("MI_BULKY_WASTE_CAMPAIGNS_PATH", ""))
          @organization_host = organization_host.to_s.downcase
          @reviewed_hosts = reviewed_hosts.map { |host| host.to_s.downcase }
          @path = path
        end

        def call(day:)
          return unavailable("bulky_waste_campaigns_unconfigured") if @path.to_s.empty?

          data = File.open(@path, "rb") { |file| file.read(MAX_BYTES + 1) } || ""
          raise InvalidConfig if data.bytesize > MAX_BYTES

          config = JSON.parse(data)
          validate_config!(config)
          return unavailable("bulky_waste_campaigns_wrong_community") unless config.fetch("organization_host").downcase == @organization_host

          facts = config.fetch("campaigns").filter_map do |row|
            validate_row!(row)
            reviewed = Date.iso8601(row.fetch("reviewed_on"))
            next unless row.fetch("publishable") && row.fetch("review_state") == "reviewed"
            next unless reviewed <= day && day <= Date.iso8601(row.fetch("review_valid_until"))

            start = Date.iso8601(row.fetch("starts_on"))
            finish = Date.iso8601(row.fetch("ends_on"))
            phase = day < start ? "upcoming" : (day > finish ? "expired" : "in_published_window")
            row.slice("id", "text", "coverage_text", "source_url", "source_on", "reviewed_on", "review_valid_until", "starts_on", "ends_on").merge(
              "kind" => "reviewed_bulky_waste_campaign", "phase" => phase,
              "warning_codes" => %w(snapshot_not_live_status address_eligibility_not_confirmed)
            )
          end
          { status: facts.empty? ? "empty" : "ok", facts:,
            coverage: { "organization_host" => @organization_host, "scope" => "reviewed_static_announcements" },
            validity: { "as_of_date" => day.iso8601, "live_status" => false },
            warnings: %w(snapshot_not_live_status address_eligibility_not_confirmed newer_announcement_not_excluded) }
        rescue InvalidConfig, JSON::ParserError, KeyError, TypeError, Date::Error, URI::InvalidURIError,
               Errno::ENOENT, Errno::EACCES, Errno::ENOTDIR, Errno::EISDIR
          unavailable("bulky_waste_campaigns_invalid_configuration")
        end

        private

        def validate_config!(config)
          raise InvalidConfig unless config.is_a?(Hash) && (config.keys - TOP_KEYS).empty? && config.fetch("format") == 1
          host = config.fetch("organization_host")
          raise InvalidConfig unless host.is_a?(String) && /\A[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?\z/i.match?(host)

          rows = config.fetch("campaigns")
          raise InvalidConfig unless rows.is_a?(Array) && rows.size <= MAX_CAMPAIGNS && rows.all? { |row| row.is_a?(Hash) }
          raise InvalidConfig unless rows.map { |row| row.fetch("id") }.uniq.size == rows.size
        end

        def validate_row!(row)
          raise InvalidConfig unless (row.keys - ROW_KEYS).empty? && (ROW_KEYS - row.keys).empty?
          raise InvalidConfig unless row.fetch("id").is_a?(String) && /\A[a-z0-9][a-z0-9_-]{0,79}\z/.match?(row.fetch("id"))
          %w(text coverage_text).each do |field|
            value = row.fetch(field)
            raise InvalidConfig unless value.is_a?(String) && !value.strip.empty? && value.valid_encoding? && value.length <= 1_000 && !value.match?(/[\x00-\x08\x0b\x0c\x0e-\x1f]/)
          end
          raise InvalidConfig unless %w(reviewed pending rejected).include?(row.fetch("review_state"))
          raise InvalidConfig unless [true, false].include?(row.fetch("publishable"))

          dates = %w(source_on reviewed_on review_valid_until starts_on ends_on).to_h do |field|
            value = row.fetch(field)
            raise InvalidConfig unless value.is_a?(String) && /\A\d{4}-\d{2}-\d{2}\z/.match?(value)

            [field, Date.iso8601(value)]
          end
          raise InvalidConfig unless dates.fetch("source_on") <= dates.fetch("reviewed_on") &&
                                     dates.fetch("reviewed_on") <= dates.fetch("review_valid_until") &&
                                     dates.fetch("starts_on") <= dates.fetch("ends_on")

          value = row.fetch("source_url")
          raise InvalidConfig unless value.is_a?(String) && value.length <= 2_000

          source = URI.parse(value)
          raise InvalidConfig unless source.scheme == "https" && source.userinfo.nil? && source.port == 443 &&
                                     @reviewed_hosts.include?(source.host.to_s.downcase)
        end

        def unavailable(warning)
          { status: "unavailable", warnings: [warning] }
        end
      end
    end
  end
end
