# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    module Milica
      module BoardNoticeReference
        module_function

        def post_id(text)
          reference = text.to_s.strip.match(/\A(.+?) #([1-9]\d{0,15})[.!]?\z/)
          return unless reference && ["procitaj objavu sa table", "read board notice"].include?(Decidim::Bih::Text.fold(reference[1]))

          reference[2].to_i
        end
      end
    end
  end
end
