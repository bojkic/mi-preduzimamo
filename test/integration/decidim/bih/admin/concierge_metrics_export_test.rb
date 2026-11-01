# frozen_string_literal: true

require "test_helper"
require "csv"

module Decidim
  module Bih
    module Admin
      class ConciergeMetricsExportTest < ActionDispatch::IntegrationTest
        include ::Devise::Test::IntegrationHelpers

        setup do
          @organization = create_organization
          @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
          host! @organization.host
          @day = Time.current.in_time_zone("Europe/Sarajevo").to_date - 1
        end

        def add(**attributes)
          ConciergeMetricRollup.create!(organization: @organization, day: @day, kind: "answer_detail", topic: "water", label: "answered",
                                        facet: "status", traffic_kind: "synthetic", release_sha: "a" * 40, prompt_version: 1, count: 5, **attributes)
        end

        test "table and csv retain identical filters and reconcile the same seeded tenant window" do
          add(count: 9)
          add(facet: "fee", count: 5)
          add(traffic_kind: "unclassified", count: 23)
          add(day: @day - 8, count: 37)
          add(organization: create_organization, count: 41)
          sign_in @admin
          get "/admin/bih/analytics", params: { tab: "metrics", period: 7, cohort: "captured", traffic: "synthetic" }
          assert_response :success
          assert_select "#admin-concierge-metrics [data-metrics-total]", text: /14/
          assert_select "#admin-concierge-metrics a[href*='mi_bot_metrics'][href*='traffic=synthetic'][href*='cohort=captured'][href*='period=7']"
          get "/admin/bih/analytics/export/mi_bot_metrics.csv", params: { period: 7, cohort: "captured", traffic: "synthetic" }
          assert_response :success
          rows = CSV.parse(response.body, headers: true)
          assert_equal "14", rows.first["sample_size"]
          assert_equal(rows.first["count"].to_i, rows.drop(1).sum { |row| row["count"].to_i })
          equivalent = ConciergeMetricRollup.where(organization: @organization, kind: "answer_detail", day: (@day - 6)..@day, traffic_kind: "synthetic").sum(:count)
          assert_equal equivalent, rows.first["count"].to_i
          assert_equal ConciergeMetricsSummary::HEADERS, rows.headers
          assert_empty rows.headers & %w(user_id organization_id session_digest citizen_message bot_reply_text phone email)
        end

        test "export suppresses sparse labels and exact denominator" do
          add(count: 10)
          add(topic: "health", facet: "contact", count: 1)
          sign_in @admin
          get "/admin/bih/analytics/export/mi_bot_metrics.csv"
          assert_response :success
          rows = CSV.parse(response.body, headers: true)
          assert_nil rows.first["sample_size"]
          assert_nil rows.first["count"]
          assert_equal "suppressed", rows.first["privacy_status"]
          assert_not_includes response.body, "health"
          assert_equal "10", rows[-1]["count"]
        end

        test "anonymous callers cannot obtain operational metrics" do
          add
          get "/admin/bih/analytics/export/mi_bot_metrics.csv"
          assert_response :redirect
          assert_not_includes response.body, "process_boot_checkout"
        end
      end
    end
  end
end
