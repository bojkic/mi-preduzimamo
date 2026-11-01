# frozen_string_literal: true

require "test_helper"
require "support/synthetic_messaging_configuration"
require "webmock/minitest"

module Decidim
  module Bih
    class InstrumentationTest < ActiveSupport::TestCase
      include SyntheticMessagingConfiguration
      include ActionMailer::TestHelper

      GEMINI_BASE = "https://gen.example.com"
      GEMINI_MODEL = "gemini-flash-lite-latest"
      GEMINI_ENDPOINT = "#{GEMINI_BASE}/v1beta/models/#{GEMINI_MODEL}:generateContent".freeze
      ODOO_BASE = "https://odoo.test"
      ODOO_RPC = "#{ODOO_BASE}/jsonrpc".freeze
      INFOBIP_BASE = "https://test.api.infobip.com"

      setup do
        install_synthetic_intake
        WebMock.disable_net_connect!(allow_localhost: true)
        @organization = create_organization
      end

      teardown do
        restore_synthetic_intake
        WebMock.reset!
        WebMock.allow_net_connect!
      end

      test "Gemini client emits metadata-only request instrumentation" do
        stub_request(:post, GEMINI_ENDPOINT)
          .to_return(
            status: 200,
            body: gemini_envelope("category" => "putevi", "severity" => "normalan", "summary" => "Rupa na putu"),
            headers: { "Content-Type" => "application/json" }
          )

        events = capture_events("decidim_bih.gemini.generate_content") do
          Decidim::Bih::Ai::GeminiClient.new(
            api_key: "secret-key",
            base_url: GEMINI_BASE,
            model: GEMINI_MODEL
          ).generate_content(
            contents: [{ role: "user", parts: [{ text: "Ne radi rasvjeta kod skole" }] }],
            response_schema: { type: "object", properties: { summary: { type: "string" } } }
          )
        end

        payload = assert_single_payload(events)
        assert_equal "gemini", payload[:provider]
        assert_equal "generate_content", payload[:operation]
        assert_equal GEMINI_MODEL, payload[:model]
        assert_equal 200, payload[:http_status]
        assert_equal true, payload[:success]
        assert_metadata_only payload
      end

      test "Infobip client emits failure instrumentation without recipient data" do
        stub_request(:post, "#{INFOBIP_BASE}/sms/2/text/advanced")
          .to_return(status: 401, body: { requestError: { to: "38765111222", api_key: "secret-key" } }.to_json)

        events = capture_events("decidim_bih.infobip.request") do
          assert_raises Decidim::Bih::Infobip::Error do
            Decidim::Bih::Infobip::Client.new(base_url: INFOBIP_BASE, api_key: "secret-key")
                                         .send_sms(to: "+387 65 111 222", text: "Kod 123456", from: "LFTest")
          end
        end

        payload = assert_single_payload(events)
        assert_equal "infobip", payload[:provider]
        assert_equal "sms", payload[:channel]
        assert_equal "/sms/2/text/advanced", payload[:path]
        assert_equal 401, payload[:http_status]
        assert_equal false, payload[:success]
        assert_equal "Decidim::Bih::Infobip::Error", payload[:error_class]
        assert_metadata_only payload
      end

      test "Odoo client emits authenticate and read instrumentation" do
        stub_request(:post, ODOO_RPC)
          .with(body: hash_including("params" => hash_including("method" => "authenticate")))
          .to_return(status: 200, body: { result: 7 }.to_json)
        stub_request(:post, ODOO_RPC)
          .with(body: hash_including("params" => hash_including("method" => "execute_kw")))
          .to_return(status: 200, body: { result: [{ "price_total" => 12.5, "order_id" => [10, "S0010"] }] }.to_json)

        events = capture_events(/decidim_bih\.odoo\.rpc/) do
          Decidim::Bih::Odoo::Client.new(
            base_url: ODOO_BASE,
            db: "authored_community",
            login: "api@example.test",
            api_key: "secret-key"
          ).read("sale.order.line", [], %w(price_total order_id), limit: 1)
        end

        assert_equal 2, events.size
        authenticate = events[0].last
        execute_kw = events[1].last
        assert_equal "authenticate", authenticate[:method]
        assert_equal true, authenticate[:success]
        assert_equal "execute_kw", execute_kw[:method]
        assert_equal "sale.order.line", execute_kw[:model]
        assert_equal true, execute_kw[:success]
        events.each { |(_, payload)| assert_metadata_only payload }
      end

      test "Sistem48 forwarder emits success instrumentation" do
        report = sistem48_report_hash

        events = capture_events("decidim_bih.sistem48.forward") do
          assert_emails 1 do
            assert Decidim::Bih::Sistem48::Forwarder.new.call(report)
          end
        end

        payload = assert_single_payload(events)
        assert_equal "sistem48", payload[:provider]
        assert_equal "BR-2026-0007", payload[:reference]
        assert_equal :rasvjeta, payload[:category]
        assert_equal true, payload[:success]
        assert_metadata_only payload
      end

      test "report processing emits job-level outcome instrumentation" do
        report = Decidim::Bih::Report.create!(
          organization: @organization,
          description: "Velika rupa na putu kod skole"
        )

        Setting.put(@organization, "reports", "review_first", false)
        events = Decidim::Bih.stub(:sistem48_auto_forward, true) do
          capture_events("decidim_bih.report_processing") do
            Decidim::Bih::ReportProcessing.new(
              forwarder: forwarder_returning(true)
            ).call(report: report, forward: true)
          end
        end

        payload = assert_single_payload(events)
        assert_equal report.id, payload[:report_id]
        assert_equal @organization.id, payload[:organization_id]
        assert_equal report.reference, payload[:reference]
        assert_equal "proslijedjeno", payload[:status]
        assert_equal true, payload[:success]
        assert_metadata_only payload
      end

      test "report processing holds review-first reports with successful metadata-only instrumentation" do
        report = Decidim::Bih::Report.create!(
          organization: @organization,
          description: "Velika rupa na putu kod skole"
        )
        forwarder_calls = []
        forwarder = Object.new.tap do |stub|
          stub.define_singleton_method(:call) { |_| forwarder_calls << true }
        end

        events = capture_events("decidim_bih.report_processing") do
          Decidim::Bih::ReportProcessing.new(
            forwarder:
          ).call(report: report, forward: false)
        end

        payload = assert_single_payload(events)
        assert_equal "primljeno", payload[:status]
        assert_equal true, payload[:success]
        assert_metadata_only payload
        assert_empty forwarder_calls
        report.reload
        assert_equal "primljeno", report.status
        assert_nil report.category
        assert_nil report.department
        assert_nil report.ai_summary
        assert_equal 0, report.events.where(event_type: "classification_updated").count
        assert_equal 1, report.events.where(event_type: "forwarding_held_for_review").count
        serialized = payload.to_json
        assert_not_includes serialized, "Velika rupa na putu kod skole"
        assert_not_includes serialized, "Putevi i infrastruktura"
        assert_not_includes serialized, "Rupa na kolovozu"
      end

      test "a raising instrumented block publishes no raw exception in its payload" do
        raw_message = "Send failed for MSISDN +38765111222 (token=secret-key)"

        raised = nil
        events = capture_events("decidim_bih.test.raises") do
          raised = assert_raises RuntimeError do
            Decidim::Bih::Instrumentation.instrument("test.raises", attempt: 1) do |_payload|
              raise raw_message
            end
          end
        end

        # The re-raised exception must not chain the original (PII-bearing) one as
        # its cause — otherwise Sidekiq/Rails would log the raw message via the
        # cause chain even though the payload is clean.
        assert_nil raised.cause, "the raw exception must not survive as the cause"
        assert_not_includes raised.message, "38765111222"
        assert_not_includes raised.message, "secret-key"

        payload = assert_single_payload(events)
        # The operational shape is preserved...
        assert_equal false, payload[:success]
        assert_equal "RuntimeError", payload[:error_class]
        # ...but no subscriber can serialize the raw (PII-bearing) message: the
        # auto-added :exception tuple and :exception_object both carry only
        # scrubbed text.
        serialized = payload.to_json
        assert_not_includes serialized, "38765111222"
        assert_not_includes serialized, "secret-key"

        if payload[:exception]
          assert_not_includes payload[:exception].join(" "), "38765111222"
          assert_not_includes payload[:exception].join(" "), "secret-key"
        end
        if payload[:exception_object]
          assert_not_includes payload[:exception_object].message, "38765111222"
          assert_not_includes payload[:exception_object].message, "secret-key"
        end
      end

      private

      def capture_events(pattern)
        events = []
        subscriber = ActiveSupport::Notifications.subscribe(pattern) do |name, _start, _finish, _id, payload|
          events << [name, payload.dup]
        end
        yield
        events
      ensure
        ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
      end

      def assert_single_payload(events)
        assert_equal 1, events.size
        events.first.last
      end

      def assert_metadata_only(payload)
        serialized = payload.to_json
        assert_not_includes serialized, "secret-key"
        assert_not_includes serialized, "38765111222"
        assert_not_includes serialized, "+387 65 111 222"
        assert_not_includes serialized, "Kod 123456"
        assert_not_includes serialized, "Ne radi rasvjeta kod skole"
        assert_not_includes serialized, "Vidovdanska"
      end

      def gemini_envelope(inner)
        { candidates: [{ content: { parts: [{ text: inner.to_json }] } }] }.to_json
      end

      def sistem48_report_hash
        {
          reference: "BR-2026-0007",
          category: :rasvjeta,
          department: "Javna rasvjeta",
          severity: :normalan,
          description: "Ne radi ulicna rasvjeta cijelom ulicom.",
          address: "Izmišljena ulica 3, Testna zajednica",
          lat: 0.15,
          lng: 0.25,
          photo_url: nil
        }
      end

      def forwarder_returning(return_value)
        Object.new.tap do |stub|
          stub.define_singleton_method(:call) { |_| return_value }
        end
      end
    end
  end
end
