# frozen_string_literal: true

require "test_helper"
require "timeout"

module Decidim
  module Bih
    # Committed fixtures are necessary for independent PostgreSQL connections.
    # Cleanup is scoped to this test's fresh organization, never the whole DB.
    class ReportReviewConcurrencyTest < ActiveSupport::TestCase
      self.use_transactional_tests = false
      include ActiveJob::TestHelper

      setup do
        @organization = create_organization
        @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
        @report = Report.create!(organization: @organization, description: "Concurrent fixture", address: "Fixture street", category: "rasvjeta", severity: "normalan")
        Setting.put(@organization, "sistem48_routing", "central_intake", "intake@example.org")
        clear_enqueued_jobs
      end

      teardown do
        if @organization
          reports = Report.where(organization: @organization)
          ids = reports.pluck(:id)
          ReportPhotoDraft.where(organization: @organization).find_each { |draft| draft.photo.purge }
          ReportPhotoDraft.where(organization: @organization).delete_all
          reports.find_each { |report| report.photo.purge if report.photo.attached? }
          ReportObligation.where(report_id: ids).delete_all
          ReportDispatch.where(report_id: ids).delete_all
          ReportReviewProposal.where(report_id: ids).delete_all
          ReportReplyCapability.where(decidim_bih_report_id: ids).delete_all
          ReportMessage.where(report_id: ids).delete_all
          Goodwill::CorrectionIntent.where(report_id: ids).delete_all
          ReportEvent.where(organization: @organization).delete_all
          OperatorAuditEvent.where(organization: @organization).delete_all
          reports.delete_all
          Setting.where(organization: @organization).delete_all
          @admin&.destroy!
          # Core default pages deliberately refuse normal deletion. Only this
          # disposable fixture organization is being removed.
          @organization.static_pages.delete_all
          @organization.destroy!
        end
        clear_enqueued_jobs
      end

      def race(during: nil, &work)
        ready = Queue.new
        start = Queue.new
        finished = Queue.new
        threads = 2.times.map do |index|
          Thread.new do
            ActiveRecord::Base.connection_pool.with_connection do |connection|
              connection.execute("SET lock_timeout = '5s'")
              connection.execute("SET statement_timeout = '10s'")
              ready << connection.select_value("SELECT pg_backend_pid()")
              start.pop
              work.call(index)
            ensure
              finished << index
              connection.execute("RESET lock_timeout")
              connection.execute("RESET statement_timeout")
            end
          end
        end
        Timeout.timeout(15) do
          pids = 2.times.map { ready.pop }
          assert_equal 2, pids.uniq.size, "workers must use independent database sessions"
          2.times { start << true }
          during&.call(finished)
          threads.map(&:value)
        end
      ensure
        threads&.each { |thread| thread.kill if thread.alive? }
        threads&.each(&:join)
      end

      test "two simultaneous confirmations create exactly one dispatch and approval event" do
        version = ReportReviewVersion.digest(@report)
        preview = ReportDecision.new(@report, @admin).preview(action: "send", values: {}, version:)
        results = race do
          ReportDecision.new(Report.find(@report.id), Decidim::User.find(@admin.id)).call(
            action: "send", values: {}, version:, confirmed: true, approved_mail_digest: preview[:digest]
          )
          :approved
        rescue ReportDecision::Invalid
          :stale
        end
        assert_equal [:approved, :stale], results.sort
        assert_equal 1, @report.dispatches.count
        assert_equal 1, @report.events.where(event_type: "case_decision_applied").count
        assert_nil @report.reload.forwarded_at
      end

      test "competing delivery workers send once while a real concurrent reply stays pending" do
        @report.update!(review_state: "validated", reviewed_at: Time.current)
        dispatch = ReportDispatching.queue!(report: @report, actor: @admin, digest: ReportCaseWorkflow.digest(@report))
        transport_started = Queue.new
        release_transport = Queue.new
        sends = Queue.new
        transport = Object.new
        transport.define_singleton_method(:deliver_now) do
          sends << true
          transport_started << true
          release_transport.pop
        end
        during = lambda do |finished|
          transport_started.pop
          assert_equal "sending", dispatch.reload.state
          ReportCaseWorkflow.new(@report.reload, nil).reply(body: "Arrived during delivery")
          finished.pop # The other worker can finish while transport is held.
          release_transport << true
        end
        ReportDispatchMailer.stub(:delivery, transport) do
          race(during:) { ReportDispatching.deliver!(ReportDispatch.find(dispatch.id)) }
        end
        assert_equal 1, sends.size
        assert_equal "accepted", dispatch.reload.state
        assert_equal "pending", @report.reload.review_state
        assert_equal "proslijedjeno", @report.status
        assert @report.review_pending_since
      end

      test "two concurrent photo confirmations return the same report" do
        upload = Rack::Test::UploadedFile.new(Rails.root.join("test/fixtures/files/chat_photo.jpg"), "image/jpeg")
        draft = ReportPhotoDraft.store!(organization: @organization, owner: SecureRandom.hex(32), upload:)
        before = Report.where(organization: @organization).count
        ids = race do
          ReportPhotoDraft.find(draft.id).consume! do |photo|
            ReportIntake.new.call(organization: @organization, description: "One photo submission", photo:)
          end.id
        end
        assert_equal 1, ids.uniq.size
        assert_equal before + 1, (Report.uncached { Report.where(organization: @organization).count })
        assert Report.find(ids.first).photo.attached?
      end
    end
  end
end
