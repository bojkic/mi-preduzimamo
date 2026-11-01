# frozen_string_literal: true

require "net/http"
require "openssl"
require "timeout"
require "uri"

require_relative "city_source_request_policy"

module DecidimApp
  module Bijeljina
    # Background-only network adapter. Re-fetches known canonical URLs so an edit
    # is discoverable; consumers persist versioned parser candidates separately.
    class CityServiceArticleFetcher
      MAX_ITEMS = 8
      SOURCE_MAX_ITEMS = { "water_service" => 12, "city_official_notices" => 24 }.freeze
      MAX_BYTES = 262_144
      MAX_TOTAL_BYTES = 1_048_576
      SOURCE_MAX_TOTAL_BYTES = { "city_official_notices" => 24 * MAX_BYTES }.freeze
      MAX_SECONDS = 20
      SOURCE_MAX_SECONDS = { "city_official_notices" => 90 }.freeze
      MAX_REDIRECTS = 3
      Result = Struct.new(:articles, :status, :error_code, :failures, keyword_init: true)
      class FetchError < StandardError; end

      class DeadlineExceeded < FetchError; end

      def initialize(source:, fetcher: nil, max_items: nil, max_bytes: MAX_BYTES, timeout: nil)
        @source = source
        @fetcher = fetcher || method(:fetch_url)
        @max_items = (max_items || SOURCE_MAX_ITEMS.fetch(source.fetch(:key), MAX_ITEMS)).to_i.clamp(1, SOURCE_MAX_ITEMS.fetch(source.fetch(:key), MAX_ITEMS))
        @max_bytes = max_bytes.to_i.clamp(1, MAX_BYTES)
        source_key = source.fetch(:key)
        @max_total_bytes = SOURCE_MAX_TOTAL_BYTES.fetch(source_key, MAX_TOTAL_BYTES)
        max_seconds = SOURCE_MAX_SECONDS.fetch(source_key, MAX_SECONDS)
        @timeout = (timeout || max_seconds).to_f.clamp(0.01, max_seconds)
      end

      def call(html:, source_url: source.fetch(:source_url), deadline: nil, fetched_at: Time.current, **_observation_metadata)
        @expires_at = monotonic + [@timeout, deadline ? deadline.remaining_seconds.to_f : @timeout].min
        @links_truncated = false
        articles = []
        failures = []
        total_bytes = 0
        links = article_links(html, source_url, now: fetched_at)
        if links.empty?
          return Result.new(articles: [], status: :ok, failures: []) if source.fetch(:key) == "bulky_waste" &&
                                                                    Nokogiri::HTML(html.to_s).at_css(".categoryBlog .categoryTitle h2 a")

          return Result.new(articles: [], status: :unreviewed, error_code: :article_links_missing)
        end

        collect_links(links, articles, failures, total_bytes)
        failures << { "error_code" => "article_selection_truncated" } if @links_truncated
        Result.new(articles:, status: failures.empty? ? :ok : :unreviewed,
                   error_code: failures.first&.fetch("error_code")&.to_sym, failures:)
      end

      private

      attr_reader :source

      def collect_links(links, articles, failures, total_bytes)
        links.each do |url|
          extracted, bytes = fetch_article_with_retry(url)
          total_bytes += bytes
          if total_bytes > @max_total_bytes
            failures << { "url" => url, "error_code" => "article_total_byte_limit" }
            break
          end

          articles.concat(extracted.first(1))
          remaining!
        rescue DeadlineExceeded
          failures << { "url" => url, "error_code" => "article_deadline_exceeded" }
          break
        rescue CitySourceRequestPolicy::PolicyError => e
          failures << { "url" => url, "error_code" => e.code.to_s, "retry_at" => e.retry_at&.iso8601 }
          break # A shared-host policy refusal applies to subsequent articles too.
        rescue FetchError, IOError, SystemCallError, Timeout::Error, URI::InvalidURIError, SocketError, OpenSSL::SSL::SSLError => e
          failures << { "url" => url, "error_code" => "article_fetch_incomplete", "error_class" => e.class.name }
        end
      end

      # The City Hall CDN has twice closed the TLS connection at the same late
      # article in a 20-card batch while a direct request succeeded immediately
      # afterward. Retry that transport failure once, inside the existing batch
      # deadline and shared-host pacing; never retry an HTTP or policy refusal.
      def fetch_article_with_retry(url)
        attempts = 0
        begin
          attempts += 1
          fetch_article(url)
        rescue IOError, SystemCallError, Timeout::Error, SocketError, OpenSSL::SSL::SSLError
          raise unless source.fetch(:key) == "city_official_notices" && attempts == 1

          remaining!
          retry
        end
      end

      def fetch_article(url)
        seconds = remaining!
        response = Timeout.timeout(seconds, DeadlineExceeded) do
          @fetcher.call(url:, timeout: seconds, max_bytes: @max_bytes)
        end
        extract_response(response, url:)
      end

      def extract_response(response, url:)
        final_url = CityServiceArticle.approved_url(response.fetch(:final_url, url), url)
        raise FetchError, "invalid final article URL" unless final_url && allowed_article_path?(final_url)
        raise FetchError, "article HTTP failure" unless response.fetch(:http_status).to_i == 200
        raise FetchError, "article content type" unless response.fetch(:content_type, "text/html").start_with?("text/html")

        body = response.fetch(:body).to_s
        raise FetchError, "article byte limit" if body.bytesize > @max_bytes
        raise FetchError, "missing primary article" unless Nokogiri::HTML(body).at_css(".single-post-wrap.entry-content, .entry__article, article .entry-content, article .post-content, article, .item-page")

        extracted = CityServiceArticle.extract(html: body, source_url: final_url)
        raise FetchError, "incomplete article" unless extracted.all?(&:complete)

        [extracted, body.bytesize]
      end

      def article_links(html, source_url, now:)
        document = Nokogiri::HTML(html.to_s)
        if document.at_css(".single-post-wrap.entry-content")
          canonical = document.at_css('link[rel="canonical"]')&.[]("href") || source_url
          url = CityServiceArticle.approved_url(canonical, source_url)
          return url && allowed_article_path?(url) ? [url] : []
        end
        document.css("nav, footer, aside, .related, .related-posts, #comments").remove
        selector = case source.fetch(:key)
                   when "city_official_notices" then ".blog__content article h2.entry__title a"
                   when "bulky_waste" then ".categoryBlog .categoryTitle h2 a"
                   else "article a, .entry-title a, h2 a, h3 a, .card-title a"
                   end
        links = document.css(selector).filter_map do |node|
          next if source.fetch(:key) == "bulky_waste" &&
                  !CityServiceContentFilter.relevant?("bulky_waste", node.text, now:)

          url = CityServiceArticle.approved_url(node["href"], source_url)
          url if url && allowed_article_path?(url)
        end.uniq
        @links_truncated = links.size > @max_items
        links.first(@max_items)
      end

      def allowed_article_path?(url)
        path = URI.parse(url).path
        return path.match?(%r{\A/v2/vodosnabdijevanje-[^/]+/?\z}) if source.fetch(:key) == "water_service"
        return path.match?(CityNoticeDiscovery::ARTICLE_PATH) if source.fetch(:key) == "city_official_notices"

        !path.match?(%r{/(?:category|tag|author|page)/})
      end

      def fetch_url(url:, timeout:, max_bytes:, redirects: 0)
        uri = URI.parse(url)
        seconds = [remaining!, timeout].min
        policy = CitySourceRequestPolicy.default
        seconds = policy.before_request(uri, timeout: seconds)
        Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: seconds, read_timeout: seconds) do |http|
          request = Net::HTTP::Get.new(uri)
          request["User-Agent"] = CityServiceNoticeCollector::DEFAULT_USER_AGENT
          request["Accept"] = "text/html"
          http.request(request) do |response|
            policy.observe_response(uri, response)
            if response.is_a?(Net::HTTPRedirection)
              raise FetchError, "too many article redirects" if redirects >= MAX_REDIRECTS

              target = CityServiceArticle.approved_url(response["location"], url)
              raise FetchError, "invalid article redirect" unless target && allowed_article_path?(target)

              return fetch_url(url: target, timeout: remaining!, max_bytes:, redirects: redirects + 1)
            end
            body = +""
            response.read_body do |chunk|
              remaining!
              raise FetchError, "article byte limit" if body.bytesize + chunk.bytesize > max_bytes

              body << chunk
            end
            return { http_status: response.code.to_i, final_url: uri.to_s, content_type: response["content-type"].to_s, body: }
          end
        end
      end

      def remaining!
        seconds = @expires_at - monotonic
        raise DeadlineExceeded, "article refresh deadline" unless seconds.positive?

        seconds
      end

      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
