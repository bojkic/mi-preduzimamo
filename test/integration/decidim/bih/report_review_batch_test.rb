# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    class ReportReviewBatchTest < ActiveSupport::TestCase
      setup do
        @organization = create_organization
        @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
        Setting.put(@organization, "sistem48_routing", "central_intake", "intake@example.org")
        @batch = ReportReviewBatch.new(organization: @organization, actor: @admin)
      end

      def report
        Report.create!(organization: @organization, description: "Street lighting does not work", address: "Test street",
                       category: "rasvjeta", severity: "normalan")
      end

      def entry(subject, action: "review", values: {})
        { reference: subject.reference, action:, values:, version: ReportReviewVersion.digest(subject.reload) }
      end

      test "only separately approved cases execute and a changed case does not stop the rest" do
        subjects = Array.new(3) { report }
        prepared = @batch.prepare(subjects.map { |subject| entry(subject) })
        assert_equal %w(prepared prepared prepared), prepared.map(&:state)
        assert subjects.all? { |subject| subject.reload.reviewed_at.nil? }
        ReportCaseWorkflow.new(subjects.first, nil).reply(body: "New detail")
        results = @batch.apply(prepared.each_with_index.map { |row, index| { token: row.token, approve: index == 1 ? "0" : "1" } })
        assert_equal %w(failed skipped applied), results.map(&:state)
        assert_nil subjects.first.reload.reviewed_at
        assert_nil subjects.second.reload.reviewed_at
        assert_equal @admin, subjects.last.reload.reviewed_by
      end

      test "invalid case and malformed entry do not prevent a valid case from being prepared" do
        subject = report
        results = @batch.prepare([entry(subject, values: {}, action: "invalid"), nil, entry(report)])
        assert_equal %w(failed failed prepared), results.map(&:state)
        assert_empty subject.events.where(event_type: "case_decision_applied")
      end

      test "mail approval uses the displayed snapshot and ignores unsigned changes" do
        subject = report
        prepared = @batch.prepare([entry(subject, action: "send", values: { forwarding_note: "Approved detail" })]).sole
        assert_equal "prepared", prepared.state
        assert_includes prepared.snapshot.fetch(:body), "Approved detail"
        assert_not_includes prepared.token, "Approved detail"
        assert_empty subject.dispatches
        result = @batch.apply([{ token: prepared.token, approve: "1", values: { forwarding_note: "Forged detail" } }]).sole
        assert_equal "queued", result.state
        dispatch = subject.dispatches.sole
        assert_equal @admin, dispatch.approved_by
        assert_equal prepared.snapshot.fetch(:body), dispatch.snapshot.fetch("body")
        assert_not_includes dispatch.snapshot.fetch("body"), "Forged detail"
        assert_nil subject.reload.forwarded_at
      end

      test "repeated confirmation cannot duplicate a decision" do
        subject = report
        prepared = @batch.prepare([entry(subject)]).sole
        2.times { @batch.apply([{ token: prepared.token, approve: "1" }]) }
        assert_equal 1, subject.events.where(event_type: "case_decision_applied").count
        assert subject.events.where(event_type: "case_decision_applied").sole.metadata["approval_key"].present?
      end

      test "tokens are actor bound expire and cannot cross tenants" do
        prepared = @batch.prepare([entry(report)]).sole
        other_admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
        other_batch = ReportReviewBatch.new(organization: @organization, actor: other_admin)
        assert_equal "failed", other_batch.apply([{ token: prepared.token, approve: "1" }]).sole.state
        foreign_org = create_organization
        foreign_actor = FactoryBot.create(:user, :admin, :confirmed, organization: foreign_org)
        foreign_batch = ReportReviewBatch.new(organization: foreign_org, actor: foreign_actor)
        assert_equal "failed", foreign_batch.apply([{ token: prepared.token, approve: "1" }]).sole.state
        travel 11.minutes do
          assert_equal "failed", @batch.apply([{ token: prepared.token, approve: "1" }]).sole.state
        end
      end

      test "malformed token affects only its row and does not inherit the prior reference" do
        prepared = @batch.prepare([entry(report)]).sole
        results = @batch.apply([{ token: prepared.token, approve: "0" }, { token: "invalid", approve: "1" }])
        assert_equal %w(skipped failed), results.map(&:state)
        assert_nil results.last.reference
      end

      test "validation failure in one approved decision leaves the next independently executable" do
        invalid_case = report
        valid_case = report
        prepared = @batch.prepare([entry(invalid_case, action: "reject"), entry(valid_case)])
        results = @batch.apply(prepared.map { |row| { token: row.token, approve: "1" } })
        assert_equal %w(failed applied), results.map(&:state)
        assert_equal "primljeno", invalid_case.reload.status
        assert_nil invalid_case.reviewed_at
        assert_equal @admin, valid_case.reload.reviewed_by
      end

      test "permissions are rechecked after preview and input is bounded" do
        prepared = @batch.prepare([entry(report)]).sole
        @admin.update!(admin: false)
        assert_raises(Decidim::ActionForbidden) { @batch.apply([{ token: prepared.token, approve: "1" }]) }
        @admin.update!(admin: true)
        assert_raises(ReportDecision::Invalid) { @batch.prepare(Array.new(26) { {} }) }
      end
    end
  end
end
