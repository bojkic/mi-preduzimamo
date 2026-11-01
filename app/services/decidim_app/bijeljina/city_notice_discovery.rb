# frozen_string_literal: true

require "nokogiri"
require "uri"

module DecidimApp
  module Bijeljina
    # Discovery only. RSS summaries and generated feed clocks never become
    # application facts; every selected article still requires bounded review.
    module CityNoticeDiscovery
      RSS_URL = "https://www.gradbijeljina.org/rss/"
      ARTICLE_PATH = %r{\A/(?:(?:lat|sr)/news/(?:obavjestenja|konkursi|novosti)/(?:[a-z0-9_-]*/)*|cir/vesti/)(\d+)\.[^/]+\.html\z}

      module_function

      def call(html:, source_url:, rss_body: nil)
        links = html_links(html, source_url:)
        links.concat(rss_links(rss_body)) if rss_body
        links.uniq { |link| article_id(link) }
      end

      def html_links(html, source_url:)
        primary = Nokogiri::HTML(html.to_s).at_css(".blog__content")
        raise PublicCallsPreparation::InvalidSource, "listing structure unavailable" unless primary && primary.at_css("article")

        primary.css("article h2.entry__title a").filter_map do |node|
          approved_article(node["href"], source_url) if relevant?(node.text)
        end
      end

      def rss_links(body)
        raise PublicCallsPreparation::InvalidSource, "RSS declarations prohibited" if body.match?(/<!DOCTYPE|<!ENTITY/i)

        document = Nokogiri::XML(body) { |config| config.strict.nonet }
        raise PublicCallsPreparation::InvalidSource, "RSS structure unavailable" unless document.at_xpath("/rss/channel/title")

        document.xpath("/rss/channel/item").filter_map do |item|
          approved_article(item.at_xpath("link")&.text, RSS_URL) if relevant?(item.at_xpath("title")&.text)
        end
      rescue Nokogiri::XML::SyntaxError
        raise PublicCallsPreparation::InvalidSource, "invalid city RSS"
      end

      def relevant?(text)
        folded = Decidim::Bih::Text.fold(text.to_s)
        folded.match?(PublicCallsPreparation::CALL_PATTERN)
      end

      def approved_article(value, base)
        return if value.to_s.empty? || value.to_s.bytesize > 2000

        uri = URI.join(base, value.to_s)
        return unless uri.scheme == "https" && uri.host == "www.gradbijeljina.org" && uri.port == 443 && uri.userinfo.nil?
        return unless uri.path.match?(ARTICLE_PATH)

        uri.fragment = uri.query = nil
        uri.to_s
      rescue URI::InvalidURIError
        nil
      end

      def article_id(url)
        URI.parse(url).path.match(ARTICLE_PATH)&.[](1)
      end
    end
  end
end
