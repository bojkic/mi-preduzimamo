# frozen_string_literal: true

require "test_helper"
module Decidim
  module Bih
    class ReportShadowSweepTest < ActiveSupport::TestCase
      include ActiveJob::TestHelper
      setup do
        @org = create_organization
        @actor = FactoryBot.create(:user, :confirmed, :admin, organization: @org)
        @report = Report.create!(organization: @org, description: "Known defect", address: "Street 1", category: "putevi")
        Setting.put(@org, "report_review", "case_agent", "shadow")
      end
      test "sweep is idempotent and budget exhaustion resumes without duplicate execution" do
        sweep = ReportShadowSweep.start!(organization: @org, actor: @actor, report_ids: [@report.id])
        assert_equal sweep["id"], ReportShadowSweep.start!(organization: @org, actor: @actor, report_ids: [@report.id])["id"]
        failure = Struct.new(:failure_reason, :id, :state).new("daily_budget_exceeded", 1, "unavailable")
        assistant = Object.new
        assistant.define_singleton_method(:call) { |*_args, **_options| failure }
        ReportReviewAssistant.stub(:new, -> { assistant }) { ReportShadowSweep.new(@org).call }
        value = Setting.namespace_for(@org, "report_review").fetch("shadow_sweep")
        assert_equal [@report.id], value["pending"]
        assert_equal "running", value["state"]
        assert_empty value["results"]
        assert_no_enqueued_jobs(only: ReportShadowSweepJob) { ReportShadowSweep.resume!(@org) }
        travel 2.days do
          ready = Struct.new(:failure_reason, :id, :state).new(nil, 2, "ready")
          assistant.define_singleton_method(:call) { |*_args, **_options| ready }
          ReportReviewAssistant.stub(:new, -> { assistant }) { ReportShadowSweep.new(@org).call }
          value = Setting.namespace_for(@org, "report_review").fetch("shadow_sweep")
          assert_equal "complete", value["state"]
          assert_equal 1, value["results"].size
          assert_empty value["pending"]
        end
      end
      test "an overlapping model run stays pending and cannot announce completion" do
        ReportShadowSweep.start!(organization: @org, actor: @actor, report_ids: [@report.id])
        generating = Struct.new(:failure_reason, :id, :state).new(nil, 3, "generating")
        assistant = Object.new
        assistant.define_singleton_method(:call) { |*_args, **_options| generating }
        ReportReviewAssistant.stub(:new, -> { assistant }) { ReportShadowSweep.new(@org).call }
        value = Setting.namespace_for(@org, "report_review").fetch("shadow_sweep")
        assert_equal [@report.id], value["pending"]
        assert_equal "running", value["state"]
        assert_empty value["results"]
        assert_operator Time.iso8601(value["eligible_at"]), :>, Time.current
        assert_empty Decidim::Notification.where(user: @actor, event_name: "decidim.events.bih.report_shadow_sweep_completed")
      end
      test "policy planning accepts a city-wide proposal without a repair location" do
        collection = ReportCollection.create!(organization: @org, title: "Cycling", topic: "Cycling links", summary: "City-wide cycling links", assigned_to: @actor,
                                              review_due_at: 14.days.from_now)
        @report.update!(address: nil)
        values = { report_collection_id: collection.id, forwarding_note: "City-wide cycling proposal", confirm_review: "1" }
        assert_raises(ReportPlanning::Invalid) { ReportPlanning.new(@report, @actor).plan(values) }
        ReportPlanning.new(@report, @actor).plan(values.merge(report_subtype: "opsti_prijedlog"))
        assert_equal "planirano", @report.reload.status
        assert_nil @report.address
        ReportCollectionWorkflow.new(collection, @actor).ready
        assert_equal "ready", collection.reload.state
      end
      test "owner approval cannot satisfy missing policy evidence" do
        Setting.put(@org, "report_automation", "owner_authorized", true)
        result = ReportAutomationReadiness.new(organization: @org).call
        assert(result.values.none? { |policy| policy[:ready] })
        assert_includes result.fetch("city_reminder")[:reasons], "policy_not_deployed"
        assert_includes result.fetch("city_reminder")[:reasons], "too_few_reviewed_cases"
        assert_no_difference ["ReportMessage.count", "ReportDispatch.count"] do
          2.times { ReportAutomationReadiness.new(organization: @org).call }
        end
      end
    end
  end
end
