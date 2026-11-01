# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/synthetic_event_source_registry"

module DecidimApp
  module Bijeljina
    # Independently authored teaser/detail grammar; no captured provider page
    # or actual heating-season claim. Only injected fetchers are used.
    class CityServiceHeatingArticlesTest < ActiveSupport::TestCase
      include SyntheticEventSourceRegistry
      LISTING = Rails.root.join("test/fixtures/files/synthetic/heating_listing.html")
      DETAIL = Rails.root.join("test/fixtures/files/synthetic/heating_detail.html")

      setup do
        @source = CityServiceSources.fetch("heating_service")
        @listing = LISTING.read
        @detail = DETAIL.read
      end

      test "the listing publishes only truncated teasers, which is why it never parsed" do
        # The defect in one assertion: every card is cut, so the shared
        # extractor correctly refuses the whole page as incomplete.
        assert_includes @listing, "Pročitaj više..."
        extracted = CityServiceArticle.extract(html: @listing, source_url: @source.fetch(:source_url))
        assert extracted.none?(&:complete), "the teaser listing must not be treated as a complete notice"
      end

      test "detail links are found on the button and keep their query identity" do
        links = CityServiceHeatingArticles.listing_links(@listing, @source.fetch(:source_url))

        assert_equal 5, links.size
        assert_equal "https://heating-service.example.invalid/vijesti-detaljno.php?id=900005", links.first
        assert_includes links, "https://heating-service.example.invalid/vijesti-detaljno.php?id=900004"
        links.each { |link| assert_match(/\?id=\d+\z/, link) }
      end

      test "the shared extractor cannot produce these links, which is why this class exists" do
        # Two independent reasons, both asserted so a future "just reuse the
        # shared fetcher" change fails loudly instead of silently regressing.
        document = Nokogiri::HTML(@listing)
        assert_empty document.css("article a, .entry-title a, h2 a, h3 a, .card-title a")
        stripped = CityServiceArticle.approved_url("vijesti-detaljno.php?id=900004", @source.fetch(:source_url))
        assert_equal "https://heating-service.example.invalid/vijesti-detaljno.php", stripped
      end

      test "an off-source or malformed link is refused" do
        base = URI.parse(@source.fetch(:source_url))

        assert_nil CityServiceHeatingArticles.detail_url("https://evil.example.invalid/vijesti-detaljno.php?id=1", base)
        assert_nil CityServiceHeatingArticles.detail_url("vijesti.php", base)
        assert_nil CityServiceHeatingArticles.detail_url("vijesti-detaljno.php?id=1;drop", base)
        assert_nil CityServiceHeatingArticles.detail_url("", base)
      end

      test "the full notice is complete, titled and dated from its own content" do
        article = CityServiceHeatingArticles.article(html: @detail, source_url: "https://heating-service.example.invalid/vijesti-detaljno.php?id=900004")

        assert article.complete
        assert_includes article.title, "GREJNOJ SEZONI 2040/2041"
        assert_equal Date.new(2040, 9, 14), article.source_published_at.to_date
        assert_equal "Europe/Sarajevo", article.source_published_at.time_zone.name
        assert_includes article.html, "IZMIŠLJENA POTPUNA TESTNA OBAVIJEST"
        assert_equal 64, article.content_version.length
      end

      test "the publication instant is the printed date, not the moment of fetching" do
        # A re-fetched old notice must never be able to look like today's news.
        first = CityServiceHeatingArticles.article(html: @detail, source_url: "https://heating-service.example.invalid/vijesti-detaljno.php?id=900004")
        later = travel_to(Time.utc(2041, 3, 1)) do
          CityServiceHeatingArticles.article(html: @detail, source_url: "https://heating-service.example.invalid/vijesti-detaljno.php?id=900004")
        end

        assert_equal first.source_published_at, later.source_published_at
        assert_equal Date.new(2040, 9, 14), later.source_published_at.to_date
        assert_equal first.content_version, later.content_version
      end

      test "a detail page that is still truncated is not a complete notice" do
        truncated = @detail.sub(%r{<p class="authored-attachment">.*?</p>}m, "<p>Izmišljeni skraćeni tekst...</p>")

        article = CityServiceHeatingArticles.article(html: truncated, source_url: "https://heating-service.example.invalid/vijesti-detaljno.php?id=900004")

        assert_not article.complete
      end

      test "an authored mixed-script A inside Latin words still matches the heating profile" do
        # Reproduce U+0410 inside a Latin token; no captured provider text.
        assert_includes @listing, "OBАVJEŠTENjE"
        assert_includes CityServiceTime.fold("OBАVJEŠTENjE O GREJNOJ SEZONI"), "obavjestenje"
      end

      test "following the teasers yields complete articles through an injected fetcher" do
        result = follower.call(html: @listing, source_url: @source.fetch(:source_url))

        assert_equal :ok, result.status
        assert_nil result.error_code
        assert_equal 5, result.articles.size
        assert result.articles.all?(&:complete)
        assert_equal "https://heating-service.example.invalid/vijesti-detaljno.php?id=900005", result.articles.first.source_url
      end

      test "a listing with no detail links is unreviewed rather than empty-and-fine" do
        result = follower.call(html: "<html><body><p>nema vijesti</p></body></html>", source_url: @source.fetch(:source_url))

        assert_equal :unreviewed, result.status
        assert_equal :article_links_missing, result.error_code
      end

      test "an article fetch failure is reported, not silently dropped" do
        failing = CityServiceHeatingArticles.new(source: @source, fetcher: ->(**_args) { { http_status: 503, final_url: nil, content_type: "text/html", body: "" } })

        result = failing.call(html: @listing, source_url: @source.fetch(:source_url))

        assert_equal :unreviewed, result.status
        assert_equal :article_fetch_incomplete, result.error_code
        assert_empty result.articles
      end

      test "only the heating source may be followed by this class" do
        assert_raises(KeyError) { CityServiceHeatingArticles.new(source: CityServiceSources.fetch("water_service")) }
      end

      private

      def follower(body: nil)
        CityServiceHeatingArticles.new(source: @source, fetcher: lambda do |url:, timeout:, max_bytes:|
          assert_operator timeout, :positive?
          assert_operator max_bytes, :positive?
          { http_status: 200, final_url: url, content_type: "text/html; charset=UTF-8", body: body || @detail }
        end)
      end
    end
  end
end
