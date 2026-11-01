# frozen_string_literal: true

require "test_helper"
require "rake"

module Tasks
  # Backfill task for the per-MZ heatmap: set mz_slug on existing located
  # reports so the heatmap is not empty on first deploy. Idempotent; skips
  # reports without coordinates; one PointRouting call each, rescued.
  class BackfillMzSlugTest < ActiveSupport::TestCase
    TASK = "decidim_bih:reports:backfill_mz_slug"

    def self.load_tasks
      return if Rake::Task.task_defined?(TASK)

      Rails.application.load_tasks
    end

    setup do
      self.class.load_tasks
      @organization = create_organization

      @mz = Decidim::Bih::LocalArea.create!(
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

    teardown do
      Rake::Task[TASK].reenable
    end

    def run_task(host)
      capture_io { Rake::Task[TASK].invoke(host) }
    end

    test "aborts when the host does not resolve to an organization" do
      assert_raises(SystemExit) do
        capture_io { Rake::Task[TASK].invoke("nope.example.org") }
      end
    end

    test "backfills mz_slug for an existing located report" do
      report = Decidim::Bih::Report.create!(
        organization: @organization,
        description: "Postojeća prijava sa lokacijom",
        latitude: 44.755,
        longitude: 19.215
      )
      assert_nil report.mz_slug

      run_task(@organization.host)

      assert_equal "mz-centar", report.reload.mz_slug
    end

    test "skips reports without coordinates" do
      report = Decidim::Bih::Report.create!(
        organization: @organization,
        description: "Bez lokacije"
      )

      run_task(@organization.host)

      assert_nil report.reload.mz_slug
    end

    test "is idempotent — re-running does not change an already-set slug" do
      report = Decidim::Bih::Report.create!(
        organization: @organization,
        description: "Lokacija",
        latitude: 44.755,
        longitude: 19.215
      )
      run_task(@organization.host)
      Rake::Task[TASK].reenable
      run_task(@organization.host)

      assert_equal "mz-centar", report.reload.mz_slug
    end
  end
end
