# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module Postal
      class PostalKomsilukServiceTest < ActiveSupport::TestCase
        setup do
          @organization = create_organization
          @user = FactoryBot.create(:user, :confirmed, organization: @organization)

          # Independent authored rectangles around 0.15/0.25; no municipal GIS
          import_fixture_areas
        end

        # ─── On postal grant, komšiluk is set with source=postal ────────────
        # Production flow: after_commit calls call_with_address(user:, address:)
        # because grant! already cleared verification_metadata before commit.

        test "call_with_address sets the citizen komsiluk from the verified address" do
          Decidim::Bih::Geo::Geocoder.stub(:coordinates, { lat: 0.25, lon: 0.15 }) do
            result = PostalKomsilukService.call_with_address(
              user: @user,
              address: "Izmišljena ulica 12, Testna zajednica"
            )

            assert_equal :updated, result

            profile = Decidim::Bih::CitizenProfile.find_by(
              decidim_organization_id: @organization.id,
              decidim_user_id: @user.id
            )
            assert_not_nil profile
            assert_equal "postal", profile.source
            assert_not_nil profile.komsiluk_id
          end
        end

        test "overrides a prior self-declared (map) komsiluk with source=postal" do
          south_komsiluk = Decidim::Bih::LocalArea.find_by(
            decidim_organization_id: @organization.id,
            slug: "izmisljeni-komsiluk-jug"
          )

          profile = Decidim::Bih::CitizenProfile.for_user(@user, organization: @organization)
          assert_not_nil south_komsiluk, "Authored south fixture must be imported"
          profile.assign_komsiluk!(south_komsiluk, source: "map")
          assert_equal "map", profile.reload.source

          # Postal geocodes to the north komsiluk
          Decidim::Bih::Geo::Geocoder.stub(:coordinates, { lat: 0.25, lon: 0.15 }) do
            PostalKomsilukService.call_with_address(user: @user, address: "Izmišljena ulica 5, Testna zajednica")
          end

          north_komsiluk = Decidim::Bih::LocalArea.find_by(
            decidim_organization_id: @organization.id,
            slug: "izmisljeni-komsiluk-sjever"
          )
          profile.reload
          assert_equal "postal", profile.source, "postal must override prior self-declared source"
          assert_not_nil north_komsiluk, "Authored north fixture must be imported"
          assert_equal north_komsiluk.id, profile.komsiluk_id
        end

        test "returns :not_geocoded when geocoder fails" do
          Decidim::Bih::Geo::Geocoder.stub(:coordinates, nil) do
            result = PostalKomsilukService.call_with_address(
              user: @user,
              address: "Unknown address X"
            )
            assert_equal :not_geocoded, result
          end
        end

        test "returns :no_area when point is outside all komsiluci" do
          Decidim::Bih::Geo::Geocoder.stub(:coordinates, { lat: 0.0, lon: 0.0 }) do
            result = PostalKomsilukService.call_with_address(
              user: @user,
              address: "Neka ulica 1"
            )
            assert_equal :no_area, result
          end
        end

        test "returns :no_address when address is blank" do
          result = PostalKomsilukService.call_with_address(user: @user, address: nil)
          assert_equal :no_address, result

          result2 = PostalKomsilukService.call_with_address(user: @user, address: "")
          assert_equal :no_address, result2
        end

        # ─── call() reads address from a pending (pre-grant) authorization ───
        # This covers the case where call() is invoked directly on an auth
        # row that still has address in verification_metadata (pending state).

        test "call reads the address from a pending (pre-grant) authorization" do
          # Pending auth: address in metadata, NOT yet granted
          pending_auth = Decidim::Authorization.create!(
            user: @user,
            name: "postal_letter",
            granted_at: nil,
            verification_metadata: {
              "address" => "Izmišljena ulica 12, Testna zajednica",
              "verification_code" => "111222"
            }
          )

          Decidim::Bih::Geo::Geocoder.stub(:coordinates, { lat: 0.25, lon: 0.15 }) do
            result = PostalKomsilukService.call(pending_auth)
            assert_equal :updated, result
          end

          profile = Decidim::Bih::CitizenProfile.find_by(
            decidim_organization_id: @organization.id,
            decidim_user_id: @user.id
          )
          assert_not_nil profile
          assert_equal "postal", profile.source
        end

        # ─── Address is never re-stored anywhere ────────────────────────────

        test "the address is never persisted to CitizenProfile (only komsiluk_id)" do
          Decidim::Bih::Geo::Geocoder.stub(:coordinates, { lat: 0.25, lon: 0.15 }) do
            PostalKomsilukService.call_with_address(user: @user, address: "Izmišljena ulica 12, Testna zajednica")
          end

          profile = Decidim::Bih::CitizenProfile.find_by(
            decidim_organization_id: @organization.id,
            decidim_user_id: @user.id
          )
          assert_not profile.class.column_names.include?("address"),
                     "CitizenProfile must never have an address column"
        end

        private

        def import_fixture_areas
          # Load MZ from the MZ fixture (new schema: no komšiluk features).
          mz_path = Rails.root.join("test/fixtures/files/synthetic/postal_areas.geojson")
          import_geojson_file(mz_path)

          # Load komšiluci from the komšiluk fixture (new schema: id/naziv, no parent_slug).
          k_path = Rails.root.join("test/fixtures/files/synthetic/postal_komsiluci.geojson")
          import_geojson_file(k_path)
        end

        def import_geojson_file(path)
          geojson = JSON.parse(File.read(path))
          geojson["features"].each do |feature|
            props = feature["properties"]
            kind = props["kind"]

            slug = if kind == "komsiluk"
                     naziv = props["naziv"].to_s.strip
                     naziv.present? ? slugify(naziv) : "komsiluk-#{props["id"]}"
                   else
                     props["slug"]
                   end

            name = if kind == "komsiluk"
                     display = props["naziv"].to_s.strip.presence || slug
                     { "sr" => display, "bs" => display, "hr" => display, "en" => display }
                   else
                     props["name"]
                   end

            Decidim::Bih::LocalArea.find_or_create_by!(
              decidim_organization_id: @organization.id,
              slug:
            ) do |area|
              area.kind = kind
              area.name = name
              area.boundary = feature["geometry"]
              area.organization = @organization
            end
          end
        end

        # Mirrors the rake task's slugify logic for test fixture loading.
        def slugify(str)
          s = str.dup
          s.gsub!(/[čć]/i) { |c| c == c.upcase ? "C" : "c" }
          s.gsub!(/[š]/i) { |c| c == c.upcase ? "S" : "s" }
          s.gsub!(/[ž]/i) { |c| c == c.upcase ? "Z" : "z" }
          s.gsub!(/[đ]/i) { |c| c == c.upcase ? "D" : "d" }
          s.downcase!
          s.gsub!(/[^a-z0-9]+/, "-")
          s.gsub!(/\A-+|-+\z/, "")
          s.presence || "komsiluk"
        end
      end
    end
  end
end
