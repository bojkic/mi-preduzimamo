# frozen_string_literal: true

require "test_helper"
require "support/synthetic_release_policy"

module Decidim
  module Bih
    module Admin
      class OperationsSummaryTest < ActiveSupport::TestCase
        include SyntheticReleasePolicy
        setup do
          @organization = create_organization
          @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
          @mz = Decidim::Bih::LocalArea.create!(
            organization: @organization,
            kind: "mz",
            slug: "mz-operations-summary",
            name: { "sr" => "MZ Operations Summary" }
          )
          @komsiluk = Decidim::Bih::LocalArea.create!(
            organization: @organization,
            kind: "komsiluk",
            slug: "komsiluk-operations-summary",
            name: { "sr" => "Komšiluk Operations Summary" },
            parent: @mz,
            primary_mz_slug: @mz.slug,
            overlapping_mz_slugs: [@mz.slug]
          )
        end

        test "builds dashboard metrics from organization scoped counts" do
          Decidim::Bih::OperatorRole.create!(
            organization: @organization,
            user: @admin,
            created_by: @admin,
            role: "analytics_viewer",
            expires_at: 1.month.from_now
          )
          DecidimApp::Bijeljina::CityServiceEvent.create!(
            organization: @organization,
            source_key: "electricity_outages",
            source_fingerprint: "operations-summary-electricity",
            event_type: "planned_outage",
            severity: "service_outage",
            targeting_level: "komsiluk",
            title: "Planirano isključenje",
            summary: "Izmišljeno polje 09:00-12:00",
            source_url: "https://example.test/outages",
            parser_version: "test",
            state: "pending_review"
          )

          metrics = OperationsSummary.new(organization: @organization).metrics_by_item

          assert_equal 1, metrics.fetch("city_alerts").fetch(:value)
          assert_equal "attention", metrics.fetch("city_alerts").fetch(:tone)
          assert_not metrics.has_key?("broadcasts")
          assert_equal 2, metrics.fetch("local_areas").fetch(:value)
          assert_equal 1, metrics.fetch("operator_roles").fetch(:value)
        end

        test "the city-alert tile counts what the review queue shows, not what expired unreviewed" do
          actionable = city_alert(fingerprint: "operations-summary-actionable", ends_at: 2.days.from_now)
          expired = city_alert(fingerprint: "operations-summary-expired", ends_at: 2.days.ago)
          workflow = DecidimApp::Bijeljina::CityServiceWorkflow.new(organization: @organization)

          assert_equal [actionable.id], workflow.ids(tab: "review")
          assert_equal "finished", workflow.entries.fetch(expired.id).status
          assert_equal 2, DecidimApp::Bijeljina::CityServiceEvent.for_organization(@organization).pending_review.count

          metrics = OperationsSummary.new(organization: @organization).metrics_by_item

          assert_equal 1, metrics.fetch("city_alerts").fetch(:value)
        end

        test "the neighbourhood board tile counts what its review tab lists, not expired held city notices" do
          post = lambda do |**attributes|
            Decidim::Bih::KomsilukPost.create!({ organization: @organization, komsiluk: @komsiluk, category: "safety", title: "Prekid vode",
                                                 body: "Prekid vodosnabdijevanja", review_state: "pending" }.merge(attributes))
          end
          post.call(origin: "citizen")
          post.call(origin: "city_service", status: "hidden", expires_at: 1.hour.from_now)
          post.call(origin: "city_service", status: "hidden", expires_at: 1.hour.ago)
          metrics = OperationsSummary.new(organization: @organization).metrics_by_item
          listed = Decidim::Bih::Komsiluk::ModerationQueue.new(scope: Decidim::Bih::KomsilukPost.where(organization: @organization), params: {}).counts["review"]
          assert_equal 2, listed
          assert_equal listed, metrics.fetch("komsiluk_posts").fetch(:value)
        end

        test "an alert that expired before it was published is reported beside the queue, not inside it" do
          city_alert(fingerprint: "operations-summary-open", ends_at: 2.days.from_now)
          missed = city_alert(fingerprint: "operations-summary-missed", ends_at: 2.days.ago)
          workflow = DecidimApp::Bijeljina::CityServiceWorkflow.new(organization: @organization)

          assert_equal "expired_unpublished", workflow.entries.fetch(missed.id).reason
          assert_equal 1, DecidimApp::Bijeljina::CityServiceWorkflow.expired_unpublished_count(organization: @organization)

          metric = OperationsSummary.new(organization: @organization).metrics_by_item.fetch("city_alerts")

          assert_equal 1, metric.fetch(:value)
          assert_equal I18n.t("decidim.bih.admin.operations_summary.metrics.expired_unpublished", total: 1, locale: :sr),
                       metric.fetch(:note)
        end

        test "an alert that expired after it reached the board is not a miss" do
          published = city_alert(fingerprint: "operations-summary-ran-its-course", ends_at: 2.days.ago)
          published.update!(state: "board_published", published_at: 3.days.ago)
          workflow = DecidimApp::Bijeljina::CityServiceWorkflow.new(organization: @organization)

          assert_equal "expired", workflow.entries.fetch(published.id).reason
          assert_equal 0, DecidimApp::Bijeljina::CityServiceWorkflow.expired_unpublished_count(organization: @organization)
          assert_nil OperationsSummary.new(organization: @organization).metrics_by_item.fetch("city_alerts")[:note]
        end

        test "no missed alerts means no note at all" do
          city_alert(fingerprint: "operations-summary-only-open", ends_at: 2.days.from_now)

          assert_nil OperationsSummary.new(organization: @organization).metrics_by_item.fetch("city_alerts")[:note]
        end

        test "exposes manual approval and runbook handoffs without secrets" do
          handoffs = OperationsSummary.new(organization: @organization).handoffs

          assert_equal %w(viber_launch external_chat_launch privacy_retention release_restart backup_restore),
                       (handoffs.map { |handoff| handoff.fetch(:id) })
          assert_includes handoffs.map { |handoff| handoff.fetch(:command) }, "script/mi_viber_launch_readiness_smoke"
          assert_includes handoffs.map { |handoff| handoff.fetch(:command) }, "docs/operations/release-approval-policy.md"
          assert(handoffs.all? { |handoff| handoff.fetch(:url).start_with?("/admin/bih/governance#") })
          assert_not_includes handoffs.to_json, "TOKEN"
          assert_not_includes handoffs.to_json, "PASSWORD"
        end

        test "unknown counts remain neutral instead of looking healthy" do
          metric = OperationsSummary.new(organization: @organization).send(:count_metric, nil, "review_needed")

          assert_equal "—", metric.fetch(:value)
          assert_equal "neutral", metric.fetch(:tone)
          assert_equal I18n.t("decidim.bih.admin.operations_summary.metrics.no_data"), metric.fetch(:label)
        end

        test "governance metric requires a current record for every workflow" do
          Decidim::Bih::GovernanceApproval.create!(
            organization: @organization,
            user: @admin,
            governance_kind: "release_restart",
            approval_role: "technical_release_owner",
            status: "approved",
            scope_key: Decidim::Bih::GovernanceApproval.release_scope_key("a" * 40, "b" * 40),
            app_sha: "a" * 40,
            engine_sha: "b" * 40,
            restart_window_starts_at: 1.hour.ago,
            restart_window_ends_at: 1.hour.from_now,
            metadata: {
              "verification_lane" => "fast",
              "local_gate_status" => "passed",
              "verification_result_digest" => "sha256:#{"c" * 64}",
              "verification_policy_sha256" => Decidim::Bih::GovernanceApproval.local_verification_policy_sha256,
              "required_scopes" => Decidim::Bih::GovernanceApproval.verification_scopes("fast")
            },
            backup_health_status: "passed",
            restore_smoke_status: "passed",
            backup_manifest_digest: "sha256:#{"f" * 64}",
            migration_state: "no_pending",
            evidence_summary: "Current release approval exists.",
            evidence_digest: "sha256:#{"e" * 64}",
            approved_at: Time.current
          )
          metric = OperationsSummary.new(organization: @organization).metrics_by_item.fetch("governance")

          assert_equal "1/#{Decidim::Bih::GovernanceApproval::GOVERNANCE_KINDS.size}", metric.fetch(:value)
          assert_equal "attention", metric.fetch(:tone)
          assert_equal I18n.t("decidim.bih.admin.operations_summary.metrics.governance_missing"), metric.fetch(:label)
        end

        test "governance metric reflects latest approval status" do
          Decidim::Bih::GovernanceApproval.create!(
            organization: @organization,
            user: @admin,
            governance_kind: "release_restart",
            approval_role: "admin",
            status: "needs_follow_up",
            scope_key: "release-2026-07-09",
            evidence_summary: "Gate passed but restart window still needs confirmation.",
            evidence_digest: "sha256:#{"d" * 64}",
            approved_at: Time.current
          )

          metric = OperationsSummary.new(organization: @organization).metrics_by_item.fetch("governance")

          assert_equal I18n.t("decidim.bih.admin.operations_summary.metrics.governance_follow_up"), metric.fetch(:label)
          assert_equal "attention", metric.fetch(:tone)
        end

        private

        def city_alert(fingerprint:, ends_at:)
          DecidimApp::Bijeljina::CityServiceEvent.create!(
            organization: @organization,
            source_key: "electricity_outages",
            source_fingerprint: fingerprint,
            event_type: "planned_outage",
            severity: "service_outage",
            targeting_level: "komsiluk",
            affected_area_slugs: [@komsiluk.slug],
            title: "Planirano isključenje",
            summary: "Izmišljeno polje 09:00-12:00",
            source_url: "https://example.test/outages",
            parser_version: "test",
            state: "pending_review",
            starts_at: ends_at - 3.hours,
            ends_at:
          )
        end
      end
    end
  end
end
