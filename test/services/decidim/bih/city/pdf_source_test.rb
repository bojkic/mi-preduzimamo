# frozen_string_literal: true

require "test_helper"
require "webmock/minitest"

module Decidim
  module Bih
    module City
      # Unit-tests the shared, size-bounded PDF download extracted from Budget and
      # WasteSchedule, so the MAX_PDF_BYTES guard is verified in one place for
      # both callers.
      class PdfSourceTest < ActiveSupport::TestCase
        URL = "https://example.test/source.pdf"

        # A throwaway error class standing in for BudgetError / WasteScheduleError.
        class SampleError < StandardError; end

        setup { WebMock.disable_net_connect!(allow_localhost: true) }

        teardown do
          WebMock.reset!
          WebMock.allow_net_connect!
        end

        def download(timeout: 5)
          PdfSource.download_to_tempfile(
            url: URL, timeout: timeout, error_class: SampleError,
            label: "Sample PDF", prefix: "pdf_source_test"
          )
        end

        test "downloads a successful body into a readable tempfile" do
          stub_request(:get, URL).to_return(status: 200, body: "%PDF-1.4 hello")

          file = download
          file.rewind

          assert_equal "%PDF-1.4 hello", file.read
        ensure
          file&.close!
        end

        test "uses the documented 25 MiB cap" do
          assert_equal 25 * 1024 * 1024, PdfSource::MAX_PDF_BYTES
        end

        test "raises when the body exceeds MAX_PDF_BYTES" do
          oversize = "x" * (PdfSource::MAX_PDF_BYTES + 1)
          stub_request(:get, URL).to_return(status: 200, body: oversize)

          error = assert_raises(SampleError) { download }
          assert_match("Sample PDF too large", error.message)
        end

        test "accepts a body exactly at the cap" do
          at_cap = "x" * PdfSource::MAX_PDF_BYTES
          stub_request(:get, URL).to_return(status: 200, body: at_cap)

          file = download

          assert_equal PdfSource::MAX_PDF_BYTES, File.size(file.path)
        ensure
          file&.close!
        end

        test "raises with the label on a non-success status" do
          stub_request(:get, URL).to_return(status: 502)

          error = assert_raises(SampleError) { download }
          assert_match("Sample PDF returned HTTP 502", error.message)
        end

        test "raises with the label on a transport error" do
          stub_request(:get, URL).to_timeout

          error = assert_raises(SampleError) { download }
          assert_match("Sample PDF transport error", error.message)
        end
      end
    end
  end
end
