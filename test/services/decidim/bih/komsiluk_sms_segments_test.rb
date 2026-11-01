# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    class KomsilukSmsSegmentsTest < ActiveSupport::TestCase
      test "GSM single and concatenated messages use the actual septet limits" do
        assert_equal 1, Komsiluk::SmsSegments.estimate("a" * 160)[:segments]
        assert_equal 2, Komsiluk::SmsSegments.estimate("a" * 161)[:segments]
        assert_equal 2, Komsiluk::SmsSegments.estimate("a" * 306)[:segments]
        assert_equal 3, Komsiluk::SmsSegments.estimate("a" * 307)[:segments]
        assert_equal 2, Komsiluk::SmsSegments.estimate("^" * 81)[:segments]
        assert_equal "GSM-7", Komsiluk::SmsSegments.estimate("{}€")[:encoding]
      end

      test "Serbian scripts and supplementary characters are billed as UTF16 units without transliteration" do
        assert_equal({ encoding: "Unicode", units: 70, segments: 1 }, Komsiluk::SmsSegments.estimate("Ж" * 70))
        assert_equal 2, Komsiluk::SmsSegments.estimate("č" * 71)[:segments]
        assert_equal 2, Komsiluk::SmsSegments.estimate("😀" * 36)[:segments]
        assert_equal 72, Komsiluk::SmsSegments.estimate("😀" * 36)[:units]
        assert_equal 0, Komsiluk::SmsSegments.estimate("")[:segments]
      end
    end
  end
end
