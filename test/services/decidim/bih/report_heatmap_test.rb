# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    # Aggregation for the per-MZ problem + AI-category heatmap. Turns individual
    # citizen reports into a community-level, PII-FREE signal: counts only
    # (category / severity / MZ / time window), NEVER descriptions, contacts,
    # coordinates or references.
    class ReportHeatmapTest < ActiveSupport::TestCase
      setup do
        @organization = create_organization
        @other_org = create_organization

        @mz_centar = LocalArea.create!(
          organization: @organization, kind: "mz", slug: "mz-centar",
          name: { "sr" => "Centar", "en" => "Centre" }
        )
        @mz_pazar = LocalArea.create!(
          organization: @organization, kind: "mz", slug: "mz-pazar",
          name: { "sr" => "Pazar", "en" => "Pazar" }
        )
      end

      def create_report(mz_slug:, category:, severity: "normalan", organization: @organization, created_at: Time.current)
        Decidim::Bih::Report.create!(
          organization:,
          description: "Problem #{SecureRandom.hex(4)}",
          category:,
          severity:,
          mz_slug:,
          created_at:
        )
      end

      test "counts reports grouped by MZ and category" do
        create_report(mz_slug: "mz-centar", category: "putevi")
        create_report(mz_slug: "mz-centar", category: "putevi")
        create_report(mz_slug: "mz-centar", category: "rasvjeta")
        create_report(mz_slug: "mz-pazar", category: "putevi")

        result = Decidim::Bih::ReportHeatmap.new(organization: @organization).call

        centar = result.areas.find { |a| a.mz_slug == "mz-centar" }
        pazar = result.areas.find { |a| a.mz_slug == "mz-pazar" }

        assert_equal 3, centar.total
        assert_equal 2, centar.category_counts["putevi"]
        assert_equal 1, centar.category_counts["rasvjeta"]
        assert_equal 1, pazar.total
        assert_equal 1, pazar.category_counts["putevi"]
      end

      test "resolves the MZ display name via LocalArea" do
        create_report(mz_slug: "mz-centar", category: "putevi")

        result = I18n.with_locale(:sr) do
          Decidim::Bih::ReportHeatmap.new(organization: @organization).call
        end

        centar = result.areas.find { |a| a.mz_slug == "mz-centar" }
        assert_equal "Centar", centar.mz_name
      end

      test "is scoped to the organization" do
        create_report(mz_slug: "mz-centar", category: "putevi")
        create_report(mz_slug: "mz-centar", category: "putevi", organization: @other_org)

        result = Decidim::Bih::ReportHeatmap.new(organization: @organization).call
        centar = result.areas.find { |a| a.mz_slug == "mz-centar" }

        assert_equal 1, centar.total
      end

      test "excludes reports with a nil mz_slug" do
        create_report(mz_slug: nil, category: "putevi")
        create_report(mz_slug: "mz-centar", category: "putevi")

        result = Decidim::Bih::ReportHeatmap.new(organization: @organization).call

        assert_equal 1, result.total
        assert_equal ["mz-centar"], result.areas.map(&:mz_slug)
      end

      test "excludes reports outside the time window" do
        create_report(mz_slug: "mz-centar", category: "putevi", created_at: 10.days.ago)
        create_report(mz_slug: "mz-centar", category: "putevi", created_at: 200.days.ago)

        result = Decidim::Bih::ReportHeatmap.new(organization: @organization, since: 90.days.ago).call
        centar = result.areas.find { |a| a.mz_slug == "mz-centar" }

        assert_equal 1, centar.total
      end

      test "the default window is the last 90 days" do
        create_report(mz_slug: "mz-centar", category: "putevi", created_at: 10.days.ago)
        create_report(mz_slug: "mz-centar", category: "putevi", created_at: 120.days.ago)

        result = Decidim::Bih::ReportHeatmap.new(organization: @organization).call
        centar = result.areas.find { |a| a.mz_slug == "mz-centar" }

        assert_equal 1, centar.total
      end

      test "counts by severity as well" do
        create_report(mz_slug: "mz-centar", category: "putevi", severity: "hitan")
        create_report(mz_slug: "mz-centar", category: "putevi", severity: "hitan")
        create_report(mz_slug: "mz-centar", category: "rasvjeta", severity: "normalan")

        result = Decidim::Bih::ReportHeatmap.new(organization: @organization).call
        centar = result.areas.find { |a| a.mz_slug == "mz-centar" }

        assert_equal 2, centar.severity_counts["hitan"]
        assert_equal 1, centar.severity_counts["normalan"]
      end

      test "the result carries NO PII fields" do
        create_report(mz_slug: "mz-centar", category: "putevi")

        result = Decidim::Bih::ReportHeatmap.new(organization: @organization).call
        area = result.areas.first

        # The aggregated area struct exposes ONLY counts + MZ identity.
        forbidden = [:description, :reporter_email, :reporter_phone, :reporter_contact,
                     :latitude, :longitude, :address, :reference]
        forbidden.each do |attr|
          assert_not area.respond_to?(attr),
                     "heatmap area must not expose PII attribute #{attr}"
        end
      end

      test "areas are ordered by descending total" do
        create_report(mz_slug: "mz-pazar", category: "putevi")
        create_report(mz_slug: "mz-centar", category: "putevi")
        create_report(mz_slug: "mz-centar", category: "rasvjeta")

        result = Decidim::Bih::ReportHeatmap.new(organization: @organization).call

        assert_equal ["mz-centar", "mz-pazar"], result.areas.map(&:mz_slug)
      end

      test "returns an empty, well-formed result when there is no data" do
        result = Decidim::Bih::ReportHeatmap.new(organization: @organization).call

        assert_equal 0, result.total
        assert_empty result.areas
        assert_kind_of Array, result.categories
      end
    end
  end
end
