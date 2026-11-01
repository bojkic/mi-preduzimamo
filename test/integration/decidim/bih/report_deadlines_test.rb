# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    class ReportDeadlinesTest < ActiveSupport::TestCase
      setup do
        @organization = create_organization
        @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
        # Deadlines are fixed 24-hour days (Ruby `days.to_i`, SQL INTERVAL on UTC), while the
        # expectations below use calendar `N.days.ago/from_now`. Those differ by an hour whenever a
        # DST change falls in between (they failed on 2026-10-22, three days before the switch), so
        # pin a midsummer clock with no transition within the 40 days either side. DST itself is
        # covered explicitly by "agree across daylight saving changes".
        @now = Time.find_zone!("Europe/Sarajevo").local(2026, 7, 15, 10, 0, 0)
        travel_to @now
        Setting.put(@organization, "sistem48_routing", "central_intake", "intake@example.org")
      end

      teardown { travel_back }

      def report(**values)
        Report.create!({ organization: @organization, description: "Lighting problem", address: "Test street", category: "rasvjeta",
                         severity: "normalan", assigned_to: @admin }.merge(values))
      end

      test "SQL deadlines match displayed dates across phases and explicit overrides" do
        pending = report(created_at: 5.days.ago)
        reviewed = report(created_at: 20.days.ago, review_state: "validated", reviewed_at: 1.day.ago)
        citizen = report(created_at: 30.days.ago, review_state: "needs_information")
        citizen.case_messages.create!(actor: @admin, actor_role: "staff", kind: "question", body: "Which crossing?", created_at: 2.days.ago)
        city = report(status: "proslijedjeno", review_state: "validated", forwarded_at: 40.days.ago, sistem48_synced_at: @now)
        explicit = report(status: "proslijedjeno", review_state: "validated", forwarded_at: 40.days.ago, response_due_at: 3.days.from_now)
        terminal = report(status: "rijeseno", response_due_at: 2.days.ago)
        duplicate = report(duplicate_of: pending, response_due_at: 2.days.ago)
        collection = ReportCollection.create!(organization: @organization, title: "Lighting", topic: "Lamps", assigned_to: @admin, review_due_at: 3.days.from_now)
        planned = report(status: "planirano", review_state: "validated", report_collection: collection)
        expected = [3.days.ago, 1.day.from_now, 5.days.from_now, 40.days.ago + ReportWorkQueue::CITY_DAYS.days, 3.days.from_now, nil, nil, 3.days.from_now]
        [pending, reviewed, citizen, city, explicit, terminal, duplicate, planned].zip(expected).each do |subject, deadline|
          deadline ? assert_equal(deadline, ReportWorkQueue.due_at(subject)) : assert_nil(ReportWorkQueue.due_at(subject))
          sql_date = Report.where(id: subject.id).pick(Arel.sql(ReportWorkQueue.deadline_sql))
          deadline ? assert_equal(deadline, sql_date) : assert_nil(sql_date)
          assert_equal deadline.present? && deadline < @now, ReportWorkQueue.overdue.exists?(id: subject.id)
        end
        triage = Admin::ReportTriageSummary.new(organization: @organization)
        assert_includes triage.scope_for("stale_city_followup"), city
        assert_not_includes triage.scope_for("stale_city_followup"), explicit
      end

      test "persisted task deadlines and superseded questions are shared by SQL and presenter" do
        subject = report(status: "proslijedjeno", review_state: "needs_information", forwarded_at: 20.days.ago,
                         response_due_at: 5.days.from_now, deadline_kind: "citizen")
        question = subject.case_messages.create!(actor: @admin, actor_role: "staff", kind: "question", body: "Photo?", created_at: 2.days.ago)
        assert_equal 20.days.ago + ReportWorkQueue::CITY_DAYS.days, ReportWorkQueue.due_at(subject)
        assert_equal 20.days.ago + ReportWorkQueue::CITY_DAYS.days, Report.where(id: subject.id).pick(Arel.sql(ReportWorkQueue.deadline_sql))
        tasks = ReportObligations.materialize!(subject, actor: @admin)
        info = tasks.find { |task| task.kind == "info_request" }
        city = tasks.find { |task| task.kind == "city_response" }
        ReportObligations.supersede!(info, by: question)
        city.update!(due_at: 3.days.from_now)
        subject.obligations.reset
        assert_equal 3.days.from_now, ReportWorkQueue.due_at(subject)
        assert_equal 3.days.from_now, Report.where(id: subject.id).pick(Arel.sql(ReportWorkQueue.deadline_sql))
        assert_equal ["city_response"], ReportObligations.for_report(subject).map(&:kind)
        assert_equal "city", ReportWorkQueue.waiting_on(subject)
        subject.update!(status: "rijeseno")
        assert_empty ReportObligations.for_report(subject)
        assert_nil Report.where(id: subject.id).pick(Arel.sql(ReportWorkQueue.deadline_sql))
      end

      test "followup to an already forwarded legacy case does not require a new structured location" do
        subject = report(status: "proslijedjeno", review_state: "validated", forwarded_at: 20.days.ago, address: nil, latitude: nil, longitude: nil)
        values = { body: "Please inspect the location described in the original report." }
        preview = ReportDecision.new(subject, @admin).preview(action: "followup", values:, version: ReportReviewVersion.digest(subject))
        assert preview[:digest].present?
        fresh = report(address: nil, latitude: nil, longitude: nil)
        assert_raises(ReportDecision::Invalid) { ReportDecision.new(fresh, @admin).preview(action: "send", values:, version: ReportReviewVersion.digest(fresh)) }
      end

      test "wrong deadline kind cannot become a city followup date" do
        subject = report(status: "proslijedjeno", review_state: "validated", forwarded_at: 20.days.ago,
                         response_due_at: 20.days.from_now, deadline_kind: "citizen")
        assert_equal 20.days.ago + ReportWorkQueue::CITY_DAYS.days, ReportWorkQueue.due_at(subject)
        assert_equal 20.days.ago + ReportWorkQueue::CITY_DAYS.days, Report.where(id: subject.id).pick(Arel.sql(ReportWorkQueue.deadline_sql))
      end

      test "derived display and database deadlines agree across daylight saving changes" do
        Time.use_zone("Europe/Sarajevo") do
          subject = report(created_at: Time.zone.local(2026, 10, 24, 10))
          expected = subject.created_at + 48.hours
          assert_equal expected, ReportWorkQueue.due_at(subject)
          assert_equal expected, Report.where(id: subject.id).pick(Arel.sql(ReportWorkQueue.deadline_sql))
        end
      end

      test "derived overdue review triggers one reminder and never invents a stored deadline" do
        subject = report(created_at: 5.days.ago)
        assert_nil subject.response_due_at
        2.times { ReportCaseReminderJob.perform_now }
        assert_equal 1, subject.events.where(event_type: "case_deadline_reminded").count
        assert_equal 1, Decidim::Notification.where(user: @admin, event_name: "decidim.events.bih.report_overdue").count
        assert_equal 3.days.ago, subject.reload.reminded_due_at
        assert_nil subject.response_due_at
      end

      test "sending suppresses obsolete review deadline but new citizen reply restores its own task" do
        subject = report(review_state: "validated", reviewed_at: 4.days.ago, response_due_at: 1.day.ago)
        dispatch = ReportDispatching.queue!(report: subject, actor: @admin, digest: ReportCaseWorkflow.digest(subject))
        subject.reload
        assert_equal "sending", ReportWorkQueue.waiting_on(subject)
        assert_nil ReportWorkQueue.due_at(subject)
        assert_not ReportWorkQueue.overdue.exists?(id: subject.id)
        assert_not ReportWorkQueue.new(organization: @organization).scope.exists?(id: subject.id)
        ReportCaseWorkflow.new(subject, nil).reply(body: "New location")
        assert_equal "review", ReportWorkQueue.waiting_on(subject.reload)
        assert_equal 2.days.from_now, ReportWorkQueue.due_at(subject)
        assert ReportWorkQueue.new(organization: @organization).scope.exists?(id: subject.id)
        dispatch.update!(state: "unknown")
        assert ReportWorkQueue.new(organization: @organization).scope.exists?(id: subject.id)
      end

      test "collection deadline changes preserve a member reply deadline and submission starts city clock" do
        collection = ReportCollection.create!(organization: @organization, title: "Lighting", topic: "Lamps", summary: "Fix the lamps", assigned_to: @admin,
                                              review_due_at: 14.days.from_now)
        subject = report
        ReportPlanning.new(subject, @admin).plan(report_collection_id: collection.id, forwarding_note: "Inspect the lamp", confirm_review: "1")
        ReportCaseWorkflow.new(subject, nil).reply(body: "Another detail")
        deadline = subject.reload.response_due_at
        ReportCollectionWorkflow.new(collection, @admin).update(assigned_to_id: @admin.id, review_due_at: 20.days.from_now.iso8601)
        assert_equal deadline, subject.reload.response_due_at
        assert_equal "review", subject.deadline_kind
        ReportDecision.new(subject, @admin).call(action: "review", values: {}, version: ReportReviewVersion.digest(subject), confirmed: true)
        ReportCollectionWorkflow.new(collection, @admin).ready
        ReportCollectionWorkflow.new(collection, @admin).record_submission(recipient: "City office", reference: "Receipt 123", confirmed: "1")
        assert_equal "city", subject.reload.deadline_kind
        assert_equal ReportWorkQueue::CITY_DAYS.days.from_now, subject.response_due_at
        history = subject.events.where(event_type: "case_deadline_changed").last.metadata
        assert_equal 20.days.from_now.iso8601, history["from_due_at"]
        assert_equal ReportWorkQueue::CITY_DAYS.days.from_now.iso8601, history["to_due_at"]
        assert_equal "planning", history["from_deadline_kind"]
        assert_equal "city", history["to_deadline_kind"]
      end
    end
  end
end
