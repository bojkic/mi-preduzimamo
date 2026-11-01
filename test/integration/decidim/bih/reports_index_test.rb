# frozen_string_literal: true

require "test_helper"
# See reports_intake_test.rb for why Capybara is required here (the Decidim
# layout resolves default URL options via Capybara.server_port in tests).
require "capybara"

module Decidim
  module Bih
    # HTTP coverage for the public issue-tracker index at /biceriseno/prijave.
    # The list is tenant-scoped, filterable, and — like the map — must never
    # expose reporter PII or the free-text description.
    class ReportsIndexTest < ActionDispatch::IntegrationTest
      include ::Devise::Test::IntegrationHelpers

      setup do
        @organization = create_organization
        host! @organization.host
      end

      def report(**attrs)
        Decidim::Bih::Report.create!(
          organization: @organization,
          description: "Rupa na putu",
          **attrs
        )
      end

      test "GET prijave renders the index page" do
        report(reference: "BR-2026-0001")

        get "/biceriseno/prijave"

        assert_response :success
        assert_includes response.body, "BR-2026-0001"
      end

      test "index lists only reports for the current organization" do
        report(reference: "BR-2026-0001")
        other = create_organization
        Decidim::Bih::Report.create!(
          organization: other, description: "Tudja prijava", reference: "BR-2026-9999"
        )

        get "/biceriseno/prijave"

        assert_response :success
        assert_includes response.body, "BR-2026-0001"
        assert_not_includes response.body, "BR-2026-9999"
      end

      test "index never leaks reporter PII, description, or status token" do
        record = report(
          reference: "BR-2026-0001",
          description: "Tajni opis problema koji ne smije biti vidljiv",
          reporter_email: "tajni@example.org",
          reporter_phone: "065123456",
          anonymous: false,
          address: "Karađorđeva 1"
        )

        get "/biceriseno/prijave"

        assert_response :success
        assert_not_includes response.body, "tajni@example.org"
        assert_not_includes response.body, "065123456"
        assert_not_includes response.body, "Tajni opis problema"
        assert_not_includes response.body, record.status_token
        assert_includes response.body, "Karađorđeva 1"
      end

      test "index shows the exact address for either legacy publication flag" do
        report(reference: "BR-2026-0001", address: "Karađorđeva 1", public_location_exact: false)
        report(reference: "BR-2026-0002", address: "Filipa Višnjića 2", public_location_exact: true)

        get "/biceriseno/prijave"

        assert_response :success
        assert_includes response.body, "Karađorđeva 1"
        assert_includes response.body, "Filipa Višnjića 2"
      end

      test "status filter narrows the results" do
        report(reference: "BR-2026-0001", status: "rijeseno")
        report(reference: "BR-2026-0002", status: "primljeno")

        get "/biceriseno/prijave", params: { status: "rijeseno" }

        assert_response :success
        assert_includes response.body, "BR-2026-0001"
        assert_not_includes response.body, "BR-2026-0002"
      end

      test "index renders citizen-facing public status labels" do
        report(reference: "BR-2026-0001", status: "proslijedjeno")

        get "/biceriseno/prijave"

        assert_response :success
        assert_includes response.body, I18n.t(
          "decidim.bih.reports.public_statuses.sent_to_service", locale: :sr
        )
        assert_not_includes response.body, I18n.t("decidim.bih.reports.statuses.proslijedjeno", locale: :sr)
      end

      test "category filter narrows the results" do
        report(reference: "BR-2026-0001", category: "rasvjeta")
        report(reference: "BR-2026-0002", category: "putevi")

        get "/biceriseno/prijave", params: { category: "rasvjeta" }

        assert_response :success
        assert_includes response.body, "BR-2026-0001"
        assert_not_includes response.body, "BR-2026-0002"
      end

      test "reference search narrows the results" do
        report(reference: "BR-2026-0001")
        report(reference: "BR-2026-0002")

        get "/biceriseno/prijave", params: { q: "0001" }

        assert_response :success
        assert_includes response.body, "BR-2026-0001"
        assert_not_includes response.body, "BR-2026-0002"
      end

      test "lowercase exact reference search opens only the current organization report" do
        report(reference: "BR-2026-0001")
        other_organization = create_organization
        foreign = Decidim::Bih::Report.create!(
          organization: other_organization,
          description: "Tudja prijava",
          reference: "BR-2026-9001"
        )

        get "/biceriseno/prijave", params: { q: "br-2026-0001" }

        assert_redirected_to "/biceriseno/prijave/BR-2026-0001"

        get "/biceriseno/prijave", params: { q: foreign.reference.downcase }

        assert_response :success
        assert_not_includes response.body, foreign.reference
      end

      test "an unknown status param is ignored (no records hidden by a bogus filter)" do
        report(reference: "BR-2026-0001", status: "primljeno")

        get "/biceriseno/prijave", params: { status: "bogus" }

        assert_response :success
        assert_includes response.body, "BR-2026-0001"
      end

      test "empty state renders when there are no reports" do
        get "/biceriseno/prijave"

        assert_response :success
        assert_includes response.body, I18n.t("decidim.bih.reports.index.empty.title", locale: :sr)
      end

      test "my reports is account-scoped and uses protected token tracking links" do
        citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
        other = FactoryBot.create(:user, :confirmed, organization: @organization)
        own = report(reference: "BR-2026-0101", author: citizen)
        someone_else = report(reference: "BR-2026-0102", author: other)
        sign_in citizen

        get "/biceriseno/prijave", params: { view: "mine" }

        assert_response :success
        assert_includes response.body, own.reference
        assert_not_includes response.body, someone_else.reference
        assert_includes response.body, own.status_token
        assert_includes response.headers["Cache-Control"], "no-store"
        assert_equal "strict-origin", response.headers["Referrer-Policy"]
        assert_equal "noindex, nofollow", response.headers["X-Robots-Tag"]
      end

      test "my reports requires an account and does not expose token links anonymously" do
        own = report(reference: "BR-2026-0103")

        get "/biceriseno/prijave", params: { view: "mine" }

        assert_response :redirect
        assert_redirected_to %r{/users/sign_in}
        assert_not_includes response.body, own.status_token
      end
    end
  end
end
