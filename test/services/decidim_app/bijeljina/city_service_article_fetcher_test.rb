# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/synthetic_event_source_registry"

module DecidimApp
  module Bijeljina
    class CityServiceArticleFetcherTest < ActiveSupport::TestCase
      include SyntheticEventSourceRegistry
      setup do
        # This branch has fixed city-portal selectors and path grammar under
        # D2; the canonical host is a reference identity, fetched bodies are authored.
        rows = CityServiceSources::SOURCES.map do |row|
          row.fetch(:key) == "city_official_notices" ? row.merge(source_url: "https://www.gradbijeljina.org/lat/news/obavjestenja/").freeze : row
        end
        CityServiceSources.send(:remove_const, :SOURCES)
        CityServiceSources.const_set(:SOURCES, rows.freeze)
        @source = CityServiceSources.fetch("water_service")
        @url = "https://water.example.invalid/v2/vodosnabdijevanje-za-08-septembar-2040-god/"
        @html = Rails.root.join("test/fixtures/files/synthetic/water_article.html").read
      end

      test "background fetch keeps canonical primary article publication and content version" do
        requested = []
        fetcher = lambda do |url:, timeout:, max_bytes:|
          requested << url
          assert_operator timeout, :<=, 20
          assert_equal 262_144, max_bytes
          response(@html, url:)
        end
        result = adapter(fetcher).call(html: listing)
        assert_equal :ok, result.status
        assert_equal [@url], requested
        article = result.articles.sole
        assert_equal @url, article.source_url
        assert_equal Time.iso8601("2040-09-08T05:47:11+02:00"), article.source_published_at
        assert article.complete
        assert_not_includes article.html, "related-posts"
        assert_match(/\A[a-f0-9]{64}\z/, article.content_version)
      end

      test "known URLs are checked again so same URL edits change version" do
        body = @html
        fetcher = ->(url:, **) { response(body, url:) }
        service = adapter(fetcher)
        original = service.call(html: listing).articles.sole
        body = body.sub("14:30", "15:30")
        edited = service.call(html: listing).articles.sole
        assert_equal original.source_url, edited.source_url
        assert_not_equal original.content_version, edited.content_version
      end

      test "listing links and returned final URLs are limited to approved host and article path" do
        calls = []
        fetcher = lambda { |url:, **|
          calls << url
          response(@html, url: "https://example.net/stolen/")
        }
        html = "#{listing}<article><h2><a href=\"https://example.net/v2/vodosnabdijevanje-malicious/\">Notice</a></h2></article>" \
               '<article><h2><a href="/v2/wp-admin/">Admin</a></h2></article>'
        result = adapter(fetcher).call(html:)
        assert_equal [@url], calls
        assert_equal :unreviewed, result.status
        assert_empty result.articles
      end

      test "one total refresh deadline is reduced across articles and timeout does not erase completed details" do
        remaining = Struct.new(:remaining_seconds).new(0.1)
        calls = 0
        fetcher = lambda do |url:, **|
          calls += 1
          sleep 0.2 if calls == 2
          response(@html, url:)
        end
        result = adapter(fetcher).call(html: listing + listing(url: @url.sub("08-", "09-")), deadline: remaining)
        assert_equal :unreviewed, result.status
        assert_equal :article_deadline_exceeded, result.error_code
        assert_equal 1, result.articles.size
      end

      test "byte item and malformed detail limits yield unreviewed without a normal-service claim" do
        result = CityServiceArticleFetcher.new(source: @source, fetcher: ->(url:, **) { response(@html, url:) }, max_bytes: 10).call(html: listing)
        assert_equal :unreviewed, result.status
        assert_empty result.articles
        result = adapter(->(url:, **) { response("<p>Upstream page missing</p>", url:) }).call(html: listing)
        assert_equal :unreviewed, result.status
        assert_empty result.articles
        calls = 0
        fetcher = lambda { |url:, **|
          calls += 1
          response(@html, url:)
        }
        limited = CityServiceArticleFetcher.new(source: @source, fetcher:, max_items: 1).call(html: listing + listing(url: @url.sub("08-", "09-")))
        assert_equal 1, calls
        assert_equal :unreviewed, limited.status
        assert_equal :article_selection_truncated, limited.error_code
      end

      test "city listing teaser is replaced by the complete selected article" do
        source = CityServiceSources.fetch("city_official_notices")
        url = "https://www.gradbijeljina.org/lat/news/obavjestenja/900001.izmisljeni-poziv.html"
        listing_html = "<div class='blog__content'><article><h2 class='entry__title'><a href='#{url}'>Zdravstvena zaštita...</a></h2></article></div>"
        detail_html = "<div class='blog__content'><article><h1>JAVNI POZIV</h1><div class='entry__article'><p>" \
                      "IZMIŠLJENI JAVNI POZIV za raspodjelu sredstava izmišljenim veterinarskim organizacijama za mjere zdravstvene zaštite pasa." \
                      "</p></div></article></div>"
        result = CityServiceArticleFetcher.new(source:, fetcher: ->(url:, **) { response(detail_html, url:) }).call(html: listing_html)
        assert_equal :ok, result.status
        assert_equal url, result.articles.sole.source_url
        assert_includes result.articles.sole.html, "raspodjelu sredstava"
        refute_includes result.articles.sole.html, "Zdravstvena zaštita..."
        assert_equal CityServiceArticleFetcher, CityServiceSourceScrape::ARTICLE_FOLLOWERS.fetch("city_official_notices")
        parser = CityServiceOfficialPostParser.new(organization: create_organization, source:)
        assert_empty parser.call(article: result.articles.sole, fetched_at: Time.iso8601("2040-09-25T09:00:00Z"))
      end

      test "city listing follows all twenty current cards within its bounded source budget" do
        source = CityServiceSources.fetch("city_official_notices")
        base = "https://www.gradbijeljina.org/lat/news/obavjestenja/"
        listing_html = (1..20).map do |number|
          "<div class='blog__content'><article><h2 class='entry__title'><a href='#{base}#{900000 + number}.notice.html'>Notice #{number}</a></h2></article></div>"
        end.join
        detail_html = "<article><div class='entry__article'><p>Complete city notice.</p></div></article>" \
                      "<div class='site-shell'>#{"x" * 60_000}</div>"
        fetched = []
        fetcher = lambda do |url:, **|
          fetched << url
          response(detail_html, url:)
        end

        result = CityServiceArticleFetcher.new(source:, fetcher:).call(html: listing_html)
        assert_equal :ok, result.status
        assert_equal 20, fetched.size
        assert_equal 20, result.articles.size

        extra_cards = (21..25).map do |number|
          "<div class='blog__content'><article><h2 class='entry__title'><a href='#{base}#{900000 + number}.notice.html'>Notice #{number}</a></h2></article></div>"
        end.join
        overflow = CityServiceArticleFetcher.new(source:, fetcher:).call(html: listing_html + extra_cards)
        assert_equal :unreviewed, overflow.status
        assert_equal :article_selection_truncated, overflow.error_code
      end

      test "city retries one transient TLS failure without accepting an incomplete batch" do
        source = CityServiceSources.fetch("city_official_notices")
        url = "https://www.gradbijeljina.org/lat/news/obavjestenja/900002.izmisljeni-test.html"
        listing_html = "<div class='blog__content'><article><h2 class='entry__title'><a href='#{url}'>Notice</a></h2></article></div>"
        detail_html = "<article><div class='entry__article'><p>Complete city notice.</p></div></article>"
        attempts = 0
        fetcher = lambda do |url:, **|
          attempts += 1
          raise OpenSSL::SSL::SSLError, "transient TLS failure" if attempts == 1

          response(detail_html, url:)
        end
        result = CityServiceArticleFetcher.new(source:, fetcher:).call(html: listing_html)
        assert_equal :ok, result.status
        assert_equal 2, attempts
        assert_equal 1, result.articles.size
      end

      test "city still marks batch incomplete after two TLS failures" do
        source = CityServiceSources.fetch("city_official_notices")
        url = "https://www.gradbijeljina.org/lat/news/obavjestenja/900002.izmisljeni-test.html"
        listing_html = "<div class='blog__content'><article><h2 class='entry__title'><a href='#{url}'>Notice</a></h2></article></div>"
        attempts = 0
        fetcher = lambda do |**|
          attempts += 1
          raise OpenSSL::SSL::SSLError, "persistent TLS failure"
        end
        result = CityServiceArticleFetcher.new(source:, fetcher:).call(html: listing_html)
        assert_equal :unreviewed, result.status
        assert_equal :article_fetch_incomplete, result.error_code
        assert_equal 2, attempts
      end

      test "approved canonical URL prevents HTTPS downgrade and escaped v2 path traversal" do
        assert_nil CityServiceArticle.approved_url("http://water.example.invalid/v2/vodosnabdijevanje-x/", @url)
        assert_nil CityServiceArticle.approved_url("../../wp-admin/", @url)
        assert_nil CityServiceArticle.approved_url("https://water.example.invalid:444/v2/vodosnabdijevanje-x/", @url)
      end

      test "failed article is named and later successful articles are retained" do
        second = @url.sub("08-", "09-")
        fetcher = lambda do |url:, **|
          raise IOError, "fixture outage" if url == @url

          response(@html, url:)
        end
        result = adapter(fetcher).call(html: listing + listing(url: second))
        assert_equal :unreviewed, result.status
        assert_equal 1, result.articles.size
        assert_equal @url, result.failures.sole.fetch("url")
        assert_equal "IOError", result.failures.sole.fetch("error_class")
      end

      private

      def adapter(fetcher)
        CityServiceArticleFetcher.new(source: @source, fetcher:)
      end

      def listing(url: @url)
        "<article><h2><a href='#{url}'>Vodosnabdijevanje</a></h2></article>"
      end

      def response(body, url:)
        { http_status: 200, final_url: url, content_type: "text/html", body: }
      end
    end
  end
end
