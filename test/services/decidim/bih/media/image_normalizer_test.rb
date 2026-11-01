# frozen_string_literal: true

require "test_helper"
require "mini_magick"
require "tempfile"

module Decidim
  module Bih
    module Media
      class ImageNormalizerTest < ActiveSupport::TestCase
        test "strips metadata from report images" do
          source = image_with_comment("SecretCamera")

          normalized = ImageNormalizer.call(io: File.open(source.path, "rb"), filename: "photo.jpg", content_type: "image/jpeg")

          assert normalized
          assert_equal "photo.jpg", normalized[:filename]
          assert_equal "image/jpeg", normalized[:content_type]
          assert_equal "", image_comment(normalized[:io])
        ensure
          source&.close!
        end

        test "returns nil for unprocessable image bytes" do
          attachable = { io: StringIO.new("not an image"), filename: "bad.jpg", content_type: "image/jpeg" }

          assert_nil ImageNormalizer.call(attachable)
        end

        private

        def image_with_comment(comment)
          file = Tempfile.new(["report-photo", ".jpg"], binmode: true)
          MiniMagick::Tool::Convert.new do |convert|
            convert.size "2x2"
            convert.xc "red"
            convert.set "comment", comment
            convert << file.path
          end
          file
        end

        def image_comment(io)
          io.rewind if io.respond_to?(:rewind)
          file = Tempfile.new(["normalized", ".jpg"], binmode: true)
          file.write(io.read)
          file.close
          MiniMagick::Image.open(file.path)["%c"]
        ensure
          file&.close!
          io.rewind if io.respond_to?(:rewind)
        end
      end
    end
  end
end
