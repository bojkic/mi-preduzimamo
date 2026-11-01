# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module Privacy
      class ReportReviewRetentionTest < ActiveSupport::TestCase
        setup do
          @organization = create_organization
          @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
          @old = 4.years.ago
          @cutoff = 3.years.ago
          @report = Report.create!(organization: @organization, description: "Private report", address: "Street", category: "rasvjeta",
                                   review_state: "validated", reviewed_at: @old, forwarding_recipient: "intake@example.org")
          Setting.put(@organization, "sistem48_routing", "central_intake", "intake@example.org")
          @dispatch = ReportDispatching.queue!(report: @report, actor: @admin, digest: ReportCaseWorkflow.digest(@report))
          @dispatch.update!(state: "accepted", accepted_at: @old, reconciliation_evidence: "Private evidence", updated_at: @old)
          @proposal = @report.review_proposals.create!(input_digest: "old", prompt_version: "report-review-v8",
                                                       state: "ready", proposal: { question: "Private question" }, approved_action: "ask", decided_by: @admin, decided_at: @old)
          @proposal.update_columns(updated_at: @old) # rubocop:disable Rails/SkipsModelValidations -- stage historical retention boundaries without callbacks
          @report.update_columns(review_draft: { values: { body: "Private draft" } }, updated_at: @old) # rubocop:disable Rails/SkipsModelValidations -- stage historical retention boundaries without callbacks
        end

        def sweep(dry_run: true)
          ReportReviewRetention.new(organization: @organization, cutoff: @cutoff, dry_run:).call
        end

        test "review copies are counted and applied through the guarded policy pipeline" do
          attrs = { organization: @organization, report_review_before: @cutoff }
          preview = RetentionSweep.call(**attrs, record_run: true)
          assert_equal 3, preview.total
          assert_equal 1, preview.counts[:report_dispatch_contents]
          assert preview.run.cutoffs.has_key?("report_review_before")
          assert_raises(RetentionSweep::GovernanceApprovalRequired) { RetentionSweep.authorized_live_call(**attrs) }
          GovernanceApproval.create!(organization: @organization, user: @admin, governance_kind: "privacy_retention", approval_role: "admin",
                                     status: "approved", scope_key: RetentionSweep.scope_key(report_contact_before: @cutoff), evidence_summary: "Different data with same total",
                                     metadata: { dry_run_status: "warn", dry_run_total: preview.total })
          assert_raises(RetentionSweep::GovernanceApprovalRequired) { RetentionSweep.authorized_live_call(**attrs) }
          assert_nil @dispatch.reload.data_redacted_at
          GovernanceApproval.create!(organization: @organization, user: @admin, governance_kind: "privacy_retention", approval_role: "admin",
                                     status: "approved", scope_key: RetentionSweep.scope_key(**attrs), evidence_summary: "Reviewed test counts",
                                     metadata: { dry_run_status: "warn", dry_run_total: preview.total })
          assert_equal 3, RetentionSweep.authorized_live_call(**attrs).total
          assert @dispatch.reload.data_redacted_at
        end

        test "approval scope distinguishes cutoff categories precision and exact times" do
          key = RetentionSweep.scope_key(report_review_before: @cutoff)
          assert_not_equal key, RetentionSweep.scope_key(report_contact_before: @cutoff)
          assert_not_equal key, RetentionSweep.scope_key(report_review_before: @cutoff + 1.second)
          assert_not_equal RetentionSweep.scope_key(report_coordinates_before: @cutoff, report_coordinate_precision: 2),
                           RetentionSweep.scope_key(report_coordinates_before: @cutoff, report_coordinate_precision: 3)
          assert_equal key, RetentionSweep.scope_key(report_review_before: @cutoff.iso8601(6))
        end

        test "dry run counts private copies without decrypting or changing them" do
          before = @dispatch.snapshot_ciphertext
          assert_equal({ report_dispatch_contents: 1, report_review_proposals: 1, report_review_drafts: 1 }, sweep)
          assert_equal before, @dispatch.reload.snapshot_ciphertext
          assert_nil @proposal.reload.data_redacted_at
          assert @report.reload.review_draft.present?
        end

        test "redaction preserves decisions and delivery outcome and is idempotent" do
          assert_equal 3, sweep(dry_run: false).values.sum
          assert_equal "accepted", @dispatch.reload.state
          assert_equal @old.to_i, @dispatch.accepted_at.to_i
          assert_equal({}, @dispatch.snapshot)
          assert_nil @dispatch.reconciliation_evidence
          assert @dispatch.data_redacted_at
          assert_equal "ask", @proposal.reload.approved_action
          assert_equal @admin.id, @proposal.decided_by_id
          assert_nil @proposal.proposal_ciphertext
          assert_equal({}, @proposal.suggested_values)
          assert_not @proposal.current?
          assert_equal({}, @report.reload.review_draft)
          assert_not @dispatch.update(data_redacted_at: nil)
          assert_not @proposal.update(data_redacted_at: nil)
          @dispatch.reload
          @proposal.reload
          assert_equal 0, sweep(dry_run: false).values.sum
          context = Ai::ReportReviewContext.new(@report)
          assert_equal false, context.data[:dispatch_history].first[:content_available]
          assert_nil context.sources["dispatch:#{@dispatch.id}"]
        end

        test "in flight unknown recent and foreign data are excluded" do
          %w(queued sending unknown).each do |state|
            @dispatch.update_columns(state:, updated_at: @old) # rubocop:disable Rails/SkipsModelValidations -- stage historical retention boundaries without callbacks
            assert_equal 0, sweep[:report_dispatch_contents]
          end
          @dispatch.update_columns(state: "accepted", updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations -- stage historical retention boundaries without callbacks
          @proposal.update_columns(updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations -- stage historical retention boundaries without callbacks
          @report.update_columns(updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations -- stage historical retention boundaries without callbacks
          assert_equal 0, sweep.values.sum
          other = create_organization
          assert_equal 0, ReportReviewRetention.new(organization: other, cutoff: 1.day.from_now).call.values.sum
        end
      end
    end
  end
end
