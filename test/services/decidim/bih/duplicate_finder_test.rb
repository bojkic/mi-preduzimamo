# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    # Unit coverage for the duplicate-report detection used at the WEB intake.
    # The finder is org-scoped, considers only NON-terminal recent reports inside
    # a small radius, and prefers a same-category match. It must never cross orgs
    # and must degrade to "no match" when coordinates are missing.
    class DuplicateFinderTest < ActiveSupport::TestCase
      # A point in Bijeljina; the deltas below are derived from it.
      BASE_LAT = 44.7560
      BASE_LNG = 19.2160

      setup do
        @organization = create_organization
      end

      def report(lat: BASE_LAT, lng: BASE_LNG, status: "primljeno", category: nil, # rubocop:disable Metrics/ParameterLists
                 created_at: Time.current, organization: @organization)
        r = Decidim::Bih::Report.new(
          organization: organization,
          description: "Rupa na putu",
          latitude: lat,
          longitude: lng,
          status: status,
          category: category
        )
        r.save!
        # created_at is set on insert; override for "recency" cases.
        r.update_column(:created_at, created_at) if created_at != r.created_at # rubocop:disable Rails/SkipsModelValidations
        r
      end

      def find(latitude: BASE_LAT, longitude: BASE_LNG, category: nil)
        Decidim::Bih::DuplicateFinder.new.call(
          organization: @organization,
          latitude: latitude,
          longitude: longitude,
          category: category
        )
      end

      test "matches a recent non-terminal report at the same point" do
        existing = report
        assert_equal existing.id, find&.id
      end

      test "matches a report a few metres away (within the radius)" do
        # ~30 m north (1 deg latitude ~= 111_320 m).
        existing = report(lat: BASE_LAT + 0.00027, lng: BASE_LNG)
        assert_equal existing.id, find&.id
      end

      test "does NOT match a report far away (outside the radius)" do
        # ~1 km north — well outside the ~100 m radius.
        report(lat: BASE_LAT + 0.009, lng: BASE_LNG)
        assert_nil find
      end

      test "does NOT match a terminal (rijeseno) report" do
        report(status: "rijeseno")
        assert_nil find
      end

      test "does NOT match a terminal (odbijeno) report" do
        report(status: "odbijeno")
        assert_nil find
      end

      test "does NOT match an old report (outside the recency window)" do
        report(created_at: 60.days.ago)
        assert_nil find
      end

      test "does NOT match a report from another organization" do
        other = create_organization
        report(organization: other)
        assert_nil find
      end

      test "returns nil when the query has no coordinates" do
        report
        assert_nil find(latitude: nil, longitude: nil)
      end

      test "ignores a report that itself has no coordinates" do
        report(lat: nil, lng: nil)
        assert_nil find
      end

      test "prefers a same-category match over a different-category one nearby" do
        # Two nearby candidates; the category-matching one should win.
        report(lat: BASE_LAT + 0.0002, lng: BASE_LNG, category: "saobracaj")
        same = report(lat: BASE_LAT + 0.0003, lng: BASE_LNG, category: "putevi")

        match = find(category: "putevi")
        assert_equal same.id, match&.id
      end

      test "still matches when the query category is nil (no preference)" do
        existing = report(category: "putevi")
        assert_equal existing.id, find(category: nil)&.id
      end
    end
  end
end
