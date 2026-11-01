# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module Geo
      class RelationsComputerTest < ActiveSupport::TestCase
        setup do
          @organization = create_organization

          # MZ layout (two adjacent squares):
          #   mz-centar: lon 19.210..19.220, lat 44.750..44.760
          #   mz-pazar:  lon 19.200..19.210, lat 44.745..44.755
          @mz_centar = LocalArea.create!(
            organization: @organization,
            kind: "mz",
            slug: "mz-rc-centar",
            name: { "sr" => "Centar" },
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
            slug: "mz-rc-pazar",
            name: { "sr" => "Pazar" },
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

          @computer = RelationsComputer.new(@organization)
        end

        # ─── Komšiluk fully inside one MZ ───────────────────────────────────

        test "komsiluk fully inside mz-centar gets primary_mz=centar and overlapping=[centar]" do
          # Fully inside mz-centar (lon 19.212..19.218, lat 44.752..44.758)
          k = LocalArea.create!(
            organization: @organization,
            kind: "komsiluk",
            slug: "k-inside-centar",
            name: { "sr" => "Inside Centar" },
            boundary: {
              "type" => "Polygon",
              "coordinates" => [
                [
                  [19.212, 44.752],
                  [19.218, 44.752],
                  [19.218, 44.758],
                  [19.212, 44.758],
                  [19.212, 44.752]
                ]
              ]
            }
          )

          @computer.compute!
          k.reload

          assert_equal "mz-rc-centar", k.primary_mz_slug
          assert_includes k.overlapping_mz_slugs, "mz-rc-centar"
          assert_not_includes k.overlapping_mz_slugs, "mz-rc-pazar"
        end

        # ─── Komšiluk overlapping TWO MZ ─────────────────────────────────────

        test "komsiluk spanning boundary of centar+pazar overlaps both MZ" do
          # Spans the lon=19.210 boundary between mz-centar and mz-pazar.
          # Left half (19.205..19.210) in mz-pazar, right half (19.210..19.215) in mz-centar.
          # Lat 44.750..19.755 overlaps the shared lat band.
          k = LocalArea.create!(
            organization: @organization,
            kind: "komsiluk",
            slug: "k-spanning",
            name: { "sr" => "Granicni Komsiluk" },
            boundary: {
              "type" => "Polygon",
              "coordinates" => [
                [
                  [19.205, 44.750],
                  [19.215, 44.750],
                  [19.215, 44.754],
                  [19.205, 44.754],
                  [19.205, 44.750]
                ]
              ]
            }
          )

          @computer.compute!
          k.reload

          assert_includes k.overlapping_mz_slugs, "mz-rc-centar", "spanning komsiluk must overlap mz-centar"
          assert_includes k.overlapping_mz_slugs, "mz-rc-pazar", "spanning komsiluk must overlap mz-pazar"
          assert_not_nil k.primary_mz_slug, "primary_mz_slug must be set"
          # Both halves are equal width so centar and pazar each get ~half the points;
          # exact tie-breaking is implementation-defined but a winner must be chosen.
          assert_includes %w(mz-rc-centar mz-rc-pazar), k.primary_mz_slug
        end

        test "primary_mz is the MZ with the most sample hits (larger overlap wins)" do
          # Komšiluk with 3/4 of its area inside mz-centar and 1/4 inside mz-pazar.
          # lon range: 19.207..19.218 → about 3 units in centar (19.210..19.218),
          # 0.3 units in pazar (19.207..19.210). centar clearly wins.
          k = LocalArea.create!(
            organization: @organization,
            kind: "komsiluk",
            slug: "k-mostly-centar",
            name: { "sr" => "Mostly Centar" },
            boundary: {
              "type" => "Polygon",
              "coordinates" => [
                [
                  [19.207, 44.751],
                  [19.218, 44.751],
                  [19.218, 44.754],
                  [19.207, 44.754],
                  [19.207, 44.751]
                ]
              ]
            }
          )

          @computer.compute!
          k.reload

          assert_equal "mz-rc-centar", k.primary_mz_slug,
                       "3/4 of area is in centar so centar must be primary"
        end

        test "does not run scanline checks for an MZ with a disjoint bounding box" do
          far_mz = LocalArea.create!(
            organization: @organization,
            kind: "mz",
            slug: "mz-rc-far-away",
            name: { "sr" => "Far away" },
            boundary: {
              "type" => "Polygon",
              "coordinates" => [[
                [20.000, 45.000],
                [20.010, 45.000],
                [20.010, 45.010],
                [20.000, 45.010],
                [20.000, 45.000]
              ]]
            }
          )
          k = LocalArea.create!(
            organization: @organization,
            kind: "komsiluk",
            slug: "k-bbox-prefilter",
            name: { "sr" => "BBox prefilter" },
            boundary: {
              "type" => "Polygon",
              "coordinates" => [[
                [19.212, 44.752],
                [19.218, 44.752],
                [19.218, 44.758],
                [19.212, 44.758],
                [19.212, 44.752]
              ]]
            }
          )

          far_boundary = far_mz.boundary
          original_intervals = AreaLocator.method(:longitude_intervals_at)
          far_boundary_checks = 0

          AreaLocator.stub(:longitude_intervals_at, lambda { |lat, geometry|
            far_boundary_checks += 1 if geometry == far_boundary
            original_intervals.call(lat, geometry)
          }) do
            @computer.compute!
          end

          assert_equal 0, far_boundary_checks
          assert_equal "mz-rc-centar", k.reload.primary_mz_slug
        end

        # ─── Komšiluk with no boundary is skipped ───────────────────────────

        test "skips komsiluk with nil boundary (excluded from load query)" do
          # A nil-boundary komšiluk is filtered by `.where.not(boundary: nil)` in
          # load_areas, so it never enters the compute loop. The result counts
          # reflect only the komsiluci that were loaded. The record is unchanged.
          k = LocalArea.create!(
            organization: @organization,
            kind: "komsiluk",
            slug: "k-no-boundary",
            name: { "sr" => "No Boundary" },
            boundary: nil
          )

          result = @computer.compute!

          k.reload
          assert_nil k.primary_mz_slug
          # nil-boundary records are excluded before the loop (not "skipped" inside it)
          assert_equal 0, result[:updated]
          assert_equal 0, result[:skipped]
        end

        # ─── Thin komšiluk that slips between grid cell-centres ──────────────

        test "a komsiluk whose grid yields no samples still resolves its MZ via the interior fallback" do
          # A thin/small komšiluk can land entirely between the 80x80 grid
          # cell-centres, leaving it with NO MZ relations. Simulate an empty grid
          # and assert the interior-point fallback still resolves the MZ.
          k = LocalArea.create!(
            organization: @organization, kind: "komsiluk", slug: "k-thin",
            name: { "sr" => "Thin" },
            boundary: {
              "type" => "Polygon",
              "coordinates" => [[
                [19.212, 44.752], [19.218, 44.752], [19.218, 44.758], [19.212, 44.758], [19.212, 44.752]
              ]]
            }
          )

          @computer.stub(:grid_points_in_geom, ->(*) { [] }) do
            @computer.compute!
          end
          k.reload

          assert_equal "mz-rc-centar", k.primary_mz_slug, "must fall back to the containing MZ when the grid misses"
          assert_includes k.overlapping_mz_slugs, "mz-rc-centar"
        end

        # ─── Idempotency ─────────────────────────────────────────────────────

        test "compute! is idempotent (re-runnable)" do
          k = LocalArea.create!(
            organization: @organization,
            kind: "komsiluk",
            slug: "k-idem",
            name: { "sr" => "Idem" },
            boundary: {
              "type" => "Polygon",
              "coordinates" => [
                [
                  [19.212, 44.752],
                  [19.218, 44.752],
                  [19.218, 44.758],
                  [19.212, 44.758],
                  [19.212, 44.752]
                ]
              ]
            }
          )

          @computer.compute!
          first_slug = k.reload.primary_mz_slug

          RelationsComputer.new(@organization).compute!
          second_slug = k.reload.primary_mz_slug

          assert_equal first_slug, second_slug, "compute! must be idempotent"
        end

        # ─── komsiluk outside all MZ ─────────────────────────────────────────

        test "komsiluk outside all MZ gets empty overlapping_mz_slugs" do
          k = LocalArea.create!(
            organization: @organization,
            kind: "komsiluk",
            slug: "k-outside",
            name: { "sr" => "Outside" },
            boundary: {
              "type" => "Polygon",
              "coordinates" => [
                [
                  [19.300, 44.800],
                  [19.310, 44.800],
                  [19.310, 44.810],
                  [19.300, 44.810],
                  [19.300, 44.800]
                ]
              ]
            }
          )

          @computer.compute!
          k.reload

          assert_equal [], k.overlapping_mz_slugs
          assert_nil k.primary_mz_slug
        end
      end
    end
  end
end
