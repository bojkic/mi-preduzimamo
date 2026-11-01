# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module Concierge
      class StickersTest < ActiveSupport::TestCase
        # Minimal stand-in for an organization exposing #host.
        Org = Struct.new(:host, keyword_init: true)

        test "url_for builds an absolute host-scoped PNG url for a known id" do
          url = Stickers.url_for(:prijavljeno, organization: Org.new(host: "mi.example.com"))
          assert_equal "https://mi.example.com/mi/stickers/prijavljeno.png", url
        end

        test "url_for accepts a string id" do
          url = Stickers.url_for("glas", organization: Org.new(host: "mi.example.com"))
          assert_equal "https://mi.example.com/mi/stickers/glas.png", url
        end

        test "url_for returns nil for an unknown id (no 404 image)" do
          assert_nil Stickers.url_for(:nepostojeci, organization: Org.new(host: "mi.example.com"))
        end

        test "url_for falls back to the default host when the org has none" do
          assert_equal "https://#{Decidim::Bih.default_host}/mi/stickers/hvala.png",
                       Stickers.url_for(:hvala, organization: Org.new(host: nil))
        end

        test "url_for falls back to the default host when no organization is given" do
          assert_equal "https://#{Decidim::Bih.default_host}/mi/stickers/bravo.png",
                       Stickers.url_for(:bravo)
        end

        test "every advertised id is a known sticker" do
          [:prijavljeno, :podrzano, :glas, :hvala, :preuzimamo, :rijeseno, :stize, :volim, :bravo].each do |id|
            assert_includes Stickers::IDS, id
          end
        end
      end
    end
  end
end
