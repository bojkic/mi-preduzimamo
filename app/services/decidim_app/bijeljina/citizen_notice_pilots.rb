# frozen_string_literal: true

require "net/http"
require "openssl"
require "timeout"
require "uri"
require "digest"
require "json"
require_relative "citizen_notice_pilot_parser"

module DecidimApp
  module Bijeljina
    # Explicit operator-run pilots, independent of the configured source catalog.
    # No cron registration or citizen-turn fetch; existing durable snapshots keep
    # last-good data separate from the latest failed attempt.
    class CitizenNoticePilots
      VERSION = "citizen-notice-pilots-community-v1"
      MAX_BYTES = 262_144
      MAX_REQUESTS = 4
      MAX_SECONDS = 20
      USER_AGENT = "MilicaCitizenSources/1.0 (+https://mi.fondacijabijeljina.com)"
      SOURCES = {
        "bihamk_border" => { url: "https://bihamk.ba/spi/stanje-na-cesti-u-bih/granicni-prijelazi", label: "BIHAMK", max_age: 3.hours },
        "pio_notices" => { url: "https://www.fondpiors.org/?feed=rss2", label: "Fond PIO RS", max_age: 2.days },
        "jfdz_notices" => { url: "https://jfdz.org/sr", label: "Javni fond za dječiju zaštitu", max_age: 2.days }
      }.freeze
      class InvalidSource < StandardError; end

      def self.snapshot_key(key)
        SOURCES.fetch(key)
        "citizen_notice_pilot:#{key}"
      end

      def self.version_for(key)
        Digest::SHA256.hexdigest(JSON.generate([VERSION, SOURCES.fetch(key)]))
      end

      def self.approved_url(value, key)
        uri = URI.parse(value.to_s)
        expected = URI(SOURCES.fetch(key)[:url])
        raise InvalidSource, "unapproved pilot URL" unless uri.scheme == "https" && uri.host == expected.host && uri.port == 443 && uri.userinfo.nil?
        raise InvalidSource, "unapproved child benefit URL" if key == "jfdz_notices" && !uri.path.match?(%r{\A/sr(?:/news/\d+/[a-z0-9-]+)?\z})

        uri.fragment = nil
        uri.to_s
      rescue URI::InvalidURIError
        raise InvalidSource, "invalid pilot URL"
      end

      def initialize(source_store: nil, fetcher: nil)
        @store = source_store || CityServiceSourceCheckStore.new
        @fetcher = fetcher || method(:fetch)
      end

      def refresh(key:, now: Time.current)
        source = SOURCES.fetch(key)
        @key = key
        @requests = 0
        @expires = Process.clock_gettime(Process::CLOCK_MONOTONIC) + MAX_SECONDS
        @store.with_refresh_lock(self.class.snapshot_key(key)) do
          records = collect(key, source:, now:)
          records.each { |record| record["source_url"] ||= source[:url] }
          payload = { "status" => records.empty? ? "empty" : "ok", "records" => records, "checked_at" => now.iso8601, "pilot_key" => key,
                      "coverage" => "selected_public_notices", "personal_status_supported" => false }
          @store.promote(source_key: self.class.snapshot_key(key), source_version: self.class.version_for(key), payload:, success: true,
                         attempted_at: now, checked_at: now, content_hash: Digest::SHA256.hexdigest(JSON.generate(records)))
          payload
        rescue InvalidSource, Timeout::Error, IOError, SystemCallError, SocketError, OpenSSL::SSL::SSLError => e
          payload = { "status" => "unavailable", "records" => [], "pilot_key" => key, "error_code" => e.is_a?(OpenSSL::SSL::SSLError) ? "tls_verification_failed" : "pilot_preparation_failed" }
          @store.promote(source_key: self.class.snapshot_key(key), source_version: self.class.version_for(key), payload:, success: false, attempted_at: now)
          payload
        end
      end

      private

      def collect(key, source:, now:)
        body = request(source[:url])
        case key
        when "bihamk_border" then CitizenNoticePilotParser.borders(body, now:)
        when "pio_notices" then CitizenNoticePilotParser.pension_feed(body, now:)
        when "jfdz_notices"
          child_links(body).flat_map { |url| CitizenNoticePilotParser.child_benefit(request(url), url:, now:) }
        end
      end

      def child_links(body)
        document = Nokogiri::HTML(body)
        links = document.css('a[href*="/sr/news/"]')
        raise InvalidSource, "child benefit listing changed" if links.empty?

        links.filter_map do |anchor|
          next unless CitizenNoticePilotParser.fold(anchor.text).match?(/isplat/)

          self.class.approved_url(anchor["href"], "jfdz_notices")
        end.uniq.first(MAX_REQUESTS - 1)
      end

      def request(url)
        self.class.approved_url(url, @key)
        @requests += 1
        remaining = @expires - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        raise InvalidSource, "pilot request budget exceeded" if @requests > MAX_REQUESTS || remaining <= 0

        response = Timeout.timeout(remaining) { @fetcher.call(url:, timeout: [remaining, 8].min, max_bytes: MAX_BYTES) }
        final_url = self.class.approved_url(response.fetch(:final_url, url), @key)
        body = response.fetch(:body).to_s
        raise InvalidSource, "incomplete pilot response" unless response[:http_status].to_i == 200 && final_url == url && body.bytesize <= MAX_BYTES && !body.strip.empty?

        body
      end

      def fetch(url:, timeout:, max_bytes:)
        uri = URI(url)
        timeout = CitySourceRequestPolicy.default.before_request(uri, timeout:)
        Net::HTTP.start(uri.host, uri.port, use_ssl: true, verify_mode: OpenSSL::SSL::VERIFY_PEER, open_timeout: timeout, read_timeout: timeout) do |http|
          request = Net::HTTP::Get.new(uri)
          request["User-Agent"] = CitySourceRequestPolicy::USER_AGENT
          http.request(request) do |response|
            CitySourceRequestPolicy.default.observe_response(uri, response)
            body = +""
            response.read_body do |chunk|
              body << chunk
              raise InvalidSource, "pilot response too large" if body.bytesize > max_bytes
            end
            return { http_status: response.code.to_i, body:, final_url: url }
          end
        end
      rescue CitySourceRequestPolicy::PolicyError
        raise InvalidSource, "source request policy refused"
      end
    end
  end
end
