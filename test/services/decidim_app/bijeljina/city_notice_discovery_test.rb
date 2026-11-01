# frozen_string_literal: true

require "test_helper"

module DecidimApp
  module Bijeljina
    class CityNoticeDiscoveryTest < ActiveSupport::TestCase
      URL = "https://www.gradbijeljina.org/lat/news/obavjestenja/"

      test "parent and RSS relative Cyrillic mirrors deduplicate by provider article id" do
        html = '<div class="blog__content"><article><h2 class="entry__title"><a href="/lat/news/obavjestenja/obavjestenja/7256.poziv.html">Javni poziv</a></h2></article></div>'
        rss = "<rss><channel><title>Grad Bijeljina</title><lastBuildDate>not-a-date</lastBuildDate>" \
              "<item><title>Јавни позив</title><link>/cir/vesti/7256._poziv.html</link></item>" \
              "<item><title>Јавни увид</title><link>/cir/vesti/7257._uvid.html</link></item></channel></rss>"
        links = CityNoticeDiscovery.call(html:, source_url: URL, rss_body: rss)
        assert_equal(%w(7256 7257), links.map { |link| CityNoticeDiscovery.article_id(link) })
      end

      test "unapproved external paths and XML declarations cannot become detail fetches" do
        assert_nil CityNoticeDiscovery.approved_article("https://evil.example/7256.poziv.html", URL)
        assert_nil CityNoticeDiscovery.approved_article("/admin/7256.poziv.html", URL)
        assert_raises(PublicCallsPreparation::InvalidSource) { CityNoticeDiscovery.rss_links('<!DOCTYPE rss SYSTEM "file:///etc/passwd"><rss/>') }
        assert_raises(PublicCallsPreparation::InvalidSource) { CityNoticeDiscovery.rss_links("<html>template</html>") }
      end
    end
  end
end
