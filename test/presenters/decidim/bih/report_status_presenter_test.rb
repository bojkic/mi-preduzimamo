# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    # Characterization test for ReportStatusPresenter, which is the extracted
    # single source of truth for the per-status colour (legend/marker) and tone
    # (pill bg/ink/dot) that were previously hand-duplicated across the reports
    # views (show, index, duplicate, reports_map/show).
    #
    # The exact values asserted below are the literals those views rendered, so
    # a failure here means a public surface would change colour.
    class ReportStatusPresenterTest < ActiveSupport::TestCase
      # The legend/marker colour each view rendered, per status.
      EXPECTED_COLORS = {
        "primljeno" => "#2c7fb8",
        "planirano" => "#64748b",
        "proslijedjeno" => "#f59e0b",
        "u_obradi" => "#eab308",
        "rijeseno" => "#16a34a",
        "odbijeno" => "#9ca3af"
      }.freeze

      # The [bg, ink, dot] pill tone each view rendered, per status.
      EXPECTED_TONES = {
        "primljeno" => ["#dcebf6", "#1c3d53", "#5b9bc4"],
        "planirano" => ["#eef1f3", "#374151", "#64748b"],
        "proslijedjeno" => ["#fdf6d6", "#7a5d10", "#f3cf5e"],
        "u_obradi" => ["#fdf6d6", "#7a5d10", "#f3cf5e"],
        "rijeseno" => ["#e6efcf", "#46611f", "#9bbb5f"],
        "odbijeno" => ["#eef1f3", "#51606b", "#9ca3af"]
      }.freeze

      test "color returns the exact legend/marker colour for every status" do
        Decidim::Bih::Report::STATUSES.each do |status|
          assert_equal EXPECTED_COLORS.fetch(status),
                       Decidim::Bih::ReportStatusPresenter.color(status),
                       "colour for #{status} must be unchanged"
        end
      end

      test "tone returns the exact [bg, ink, dot] pill tone for every status" do
        Decidim::Bih::Report::STATUSES.each do |status|
          assert_equal EXPECTED_TONES.fetch(status),
                       Decidim::Bih::ReportStatusPresenter.tone(status),
                       "tone for #{status} must be unchanged"
        end
      end

      test "for returns both colour and tone for a status" do
        assert_equal(
          { color: "#16a34a", tone: ["#e6efcf", "#46611f", "#9bbb5f"] },
          Decidim::Bih::ReportStatusPresenter.for("rijeseno")
        )
      end

      test "an unknown status falls back to the neutral tone/colour the views used" do
        assert_equal ["#eef1f3", "#51606b", "#9ca3af"],
                     Decidim::Bih::ReportStatusPresenter.tone("bogus")
        assert_equal "#9ca3af", Decidim::Bih::ReportStatusPresenter.color("bogus")
      end

      test "a nil status falls back to the neutral tone (matches the view || guard)" do
        assert_equal ["#eef1f3", "#51606b", "#9ca3af"],
                     Decidim::Bih::ReportStatusPresenter.tone(nil)
      end

      test "colors yields a status=>colour map in STATUSES order (byte-identical to_json)" do
        # The map view serialises this with to_json into a data attribute; the
        # JSON must match the previous inline hash exactly (same keys, order).
        expected_json = {
          "primljeno" => "#2c7fb8",
          "planirano" => "#64748b",
          "proslijedjeno" => "#f59e0b",
          "u_obradi" => "#eab308",
          "rijeseno" => "#16a34a",
          "odbijeno" => "#9ca3af"
        }.to_json

        assert_equal expected_json, Decidim::Bih::ReportStatusPresenter.colors.to_json
      end

      test "label returns the citizen-facing public lifecycle label" do
        assert_equal I18n.t("decidim.bih.reports.public_statuses.sent_to_service", locale: :sr),
                     Decidim::Bih::ReportStatusPresenter.label("proslijedjeno", locale: :sr)
        assert_equal I18n.t("decidim.bih.reports.public_statuses.not_actionable", locale: :sr),
                     Decidim::Bih::ReportStatusPresenter.label("odbijeno", locale: :sr)
      end

      test "labels yields a status=>public label map in STATUSES order" do
        labels = Decidim::Bih::ReportStatusPresenter.labels(locale: :sr)

        assert_equal Decidim::Bih::ReportStatusPresenter.filter_statuses, labels.keys
        assert_equal I18n.t("decidim.bih.reports.public_statuses.sent_to_service", locale: :sr),
                     labels.fetch("proslijedjeno")
      end
    end
  end
end
