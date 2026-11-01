# frozen_string_literal: true

require "test_helper"
# See reports_intake_test.rb for why Capybara is required here (the Decidim
# layout resolves default URL options via Capybara.server_port in tests).
require "capybara"

module Decidim
  module Bih
    # HTTP coverage for the public reports map at /biceriseno/mapa and its
    # sibling GeoJSON endpoint /biceriseno/mapa.json. Decidim derives the current
    # organization from the request host.
    class ReportsMapTest < ActionDispatch::IntegrationTest
      setup do
        @organization = create_organization
        host! @organization.host
        @previous_cache = Rails.cache
        Rails.cache = ActiveSupport::Cache::MemoryStore.new
      end

      teardown do
        Rails.cache = @previous_cache
      end

      def located_report(**attrs)
        Decidim::Bih::Report.create!(
          organization: @organization, description: "Rupa na putu", latitude: 44.75, longitude: 19.21, **attrs
        )
      end

      test "GET mapa renders the map page" do
        get "/biceriseno/mapa"

        assert_response :success
        assert_select "#bih-reports-map"
        assert_select "script[src=?]", "/leaflet/leaflet.js"
        assert_select "script[src^='/mi/bih-reports-map.js']", 1
        assert_not_includes response.body, "fetch(el.dataset.geojsonUrl"
        assert_not_includes response.body, "L.geoJSON(data"
      end

      test "GET mapa exposes severity styling data + a severity legend for the markers" do
        get "/biceriseno/mapa"

        assert_response :success
        # Severity drives marker size; the JS reads these from data attributes.
        assert_select "#bih-reports-map[data-severity-radii]"
        assert_select "#bih-reports-map[data-severity-labels]"
        # A dedicated severity legend (size-based, not colour-only) is rendered.
        assert_select ".bih-reports-map__legend--severity"
        # Every severity is named in the legend so the size scale is decodable.
        Decidim::Bih::ReportTaxonomy::SEVERITIES.each do |severity|
          label = I18n.t("decidim.bih.reports.severities.#{severity}", default: severity.to_s)
          assert_includes response.body, label
        end
      end

      test "GET mapa.json returns a GeoJSON FeatureCollection of located reports" do
        report = located_report(status: "proslijedjeno")

        get "/biceriseno/mapa.json"

        assert_response :success
        assert_equal "application/json", response.media_type
        body = response.parsed_body
        assert_equal "FeatureCollection", body["type"]
        assert_equal 1, body["features"].size

        props = body["features"].first["properties"]
        assert_equal report.reference, props["reference"]
        assert_equal "proslijedjeno", props["status"]
        assert_equal "sent_to_service", props["public_status"]
        assert_equal I18n.t("decidim.bih.reports.public_statuses.sent_to_service", locale: :sr),
                     props["public_status_label"]
        assert_equal "/biceriseno/prijave/#{report.reference}", URI(props["status_url"]).path
      end

      test "GET mapa.json excludes reports without coordinates" do
        located_report
        Decidim::Bih::Report.create!(organization: @organization, description: "Bez lokacije")

        get "/biceriseno/mapa.json"

        body = response.parsed_body
        assert_equal 1, body["features"].size
      end

      test "GET mapa.json never leaks reporter PII" do
        located_report(reporter_email: "tajni@example.org", reporter_phone: "065123456", anonymous: false)

        get "/biceriseno/mapa.json"

        assert_not_includes response.body, "tajni@example.org"
        assert_not_includes response.body, "065123456"
      end

      test "GET mapa.json is scoped to the current organization" do
        located_report
        other = create_organization
        Decidim::Bih::Report.create!(
          organization: other, description: "Tudja", latitude: 45.0, longitude: 18.0, reference: "BR-2026-7777"
        )

        get "/biceriseno/mapa.json"

        body = response.parsed_body
        refs = body["features"].map { |f| f["properties"]["reference"] }
        assert_not_includes refs, "BR-2026-7777"
      end

      test "GET mapa.json cache refreshes after a report status change" do
        report = located_report(status: "primljeno")

        get "/biceriseno/mapa.json"
        assert_equal "primljeno", response.parsed_body.dig("features", 0, "properties", "status")

        report.update!(status: "rijeseno")
        get "/biceriseno/mapa.json"

        assert_equal "rijeseno", response.parsed_body.dig("features", 0, "properties", "status")
      end

      test "GET mapa.json flags recently resolved reports for the distinct layer" do
        report = located_report
        report.update!(status: "rijeseno")

        get "/biceriseno/mapa.json"

        props = response.parsed_body.dig("features", 0, "properties")
        assert_equal "rijeseno", props["status"]
        assert_equal true, props["resolved_recently"]
      end

      test "GET mapa exposes the recently-resolved layer styling + legend" do
        get "/biceriseno/mapa"

        assert_response :success
        assert_select "#bih-reports-map[data-layer-resolved]"
        assert_select "#bih-reports-map[data-resolved-ring-color]"
        assert_includes response.body, I18n.t("decidim.bih.reports_map.show.legend_resolved_recently", locale: :sr)
      end

      test "GET mapa renders citizen-facing status labels" do
        get "/biceriseno/mapa"

        assert_response :success
        assert_includes response.body, I18n.t(
          "decidim.bih.reports.public_statuses.sent_to_service", locale: :sr
        )
        assert_not_includes response.body, I18n.t("decidim.bih.reports.statuses.proslijedjeno", locale: :sr)
      end
    end
  end
end
