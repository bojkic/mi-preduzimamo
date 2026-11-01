# frozen_string_literal: true

require "test_helper"
require "capybara"

module Decidim
  module Bih
    class ReportReviewMetricsTest < ActionDispatch::IntegrationTest
      include ::Devise::Test::IntegrationHelpers
      setup do
        @organization = create_organization
        @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
        @now = Time.current.change(usec: 0)
        host! @organization.host
        sign_in @admin
      end

      def report(**values)
        Report.create!({ organization: @organization, description: "PRIVATE REPORT CONTENT", address: "Private address", created_at: @now - 10.hours }.merge(values))
      end

      def review(subject, at:, action: "review", source: "admin")
        subject.events.create!(organization: subject.organization, actor: source == "admin" ? @admin : nil, source:, event_type: "case_decision_applied",
                               occurred_at: at, metadata: { action: })
      end

      test "elapsed metrics use the first human decision after receipt and expose missing coverage" do
        first = report
        second = report
        report
        review(first, at: @now - 9.hours, action: "note")
        review(first, at: @now - 8.hours, source: "background")
        review(first, at: @now - 7.hours)
        review(first, at: @now - 5.hours)
        review(second, at: @now - 1.hour)
        first.case_messages.create!(actor_role: "citizen", kind: "reply", body: "PRIVATE FIRST REPLY", created_at: @now - 6.hours)
        first.case_messages.create!(actor_role: "citizen", kind: "reply", body: "PRIVATE LATER REPLY", created_at: @now - 4.hours)
        first.case_messages.create!(actor_role: "citizen", kind: "feedback", body: "Accepted", created_at: @now - 3.hours)
        review(first, at: @now + 1.hour)
        metrics = ReportReviewMetrics.new(organization: @organization, now: @now).call
        assert_equal({ total: 3, measured: 2, median_seconds: 6.hours.to_f }, metrics[:first_review])
        assert_equal({ total: 2, measured: 1, median_seconds: 1.hour.to_f }, metrics[:reply_review])
        assert_not_includes metrics.to_json, "PRIVATE"
      end

      test "legacy questions count but pending reviews and unrelated tenant records do not" do
        subject = report
        subject.events.create!(organization: @organization, actor: @admin, source: "admin", event_type: "case_reviewed",
                               occurred_at: @now - 9.hours, metadata: { review_state: "pending" })
        subject.events.create!(organization: @organization, actor: @admin, source: "admin", event_type: "case_message_created",
                               occurred_at: @now - 8.hours, metadata: { kind: "question" })
        report(organization: create_organization)
        metrics = ReportReviewMetrics.new(organization: @organization, now: @now).call
        assert_equal 1, metrics[:reports]
        assert_equal 2.hours.to_f, metrics[:first_review][:median_seconds]
      end

      test "empty evidence is unmeasured and AI changes are not labelled accuracy" do
        subject = report
        subject.review_proposals.create!(input_digest: "fixture", prompt_version: "fixture", state: "ready", proposal: { action: "review" }, decided_by: @admin,
                                         decided_at: @now, approved_action: "review", changed_fields: ["category"])
        metrics = ReportReviewMetrics.new(organization: @organization, now: @now).call
        assert_nil metrics[:first_review][:median_seconds]
        assert_equal 0, metrics[:first_review][:measured]
        assert_equal 1, metrics[:ai_decisions]
        assert_equal 1, metrics[:ai_changed]
        assert_equal({ "review" => 1 }, metrics[:ai_changes_by_action])
      end

      test "review cursor prevents a same-time older decision from consuming a new reply" do
        subject = report
        reply = subject.case_messages.create!(actor_role: "citizen", kind: "reply", body: "Later reply", created_at: @now)
        subject.events.create!(organization: @organization, actor: @admin, source: "admin", event_type: "case_decision_applied", occurred_at: @now,
                               metadata: { action: "review", reviewed_message_id: reply.id - 1 })
        metrics = ReportReviewMetrics.new(organization: @organization, now: @now).call
        assert_equal 0, metrics[:reply_review][:measured]
        subject.events.create!(organization: @organization, actor: @admin, source: "admin", event_type: "case_decision_applied", occurred_at: @now,
                               metadata: { action: "review", reviewed_message_id: reply.id })
        metrics = ReportReviewMetrics.new(organization: @organization, now: @now).call
        assert_equal 1, metrics[:reply_review][:measured]
        assert_equal 0, metrics[:reply_review][:median_seconds]
      end

      test "ordinary queue and old attention bookmark do not compute statistics" do
        subject = report
        boom = ->(**) { raise "Statistics must remain lazy" }
        ReportReviewMetrics.stub(:new, boom) do
          ReportHeatmap.stub(:new, boom) do
            Admin::ReportTriageSummary.stub(:new, boom) do
              get "/admin/bih/reports"
              assert_response :success
              assert_includes response.body, subject.reference
              get "/admin/bih/reports", params: { tab: "attention" }
              assert_response :success
              assert_select "#admin-reports-list"
              assert_select "#admin-reports-escalation", count: 0
            end
          end
        end
      end

      test "statistics render coverage without private content and planned view includes collections" do
        report
        collection = ReportCollection.create!(organization: @organization, title: "Lighting collection", topic: "Lamps", assigned_to: @admin, review_due_at: 2.weeks.from_now)
        get "/admin/bih/reports", params: { tab: "insights" }
        assert_response :success
        assert_select "#report-review-metrics"
        assert_select "#admin-reports-sla"
        assert_select "#admin-reports-list", count: 0
        assert_not_includes response.body, "PRIVATE REPORT CONTENT"
        assert_not_includes response.body, "Private address"
        get "/admin/bih/reports", params: { view: "planning" }
        assert_select "#report-planning-collections a[href='/admin/bih/report-collections/#{collection.id}']"
      end
    end
  end
end
