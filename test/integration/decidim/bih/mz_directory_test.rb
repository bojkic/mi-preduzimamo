# frozen_string_literal: true

require "test_helper"
# Integration tests that render the Decidim layout need Capybara loaded so
# Decidim::UrlOptionResolver can reference Capybara.server_port in tests.
require "capybara"

module Decidim
  module Bih
    # HTTP coverage for the public, read-only Mjesna zajednica (MZ) directory at
    # /biceriseno/mjesne-zajednice and /biceriseno/mjesne-zajednice/:slug.
    # Decidim derives the current organization from the request host. No auth.
    class MzDirectoryTest < ActionDispatch::IntegrationTest
      setup do
        @organization = create_organization
        host! @organization.host
        @original_support_email = Decidim::Bih.public_support_email
        @original_source_label = Decidim::Bih.mz_directory_source_label
        Decidim::Bih.public_support_email = "office@fondacijabijeljina.com"
        Decidim::Bih.mz_directory_source_label = "Grad Bijeljina GIS"
      end

      teardown do
        Decidim::Bih.public_support_email = @original_support_email
        Decidim::Bih.mz_directory_source_label = @original_source_label
      end

      def create_mz(slug:, name:, organization: @organization, **attrs)
        Decidim::Bih::LocalArea.create!(
          organization:,
          kind: "mz",
          slug:,
          name:,
          **attrs
        )
      end

      def square_boundary
        {
          "type" => "Polygon",
          "coordinates" => [
            [[19.210, 44.750], [19.220, 44.750], [19.220, 44.760], [19.210, 44.760], [19.210, 44.750]]
          ]
        }
      end

      # ─── #index ───────────────────────────────────────────────────────────

      test "GET index lists the current org's MZ with president + phone" do
        create_mz(
          slug: "centar",
          name: { "sr" => "Centar", "en" => "Centre" },
          predsjednik: "Marko Marković",
          telefon: "055111222"
        )

        get "/biceriseno/mjesne-zajednice"

        assert_response :success
        assert_includes response.body, "Centar"
        assert_includes response.body, "Marko Marković"
        assert_includes response.body, "055111222"
        # Links through to the show page by slug.
        assert_select "a[href=?]", "/biceriseno/mjesne-zajednice/centar"
        assert_includes response.body, "Grad Bijeljina GIS"
        assert_select "a[href=?]", "mailto:office@fondacijabijeljina.com"
      end

      test "GET index is scoped to the current organization" do
        create_mz(slug: "ours", name: { "sr" => "Naša MZ" })

        other = create_organization
        create_mz(slug: "theirs", name: { "sr" => "Tuđa MZ" }, organization: other)

        get "/biceriseno/mjesne-zajednice"

        assert_response :success
        assert_includes response.body, "Naša MZ"
        assert_not_includes response.body, "Tuđa MZ"
        assert_select "a[href=?]", "/biceriseno/mjesne-zajednice/theirs", count: 0
      end

      test "GET index shows explicit placeholders for partial contact data" do
        create_mz(slug: "filip", name: { "sr" => "Filip" }, predsjednik: "Slaviša Ilić", telefon: nil)

        get "/biceriseno/mjesne-zajednice"

        assert_response :success
        assert_includes response.body, "Slaviša Ilić"
        assert_includes response.body, "nije dostupan"
      end

      test "GET index does not list komšiluci (only kind=mz)" do
        create_mz(slug: "mz-one", name: { "sr" => "MZ Jedan" })
        Decidim::Bih::LocalArea.create!(
          organization: @organization,
          kind: "komsiluk",
          slug: "k-one",
          name: { "sr" => "Komšiluk Jedan" }
        )

        get "/biceriseno/mjesne-zajednice"

        assert_response :success
        assert_includes response.body, "MZ Jedan"
        assert_not_includes response.body, "Komšiluk Jedan"
      end

      # ─── #show ────────────────────────────────────────────────────────────

      test "GET show renders an MZ by slug with details" do
        create_mz(
          slug: "centar",
          name: { "sr" => "Centar", "en" => "Centre" },
          predsjednik: "Ana Anić",
          telefon: "055333444"
        )

        get "/biceriseno/mjesne-zajednice/centar"

        assert_response :success
        assert_includes response.body, "Centar"
        assert_includes response.body, "Ana Anić"
        assert_includes response.body, "055333444"
        assert_includes response.body, "Grad Bijeljina GIS"
        assert_select "a[href=?]", "mailto:office@fondacijabijeljina.com"
      end

      test "GET show shows explicit placeholders for missing contact fields" do
        create_mz(slug: "bez-telefona", name: { "sr" => "Bez telefona" }, predsjednik: "Ana", telefon: nil)

        get "/biceriseno/mjesne-zajednice/bez-telefona"

        assert_response :success
        assert_includes response.body, "Ana"
        assert_includes response.body, "nije dostupan"
      end

      test "GET show exposes the boundary + a center point for an MZ that has one" do
        create_mz(
          slug: "centar",
          name: { "sr" => "Centar" },
          boundary: square_boundary
        )

        get "/biceriseno/mjesne-zajednice/centar"

        assert_response :success
        assert_select "#bih-mz-map[data-boundary-url]"
        # The representative point of the square is its centroid (44.755, 19.215).
        assert_select "#bih-mz-map[data-center-lat=?]", "44.755"
        assert_select "#bih-mz-map[data-center-lng=?]", "19.215"
      end

      test "GET show serves the MZ boundary GeoJSON at .json" do
        create_mz(
          slug: "centar",
          name: { "sr" => "Centar" },
          boundary: square_boundary
        )

        get "/biceriseno/mjesne-zajednice/centar.json"

        assert_response :success
        assert_equal "application/json", response.media_type
        body = response.parsed_body
        assert_equal "Feature", body["type"]
        assert_equal "Polygon", body.dig("geometry", "type")
      end

      test "GET show for an MZ without a boundary still renders (no map)" do
        create_mz(slug: "bez-granice", name: { "sr" => "Bez granice" }, predsjednik: "X")

        get "/biceriseno/mjesne-zajednice/bez-granice"

        assert_response :success
        assert_includes response.body, "Bez granice"
        assert_select "#bih-mz-map", count: 0
      end

      test "GET show with an unknown slug redirects safely to the index" do
        get "/biceriseno/mjesne-zajednice/ne-postoji"

        assert_redirected_to "/biceriseno/mjesne-zajednice"
      end

      test "GET show will not surface another org's MZ by slug" do
        other = create_organization
        create_mz(slug: "tudja", name: { "sr" => "Tuđa MZ" }, organization: other)

        get "/biceriseno/mjesne-zajednice/tudja"

        assert_redirected_to "/biceriseno/mjesne-zajednice"
      end

      test "GET show will not surface a komšiluk by slug (mz only)" do
        Decidim::Bih::LocalArea.create!(
          organization: @organization,
          kind: "komsiluk",
          slug: "k-slug",
          name: { "sr" => "Komšiluk" }
        )

        get "/biceriseno/mjesne-zajednice/k-slug"

        assert_redirected_to "/biceriseno/mjesne-zajednice"
      end
    end
  end
end
