# frozen_string_literal: true

require "date"
require "digest"
require "json"
require "time"
require "uri"

module DecidimApp
  # An explicitly configured community event, not an inherited local date.
  # No network, personal invitations, delivery or survey mutations live here.
  class LaunchEventConfiguration
    InvalidConfiguration = Class.new(StandardError)
    ERROR = "Community launch event configuration is missing or invalid"
    MAX_BYTES = 16_384
    FIELDS = %w(version organization_host event_key title source_url opens_at closes_at enabled sms_fallback).freeze
    attr_reader :organization_host, :event_key, :title, :source_url, :opens_at, :closes_at, :identity

    def self.load(organization_host:, path: ENV.fetch("MI_LAUNCH_EVENT_CONFIG_PATH", ""))
      return if path.to_s.strip.empty?

      raw = File.binread(path, MAX_BYTES + 1).force_encoding(Encoding::UTF_8)
      raise InvalidConfiguration, ERROR, cause: nil unless raw.bytesize <= MAX_BYTES && raw.valid_encoding?

      configuration = new(JSON.parse(raw, max_nesting: 20))
      raise InvalidConfiguration, ERROR, cause: nil unless configuration.bound_to?(organization_host)

      configuration
    rescue JSON::ParserError, SystemCallError, EncodingError, ArgumentError, TypeError
      raise InvalidConfiguration, ERROR, cause: nil
    end

    def self.current?(configuration, organization_host:)
      return false unless configuration.is_a?(self) && configuration.enabled?

      current = load(organization_host:)
      !!(current && current.identity == configuration.identity)
    rescue InvalidConfiguration
      false
    end

    def initialize(data)
      invalid! unless data.is_a?(Hash) && data.keys.sort == FIELDS.sort
      invalid! unless data["version"].instance_of?(Integer) && data["version"] == 1
      invalid! unless [true, false].include?(data["enabled"]) && [true, false].include?(data["sms_fallback"])

      @organization_host = text(data["organization_host"], limit: 253).downcase.freeze
      invalid! unless self.class.valid_host?(@organization_host)
      @event_key = text(data["event_key"], limit: 64)
      invalid! unless /\A[a-z][a-z0-9-]{0,63}\z/.match?(@event_key)
      @title = text(data["title"], limit: 200)
      @source_url = public_url(data["source_url"])
      @opens_at = clock(data["opens_at"])
      @closes_at = clock(data["closes_at"])
      invalid! unless @closes_at > @opens_at
      @enabled = data["enabled"]
      @sms_fallback = data["sms_fallback"]
      normalized = { "version" => 1, "organization_host" => @organization_host, "event_key" => @event_key,
        "title" => @title, "source_url" => @source_url, "opens_at" => @opens_at.getutc.iso8601(6),
        "closes_at" => @closes_at.getutc.iso8601(6), "enabled" => @enabled, "sms_fallback" => @sms_fallback }
      @identity = Digest::SHA256.hexdigest(JSON.generate(normalized)).freeze
      freeze
    rescue EncodingError, ArgumentError, TypeError
      invalid!
    end

    def enabled? = @enabled
    def sms_fallback? = @sms_fallback
    def storage_key = "community-launch-v1:#{identity}".freeze

    def bound_to?(host)
      host.is_a?(String) && self.class.valid_host?(host) && organization_host == host.downcase
    end

    def open?(now:)
      enabled? && now >= opens_at && now < closes_at
    end

    def phase(now:)
      return "disabled" unless enabled?
      return "scheduled" if now < opens_at

      open?(now:) ? "open" : "closed"
    end

    def self.valid_host?(value)
      value.is_a?(String) && value.valid_encoding? && !value.empty? && value.length <= 253 &&
        value.split(".", -1).all? { |label| /\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/i.match?(label) }
    end

    private

    def invalid!
      raise InvalidConfiguration, ERROR, cause: nil
    end

    def text(value, limit:)
      invalid! unless value.is_a?(String) && value.valid_encoding?
      clean = value.encode(Encoding::UTF_8)
      invalid! if clean.empty? || clean != clean.strip || clean.length > limit || clean.match?(/[[:cntrl:]]/)
      clean.freeze
    end

    def public_url(value)
      raw = text(value, limit: 2_000)
      uri = URI.parse(raw)
      invalid! unless uri.is_a?(URI::HTTPS) && uri.host&.downcase == organization_host && uri.port == 443 && uri.userinfo.nil?
      invalid! if raw.match?(/%(?:0[0-9a-f]|1[0-9a-f]|7f)/i)
      uri.host = uri.host.downcase
      uri.to_s.freeze
    end

    def clock(value)
      raw = text(value, limit: 40)
      invalid! unless /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?(?:Z|[+-]\d{2}:\d{2})\z/.match?(raw)
      Date.iso8601(raw[0, 10])
      Time.iso8601(raw).freeze
    end
  end
end
