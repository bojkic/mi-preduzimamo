# frozen_string_literal: true

require "net/http"
require "uri"

require_relative "city_service_notice_collector"
require_relative "city_service_sources"

module DecidimApp
  module Bijeljina
    # Read-only source reachability probe for reviewed service-information feeds.
    #
    # It samples response metadata only. It never persists response bodies and is
    # intended for operator/manual collection checks before parser automation.
    module CityServiceSourceProbe
      DEFAULT_TIMEOUT = 5
      DEFAULT_MAX_BYTES = 4096
      DEFAULT_USER_AGENT = CityServiceNoticeCollector::DEFAULT_USER_AGENT
      DEFAULT_CONTACT_EMAIL = CityServiceNoticeCollector::DEFAULT_CONTACT_EMAIL
      MAX_REDIRECTS = 3

      class << self
        def call(keys: [], timeout: DEFAULT_TIMEOUT, max_bytes: DEFAULT_MAX_BYTES,
                 user_agent: DEFAULT_USER_AGENT, **options)
          sources = selected_sources(keys)
          fetcher = options.delete(:fetcher) || method(:fetch_source)
          options = options.merge(timeout:, max_bytes:, user_agent:, fetcher:)
          options[:clock] ||= -> { Time.current }

          sources.map do |source|
            probe_source(source, options)
          end
        end

        private

        def selected_sources(keys)
          selected = Array(keys).map(&:to_s).compact_blank
          return CityServiceSources.all.select { |source| source.fetch(:enabled, true) } if selected.empty?

          sources = selected.map { |key| CityServiceSources.fetch(key) }
          raise ArgumentError, "source disabled by owner" if sources.any? { |source| !source.fetch(:enabled, true) }

          sources.uniq { |source| source.fetch(:key) }
        end

        def probe_source(source, options)
          deadline = CityServiceNoticeCollector.send(:bounded_deadline, options[:deadline], options.fetch(:timeout))
          timeout = CityServiceNoticeCollector.send(:effective_timeout, options.fetch(:timeout), deadline)
          fetch_options = {
            source:,
            timeout:,
            max_bytes: options.fetch(:max_bytes),
            user_agent: options.fetch(:user_agent)
          }
          fetcher = options.fetch(:fetcher)
          fetch_options[:deadline] = deadline if CityServiceNoticeCollector.send(:fetcher_accepts_deadline?, fetcher)
          result = CityServiceNoticeCollector.send(:within_deadline, deadline, max_seconds: timeout) do
            fetcher.call(**fetch_options)
          end
          http_status = result.fetch(:http_status).to_i
          checked_at = result[:checked_at] || options[:now] || options.fetch(:clock).call

          {
            source_key: source.fetch(:key),
            label: source.fetch(:label),
            provider: source.fetch(:provider),
            source_url: source.fetch(:source_url),
            check_scope: "reachability_only",
            status: status_for(http_status),
            checked_at:,
            error_code: error_code_for(http_status),
            http_status:,
            final_url: result.fetch(:final_url),
            content_type: result.fetch(:content_type),
            bytes_sampled: result.fetch(:bytes_sampled),
            detail: detail_for(result)
          }
        rescue StandardError => e
          {
            source_key: source.fetch(:key),
            label: source.fetch(:label),
            provider: source.fetch(:provider),
            source_url: source.fetch(:source_url),
            check_scope: "reachability_only",
            status: "fail",
            checked_at: nil,
            error_code: probe_error_code(e),
            http_status: nil,
            final_url: nil,
            content_type: nil,
            bytes_sampled: 0,
            detail: sanitize("#{e.class}: #{e.message}")
          }
        end

        def probe_error_code(error)
          return "deadline_exceeded" if error.is_a?(CityServiceNoticeCollector::DeadlineExceeded)
          return "invalid_deadline" if error.is_a?(CityServiceNoticeCollector::InvalidDeadline)

          "probe_error"
        end

        def fetch_source(source:, timeout:, max_bytes:, user_agent:, deadline: nil)
          options = {
            timeout:,
            max_bytes:,
            user_agent:,
            deadline:,
            redirects: 0
          }
          fetch_url(source.fetch(:source_url), options)
        end

        def fetch_url(url, options)
          uri = URI.parse(url)
          raise ArgumentError, "unsupported URL scheme" unless %w(http https).include?(uri.scheme)

          options[:timeout] = CityServiceNoticeCollector.send(
            :effective_timeout,
            options.fetch(:timeout),
            options.fetch(:deadline)
          )
          response_data_for(uri, options)
        end

        def response_data_for(uri, options)
          timeout = options.fetch(:timeout)
          max_bytes = options.fetch(:max_bytes)
          user_agent = options.fetch(:user_agent)
          deadline = options.fetch(:deadline)
          redirects = options.fetch(:redirects)
          Net::HTTP.start(
            uri.host,
            uri.port,
            use_ssl: uri.scheme == "https",
            open_timeout: timeout,
            read_timeout: timeout
          ) do |http|
            request = Net::HTTP::Get.new(uri)
            request["User-Agent"] = user_agent
            contact = CitySourceRequestPolicy.contact_email
            request["From"] = contact if contact
            request["Accept"] = "text/html,application/json,application/pdf;q=0.8,*/*;q=0.5"
            request["Range"] = "bytes=0-#{max_bytes.to_i - 1}" if max_bytes.to_i.positive?

            http.request(request) do |response|
              return follow_redirect(response, uri, timeout:, max_bytes:, user_agent:, deadline:, redirects:) if response.is_a?(Net::HTTPRedirection)

              body = read_limited_body(response, max_bytes)
              return {
                http_status: response.code,
                final_url: uri.to_s,
                content_type: response["content-type"].to_s.split(";").first,
                bytes_sampled: body.bytesize
              }
            end
          end
        end

        def follow_redirect(response, uri, **options)
          redirects = options.fetch(:redirects)
          raise "too many redirects" if redirects >= MAX_REDIRECTS

          location = response["location"].to_s
          raise "redirect without location" if location.blank?

          redirect_options = {
            timeout: options.fetch(:timeout),
            max_bytes: options.fetch(:max_bytes),
            user_agent: options.fetch(:user_agent),
            deadline: options.fetch(:deadline),
            redirects: redirects + 1
          }
          fetch_url(URI.join(uri.to_s, location).to_s, redirect_options)
        end

        def read_limited_body(response, max_bytes)
          limit = max_bytes.to_i
          return +"" if limit <= 0

          body = +""
          response.read_body do |chunk|
            remaining = limit - body.bytesize
            break if remaining <= 0

            body << chunk.byteslice(0, remaining).to_s
          end
          body
        end

        def status_for(http_status)
          return "ok" if http_status.between?(200, 399)
          return "warn" if [401, 403, 429].include?(http_status)

          "fail"
        end

        def error_code_for(http_status)
          return if http_status.between?(200, 399)
          return "access_restricted" if [401, 403, 429].include?(http_status)

          "http_error"
        end

        def detail_for(result)
          [
            "content_type=#{result.fetch(:content_type).presence || "unknown"}",
            "bytes_sampled=#{result.fetch(:bytes_sampled)}",
            "final_url=#{result.fetch(:final_url)}"
          ].join(" ")
        end

        def sanitize(value)
          if defined?(Decidim::Bih::SafeErrorMetadata)
            Decidim::Bih::SafeErrorMetadata.sanitize_text(value, max: 240)
          else
            value.to_s.split.join(" ")[0, 240]
          end
        end
      end
    end
  end
end
