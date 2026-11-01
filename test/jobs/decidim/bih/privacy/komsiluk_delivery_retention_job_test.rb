# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module Privacy
      class KomsilukDeliveryRetentionJobTest < ActiveJob::TestCase
        setup do
          @organization = create_organization
          @admin = create(:user, :admin, :confirmed, organization: @organization)
          @cutoff = 91.days.ago.iso8601
          @intent = expired_intent(@organization, @admin)
        end

        test "delivery cutoff reaches reporting and requires exact approval before an organization scoped apply" do
          other_organization = create_organization
          other_admin = create(:user, :admin, :confirmed, organization: other_organization)
          other_intent = expired_intent(other_organization, other_admin)
          RetentionSweepJob.perform_now(organization_id: @organization.id, komsiluk_delivery_before: @cutoff)
          assert KomsilukSendIntent.exists?(@intent.id)
          run = RetentionRun.where(organization: @organization).recent.first
          assert_predicate run, :dry_run?
          assert_equal "ok", run.status
          assert_equal "job", run.source
          assert_equal 1, run.counts["komsiluk_delivery_data"]
          assert_equal Time.iso8601(@cutoff), Time.iso8601(run.cutoffs["komsiluk_delivery_before"])

          assert_raises(RetentionSweep::GovernanceApprovalRequired) do
            RetentionSweepJob.perform_now(organization_id: @organization.id, dry_run: false, komsiluk_delivery_before: @cutoff)
          end
          assert KomsilukSendIntent.exists?(@intent.id)
          GovernanceApproval.create!(
            organization: @organization, user: @admin, governance_kind: "privacy_retention",
            approval_role: "admin", status: "approved",
            scope_key: RetentionSweep.scope_key(komsiluk_delivery_before: @cutoff),
            evidence_summary: "Synthetic isolated-test aggregate reviewed.",
            metadata: { "dry_run_status" => "warn", "dry_run_total" => 1 }
          )
          RetentionSweepJob.perform_now(organization_id: @organization.id, dry_run: false, komsiluk_delivery_before: @cutoff)
          assert_not KomsilukSendIntent.exists?(@intent.id)
          assert KomsilukSendIntent.exists?(other_intent.id)
          applied = RetentionRun.where(organization: @organization).recent.first
          assert_predicate applied, :live?
          assert_equal 1, applied.counts["komsiluk_delivery_data"]
        end

        test "reporting also refuses a delivery cutoff newer than ninety days" do
          error = assert_raises(ArgumentError) do
            RetentionSweepJob.perform_now(organization_id: @organization.id, komsiluk_delivery_before: 89.days.ago.iso8601)
          end
          assert_equal "cutoff must be at least 90 days old", error.message
          assert KomsilukSendIntent.exists?(@intent.id)
        end

        private

        def expired_intent(organization, actor)
          KomsilukSendIntent.create!(organization:, actor:, kind: "publication", state: "expired",
                                     publication_key: SecureRandom.uuid, preview_digest: "retention-test-digest",
                                     expires_at: 120.days.ago, payload: { title: "Synthetic expired notice" })
        end
      end
    end
  end
end
