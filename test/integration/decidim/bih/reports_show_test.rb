# frozen_string_literal: true

require "test_helper"
# See reports_intake_test.rb for why Capybara is required here (the Decidim
# layout resolves default URL options via Capybara.server_port in tests).
require "capybara"

module Decidim
  module Bih
    # HTTP coverage for the public single-report status page at
    # /biceriseno/prijave/:reference, focused on the resolution timeline that
    # makes the city's responsiveness visible. Like the rest of the public
    # reporting surface it must never expose reporter PII or the free-text
    # description.
    class ReportsShowTest < ActionDispatch::IntegrationTest
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

      test "show renders the timeline stages with the reached-stage timestamps" do
        r = report(reference: "BR-2026-0001")
        r.update!(status: "proslijedjeno")
        r.update!(status: "u_obradi")
        r.update!(status: "rijeseno")

        get "/biceriseno/prijave/BR-2026-0001"

        assert_response :success
        body = response.body
        # Every reached lifecycle stage label is present.
        assert_includes body, I18n.t("decidim.bih.reports.public_statuses.received", locale: :sr)
        assert_includes body, I18n.t("decidim.bih.reports.public_statuses.sent_to_service", locale: :sr)
        assert_includes body, I18n.t("decidim.bih.reports.public_statuses.in_progress", locale: :sr)
        assert_includes body, I18n.t("decidim.bih.reports.public_statuses.resolved", locale: :sr)
        assert_not_includes body, I18n.t("decidim.bih.reports.statuses.proslijedjeno", locale: :sr)
        # The timeline section heading is rendered.
        assert_includes body, I18n.t("decidim.bih.reports.show.timeline.title", locale: :sr)
        # At least one localized stage timestamp is rendered.
        assert_includes body, I18n.l(r.reload.created_at, format: :long, locale: :sr)
      end

      test "tokenized status route renders the same PII-light tracker" do
        r = report(
          reference: "BR-2026-0040",
          description: "Privatni opis tokenizovane prijave",
          reporter_email: "token@example.org",
          reporter_phone: "065999000"
        )

        get "/biceriseno/prijave/#{r.reference}/status/#{r.status_token}"

        assert_response :success
        assert_equal "noindex, nofollow", response.headers["X-Robots-Tag"]
        assert_equal "strict-origin", response.headers["Referrer-Policy"]
        assert_includes response.headers["Cache-Control"], "no-store"
        assert_includes response.headers["Cache-Control"], "private"
        assert_equal "no-cache", response.headers["Pragma"]
        assert_includes response.body, r.reference
        assert_select 'meta[name="robots"][content="noindex, follow"]'
        assert_select 'link[rel="canonical"]', count: 0
        assert_select 'link[rel="alternate"]', count: 0
        assert_not_includes response.body, r.status_token
        assert_not_includes response.body, "token@example.org"
        assert_not_includes response.body, "065999000"
        assert_not_includes response.body, "Privatni opis"
      end

      test "tokenized status route does not fall back to reference when token is wrong" do
        r = report(reference: "BR-2026-0041")

        get "/biceriseno/prijave/#{r.reference}/status/not-the-token"

        assert_redirected_to "/biceriseno/prijave/new?locale=sr"
        assert_includes response.headers["Cache-Control"], "no-store"
        assert_includes response.headers["Cache-Control"], "private"
      end

      test "tokenized status route does not expose another organization's report" do
        other_organization = create_organization
        other_report = Decidim::Bih::Report.create!(
          organization: other_organization,
          reference: "BR-2026-0042",
          description: "Privatni opis druge organizacije",
          reporter_email: "other-token@example.org",
          reporter_phone: "065777000"
        )

        get "/biceriseno/prijave/#{other_report.reference}/status/#{other_report.status_token}"

        assert_redirected_to "/biceriseno/prijave/new?locale=sr"
        assert_not_includes response.body, other_report.status_token
        assert_not_includes response.body, "other-token@example.org"
        assert_not_includes response.body, "065777000"
        assert_not_includes response.body, "Privatni opis druge organizacije"
      end

      test "show falls back gracefully for a report with empty status_history" do
        r = report(reference: "BR-2026-0002", status: "proslijedjeno")
        # Simulate a legacy row predating the status_history column.
        r.update_columns( # rubocop:disable Rails/SkipsModelValidations
          status_history: [],
          forwarded_at: 2.days.ago
        )

        get "/biceriseno/prijave/BR-2026-0002"

        assert_response :success
        body = response.body
        # Falls back to created_at for primljeno and current status for the rest.
        assert_includes body, I18n.t("decidim.bih.reports.public_statuses.received", locale: :sr)
        assert_includes body, I18n.t("decidim.bih.reports.public_statuses.sent_to_service", locale: :sr)
        assert_includes body, I18n.t("decidim.bih.reports.show.timeline.title", locale: :sr)
        # The forwarded_at fallback timestamp is rendered for the proslijedjeno stage.
        assert_includes body, I18n.l(r.reload.forwarded_at, format: :long, locale: :sr)
      end

      test "show surfaces the corroboration count when at least one citizen corroborated" do
        report(reference: "BR-2026-0010", corroboration_count: 3)

        get "/biceriseno/prijave/BR-2026-0010"

        assert_response :success
        assert_includes response.body, I18n.t(
          "decidim.bih.reports.show.corroboration", count: 3, locale: :sr
        )
      end

      test "show does not render the corroboration line when the count is zero" do
        report(reference: "BR-2026-0011", corroboration_count: 0)

        get "/biceriseno/prijave/BR-2026-0011"

        assert_response :success
        assert_not_includes response.body, I18n.t(
          "decidim.bih.reports.show.corroboration", count: 1, locale: :sr
        )
      end

      test "the timeline never leaks reporter PII or the description" do
        r = report(
          reference: "BR-2026-0003",
          description: "Tajni opis koji ne smije biti vidljiv",
          reporter_email: "tajni@example.org",
          reporter_phone: "065123456"
        )
        r.update!(status: "rijeseno")

        get "/biceriseno/prijave/BR-2026-0003"

        assert_response :success
        assert_not_includes response.body, "tajni@example.org"
        assert_not_includes response.body, "065123456"
        assert_not_includes response.body, "Tajni opis"
        assert_not_includes response.body, r.status_token
      end
    end
  end
end
