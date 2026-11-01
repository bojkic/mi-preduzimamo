# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module Geo
      class PointRoutingTest < ActiveSupport::TestCase
        setup do
          @organization = create_organization

          @mz = LocalArea.create!(
            organization: @organization,
            kind: "mz",
            slug: "mz-pr-centar",
            name: { "sr" => "Centar MZ", "en" => "Centre MZ" },
            predsjednik: "Jovan Jovanović",
            telefon: "+387 55 111 222",
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

          @mz2 = LocalArea.create!(
            organization: @organization,
            kind: "mz",
            slug: "mz-pr-pazar",
            name: { "sr" => "Pazar MZ", "en" => "Pazar MZ" },
            predsjednik: "Ana Anić",
            telefon: "+387 55 333 444",
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

          @komsiluk = LocalArea.create!(
            organization: @organization,
            kind: "komsiluk",
            slug: "k-pr-centar",
            name: { "sr" => "Centar K" },
            overlapping_mz_slugs: %w(mz-pr-centar mz-pr-pazar),
            primary_mz_slug: "mz-pr-centar",
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
        end

        # ─── resolve ─────────────────────────────────────────────────────────

        test "resolve returns mz_slug and komsiluk_slug for a point inside both" do
          result = PointRouting.resolve(lat: 44.757, lon: 19.215, organization: @organization)
          assert_equal "mz-pr-centar", result[:mz_slug]
          assert_equal "k-pr-centar", result[:komsiluk_slug]
        end

        test "resolve returns nil mz_slug for a point outside all MZ" do
          result = PointRouting.resolve(lat: 44.900, lon: 19.500, organization: @organization)
          assert_nil result[:mz_slug]
          assert_nil result[:komsiluk_slug]
        end

        # ─── mz_contact ──────────────────────────────────────────────────────

        test "mz_contact returns slug, name, predsjednik, telefon" do
          info = PointRouting.mz_contact(slug: "mz-pr-centar", organization: @organization)
          assert_not_nil info
          assert_equal "mz-pr-centar", info[:slug]
          assert_equal "Jovan Jovanović", info[:predsjednik]
          assert_equal "+387 55 111 222", info[:telefon]
        end

        test "mz_contact returns nil for an unknown slug" do
          assert_nil PointRouting.mz_contact(slug: "nonexistent-mz", organization: @organization)
        end

        # ─── komsiluk_mz_presidents ───────────────────────────────────────────

        test "komsiluk_mz_presidents returns presidents of all overlapping MZ" do
          presidents = PointRouting.komsiluk_mz_presidents(
            komsiluk_slug: "k-pr-centar",
            organization: @organization
          )
          assert_equal 2, presidents.size
          slugs = presidents.map { |p| p[:slug] }
          assert_includes slugs, "mz-pr-centar"
          assert_includes slugs, "mz-pr-pazar"

          centar_entry = presidents.find { |p| p[:slug] == "mz-pr-centar" }
          assert_equal "Jovan Jovanović", centar_entry[:predsjednik]
          assert_equal "+387 55 111 222", centar_entry[:telefon]
        end

        test "komsiluk_mz_presidents returns empty array for unknown komsiluk" do
          result = PointRouting.komsiluk_mz_presidents(
            komsiluk_slug: "nonexistent-k",
            organization: @organization
          )
          assert_equal [], result
        end

        test "komsiluk_mz_presidents returns empty array when overlapping_mz_slugs is empty" do
          k_empty = LocalArea.create!(
            organization: @organization,
            kind: "komsiluk",
            slug: "k-pr-empty",
            name: { "sr" => "Empty K" }
          )
          result = PointRouting.komsiluk_mz_presidents(
            komsiluk_slug: k_empty.slug,
            organization: @organization
          )
          assert_equal [], result
        end

        # ─── Address never stored ──────────────────────────────────────────

        test "PointRouting.resolve does not store any address field" do
          # resolve just calls AreaLocator which queries the DB — no writes happen.
          before_count = Decidim::Bih::CitizenProfile.count
          PointRouting.resolve(lat: 44.757, lon: 19.215, organization: @organization)
          assert_equal before_count, Decidim::Bih::CitizenProfile.count,
                       "resolve must not write any citizen records"
        end
      end
    end
  end
end
