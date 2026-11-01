# frozen_string_literal: true

require "digest"
require "net/http"
require "nokogiri"
require "openssl"
require "timeout"
require "uri"

require_relative "city_source_request_policy"

module DecidimApp
  module Bijeljina
    # Follows JP "Gradska toplana" listing cards to the full notice.
    #
    # Why this exists at all: the heating source has been in the catalogue with
    # the right URL since the beginning, and a heating profile has been in
    # CityServiceOfficialPostParser just as long — yet the domain never
    # answered anything. The reason found by source review (task 8a) is that
    # vijesti.php publishes only teasers, every one of them cut at "...", and
    # the scrape followed article links for water_service alone. A heating
    # notice was being parsed from a sentence fragment, which CityServiceArticle
    # correctly refuses as incomplete. Nothing was wrong with the source.
    #
    # The shared CityServiceArticleFetcher cannot do this provider:
    #
    #   * its link selectors look for a heading anchor, and the Toplana card
    #     puts the title in an <h4> with the link on a separate "Pročitaj
    #     više..." button;
    #   * CityServiceArticle.approved_url deliberately drops the query string,
    #     and this provider's whole article identity is `?id=N`.
    #
    # So the heating path gets its own bounded follower rather than a loosened
    # shared one. Provider defects documented by 8a and handled here: a stray
    # </mark> inside <strong>, Cyrillic А (U+0410) inside Latin words, and a
    # date that lives in presentational markup with no datetime attribute.
    #
    # Freshness comes from the DD.MM.YYYY. date inside the article plus a
    # content hash. This provider sends no Last-Modified and no ETag, and two
    # of the four Bijeljina utility hosts send a Last-Modified equal to the
    # request time — HTTP metadata is not a freshness signal here.
    class CityServiceHeatingArticles
      SOURCE_KEY = "heating_service"
      DETAIL_PATH = "/vijesti-detaljno.php"
      MAX_ITEMS = 6
      MAX_BYTES = 262_144
      MAX_TOTAL_BYTES = 1_048_576
      MAX_SECONDS = 20
      DATE_PATTERN = /(?<day>\d{1,2})\.(?<month>\d{1,2})\.(?<year>\d{4})\./
      CONTENT_ROOTS = ".vijesti-detaljno, main .vijesti-detaljno"
      NON_CONTENT = "script, style, nav, footer, aside, form, .breadcrumb, .kontakt"

      Result = Struct.new(:articles, :status, :error_code, keyword_init: true)

      class FetchError < StandardError; end

      class DeadlineExceeded < FetchError; end

      def initialize(source:, fetcher: nil, max_items: MAX_ITEMS, max_bytes: MAX_BYTES, timeout: MAX_SECONDS)
        raise KeyError, "unsupported heating source: #{source.fetch(:key)}" unless source.fetch(:key) == SOURCE_KEY

        @source = source
        @fetcher = fetcher || method(:fetch_url)
        @max_items = max_items.to_i.clamp(1, MAX_ITEMS)
        @max_bytes = max_bytes.to_i.clamp(1, MAX_BYTES)
        @timeout = timeout.to_f.clamp(0.01, MAX_SECONDS)
      end

      # Mirrors CityServiceArticleFetcher#call so the scrape can inject either.
      def call(html:, source_url: source.fetch(:source_url), deadline: nil, **_metadata)
        @expires_at = monotonic + [@timeout, deadline ? deadline.remaining_seconds.to_f : @timeout].min
        links = self.class.listing_links(html, source_url, limit: @max_items)
        return Result.new(articles: [], status: :unreviewed, error_code: :article_links_missing) if links.empty?

        articles = []
        @total_bytes = 0
        # `each` with an append, not `map`: a failure part-way through must
        # leave the notices already fetched in `articles` for the rescue to
        # return as partial evidence.
        links.each { |url| articles << fetch_article(url) } # rubocop:disable Style/MapIntoArray
        Result.new(articles:, status: :ok, error_code: nil)
      rescue DeadlineExceeded
        Result.new(articles: articles || [], status: :unreviewed, error_code: :article_deadline_exceeded)
      rescue CitySourceRequestPolicy::PolicyError => e
        Result.new(articles: articles || [], status: :unreviewed, error_code: e.code)
      rescue FetchError, IOError, SystemCallError, Timeout::Error, URI::InvalidURIError, SocketError, OpenSSL::SSL::SSLError
        Result.new(articles: articles || [], status: :unreviewed, error_code: :article_fetch_incomplete)
      end

      class << self
        # The card link is a button, not a heading anchor, and its identity is
        # the query string. Both are the opposite of the shared extractor's
        # assumptions, which is why this is separate rather than a flag.
        def listing_links(html, source_url, limit: MAX_ITEMS)
          base = URI.parse(source_url.to_s)
          document = Nokogiri::HTML(html.to_s)
          document.css("nav, footer, aside").remove
          document.css('a[href*="vijesti-detaljno"]').filter_map do |node|
            detail_url(node["href"], base)
          end.uniq.first(limit)
        rescue URI::InvalidURIError
          []
        end

        def detail_url(href, base)
          return if href.to_s.strip.empty?

          target = URI.join(base, href)
          return unless target.scheme == base.scheme && target.host == base.host && target.port == base.port
          return unless target.path == DETAIL_PATH
          return unless target.query.to_s.match?(/\Aid=\d+\z/)

          target.fragment = nil
          target.to_s
        rescue URI::InvalidURIError
          nil
        end

        # Build the immutable snapshot the shared parser consumes. The
        # publication instant is Europe/Sarajevo local midnight of the date
        # printed in the article — never the moment we happened to fetch it, so
        # re-fetching a 2023 notice can never present it as today's news.
        def article(html:, source_url:)
          document = Nokogiri::HTML(html.to_s)
          document.css(NON_CONTENT).remove
          root = document.at_css(CONTENT_ROOTS) || document.at_css("main") || document.at_css("body")
          return unless root

          text = normalized_text(root)
          return if text.empty?

          published = published_at(root)
          CityServiceArticle::Article.new(
            html: root.to_html, source_url:, source_published_at: published, source_updated_at: nil,
            title: title(root), complete: complete?(root, text),
            content_version: Digest::SHA256.hexdigest(text)
          )
        end

        def published_at(root)
          match = normalized_text(root).match(DATE_PATTERN)
          return unless match

          date = Date.new(match[:year].to_i, match[:month].to_i, match[:day].to_i)
          ActiveSupport::TimeZone[CityServiceTime::ZONE].local(date.year, date.month, date.day)
        rescue ArgumentError
          nil
        end

        def title(root)
          node = root.at_css("h3.card-title") || root.at_css("h3, h1, h2")
          node&.text.to_s.gsub(/[[:space:]\u00a0]+/, " ").strip.presence
        end

        # The teaser that made this whole domain silent: a listing card's text
        # ends in an ellipsis. A detail page that still does is not a complete
        # notice and must not become an event.
        def complete?(root, text)
          !text.match?(/(?:\.{3}|…|\[\.\.\.\])\s*(?:Pročitaj više|Read more)?\s*\z/i) &&
            root.at_css(".read-more, .more-link, .moretag").nil?
        end

        def normalized_text(node)
          node.text.to_s.gsub(/[[:space:]\u00a0]+/, " ").strip
        end
      end

      private

      attr_reader :source

      # One notice: fetch it, validate it, and refuse anything still truncated.
      # A teaser that survived this far is the original defect and must never
      # become an event.
      def fetch_article(url)
        seconds = remaining!
        response = Timeout.timeout(seconds, DeadlineExceeded) { @fetcher.call(url:, timeout: seconds, max_bytes: @max_bytes) }
        body = validated_body(response, url:)
        @total_bytes += body.bytesize
        raise FetchError, "article byte limit" if @total_bytes > MAX_TOTAL_BYTES

        article = self.class.article(html: body, source_url: url)
        raise FetchError, "incomplete heating article" unless article&.complete

        remaining!
        article
      end

      def validated_body(response, url:)
        raise FetchError, "heating article HTTP failure" unless response.fetch(:http_status).to_i == 200
        raise FetchError, "heating article content type" unless response.fetch(:content_type, "text/html").to_s.start_with?("text/html")

        final = response.fetch(:final_url, url)
        raise FetchError, "heating article redirected off source" unless self.class.detail_url(final, URI.parse(source.fetch(:source_url)))

        body = response.fetch(:body).to_s
        raise FetchError, "heating article byte limit" if body.bytesize > @max_bytes

        body
      end

      def fetch_url(url:, timeout:, max_bytes:)
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
            # The provider serves the detail page directly; a redirect here is
            # unexpected enough to abandon rather than follow.
            raise FetchError, "heating article redirect" if response.is_a?(Net::HTTPRedirection)

            body = +""
            response.read_body do |chunk|
              remaining!
              raise FetchError, "heating article byte limit" if body.bytesize + chunk.bytesize > max_bytes

              body << chunk
            end
            return { http_status: response.code.to_i, final_url: uri.to_s, content_type: response["content-type"].to_s, body: }
          end
        end
      end

      def remaining!
        seconds = @expires_at - monotonic
        raise DeadlineExceeded, "heating article refresh deadline" unless seconds.positive?

        seconds
      end

      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
