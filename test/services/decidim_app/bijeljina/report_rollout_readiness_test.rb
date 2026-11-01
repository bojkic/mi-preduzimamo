# frozen_string_literal: true

require "test_helper"
require "support/synthetic_release_policy"

module DecidimApp
  module Bijeljina
    class ReportRolloutReadinessTest < ActiveSupport::TestCase
      include SyntheticReleasePolicy
      include ActiveJob::TestHelper

      setup do
        @organization = create_organization
        @owner = FactoryBot.create(:user, :confirmed, :admin, organization: @organization)
        @other_admin = FactoryBot.create(:user, :confirmed, :admin, organization: @organization)
        @approval = Decidim::Bih::Governance::ApprovalRecorder.new(
          organization: @organization, actor: @owner, role: "technical_release_owner",
          attributes: {
            "governance_kind" => "release_restart", "status" => "approved", "app_sha" => "a" * 40,
            "engine_sha" => "b" * 40, "scope_key" => Decidim::Bih::GovernanceApproval.release_scope_key("a" * 40, "b" * 40), "restart_window_starts_at" => 1.hour.ago,
            "restart_window_ends_at" => 1.hour.from_now, "verification_lane" => "fast",
            "local_gate_status" => "passed", "verification_result_digest" => "sha256:#{"e" * 64}",
            "backup_health_status" => "passed", "restore_smoke_status" => "passed",
            "backup_manifest_digest" => "sha256:#{"c" * 64}", "migration_state" => "no_pending",
            "evidence_summary" => "Synthetic independently checked release", "evidence_digest" => "sha256:#{"a" * 64}"
          }, runbook: "docs/operations/DEVELOPMENT_LANES.md"
        ).call
      end

      test "approval alone does not ring; verified R1 rings only its owner once and completion clears the bell" do
        readiness = ReportRolloutReadiness.new(organization: @organization)
        assert_equal 0, readiness.call
        readiness.record_verified!(key: "R1", owner_approval: @approval, evidence_digest: digest)
        milestone = Decidim::Bih::OperatorAuditEvent.find_by!(event_type: "report_rollout_milestone_verified")
        assert_nil milestone.user
        assert_equal "delegated_operator", milestone.role
        assert_equal @approval.id, milestone.metadata.fetch("authenticated_owner_approval_id")
        assert_no_enqueued_jobs { assert_equal 2, readiness.call }
        assert_equal 0, ReportRolloutReadiness.new(organization: @organization).call
        notices = Decidim::Notification.where(event_name: ReportRolloutReadiness::EVENT)
        assert_equal [@owner.id], notices.pluck(:decidim_user_id).uniq
        assert_equal %w(R2 R3), notices.map { |notice| notice.extra.fetch("stage") }.sort
        event = notices.first.event_class_instance
        I18n.with_locale(:sr) { assert_includes event.notification_title, "pripremu i pregled" }
        I18n.with_locale(:sr) do
          rendered = Nokogiri::HTML.fragment(event.notification_title)
          assert_equal "/admin/bih/governance", rendered.at("a")["href"]
          assert_includes rendered.text, "prijem e-pošte"
        end
        assert_equal "/admin/bih/governance", event.resource_path
        assert_equal "https://#{@organization.host}/admin/bih/governance", event.resource_url
        readiness.record_verified!(key: "R2", owner_approval: @approval, evidence_digest: digest)
        assert_equal(["R3"], notices.reload.map { |notice| notice.extra.fetch("stage") })
      end

      test "R4 waits for the exact freeze and verified R3; later gates are never guessed from elapsed time" do
        before_freeze = ReportRolloutReadiness.new(organization: @organization, now: Time.utc(2026, 10, 14, 17, 59, 59))
        before_freeze.record_verified!(key: "R1", owner_approval: @approval, evidence_digest: digest)
        before_freeze.record_verified!(key: "R3", owner_approval: @approval, evidence_digest: digest)
        before_freeze.call
        stages = -> { Decidim::Notification.where(event_name: ReportRolloutReadiness::EVENT).map { |notice| notice.extra.fetch("stage") } }
        assert_not_includes stages.call, "R4"
        after_freeze = ReportRolloutReadiness.new(organization: @organization, now: Time.utc(2026, 10, 14, 18))
        assert_equal 1, after_freeze.call
        assert_includes stages.call, "R4"
        after_freeze.record_verified!(key: "R5", owner_approval: @approval, evidence_digest: digest)
        after_freeze.record_verified!(key: "R2", owner_approval: @approval, evidence_digest: digest)
        after_freeze.call
        assert_includes stages.call, "R6"
        assert_not_includes stages.call, "R7"
        assert_not_includes stages.call, "R8"
        after_freeze.record_verified!(key: "R6", owner_approval: @approval, evidence_digest: digest)
        after_freeze.call
        assert_not_includes stages.call, "R8"
        after_freeze.record_verified!(key: "T3.7", owner_approval: @approval, evidence_digest: digest)
        assert_equal 1, after_freeze.call
        assert_includes stages.call, "R8"
        assert_equal 0, ReportRolloutReadiness.new(organization: @organization, now: Time.utc(2027)).call
      end

      test "unauthenticated approvals cannot configure another admin as recipient" do
        @approval.stub(:operator_audit_event, nil) do
          assert_raises(ArgumentError) do
            ReportRolloutReadiness.new(organization: @organization).record_verified!(key: "R1", owner_approval: @approval, evidence_digest: digest)
          end
        end
        assert_empty Decidim::Notification.where(event_name: ReportRolloutReadiness::EVENT)
      end

      private

      def digest = "sha256:#{"d" * 64}"
    end
  end
end
