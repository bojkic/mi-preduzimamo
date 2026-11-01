# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module Geo
      class AreaLocatorTest < ActiveSupport::TestCase
        setup do
          @organization = create_organization

          # MZ grid (two adjacent MZ):
          #   mz-centar:  lon 19.210..19.220, lat 44.750..44.760
          #   mz-pazar:   lon 19.200..19.210, lat 44.745..44.755
          @mz_centar = LocalArea.create!(
            organization: @organization,
            kind: "mz",
            slug: "mz-test-centar",
            name: { "sr" => "Test Centar MZ" },
            boundary: {
              "type" => "Polygon",
              "coordinates" => [
                [
                  [19.210, 44.750],
                  [19.220, 44.750],
                  [19.220, 44.760],
                  [19.210, 44.760],
                  [19.210, 44.750]
                ]
              ]
            }
          )

          @mz_pazar = LocalArea.create!(
            organization: @organization,
            kind: "mz",
            slug: "mz-test-pazar",
            name: { "sr" => "Test Pazar MZ" },
            boundary: {
              "type" => "Polygon",
              "coordinates" => [
                [
                  [19.200, 44.745],
                  [19.210, 44.745],
                  [19.210, 44.755],
                  [19.200, 44.755],
                  [19.200, 44.745]
                ]
              ]
            }
          )

          # Komšiluci are independent (no parent).
          @komsiluk_north = LocalArea.create!(
            organization: @organization,
            kind: "komsiluk",
            slug: "komsiluk-north",
            name: { "sr" => "Centar Sjever" },
            boundary: {
              "type" => "Polygon",
              "coordinates" => [
                [
                  [19.210, 44.755],
                  [19.220, 44.755],
                  [19.220, 44.760],
                  [19.210, 44.760],
                  [19.210, 44.755]
                ]
              ]
            }
          )

          @komsiluk_south = LocalArea.create!(
            organization: @organization,
            kind: "komsiluk",
            slug: "komsiluk-south",
            name: { "sr" => "Centar Jug" },
            boundary: {
              "type" => "Polygon",
              "coordinates" => [
                [
                  [19.210, 44.750],
                  [19.220, 44.750],
                  [19.220, 44.755],
                  [19.210, 44.755],
                  [19.210, 44.750]
                ]
              ]
            }
          )

          @locator = AreaLocator.new
        end

        # ─── locate_mz ──────────────────────────────────────────────────────────

        test "locate_mz returns the MZ containing the point" do
          mz = @locator.locate_mz(lat: 44.755, lon: 19.215, organization: @organization)
          assert_equal @mz_centar, mz
        end

        test "locate_mz returns mz-pazar for a point in that polygon" do
          mz = @locator.locate_mz(lat: 44.750, lon: 19.205, organization: @organization)
          assert_equal @mz_pazar, mz
        end

        test "locate_mz returns nil for a point outside all MZ" do
          mz = @locator.locate_mz(lat: 44.800, lon: 19.300, organization: @organization)
          assert_nil mz
        end

        test "locate_mz tolerates an area with a malformed (nil-ring) boundary" do
          # boundary is unvalidated jsonb; a single bad row must not take down
          # point routing for the whole request.
          LocalArea.create!(
            organization: @organization,
            kind: "mz",
            slug: "mz-malformed",
            name: { "sr" => "Malformed MZ" },
            boundary: { "type" => "Polygon", "coordinates" => [nil] }
          )

          # A point outside every valid MZ forces evaluation of the malformed
          # area too; it must be skipped, not crash the whole lookup.
          assert_nil @locator.locate_mz(lat: 44.800, lon: 19.300, organization: @organization)
        end

        test "locate_mz returns nil for another org's point" do
          other_org = create_organization
          mz = @locator.locate_mz(lat: 44.755, lon: 19.215, organization: other_org)
          assert_nil mz
        end

        # ─── resolve — independent MZ + komšiluk ───────────────────────────────

        test "resolve returns both mz and komsiluk independently" do
          # Point is inside mz-centar AND komsiluk-north
          result = @locator.resolve(lat: 44.758, lon: 19.215, organization: @organization)
          assert_equal @mz_centar, result[:mz]
          assert_equal @komsiluk_north, result[:komsiluk]
        end

        test "resolve mz is independent of komsiluk (no parent used)" do
          # The komsiluci have no parent set — mz must come from PIP on MZ polygons
          assert_nil @komsiluk_north.parent_id
          result = @locator.resolve(lat: 44.758, lon: 19.215, organization: @organization)
          assert_equal @mz_centar, result[:mz], "MZ must be resolved by PIP, not from komsiluk.parent"
        end

        test "resolve returns nil mz when point is outside all MZ polygons" do
          result = @locator.resolve(lat: 44.800, lon: 19.300, organization: @organization)
          assert_nil result[:mz]
          assert_nil result[:komsiluk]
        end

        test "resolve returns mz but nil komsiluk when point is inside an MZ but no komsiluk" do
          # Create a fresh locator without the pre-seeded komsiluci (different org)
          other_org = create_organization
          LocalArea.create!(
            organization: other_org,
            kind: "mz",
            slug: "mz-only",
            name: { "sr" => "MZ Only" },
            boundary: {
              "type" => "Polygon",
              "coordinates" => [
                [[19.210, 44.750], [19.220, 44.750], [19.220, 44.760], [19.210, 44.760], [19.210, 44.750]]
              ]
            }
          )
          locator = AreaLocator.new
          result = locator.resolve(lat: 44.755, lon: 19.215, organization: other_org)
          assert_not_nil result[:mz]
          assert_nil result[:komsiluk]
        end

        # ─── locate_komsiluk — point inside ──────────────────────────────────

        test "point in komsiluk north returns north komsiluk and independently-resolved MZ" do
          result = @locator.locate_komsiluk(lat: 44.758, lon: 19.215, organization: @organization)
          assert_not_nil result
          assert_equal @komsiluk_north, result[:komsiluk]
          # MZ resolved independently by PIP (not from parent)
          assert_equal @mz_centar, result[:mz]
        end

        test "point in komsiluk south returns south komsiluk and MZ" do
          result = @locator.locate_komsiluk(lat: 44.752, lon: 19.215, organization: @organization)
          assert_not_nil result
          assert_equal @komsiluk_south, result[:komsiluk]
          assert_equal @mz_centar, result[:mz]
        end

        # ─── locate_komsiluk — point outside ─────────────────────────────────

        test "point outside all polygons returns nil" do
          result = @locator.locate_komsiluk(lat: 44.800, lon: 19.300, organization: @organization)
          assert_nil result
        end

        test "point in a different organization's polygon returns nil" do
          other_org = create_organization
          result = @locator.locate_komsiluk(lat: 44.758, lon: 19.215, organization: other_org)
          assert_nil result
        end

        # ─── polygon with hole ────────────────────────────────────────────────

        test "point inside hole of a polygon returns nil" do
          # A komsiluk shaped like a ring: outer box minus inner hole
          komsiluk_with_hole = LocalArea.create!(
            organization: @organization,
            kind: "komsiluk",
            slug: "komsiluk-hole",
            name: { "sr" => "Ring Komšiluk" },
            boundary: {
              "type" => "Polygon",
              "coordinates" => [
                # exterior ring
                [
                  [19.230, 44.770],
                  [19.250, 44.770],
                  [19.250, 44.790],
                  [19.230, 44.790],
                  [19.230, 44.770]
                ],
                # hole (interior ring) — a point inside this should return nil
                [
                  [19.235, 44.775],
                  [19.245, 44.775],
                  [19.245, 44.785],
                  [19.235, 44.785],
                  [19.235, 44.775]
                ]
              ]
            }
          )

          locator = AreaLocator.new # fresh instance so memoize picks up new area

          # Point inside the exterior but inside the hole → should be nil
          result = locator.locate_komsiluk(lat: 44.780, lon: 19.240, organization: @organization)
          assert_nil result

          # Point inside the exterior but outside the hole → should find the ring komsiluk
          result = locator.locate_komsiluk(lat: 44.771, lon: 19.231, organization: @organization)
          assert_equal komsiluk_with_hole, result[:komsiluk]
        end

        # ─── MultiPolygon ────────────────────────────────────────────────────

        test "point inside one part of a MultiPolygon returns the area" do
          komsiluk_multi = LocalArea.create!(
            organization: @organization,
            kind: "komsiluk",
            slug: "komsiluk-multi",
            name: { "sr" => "Multi Komšiluk" },
            boundary: {
              "type" => "MultiPolygon",
              "coordinates" => [
                # first polygon
                [
                  [
                    [19.260, 44.760],
                    [19.270, 44.760],
                    [19.270, 44.770],
                    [19.260, 44.770],
                    [19.260, 44.760]
                  ]
                ],
                # second polygon (non-contiguous)
                [
                  [
                    [19.280, 44.760],
                    [19.290, 44.760],
                    [19.290, 44.770],
                    [19.280, 44.770],
                    [19.280, 44.760]
                  ]
                ]
              ]
            }
          )

          locator = AreaLocator.new

          # Point in the first polygon
          result = locator.locate_komsiluk(lat: 44.765, lon: 19.265, organization: @organization)
          assert_equal komsiluk_multi, result[:komsiluk]

          # Point in the second polygon
          result = locator.locate_komsiluk(lat: 44.765, lon: 19.285, organization: @organization)
          assert_equal komsiluk_multi, result[:komsiluk]

          # Point between the two polygons
          result = locator.locate_komsiluk(lat: 44.765, lon: 19.275, organization: @organization)
          assert_nil result
        end

        # ─── nil boundary is skipped ─────────────────────────────────────────

        test "area with nil boundary is skipped" do
          LocalArea.create!(
            organization: @organization,
            kind: "komsiluk",
            slug: "komsiluk-nil-boundary",
            name: { "sr" => "No Boundary" },
            boundary: nil
          )
          # Should still find the correct areas (not crash)
          result = @locator.locate_komsiluk(lat: 44.758, lon: 19.215, organization: @organization)
          assert_equal @komsiluk_north, result[:komsiluk]
        end

        # ─── point/scanline geometry helpers ─────────────────────────────────

        test "point_in_geom? returns true for a point inside a Polygon" do
          geom = {
            "type" => "Polygon",
            "coordinates" => [
              [[19.210, 44.750], [19.220, 44.750], [19.220, 44.760], [19.210, 44.760], [19.210, 44.750]]
            ]
          }
          assert @locator.point_in_geom?(19.215, 44.755, geom)
          assert_not @locator.point_in_geom?(19.230, 44.755, geom)
        end

        test "longitude_intervals_at excludes a Polygon hole" do
          geom = {
            "type" => "Polygon",
            "coordinates" => [
              [[0, 0], [4, 0], [4, 4], [0, 4], [0, 0]],
              [[1, 1], [3, 1], [3, 3], [1, 3], [1, 1]]
            ]
          }

          assert_equal [[0.0, 1.0], [3.0, 4.0]], AreaLocator.longitude_intervals_at(2, geom)
        end

        test "longitude_intervals_at keeps disjoint MultiPolygon intervals" do
          geom = {
            "type" => "MultiPolygon",
            "coordinates" => [
              [[[0, 0], [1, 0], [1, 1], [0, 1], [0, 0]]],
              [[[3, 0], [4, 0], [4, 1], [3, 1], [3, 0]]]
            ]
          }

          assert_equal [[0.0, 1.0], [3.0, 4.0]], AreaLocator.longitude_intervals_at(0.5, geom)
        end

        # ── representative_point (guaranteed-interior centroid) ──────────────

        test "representative_point returns the centre of a convex polygon" do
          square = {
            "type" => "Polygon",
            "coordinates" => [[[0, 0], [2, 0], [2, 2], [0, 2], [0, 0]]]
          }
          lat, lon = Decidim::Bih::Geo::AreaLocator.representative_point(square)
          assert_in_delta 1.0, lat, 0.001
          assert_in_delta 1.0, lon, 0.001
          assert @locator.point_in_geom?(lon, lat, square)
        end

        test "representative_point stays INSIDE a concave (U-shaped) polygon" do
          # U opening upward: the naive average lands in the notch (outside).
          u_shape = {
            "type" => "Polygon",
            "coordinates" => [[
              [0, 0], [3, 0], [3, 3], [2, 3], [2, 1], [1, 1], [1, 3], [0, 3], [0, 0]
            ]]
          }
          # naive average of the vertices is outside the U
          naive_lon = 1.5
          naive_lat = 1.75
          assert_not @locator.point_in_geom?(naive_lon, naive_lat, u_shape),
                     "the naive average should fall in the notch (outside)"

          lat, lon = Decidim::Bih::Geo::AreaLocator.representative_point(u_shape)
          assert @locator.point_in_geom?(lon, lat, u_shape),
                 "representative_point must be inside the concave polygon"
        end

        test "representative_point avoids holes" do
          donut = {
            "type" => "Polygon",
            "coordinates" => [
              [[0, 0], [4, 0], [4, 4], [0, 4], [0, 0]],
              [[1, 1], [3, 1], [3, 3], [1, 3], [1, 1]]
            ]
          }
          lat, lon = Decidim::Bih::Geo::AreaLocator.representative_point(donut)
          assert @locator.point_in_geom?(lon, lat, donut),
                 "representative_point must avoid the hole"
        end

        test "representative_point returns nil for a degenerate geometry" do
          assert_nil Decidim::Bih::Geo::AreaLocator.representative_point({})
          assert_nil Decidim::Bih::Geo::AreaLocator.representative_point("type" => "Point", "coordinates" => [1, 2])
        end
      end
    end
  end
end
