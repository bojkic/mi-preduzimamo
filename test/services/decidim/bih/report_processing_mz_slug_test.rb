# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    # Coordinates enrich the heatmap independently of AI or staff classification.
    class ReportProcessingMzSlugTest < ActiveSupport::TestCase
      setup do
        @organization = create_organization

        @mz = LocalArea.create!(
          organization: @organization, kind: "mz", slug: "mz-centar",
          name: { "sr" => "Centar", "en" => "Centre" },
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
      end

      def forwarder_ok
        Object.new.tap do |stub|
          stub.define_singleton_method(:last_error) { nil }
          stub.define_singleton_method(:call) { |_hash| true }
        end
      end

      test "resolves and persists mz_slug from the report coordinates" do
        report = Decidim::Bih::Report.create!(
          organization: @organization,
          description: "Velika rupa na putu",
          latitude: 44.755,
          longitude: 19.215
        )

        Decidim::Bih::ReportProcessing.new(
          forwarder: forwarder_ok
        ).call(report: report)

        assert_equal "mz-centar", report.reload.mz_slug
      end

      test "leaves mz_slug nil when the report has no coordinates" do
        report = Decidim::Bih::Report.create!(
          organization: @organization,
          description: "Bez lokacije"
        )

        Decidim::Bih::ReportProcessing.new(
          forwarder: forwarder_ok
        ).call(report: report)

        assert_nil report.reload.mz_slug
      end

      test "leaves mz_slug nil when the point falls outside every MZ" do
        report = Decidim::Bih::Report.create!(
          organization: @organization,
          description: "Van granica",
          latitude: 10.0,
          longitude: 10.0
        )

        Decidim::Bih::ReportProcessing.new(
          forwarder: forwarder_ok
        ).call(report: report)

        assert_nil report.reload.mz_slug
      end

      test "a routing error degrades to nil mz_slug without breaking intake" do
        report = Decidim::Bih::Report.create!(
          organization: @organization,
          description: "Greska u rutiranju",
          latitude: 44.755,
          longitude: 19.215
        )

        Decidim::Bih::Geo::PointRouting.stub(:resolve, ->(**) { raise "boom" }) do
          Decidim::Bih::ReportProcessing.new(
            forwarder: forwarder_ok
          ).call(report: report)
        end

        report.reload
        assert_nil report.mz_slug
        assert_nil report.category
      end
    end
  end
end
