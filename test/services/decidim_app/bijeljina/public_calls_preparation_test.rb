# frozen_string_literal: true

require "test_helper"

module DecidimApp
  module Bijeljina
    class PublicCallsPreparationTest < ActiveSupport::TestCase
      URL = "https://www.gradbijeljina.org/lat/news/obavjestenja//7252.call.html"
      Matcher = Struct.new(:unused) do
        def match(*)
          Struct.new(:slugs, :targeting_level, :coverage).new([], "unknown", {})
        end
      end

      setup do
        @preparation = PublicCallsPreparation.new(organization: Struct.new(:id).new(1), source_store: Object.new, area_matcher: Matcher.new)
        @now = Time.iso8601("2026-09-15T08:00:00Z")
      end

      test "assessment interval and footer dates cannot replace the application window" do
        body = "Prijave od 01.09.2026. do 20.09.2026.\nOcjenjivanje prijava od 21.09.2026. do 30.09.2026."
        item = extract(body)
        assert_equal "2026-09-20", item["closes_on"]
        assert_equal "2026-09-21", item["assessment_opens_on"]
        assert_equal "2026-09-30", item["assessment_closes_on"]
        assert_equal "2026-09-10", item["source_published_on"]
        assert_equal "public_call", item["notice_type"]
      end

      test "language mirrors retain provider numeric identity" do
        latin = extract("Prijave do 20.09.2026.")
        cyrillic = extract("Prijave do 20.09.2026.", url: "https://www.gradbijeljina.org/cir/vesti/7252._poziv.html")
        assert_equal latin["id"], cyrillic["id"]
        assert_equal "7252", latin["provider_document_id"]
      end

      test "hearings and public display are separate notice types" do
        assert_equal "public_hearing", extract("Javna rasprava od 01.09.2026. do 20.09.2026.", title: "Javna rasprava o budžetu")["notice_type"]
        assert_equal "public_display", extract("Javni uvid od 01.09.2026. do 20.09.2026.", title: "Javni uvid u plan")["notice_type"]
      end

      test "result lists retain only a closed notice without named body or attachments" do
        item = extract('Konačna lista korisnika: Osoba Test 1234567890123 <a href="/results.pdf">Rezultati</a>', title: "Rezultati javnog konkursa")
        assert_equal "closed", item["temporal_status"]
        assert_equal "results", item["document_role"]
        assert_equal "result_body_excluded", item["privacy_status"]
        assert_empty item["attachments"]
        assert_not_includes JSON.generate(item), "Osoba Test"
        assert_nil item["eligibility_evidence"]
      end

      private

      def extract(body, title: "Javni poziv za prijave", url: URL)
        html = %(<div class="blog__content"><article><div class="single-post__entry-header"><h1 class="entry-title">#{title}</h1>) +
               %(<div class="entry__meta">10.09.2026.</div></div><div class="entry__article">#{body}<footer>Prijave do 20.09.2030.</footer></div></article></div>)
        @preparation.extract(html, url, @now)
      end
    end
  end
end
