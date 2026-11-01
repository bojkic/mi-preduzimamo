# frozen_string_literal: true

require "test_helper"
require "capybara"

module Decidim
  module Bih
    # Public, anonymous per-MZ problem heatmap page. PII-safe: renders counts
    # only (category / severity / MZ / time). Inherits the same anonymous base
    # as the reports map.
    class ReportHeatmapControllerTest < ActionDispatch::IntegrationTest
      setup do
        @organization = create_organization
        host! @organization.host

        @mz = Decidim::Bih::LocalArea.create!(
          organization: @organization, kind: "mz", slug: "mz-centar",
          name: { "sr" => "Centar", "en" => "Centre" }
        )
      end

      test "renders the heatmap page anonymously" do
        get "/biceriseno/mapa-problema"
        assert_response :success
      end

      test "renders per-MZ category counts" do
        3.times do
          Decidim::Bih::Report.create!(
            organization: @organization,
            description: "Rupa #{SecureRandom.hex(4)}",
            category: "putevi",
            mz_slug: "mz-centar"
          )
        end

        get "/biceriseno/mapa-problema"
        assert_response :success

        # The MZ name and the count must both appear on the page.
        assert_includes response.body, "Centar"
        assert_includes response.body, "3"
      end

      test "does not leak any report PII onto the page" do
        Decidim::Bih::Report.create!(
          organization: @organization,
          description: "Tajni opis koji ne smije iscuriti",
          category: "putevi",
          mz_slug: "mz-centar",
          address: "Tajna adresa 5",
          reporter_email: "gradjanin@example.org",
          reporter_phone: "+387 65 123 456",
          latitude: 44.755,
          longitude: 19.215
        )

        get "/biceriseno/mapa-problema"
        assert_response :success

        assert_not_includes response.body, "Tajni opis koji ne smije iscuriti"
        assert_not_includes response.body, "Tajna adresa 5"
        assert_not_includes response.body, "gradjanin@example.org"
        assert_not_includes response.body, "+387 65 123 456"
      end
    end
  end
end
