# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module Geo
      class IntegrityCheckTest < ActiveSupport::TestCase
        # A simple square polygon helper (lon/lat order, GeoJSON closed ring).
        def square(lon_min, lat_min, lon_max, lat_max)
          {
            "type" => "Polygon",
            "coordinates" => [
              [
                [lon_min, lat_min],
                [lon_max, lat_min],
                [lon_max, lat_max],
                [lon_min, lat_max],
                [lon_min, lat_min]
              ]
            ]
          }
        end

        setup do
          @organization = create_organization

          # One MZ that all healthy komšiluci can point at / sit inside.
          @mz = LocalArea.create!(
            organization: @organization,
            kind: "mz",
            slug: "mz-ic-centar",
            name: { "sr" => "Centar" },
            boundary: square(19.210, 44.750, 19.220, 44.760)
          )
          rep = AreaLocator.representative_point(@mz.boundary)
          @mz.update!(centroid_lat: rep[0], centroid_lon: rep[1])
        end

        # Build a healthy komšiluk fully inside the MZ with consistent relations
        # and an interior centroid.
        def healthy_komsiluk(slug: "k-healthy")
          boundary = square(19.212, 44.752, 19.218, 44.758)
          rep = AreaLocator.representative_point(boundary)
          LocalArea.create!(
            organization: @organization,
            kind: "komsiluk",
            slug:,
            name: { "sr" => slug },
            boundary:,
            primary_mz_slug: "mz-ic-centar",
            overlapping_mz_slugs: %w(mz-ic-centar),
            centroid_lat: rep[0],
            centroid_lon: rep[1]
          )
        end

        # ─── Healthy data → no issues ────────────────────────────────────────

        test "healthy data returns no issues" do
          healthy_komsiluk

          issues = IntegrityCheck.new(@organization).call

          assert_empty issues.flat_map { |_type, list| list },
                       "expected no issues for healthy data, got: #{issues.inspect}"
        end

        # ─── 1. Empty overlapping_mz_slugs ───────────────────────────────────

        test "flags komsiluk with empty overlapping_mz_slugs" do
          healthy_komsiluk
          offender = LocalArea.create!(
            organization: @organization,
            kind: "komsiluk",
            slug: "k-empty-overlaps",
            name: { "sr" => "Empty" },
            boundary: square(19.213, 44.753, 19.217, 44.757),
            primary_mz_slug: "mz-ic-centar",
            overlapping_mz_slugs: []
          )

          issues = IntegrityCheck.new(@organization).call
          slugs = issues[:empty_overlaps].map { |i| i[:slug] }

          assert_includes slugs, offender.slug
          assert_not_includes slugs, "k-healthy"
        end

        # ─── 2. Nil / degenerate boundary ────────────────────────────────────

        test "flags area whose boundary is nil/degenerate (representative_point nil)" do
          healthy_komsiluk
          # A degenerate polygon: fewer than 3 distinct points → representative_point nil.
          degenerate = LocalArea.create!(
            organization: @organization,
            kind: "komsiluk",
            slug: "k-degenerate",
            name: { "sr" => "Degenerate" },
            boundary: { "type" => "Polygon", "coordinates" => [[[19.21, 44.75]]] },
            primary_mz_slug: "mz-ic-centar",
            overlapping_mz_slugs: %w(mz-ic-centar)
          )

          issues = IntegrityCheck.new(@organization).call
          slugs = issues[:degenerate_boundary].map { |i| i[:slug] }

          assert_includes slugs, degenerate.slug
          assert_not_includes slugs, "k-healthy"
        end

        test "flags area with nil boundary as degenerate" do
          nil_boundary = LocalArea.create!(
            organization: @organization,
            kind: "komsiluk",
            slug: "k-nil-boundary",
            name: { "sr" => "Nil" },
            boundary: nil,
            primary_mz_slug: "mz-ic-centar",
            overlapping_mz_slugs: %w(mz-ic-centar)
          )

          issues = IntegrityCheck.new(@organization).call
          slugs = issues[:degenerate_boundary].map { |i| i[:slug] }

          assert_includes slugs, nil_boundary.slug
        end

        # ─── 3. Dangling primary_mz_slug ─────────────────────────────────────

        test "flags komsiluk whose primary_mz_slug points at a non-existent MZ" do
          healthy_komsiluk
          dangling = LocalArea.create!(
            organization: @organization,
            kind: "komsiluk",
            slug: "k-dangling",
            name: { "sr" => "Dangling" },
            boundary: square(19.213, 44.753, 19.217, 44.757),
            primary_mz_slug: "mz-does-not-exist",
            overlapping_mz_slugs: %w(mz-does-not-exist)
          )

          issues = IntegrityCheck.new(@organization).call
          slugs = issues[:dangling_primary_mz].map { |i| i[:slug] }

          assert_includes slugs, dangling.slug
          assert_not_includes slugs, "k-healthy"
        end

        # ─── 4. Stored point outside its own boundary ────────────────────────

        test "flags area whose stored centroid is outside its own boundary" do
          healthy_komsiluk
          # Boundary in one place, centroid stored far away (stale-after-reimport).
          stale = LocalArea.create!(
            organization: @organization,
            kind: "komsiluk",
            slug: "k-stale-centroid",
            name: { "sr" => "Stale" },
            boundary: square(19.213, 44.753, 19.217, 44.757),
            primary_mz_slug: "mz-ic-centar",
            overlapping_mz_slugs: %w(mz-ic-centar),
            centroid_lat: 44.900,
            centroid_lon: 19.900
          )

          issues = IntegrityCheck.new(@organization).call
          slugs = issues[:point_outside_boundary].map { |i| i[:slug] }

          assert_includes slugs, stale.slug
          assert_not_includes slugs, "k-healthy"
        end

        test "does not flag an MZ whose stored centroid is interior" do
          healthy_komsiluk

          issues = IntegrityCheck.new(@organization).call
          slugs = issues[:point_outside_boundary].map { |i| i[:slug] }

          assert_not_includes slugs, @mz.slug
        end

        # ─── Org scoping ─────────────────────────────────────────────────────

        test "issues are scoped to the given organization" do
          other_org = create_organization
          # An offender in ANOTHER org must not appear in this org's report.
          LocalArea.create!(
            organization: other_org,
            kind: "komsiluk",
            slug: "k-other-org-empty",
            name: { "sr" => "Other" },
            boundary: square(19.213, 44.753, 19.217, 44.757),
            overlapping_mz_slugs: []
          )
          healthy_komsiluk

          issues = IntegrityCheck.new(@organization).call
          all_slugs = issues.flat_map { |_type, list| list.map { |i| i[:slug] } }

          assert_not_includes all_slugs, "k-other-org-empty"
        end

        # ─── Shape of the result ─────────────────────────────────────────────

        test "returns a hash keyed by every issue type" do
          issues = IntegrityCheck.new(@organization).call

          [:empty_overlaps, :degenerate_boundary, :dangling_primary_mz, :point_outside_boundary].each do |type|
            assert issues.has_key?(type), "expected result to contain key #{type}"
            assert_kind_of Array, issues[type]
          end
        end

        test "each issue carries a slug and a message" do
          LocalArea.create!(
            organization: @organization,
            kind: "komsiluk",
            slug: "k-msg",
            name: { "sr" => "Msg" },
            boundary: square(19.213, 44.753, 19.217, 44.757),
            overlapping_mz_slugs: []
          )

          issue = IntegrityCheck.new(@organization).call[:empty_overlaps].first

          assert_equal "k-msg", issue[:slug]
          assert_kind_of String, issue[:message]
          assert_not_empty issue[:message]
        end
      end
    end
  end
end
