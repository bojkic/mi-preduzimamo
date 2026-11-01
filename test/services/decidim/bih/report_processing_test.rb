# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    class ReportProcessingTest < ActiveSupport::TestCase
      setup do
        @organization = create_organization
        @original_auto_forward = Decidim::Bih.sistem48_auto_forward
      end

      teardown do
        Decidim::Bih.sistem48_auto_forward = @original_auto_forward
      end

      class ForwardingBoom < StandardError
        attr_reader :code

        def initialize(message, code:)
          @code = code
          super(message)
        end
      end

      def forwarder_capturing(return_value:, sink:, last_error: nil)
        Object.new.tap do |stub|
          stub.define_singleton_method(:last_error) { last_error }
          stub.define_singleton_method(:call) do |hash|
            sink << hash
            return_value
          end
        end
      end

      test "default host processing leaves classification unset and holds a persisted report for operator review" do
        assert_equal false, Decidim::Bih.sistem48_auto_forward
        report = Decidim::Bih::Report.create!(organization: @organization, description: "Rupa na lokalnom putu")
        captured = []

        Decidim::Bih::ReportProcessing.new(
          forwarder: forwarder_capturing(return_value: true, sink: captured)
        ).call(report: report)

        report.reload
        assert_nil report.category
        assert_equal "primljeno", report.status
        assert_nil report.forwarded_at
        assert_nil report.forwarding_failed_at
        assert_empty captured
        assert_not_includes report.events.pluck(:event_type), "classification_updated"
        assert_not_includes report.events.pluck(:event_type), "forwarding_sent"
        held = report.events.where(event_type: "forwarding_held_for_review").sole
        assert_equal "background", held.source
        assert_equal "system", held.actor_role
        assert_equal({ "status" => "primljeno" }, held.metadata)
      end

      test "explicitly configured unattended host forwards an unclassified report a persisted report" do
        # Compatibility behavior for hosts that explicitly enable unattended forwarding.
        Decidim::Bih.sistem48_auto_forward = true
        Setting.put(@organization, "reports", "review_first", false)
        report = Decidim::Bih::Report.create!(
          organization: @organization,
          description: "Velika rupa na putu kod skole"
        )
        captured = []

        Decidim::Bih::ReportProcessing.new(
          forwarder: forwarder_capturing(return_value: true, sink: captured)
        ).call(report: report, locale: "bs", forward: true)

        report.reload
        assert_nil report.category
        assert_nil report.department
        assert_nil report.severity
        assert_nil report.ai_summary
        assert_equal "proslijedjeno", report.status
        assert_not_nil report.forwarded_at
        assert_nil report.forwarding_failed_at
        assert_equal 0, report.forwarding_failure_count

        assert_equal 1, captured.size
        assert_equal report.reference, captured.first[:reference]

        event_types = report.events.pluck(:event_type)
        assert_not_includes event_types, "classification_updated"
        assert_includes event_types, "forwarding_sent"
      end

      test "records sanitized failure metadata and raises when forwarding fails" do
        # Compatibility behavior for hosts that explicitly enable unattended forwarding.
        Decidim::Bih.sistem48_auto_forward = true
        Setting.put(@organization, "reports", "review_first", false)
        report = Decidim::Bih::Report.create!(
          organization: @organization,
          description: "Neki problem",
          reporter_email: "gradjanin@example.org",
          reporter_phone: "+387 65 123 456",
          address: "Vidovdanska 3"
        )
        captured = []
        error = ForwardingBoom.new(
          'SMTP failed for gradjanin@example.org +387 65 123 456 address: "Vidovdanska 3" description: "Neki problem"',
          code: "smtp_421"
        )

        assert_raises Decidim::Bih::ReportProcessing::ForwardingFailed do
          Decidim::Bih::ReportProcessing.new(
            forwarder: forwarder_capturing(return_value: false, sink: captured, last_error: error)
          ).call(report: report, forward: true)
        end

        report.reload
        assert_nil report.category
        assert_equal "primljeno", report.status
        assert_nil report.forwarded_at
        assert_not_nil report.forwarding_failed_at
        assert_equal 1, report.forwarding_failure_count
        assert_includes report.forwarding_error_class, "ForwardingBoom"
        assert_equal "smtp_421", report.forwarding_error_code
        assert_includes report.forwarding_error_message, "[email]"
        assert_includes report.forwarding_error_message, "[phone]"
        assert_includes report.forwarding_error_message, "address: [redacted]"
        assert_includes report.forwarding_error_message, "description: [redacted]"
        assert_not_includes report.forwarding_error_message, "gradjanin@example.org"
        assert_not_includes report.forwarding_error_message, "+387 65 123 456"
        assert_not_includes report.forwarding_error_message, "Vidovdanska 3"
        assert_not_includes report.forwarding_error_message, "Neki problem"
        assert_equal 1, captured.size

        failure_event = report.events.where(event_type: "forwarding_failed").last
        assert_not_nil failure_event
        assert_equal "background", failure_event.source
        assert_equal "smtp_421", failure_event.metadata["error_code"]
        assert_includes failure_event.metadata["error_class"], "ForwardingBoom"
        assert_not failure_event.metadata.to_s.include?("gradjanin@example.org")
        assert_not failure_event.metadata.to_s.include?("+387 65 123 456")
        assert_not failure_event.metadata.to_s.include?("Vidovdanska 3")
        assert_not failure_event.metadata.to_s.include?("Neki problem")
      end

      test "clears failure metadata after a later successful explicit forwarding" do
        # Compatibility behavior for hosts that explicitly enable unattended forwarding.
        Decidim::Bih.sistem48_auto_forward = true
        Setting.put(@organization, "reports", "review_first", false)
        report = Decidim::Bih::Report.create!(
          organization: @organization,
          description: "Privremeno neuspjela prijava"
        )
        report.record_forwarding_failure!(ForwardingBoom.new("SMTP timeout", code: "smtp_timeout"))
        captured = []

        Decidim::Bih::ReportProcessing.new(
          forwarder: forwarder_capturing(return_value: true, sink: captured)
        ).call(report: report, forward: true)

        report.reload
        assert_equal "proslijedjeno", report.status
        assert_nil report.forwarding_failed_at
        assert_nil report.forwarding_error_class
        assert_nil report.forwarding_error_message
        assert_nil report.forwarding_error_code
        assert_equal 0, report.forwarding_failure_count
        assert_includes report.events.pluck(:event_type), "forwarding_failure_cleared"
      end

      test "does not re-send to the city when the email already went out but the status write failed" do
        # Compatibility behavior for hosts that explicitly enable unattended forwarding.
        Decidim::Bih.sistem48_auto_forward = true
        Setting.put(@organization, "reports", "review_first", false)
        report = Decidim::Bih::Report.create!(
          organization: @organization,
          description: "Vec poslano, status nije sacuvan",
          status: "primljeno"
        )
        # Simulate a prior attempt that emailed the city (forwarded_at recorded)
        # but crashed before persisting the status transition.
        report.update_column(:forwarded_at, Time.current) # rubocop:disable Rails/SkipsModelValidations
        captured = []

        Decidim::Bih::ReportProcessing.new(
          forwarder: forwarder_capturing(return_value: true, sink: captured)
        ).call(report: report, forward: true)

        report.reload
        assert_equal "proslijedjeno", report.status, "the status must be reconciled"
        assert_empty captured, "must NOT re-send the report to the city on retry"
        assert_includes report.events.pluck(:event_type), "forwarding_reconciled"
      end

      test "a concurrently forwarded report is not re-emailed: gate re-checked under a row lock" do
        # Compatibility behavior for hosts that explicitly enable unattended forwarding.
        Decidim::Bih.sistem48_auto_forward = true
        Setting.put(@organization, "reports", "review_first", false)
        # A concurrent run (Sidekiq's at-least-once delivery) already emailed the
        # city and committed the result: forwarded_at + proslijedjeno are in the
        # DB. THIS run, however, entered forward holding the pre-forward view it
        # read before the concurrent commit. Modeled here by serving the gate the
        # stale state on the unlocked (call-level) reload, while the LOCKED reload
        # reflects committed truth. The fix must re-read + re-check the gate while
        # holding a row lock; doing so it sees the report already forwarded and
        # never invokes the forwarder again. Without the lock it re-sends.
        report = Decidim::Bih::Report.create!(
          organization: @organization,
          description: "Konkurentna obrada iste prijave",
          status: "primljeno"
        )
        # Concurrent winner: committed forwarded state in the DB.
        report.update_column(:forwarded_at, Time.current) # rubocop:disable Rails/SkipsModelValidations
        report.update_column(:status, "proslijedjeno") # rubocop:disable Rails/SkipsModelValidations

        # Our run's in-memory instance, holding the stale pre-forward view until a
        # lock-protected reload reveals the committed truth.
        racing = Decidim::Bih::Report.find(report.id)
        racing.instance_variable_set(:@stale_view, true)
        racing.define_singleton_method(:status) { @stale_view ? "primljeno" : super() }
        racing.define_singleton_method(:forwarded_at) { @stale_view ? nil : super() }
        # The unlocked, call-level reload (forward(report.reload)) keeps the stale
        # view; only a lock-protected reload reveals the committed forwarded state.
        racing.define_singleton_method(:reload) do |options = nil|
          if options && options[:lock]
            @stale_view = false
            super(options)
          else
            self
          end
        end

        captured = []

        Decidim::Bih::ReportProcessing.new(
          forwarder: forwarder_capturing(return_value: true, sink: captured)
        ).call(report: racing, forward: true)

        report.reload
        assert_equal "proslijedjeno", report.status
        assert_empty captured, "must NOT re-send a report a concurrent run already forwarded"
      end

      test "does not overwrite a report that has already moved past primljeno" do
        # Compatibility behavior for hosts that explicitly enable unattended forwarding.
        Decidim::Bih.sistem48_auto_forward = true
        Setting.put(@organization, "reports", "review_first", false)
        report = Decidim::Bih::Report.create!(
          organization: @organization,
          description: "Vec u obradi",
          status: "u_obradi"
        )
        captured = []

        Decidim::Bih::ReportProcessing.new(
          forwarder: forwarder_capturing(return_value: true, sink: captured)
        ).call(report: report, forward: true)

        report.reload
        assert_equal "u_obradi", report.status
        assert_nil report.forwarded_at
        assert_empty captured
      end
    end
  end
end
