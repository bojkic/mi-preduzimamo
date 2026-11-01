# frozen_string_literal: true

require "digest"
require "nokogiri"
require "time"
require "uri"

module DecidimApp
  module Bijeljina
    # Pure primary-content extraction, shared by the background fetcher and parsers.
    module CityServiceArticle
      NON_CONTENT = "script, style, nav, footer, aside, form, .related, .related-posts, .relatedposts, " \
                    ".section-blog-info, .blog-posts, #comments, .comments-area, .entry-categories, .entry-social, " \
                    ".related-posts-section, .editors-picks-section, .mega-menu"
      Article = Struct.new(:html, :source_url, :source_published_at, :source_updated_at, :content_version, :title, :complete, keyword_init: true)

      module_function

      def extract(html:, source_url:)
        source_html = html.to_s
        truncated_article = source_html.scan(/<article\b/i).size > source_html.scan(%r{</article\s*>}i).size
        document = Nokogiri::HTML(source_html)
        published = timestamp(document.at_css('meta[property="article:published_time"]')&.[]("content"))
        updated = timestamp(document.at_css('meta[property="article:modified_time"]')&.[]("content"))
        title = document.at_css("h1")&.text.to_s.strip
        canonical = document.at_css('link[rel="canonical"]')&.[]("href")
        canonical = approved_url(canonical, source_url) || source_url
        document.css(NON_CONTENT).remove
        host = URI.parse(source_url).host
        roots = if host == "www.gradbijeljina.org" && document.at_css(".entry__article")
                  [document.at_css(".entry__article")]
                elsif host == "www.komunalacbn.com" && document.at_css(".item-page")
                  [document.at_css(".item-page")]
                else
                  primary_roots(document)
                end
        roots.map do |root|
          build_article(root, source_url:, canonical:, published:, updated:, title:, truncated_article:)
        end
      end

      def primary_roots(document)
        roots = document.css(".single-post-wrap.entry-content, article .entry-content, article .post-content")
        roots = document.css("article, .post, .entry, .news, .vijest") if roots.empty?
        roots = [document.at_css("body") || document] if roots.empty?
        roots.reject { |node| node.ancestors.any? { |ancestor| roots.include?(ancestor) } }
      end

      # Keep the publication and completeness evidence together when projecting
      # one extracted primary-content root into its immutable source snapshot.
      def build_article(root, **metadata)
        local_url = root.at_css('h1 a, h2 a, h3 a, a[rel="bookmark"]')&.[]("href")
        local_url = approved_url(local_url, metadata.fetch(:source_url)) || metadata.fetch(:canonical)
        local_publication = timestamp(root.at_css("time[datetime]")&.[]("datetime")) || metadata[:published]
        local_title = root.at_css("h1, h2, h3")&.text.to_s.strip.presence || metadata[:title]
        incomplete = root.text.strip.match?(/(?:\.{3}|…|\[\.\.\.\])\s*(?:Read more|Pročitaj više)?\s*\z/i) ||
                     root.at_css(".read-more, .more-link, .moretag").present?
        Article.new(html: root.to_html, source_url: local_url, source_published_at: local_publication,
                    source_updated_at: metadata[:updated], title: local_title, complete: !incomplete && !metadata[:truncated_article],
                    content_version: Digest::SHA256.hexdigest(root.text.gsub(/[[:space:]\u00a0]+/, " ").strip))
      end

      def approved_url(value, base)
        return if value.to_s.empty?

        original = URI.parse(base)
        target = URI.join(base, value)
        return unless same_origin?(target, original)

        prefix = original.path.start_with?("/v2/") ? "/v2/" : "/"
        return unless target.path.start_with?(prefix)
        return if target.path.match?(%r{/(?:wp-admin|wp-json|wp-login|feed)(?:/|\.|$)})

        target.fragment = nil
        target.query = nil
        target.to_s
      rescue URI::InvalidURIError
        nil
      end

      def same_origin?(target, original)
        %w(http https).include?(target.scheme) && target.host == original.host && target.port == original.port &&
          !target.userinfo && (original.scheme != "https" || target.scheme == "https")
      end

      def timestamp(value)
        return if value.to_s.empty?

        Time.iso8601(value)
      rescue ArgumentError
        nil
      end
    end
  end
end
