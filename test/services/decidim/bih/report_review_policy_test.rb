# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    class ReportReviewPolicyTest < ActiveSupport::TestCase
      setup do
        @organization = create_organization
        @auto_forward = Decidim::Bih.sistem48_auto_forward
        @review_first = Decidim::Bih.report_review_first
      end

      teardown do
        Decidim::Bih.sistem48_auto_forward = @auto_forward
        Decidim::Bih.report_review_first = @review_first
      end

      test "intake policy is independent of case agent activation and preserves explicit false" do
        Decidim::Bih.report_review_first = true
        [nil, true, false].product(%w(off shadow), [false, true]).each do |review_first, mode, auto_forward|
          Setting.put(@organization, "reports", "review_first", review_first)
          Setting.put(@organization, "report_review", "case_agent", mode)
          Decidim::Bih.sistem48_auto_forward = auto_forward
          report = Report.create!(organization: @organization, description: "Review policy fixture")
          processor = ReportProcessing.new
          expected = review_first == false && auto_forward
          assert_equal expected, processor.send(:ready_to_forward?, report, reviewed: false),
                       [review_first, mode, auto_forward].inspect
          assert_equal mode == "shadow", ReportReviewAssistant.active?(@organization)
        end
      end

      test "opting out cannot forward reviewed drafted duplicate planned or finished cases" do
        Decidim::Bih.sistem48_auto_forward = true
        Setting.put(@organization, "reports", "review_first", false)
        target = Report.create!(organization: @organization, description: "Main report")
        [
          { reviewed_at: Time.current }, { review_draft: { values: { draft_action: "ask" } } },
          { review_state: "validated" }, { review_state: "needs_information" },
          { duplicate_of_report_id: target.id }, { status: "planirano" }, { status: "rijeseno" }
        ].each do |attributes|
          report = Report.create!({ organization: @organization, description: "Guard fixture" }.merge(attributes))
          processor = ReportProcessing.new
          assert_not processor.send(:ready_to_forward?, report, reviewed: false), attributes.inspect
        end
      end

      test "override is organization scoped and absent override uses engine config" do
        other = create_organization
        Setting.put(@organization, "reports", "review_first", false)
        assert_not ReportProcessing.review_first?(@organization)
        assert ReportProcessing.review_first?(other)
        Decidim::Bih.report_review_first = false
        assert_not ReportProcessing.review_first?(other)
        Setting.put(other, "reports", "review_first", "true")
        assert ReportProcessing.review_first?(other)
        Setting.put(other, "reports", "review_first", "false")
        assert_not ReportProcessing.review_first?(other)
      end
    end
  end
end
