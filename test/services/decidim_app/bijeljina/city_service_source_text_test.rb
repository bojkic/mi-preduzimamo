# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/synthetic_event_source_registry"

module DecidimApp
  module Bijeljina
    class CityServiceSourceTextTest < ActiveSupport::TestCase
      include SyntheticEventSourceRegistry
      SourceText = CityServiceNoticeCollector::SourceText
      REPLACEMENT_CHARACTER = [0xFFFD].pack("U")

      test "a UTF-8 page with one truncated lead byte is scrubbed, never re-read as Windows-1250" do
        body = synthetic_archive_body
        assert_not body.dup.force_encoding(Encoding::UTF_8).valid_encoding?

        text = SourceText.normalize(body, content_type: "text/html", charset: "UTF-8")
        assert_equal Encoding::UTF_8, text.encoding
        assert text.valid_encoding?
        assert_equal 13, status_labels(text).count("Prijava riješena")
        assert_equal 2, status_labels(text).count("Obrada u toku")
        assert_equal 1, text.scan(REPLACEMENT_CHARACTER).size
        assert_not_includes text, "rijeĹˇena"

        # Independently authored malformed UTF-8 exercises whole-document fallback decoding.
        fallback = body.dup.force_encoding("Windows-1250").encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
        assert_equal 13, status_labels(fallback).count("Prijava rijeĹˇena")
        assert_includes fallback, "OdbaÄŤeni zahtjevi"
      end

      test "the same page without a transport charset is normalized from its own meta declaration" do
        body = synthetic_archive_body
        text = SourceText.normalize(body, content_type: "text/html")
        assert text.valid_encoding?
        assert_equal 13, status_labels(text).count("Prijava riješena")
      end

      test "a document declared in a legacy charset is transcoded from that charset" do
        latin = "<html><head><meta charset=\"windows-1250\"></head><body><p>Prijava riješena</p></body></html>".encode("Windows-1250").b
        assert_equal "Prijava riješena", SourceText.normalize(latin, content_type: "text/html", charset: "windows-1250")[%r{<p>(.*?)</p>}, 1]
        assert_equal "Prijava riješena", SourceText.normalize(latin, content_type: "text/html; charset=windows-1250")[%r{<p>(.*?)</p>}, 1]
        assert_equal "Prijava riješena", SourceText.normalize(latin, content_type: "text/html")[%r{<p>(.*?)</p>}, 1]
      end

      test "the document's own declaration is used only when the transport carries no charset" do
        utf8 = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><rss><channel><title>Упозорење</title></channel></rss>".b
        assert_equal "Упозорење", SourceText.normalize(utf8, content_type: "application/rss+xml")[%r{<title>(.*?)</title>}, 1]
        assert_equal Encoding::UTF_8, SourceText.declared_charset(utf8, "")
        assert_equal Encoding::Windows_1250, SourceText.declared_charset(utf8, "text/xml; charset=windows-1250")
        assert_equal Encoding::Windows_1250, SourceText.declared_charset(utf8, "text/xml", charset: "windows-1250")
        assert_equal Encoding::UTF_8, SourceText.declared_charset("<html>".b, "text/html; charset=x-unknown")
      end

      test "binary documents keep their bytes and checksum" do
        pdf = "%PDF-1.7 \xFF\xFE binary".b
        assert_equal pdf, SourceText.normalize(pdf, content_type: "application/pdf").b
        assert_equal pdf, SourceText.normalize(pdf, content_type: "text/html").b
        assert_equal Digest::SHA256.hexdigest(pdf), Digest::SHA256.hexdigest(SourceText.normalize(pdf, content_type: ""))
        assert_equal Encoding::ASCII_8BIT, SourceText.normalize("\x89PNG".b, content_type: "image/png").encoding
      end

      test "the collector hands parsers a valid UTF-8 body so status labels survive a truncated excerpt" do
        body = synthetic_archive_body
        fetcher = ->(**) { { body:, http_status: 200, content_type: "text/html", charset: "UTF-8", final_url: "https://sistem48-public-archive.example.invalid/source" } }
        check = CityServiceNoticeCollector.check(keys: ["sistem48_public_archive"], fetcher:).first
        assert_equal :ok, check.status
        notice = check.notices.first
        assert_includes notice.body, "Riješeni zahtjevi"
        assert_includes notice.body, "Odbačeni zahtjevi"
        assert_includes notice.body, "Prijava riješena 13"
        assert_equal({ "Prijava riješena" => 13, "Obrada u toku" => 2 }, notice.metadata["status_counts"])
        assert_equal 15, notice.metadata["entries"]
        assert_not_includes notice.body, "Tekst prijave"
        assert_no_match(/Ĺ|Ä|Ă/, notice.body)
        assert_not_includes notice.body, REPLACEMENT_CHARACTER
      end

      test "a transport charset overrides the page's own declaration through the collector" do
        # The same archive served as Windows-1250 while its meta still says utf-8.
        body = synthetic_archive_body.force_encoding(Encoding::UTF_8).scrub("").encode("Windows-1250", undef: :replace).b
        fetcher = ->(**) { { body:, http_status: 200, content_type: "text/html", charset: "windows-1250", final_url: "https://sistem48-public-archive.example.invalid/source" } }
        check = CityServiceNoticeCollector.check(keys: ["sistem48_public_archive"], fetcher:).first
        assert_equal :ok, check.status
        assert_equal({ "Prijava riješena" => 13, "Obrada u toku" => 2 }, check.notices.first.metadata["status_counts"])
        assert_includes check.notices.first.body, "Odbačeni zahtjevi"
      end

      private

      # Construct exactly one truncated UTF-8 lead byte outside status labels.
      def synthetic_archive_body
        body = file_fixture("synthetic/sistem48_archive_fifteen.html").binread
        body = body.sub("AUTHORED_FRAGMENT".b, "izmišljeni fragment ".b + [0xC5].pack("C"))
        body.sub("</body>".b, "<select name='tip_zahteva'><option>Izmišljeni tip</option></select><select name='zahtevi_status'><option>Riješeni zahtjevi</option><option>Odbačeni zahtjevi</option></select><h2>Riješeni zahtjevi</h2><h2>Odbačeni zahtjevi</h2></body>".b)
      end

      def status_labels(html)
        html.scan(/pull-right">([^<]*)</).flatten.map(&:strip)
      end
    end
  end
end
