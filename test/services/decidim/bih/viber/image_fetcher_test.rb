# frozen_string_literal: true

require "test_helper"
require "mini_magick"
require "stringio"
require "tempfile"
require "webmock/minitest"

module Decidim
  module Bih
    module Viber
      class ImageFetcherTest < ActiveSupport::TestCase
        ALLOWED_URL = "https://cdn.viber.com/path/photo.png"

        setup { WebMock.disable_net_connect!(allow_localhost: true) }
        teardown do
          WebMock.reset!
          WebMock.allow_net_connect!
        end

        def fetcher
          ImageFetcher.new
        end

        test "allowlisted image URL returns an in-memory attachable" do
          stub_request(:get, ALLOWED_URL)
            .to_return(status: 200, body: png_body, headers: { "Content-Type" => "image/png" })

          result = fetcher.call(ALLOWED_URL)

          assert_kind_of Hash, result
          assert_equal "image/png", result[:content_type]
          assert_equal "photo.png", result[:filename]
          assert_respond_to result[:io], :read
          assert result[:io].read.bytesize.positive?
        end

        test "derives a default filename when the path has no usable basename" do
          url = "https://cdn.viber.com/download"
          stub_request(:get, url)
            .to_return(status: 200, body: jpeg_body, headers: { "Content-Type" => "image/jpeg" })

          result = fetcher.call(url)

          assert_equal "viber_image.jpg", result[:filename]
        end

        test "strips a charset parameter from the content type" do
          stub_request(:get, ALLOWED_URL)
            .to_return(status: 200, body: png_body, headers: { "Content-Type" => "image/png; charset=binary" })

          assert_equal "image/png", fetcher.call(ALLOWED_URL)[:content_type]
        end

        test "non-allowlisted host returns nil without any request" do
          assert_nil fetcher.call("https://evil.example.com/photo.png")
          assert_not_requested :get, "https://evil.example.com/photo.png"
        end

        test "a lookalike host that merely ends with an allowed suffix is refused" do
          assert_nil fetcher.call("https://evilviber.com/photo.png")
        end

        test "oversized body is rejected mid-read and returns nil" do
          big = ("a" * (Decidim::Bih::Viber::ImageFetcher::MAX_BYTES + 1024)).b
          stub_request(:get, ALLOWED_URL)
            .to_return(status: 200, body: big, headers: { "Content-Type" => "image/png" })

          assert_nil fetcher.call(ALLOWED_URL)
        end

        test "non-image content type returns nil" do
          stub_request(:get, ALLOWED_URL)
            .to_return(status: 200, body: "<html>", headers: { "Content-Type" => "text/html" })

          assert_nil fetcher.call(ALLOWED_URL)
        end

        test "an SVG image content type is refused" do
          stub_request(:get, ALLOWED_URL)
            .to_return(status: 200, body: "<svg/>", headers: { "Content-Type" => "image/svg+xml" })

          assert_nil fetcher.call(ALLOWED_URL)
        end

        test "a non-success status returns nil" do
          stub_request(:get, ALLOWED_URL)
            .to_return(status: 404, body: "", headers: { "Content-Type" => "image/png" })

          assert_nil fetcher.call(ALLOWED_URL)
        end

        test "failed URL logging strips signed query strings and fragments" do
          url = "https://cdn.viber.com/path/photo.png?token=abc123&X-Amz-Signature=def456#download"
          stub_request(:get, "https://cdn.viber.com/path/photo.png")
            .with(query: hash_including("token" => "abc123", "X-Amz-Signature" => "def456"))
            .to_return(status: 403, body: "", headers: { "Content-Type" => "image/png" })

          log = capture_fetcher_log { assert_nil fetcher.call(url) }

          assert_includes log, "https://cdn.viber.com/path/photo.png"
          assert_not_includes log, "token=abc123"
          assert_not_includes log, "X-Amz-Signature"
          assert_not_includes log, "#download"
        end

        test "a transport error returns nil instead of raising" do
          stub_request(:get, ALLOWED_URL).to_raise(Faraday::ConnectionFailed.new("boom"))

          assert_nothing_raised { assert_nil fetcher.call(ALLOWED_URL) }
        end

        test "a timeout returns nil instead of raising" do
          stub_request(:get, ALLOWED_URL).to_timeout

          assert_nil fetcher.call(ALLOWED_URL)
        end

        test "embedded userinfo in the URL is refused" do
          assert_nil fetcher.call("https://attacker@cdn.viber.com/photo.png")
        end

        test "an IPv4-literal host is refused even off-allowlist" do
          assert_nil fetcher.call("https://127.0.0.1/photo.png")
        end

        test "an IPv6-literal host is refused" do
          assert_nil fetcher.call("https://[::1]/photo.png")
        end

        test "a non-http scheme is refused" do
          assert_nil fetcher.call("file:///etc/passwd")
        end

        test "a blank URL returns nil" do
          assert_nil fetcher.call(nil)
          assert_nil fetcher.call("")
        end

        test "the host allowlist is overridable via constructor" do
          url = "https://media.example.org/p.png"
          stub_request(:get, url)
            .to_return(status: 200, body: png_body, headers: { "Content-Type" => "image/png" })

          custom = ImageFetcher.new(host_allowlist: %w(example.org))

          assert_equal "image/png", custom.call(url)[:content_type]
        end

        private

        def capture_fetcher_log
          output = StringIO.new
          logger = ActiveSupport::Logger.new(output)
          original_logger = Rails.logger

          Rails.logger = logger
          yield

          output.string
        ensure
          Rails.logger = original_logger if defined?(original_logger)
        end

        def png_body
          image_body("png")
        end

        def jpeg_body
          image_body("jpg")
        end

        def image_body(extension)
          file = Tempfile.new(["viber-image", ".#{extension}"], binmode: true)
          MiniMagick::Tool::Convert.new do |convert|
            convert.size "2x2"
            convert.xc "red"
            convert << file.path
          end
          File.binread(file.path)
        ensure
          file&.close!
        end
      end
    end
  end
end
