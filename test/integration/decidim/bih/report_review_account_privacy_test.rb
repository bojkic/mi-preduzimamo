# frozen_string_literal: true

require "test_helper"
require "zip"

module Decidim
  module Bih
    class ReportReviewAccountPrivacyTest < ActiveSupport::TestCase
      include ActiveJob::TestHelper

      setup do
        @organization = create_organization
        @citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
        @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
        @report = Report.create!(organization: @organization, author: @citizen, description: "Citizen evidence", address: "Street",
                                 category: "rasvjeta", review_state: "validated", reviewed_at: Time.current,
                                 forwarding_recipient: "intake@example.org", review_draft: { values: { body: "PRIVATE_REVIEW_DRAFT" } })
        Setting.put(@organization, "sistem48_routing", "central_intake", "intake@example.org")
        @dispatch = ReportDispatching.queue!(report: @report, actor: @admin, digest: ReportCaseWorkflow.digest(@report))
        @proposal = @report.review_proposals.create!(input_digest: "test", prompt_version: Ai::CaseAgent::PROMPT_VERSION,
                                                     state: "ready", proposal: { rationale: "PRIVATE_AI_RATIONALE" }, decided_by: @admin)
      end

      def delete_account(user)
        form = Decidim::DeleteAccountForm.from_params(delete_reason: "test").with_context(current_user: user)
        Decidim::DestroyAccount.new(form).call
        assert user.reload.deleted?
      end

      test "account anonymization preserves report evidence and reviewer references" do
        delete_account(@citizen)
        assert_equal @citizen.id, @report.reload.author.id
        assert @report.author.deleted?
        assert_equal "Citizen evidence", @report.description
        delete_account(@admin)
        assert @dispatch.reload.approved_by.deleted?
        assert @proposal.reload.decided_by.deleted?
        assert Report.exists?(@report.id)
      end

      test "deleted approver cannot authorize an already queued outgoing message" do
        delete_account(@admin)
        assert_no_difference "ActionMailer::Base.deliveries.size" do
          ReportDispatching.deliver!(@dispatch.reload)
        end
        assert_equal "cancelled", @dispatch.reload.state
        assert_nil @report.reload.forwarded_at
      end

      test "standard citizen export excludes private review storage" do
        excluded = %w(Decidim::Bih::ReportDispatch Decidim::Bih::ReportReviewProposal Decidim::Bih::ReportPhotoDraft)
        assert_empty Decidim::DownloadYourDataSerializers.data_entities & excluded
        buffer = Decidim::DownloadYourDataExporter.new(@citizen, "test-export").send(:data)
        contents = []
        Zip::InputStream.open(buffer) do |zip|
          contents << zip.read while zip.get_next_entry
        end
        assert contents.any?
        %w(PRIVATE_REVIEW_DRAFT PRIVATE_AI_RATIONALE snapshot_ciphertext proposal_ciphertext owner_digest).each do |value|
          assert_not_includes contents.join, value
        end
      end

      test "report deletion cannot silently cascade approved evidence" do
        assert_raises(ActiveRecord::DeleteRestrictionError) { @report.destroy! }
        assert Report.exists?(@report.id)
        assert ReportDispatch.exists?(@dispatch.id)
        assert ReportReviewProposal.exists?(@proposal.id)
      end
    end
  end
end
