# frozen_string_literal: true

require "test_helper"
require "stringio"
require_relative "../../../support/synthetic_event_source_registry"
require_relative "../../../support/synthetic_procedures"
require_relative "../../../support/native_milica_provider"

module DecidimApp
  module Viber
    # End-to-end HTTP coverage for the Infobip Viber inbound webhook. The
    # controller renders nothing (head :ok), so no Decidim layout / Shakapacker
    # shim is needed. Infobip is unconfigured in the test env, so the outbound
    # Viber send is skipped (logged) rather than hitting the network.
    class WebhookTest < ActionDispatch::IntegrationTest
      include ActiveJob::TestHelper
      include NativeMilicaProvider
      include SyntheticEventSourceRegistry
      include SyntheticProcedures

      WEBHOOK_SECRET = "configured-test-secret"
      WRONG_WEBHOOK_SECRET = "wrong-test-secret"

      setup do
        clear_enqueued_jobs
        clear_performed_jobs
        @organization = create_organization
        install_synthetic_procedures(day: Date.current, organization_host: @organization.host)
        host! @organization.host
        @original_env = %w(
          DECIDIM_CONCIERGE_ORG_HOST INFOBIP_API_KEY INFOBIP_BASE_URL
          INFOBIP_VIBER_BOT_SENDER VIBER_WEBHOOK_SECRET
          DECIDIM_BIH_VIBER_BOT_ENABLED
        ).index_with { |key| ENV.fetch(key, nil) }
        ENV["DECIDIM_CONCIERGE_ORG_HOST"] = @organization.host
        ENV["INFOBIP_BASE_URL"] = "https://infobip.example.test"
        ENV["INFOBIP_API_KEY"] = "test-api-key"
        ENV["INFOBIP_VIBER_BOT_SENDER"] = "configured-viber-bot-sender"
        ENV["VIBER_WEBHOOK_SECRET"] = WEBHOOK_SECRET
        # The Bot is switched OFF for this deployment (Business Messages only).
        # These tests cover the dormant transport so it still works if it is
        # ever revived, so they opt it back on explicitly. See the
        # "inert while switched off" test at the bottom for the default.
        ENV["DECIDIM_BIH_VIBER_BOT_ENABLED"] = "true"
        Decidim::Bih::Config.reset!
        # The Bijeljina concierge memoizes a responder bound to an organization;
        # reset it so this test's freshly-created org is the one in use.
        DecidimApp::Bijeljina::Concierge.reset!
        Rails.cache.clear
        install_native_provider
        @queue_adapter = ActiveJob::Base.queue_adapter
        @previous_perform_enqueued_jobs = @queue_adapter.perform_enqueued_jobs
        @previous_filter = @queue_adapter.filter
        @queue_adapter.perform_enqueued_jobs = true
        @queue_adapter.filter = [DecidimApp::Viber::ProcessInboundDeliveryJob]
      end

      teardown do
        restore_synthetic_procedures
        uninstall_native_provider
        clear_enqueued_jobs
        clear_performed_jobs
        @original_env.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
        Decidim::Bih::Config.reset!
        DecidimApp::Bijeljina::Concierge.reset!
        @queue_adapter.perform_enqueued_jobs = @previous_perform_enqueued_jobs
        @queue_adapter.filter = @previous_filter
      end

      test "a configured webhook secret rejects a missing request secret" do
        with_viber_webhook_secret(WEBHOOK_SECRET) do
          assert_no_difference -> { Decidim::Bih::Report.count } do
            post "/biceriseno/viber/webhook", params: problem_payload, as: :json
          end
        end

        assert_response :unauthorized
      end

      test "a configured webhook secret rejects a wrong request secret" do
        with_viber_webhook_secret(WEBHOOK_SECRET) do
          assert_no_difference -> { Decidim::Bih::Report.count } do
            post "/biceriseno/viber/webhook",
                 params: problem_payload,
                 headers: { "X-Webhook-Secret" => WRONG_WEBHOOK_SECRET },
                 as: :json
          end
        end

        assert_response :unauthorized
      end

      test "a query-string secret is ignored" do
        with_viber_webhook_secret(WEBHOOK_SECRET) do
          assert_no_difference -> { Decidim::Bih::Report.count } do
            post "/biceriseno/viber/webhook?secret=#{WEBHOOK_SECRET}", params: problem_payload, as: :json
          end
        end

        assert_response :unauthorized
      end

      test "a weak configured webhook secret is rejected even when the header matches" do
        with_viber_webhook_secret("too-short") do
          assert_no_difference -> { Decidim::Bih::Report.count } do
            post "/biceriseno/viber/webhook",
                 params: problem_payload,
                 headers: { "X-Webhook-Secret" => "too-short" },
                 as: :json
          end
        end

        assert_response :unauthorized
      end

      test "a problem-report inbound returns safe guidance and 200 without creating a report" do
        assert_no_difference -> { Decidim::Bih::Report.count } do
          assert_difference -> { Decidim::Bih::ConciergeUsageAggregate.sum(:requests_count) }, 1 do
            post "/biceriseno/viber/webhook", params: problem_payload, headers: webhook_secret_headers, as: :json
          end
        end

        assert_response :ok
        aggregate = Decidim::Bih::ConciergeUsageAggregate.order(:created_at).last
        assert_equal @organization, aggregate.organization
        assert_equal "viber", aggregate.channel
        assert_equal "success", aggregate.outcome
        assert_equal "report_guidance", aggregate.answer_intent
      end

      test "DECIDIM_CONCIERGE_ORG_HOST selects the organization for webhook guidance" do
        other_organization = create_organization

        with_concierge_org_host(other_organization.host) do
          assert_no_difference -> { Decidim::Bih::Report.count } do
            assert_difference -> { Decidim::Bih::ConciergeUsageAggregate.sum(:requests_count) }, 1 do
              post "/biceriseno/viber/webhook", params: problem_payload, headers: webhook_secret_headers, as: :json
            end
          end
        end

        assert_response :ok
        aggregate = Decidim::Bih::ConciergeUsageAggregate.order(:created_at).last
        assert_equal other_organization, aggregate.organization
        assert_equal "report_guidance", aggregate.answer_intent
      end

      test "an active channel with unknown DECIDIM_CONCIERGE_ORG_HOST asks for retry" do
        create_organization

        with_concierge_org_host("missing-org-host.example.test") do
          assert_no_difference -> { Decidim::Bih::Report.count } do
            post "/biceriseno/viber/webhook", params: problem_payload, headers: webhook_secret_headers, as: :json
          end
        end

        assert_response :service_unavailable
      end

      test "an unset organization host uses the sole organization" do
        sole_organization_scope = Object.new
        organization = @organization
        sole_organization_scope.define_singleton_method(:limit) { |_| [organization] }

        Decidim::Organization.stub(:order, sole_organization_scope) do
          with_concierge_org_host(nil) do
            assert_no_difference -> { Decidim::Bih::Report.count } do
              post "/biceriseno/viber/webhook", params: problem_payload, headers: webhook_secret_headers, as: :json
            end
          end
        end

        assert_response :ok
      end

      test "an active channel with unset organization host and multiple organizations asks for retry" do
        create_organization

        with_concierge_org_host(nil) do
          assert_no_difference -> { Decidim::Bih::Report.count } do
            post "/biceriseno/viber/webhook", params: problem_payload, headers: webhook_secret_headers, as: :json
          end
        end

        assert_response :service_unavailable
      end

      test "a persistence failure before a durable receipt returns service unavailable without private details" do
        failure = ActiveRecord::ConnectionNotEstablished.new("private database detail")

        logs = capture_logs do
          Decidim::Bih::Viber::InboundDelivery.stub(:accept!, ->(**) { raise failure }) do
            post "/biceriseno/viber/webhook", params: problem_payload, headers: webhook_secret_headers, as: :json
          end
        end

        assert_response :service_unavailable
        assert_includes logs, "ReceiptPersistenceError"
        assert_not_includes logs, "private database detail"
        assert_not_includes logs, "38765999000"
      end

      test "an active-channel organization lookup outage asks the provider to retry" do
        failure = ActiveRecord::ConnectionNotEstablished.new("private database detail")

        logs = capture_logs do
          DecidimApp::Bijeljina::Concierge.stub(:organization, -> { raise failure }) do
            post "/biceriseno/viber/webhook", params: problem_payload, headers: webhook_secret_headers, as: :json
          end
        end

        assert_response :service_unavailable
        assert_includes logs, "ActiveRecord::ConnectionNotEstablished"
        assert_not_includes logs, "private database detail"
        assert_not_includes logs, "38765999000"
      end

      test "an unconfigured Viber channel is acknowledged without accepting a receipt" do
        ENV.delete("INFOBIP_VIBER_BOT_SENDER")
        Decidim::Bih::Config.reset!

        assert_no_difference -> { Decidim::Bih::Viber::InboundDelivery.count } do
          post "/biceriseno/viber/webhook", params: problem_payload, headers: webhook_secret_headers, as: :json
        end

        assert_response :ok
      end

      test "a switched-off Viber Bot is inert even with complete credentials" do
        # The launch state for this deployment: Bot credentials are still in the
        # environment, but the product is switched off and must accept nothing.
        ENV.delete("DECIDIM_BIH_VIBER_BOT_ENABLED")
        Decidim::Bih::Config.reset!

        assert_no_difference -> { Decidim::Bih::Viber::InboundDelivery.count } do
          post "/biceriseno/viber/webhook", params: problem_payload, headers: webhook_secret_headers, as: :json
        end

        # Acknowledged, not errored, so the provider does not retry-storm.
        assert_response :ok
      end

      test "an unconfigured Viber channel is acknowledged before organization resolution" do
        ENV.delete("INFOBIP_VIBER_BOT_SENDER")
        ENV["DECIDIM_CONCIERGE_ORG_HOST"] = "missing-org-host.example.test"
        Decidim::Bih::Config.reset!

        assert_no_difference -> { Decidim::Bih::Viber::InboundDelivery.count } do
          post "/biceriseno/viber/webhook", params: problem_payload, headers: webhook_secret_headers, as: :json
        end

        assert_response :ok
      end

      test "a payload for another Viber account is rejected" do
        payload = problem_payload
        payload[:results].first[:to] = "another-viber-account"

        assert_no_difference -> { Decidim::Bih::Viber::InboundDelivery.count } do
          post "/biceriseno/viber/webhook", params: payload, headers: webhook_secret_headers, as: :json
        end

        assert_response :ok
      end

      test "a payload without a Viber recipient is rejected" do
        payload = problem_payload
        payload[:results].first.delete(:to)

        assert_no_difference -> { Decidim::Bih::Viber::InboundDelivery.count } do
          post "/biceriseno/viber/webhook", params: payload, headers: webhook_secret_headers, as: :json
        end

        assert_response :ok
      end

      test "a duplicate webhook delivery (same message id) is processed only once" do
        payload = problem_payload
        payload[:results][0][:messageId] = "MID-DEDUP-1"

        assert_difference -> { Decidim::Bih::Viber::InboundDelivery.count }, 1 do
          assert_no_difference -> { Decidim::Bih::Report.count } do
            assert_difference -> { Decidim::Bih::ConciergeUsageAggregate.sum(:requests_count) }, 1 do
              post "/biceriseno/viber/webhook", params: payload, headers: webhook_secret_headers, as: :json
              post "/biceriseno/viber/webhook", params: payload, headers: webhook_secret_headers, as: :json
            end
          end
        end

        assert_response :ok
        delivery = Decidim::Bih::Viber::InboundDelivery.last
        assert_equal "processed", delivery.state
        assert_nil delivery.encrypted_payload
        assert_nil delivery.sender_digest
      end

      test "deduplication remains durable when the Rails cache is unavailable" do
        payload = problem_payload
        payload[:results][0][:messageId] = "MID-DURABLE"
        failing = Class.new(ActiveSupport::Cache::NullStore) { def write(*, **) = nil }.new

        Rails.stub(:cache, failing) do
          assert_no_difference -> { Decidim::Bih::Report.count } do
            post "/biceriseno/viber/webhook", params: payload, headers: webhook_secret_headers, as: :json
            post "/biceriseno/viber/webhook", params: payload, headers: webhook_secret_headers, as: :json
          end
        end

        assert_response :ok
      end

      test "every result in a provider batch is durably accepted and processed" do
        payload = {
          results: [
            problem_payload[:results].first.merge(messageId: "MID-BATCH-1"),
            problem_payload[:results].first.merge(messageId: "MID-BATCH-2", from: "38765999001")
          ]
        }

        assert_difference -> { Decidim::Bih::Viber::InboundDelivery.count }, 2 do
          assert_no_difference -> { Decidim::Bih::Report.count } do
            post "/biceriseno/viber/webhook", params: payload, headers: webhook_secret_headers, as: :json
          end
        end

        assert_response :ok
        assert_equal ["processed"], Decidim::Bih::Viber::InboundDelivery.order(:id).last(2).map(&:state).uniq
      end

      test "a service question returns 200 without creating a report" do
        @native_provider.queue_public("read_procedure", { key: "maticar" })
        payload = {
          results: [
            {
              from: "38765111000",
              to: "configured-viber-bot-sender",
              messageId: "MID-SERVICE",
              message: { type: "TEXT", text: "Gdje mogu dobiti izvod iz matične knjige rođenih?" }
            }
          ]
        }

        assert_no_difference -> { Decidim::Bih::Report.count } do
          assert_difference -> { Decidim::Bih::ConciergeUsageAggregate.sum(:requests_count) }, 1 do
            post "/biceriseno/viber/webhook", params: payload, headers: webhook_secret_headers, as: :json
          end
        end

        assert_response :ok

        aggregate = Decidim::Bih::ConciergeUsageAggregate.order(:created_at).last
        assert_equal "viber", aggregate.channel
        assert_equal "success", aggregate.outcome
        assert_equal "service", aggregate.answer_intent
      end

      test "an empty Viber inbound is counted as blank without creating a report" do
        payload = {
          results: [
            {
              from: "38765111001",
              to: "configured-viber-bot-sender",
              messageId: "MID-BLANK",
              message: { type: "TEXT", text: "   " }
            }
          ]
        }

        assert_no_difference -> { Decidim::Bih::Report.count } do
          assert_difference -> { Decidim::Bih::ConciergeUsageAggregate.sum(:requests_count) }, 1 do
            post "/biceriseno/viber/webhook", params: payload, headers: webhook_secret_headers, as: :json
          end
        end

        assert_response :ok
        aggregate = Decidim::Bih::ConciergeUsageAggregate.order(:created_at).last
        assert_equal "blank", aggregate.outcome
      end

      test "a configured Infobip client enqueues the Viber reply instead of sending inline" do
        fake_client = Object.new
        fake_client.define_singleton_method(:viber_bot_configured?) { true }
        fake_client.define_singleton_method(:viber_bot_active?) { true }
        fake_client.define_singleton_method(:send_viber_bot) { |**| raise "webhook delivered inline" }
        fake_client.define_singleton_method(:send_viber_bot_image) do |**|
          raise "webhook delivered sticker inline"
        end

        Decidim::Bih::Infobip::Client.stub(:new, -> { fake_client }) do
          assert_enqueued_with(job: Decidim::Bih::Infobip::SendViberTextJob, queue: "integrations") do
            post "/biceriseno/viber/webhook", params: problem_payload, headers: webhook_secret_headers, as: :json
          end
        end

        assert_response :ok
      end

      test "a captured Viber reply keeps its original session deadline" do
        message = Decidim::Bih::Viber::InboundMessage.parse(problem_payload.deep_stringify_keys)

        capture = Decidim::Bih::DurableEffects.capture do
          DecidimApp::Bijeljina::Concierge.process_message(message)
        end
        effect = capture.effects.find do |candidate|
          candidate["type"] == "active_job" &&
            candidate["job_class"] == "Decidim::Bih::Infobip::SendViberTextJob"
        end

        assert effect, "expected the Viber reply to be part of the durable effect envelope"
        assert effect.fetch("arguments").is_a?(Array)
        serialized_effect = effect.to_json
        assert_not_includes serialized_effect, message.sender
        assert_not_includes serialized_effect, capture.result.text
      end

      test "an enqueue exception leaves a durable pending row and logs no payload" do
        logs = capture_logs do
          DecidimApp::Viber::ProcessInboundDeliveryJob.stub(
            :perform_later,
            ->(*) { raise StandardError, "queue unavailable" }
          ) do
            post "/biceriseno/viber/webhook", params: problem_payload, headers: webhook_secret_headers, as: :json
          end
        end

        assert_response :ok
        assert_includes logs, "[Viber webhook enqueue] StandardError"
        assert_not_includes logs, "38765111000"
        assert_equal "pending", Decidim::Bih::Viber::InboundDelivery.last.state
      end

      test "the composed service reply cites the matica service" do
        @native_provider.queue_public("read_procedure", { key: "maticar" }) do |envelope|
          row = envelope.fetch("evidence").first
          "#{row.fetch("text")}\n#{row.fetch("source_url")}"
        end
        message = Decidim::Bih::Viber::InboundMessage.parse(
          "results" => [{ "from" => "x", "message" => { "type" => "TEXT", "text" => "izvod iz matične knjige rođenih" } }]
        )
        reply = DecidimApp::Bijeljina::Concierge.respond(message)

        assert_nil reply.report
        assert_includes reply.text, "community.example.invalid/procedures/maticar"
        assert_equal 2, @native_provider.calls.size
      end

      test "the native Viber reader exposes public data scope without operational health" do
        @native_provider.queue_public("read_platform_guidance", { subject: "platform" }) do |envelope|
          scope = envelope.fetch("evidence").first.dig("facts", "source_fact", "policy", "data_scope")
          assert_equal false, scope.fetch("coverage_complete")
          "Javni izvori: #{scope.fetch("reviewed_domains").join(", ")}. Integracije: #{scope.fetch("integrations").keys.join(", ")}."
        end
        message = Decidim::Bih::Viber::InboundMessage.parse(
          "results" => [{ "from" => "x", "message" => { "type" => "TEXT", "text" => "koje podatke ima MI bot" } }]
        )
        reply = DecidimApp::Bijeljina::Concierge.respond(message)

        assert_nil reply.report
        assert_equal "service", reply.answer_intent
        assert_includes reply.text, "waste_schedule"
        assert_includes reply.text, "Infobip"
        assert_equal 2, @native_provider.calls.size
      end

      test "the composed Viber responder answers deeper service-directory topics" do
        @native_provider.queue_public("read_environment", { topic: "air_quality" })
        message = Decidim::Bih::Viber::InboundMessage.parse(
          "results" => [{ "from" => "x", "message" => { "type" => "TEXT", "text" => "kvalitet vazduha u Izmišljenom gradu" } }]
        )
        checked_at = Time.current
        source_keys = %w(air_quality_realtime air_quality)
        notices = [
          city_service_notice(
            source_key: "air_quality_realtime",
            provider: "Autorski senzor",
            title: "IZMIŠLJENI TEST PM2.5 21 µg/m³",
            metadata: { "value" => 21, "unit" => "µg/m³", "pollutant" => "PM2.5", "observed_at" => checked_at.iso8601 }
          )
        ]
        checks = [
          DecidimApp::Bijeljina::CityServiceNoticeCollector::SourceCheckResult.new(
            source_key: source_keys.fetch(0),
            status: :ok,
            notices:,
            checked_at:
          ),
          DecidimApp::Bijeljina::CityServiceNoticeCollector::SourceCheckResult.new(
            source_key: source_keys.fetch(1),
            status: :empty,
            notices: [],
            checked_at:
          )
        ]
        reply = nil

        store = DecidimApp::Bijeljina::CityServiceSourceCheckStore.new
        checks.each { |check| store.record(check:) }
        DecidimApp::Bijeljina::CityServiceNoticeCollector.stub(:check, ->(**) { flunk "Viber answer must use prepared observations" }) do
          reply = DecidimApp::Bijeljina::Concierge.respond(message)
        end

        assert_equal source_keys, checks.map(&:source_key)
        assert_nil reply.report
        assert_equal "service", reply.answer_intent
        assert_includes reply.text, "PM2.5: 21 µg/m³"
        assert_includes reply.text, "Vrijeme mjerenja:"
        assert_not_includes reply.text, "gradbijeljina.org"
      end

      test "a malformed body never 500s" do
        post "/biceriseno/viber/webhook",
             params: "not-json",
             headers: { "Content-Type" => "application/json" }.merge(webhook_secret_headers)

        assert_response :ok
      end

      test "invalid JSON is acknowledged as poison without accepting a receipt" do
        assert_no_difference -> { Decidim::Bih::Viber::InboundDelivery.count } do
          post "/biceriseno/viber/webhook",
               params: "{not-json",
               headers: webhook_secret_headers.merge("CONTENT_TYPE" => "application/json")
        end

        assert_response :ok
      end

      test "an oversized body is rejected before parsing or persistence" do
        padding = "x" * (DecidimApp::BoundedWebhookBody::MAX_WEBHOOK_BODY_BYTES + 1)

        assert_no_difference -> { Decidim::Bih::Viber::InboundDelivery.count } do
          post "/biceriseno/viber/webhook",
               params: %({"padding":"#{padding}"}),
               headers: { "Content-Type" => "application/json" }.merge(webhook_secret_headers)
        end

        assert_response :payload_too_large
      end

      private

      def problem_payload
        {
          results: [
            {
              from: "38765999000",
              to: "configured-viber-bot-sender",
              messageId: "MID-#{SecureRandom.uuid}",
              message: {
                type: "LOCATION",
                text: "Velika divlja deponija pored puta kod škole",
                location: { latitude: 44.7569, longitude: 19.2143 }
              }
            }
          ]
        }
      end

      def city_service_notice(source_key:, provider:, title:, body: "", metadata: {})
        DecidimApp::Bijeljina::CityServiceNoticeCollector::Notice.new(
          source_key:,
          source_label: source_key,
          provider:,
          title:,
          body:,
          url: DecidimApp::Bijeljina::CityServiceSources.fetch(source_key).fetch(:source_url),
          fingerprint: "abc123",
          fetched_at: Time.current,
          metadata:
        )
      end

      def with_viber_webhook_secret(secret)
        original = ENV.fetch("VIBER_WEBHOOK_SECRET", nil)
        ENV["VIBER_WEBHOOK_SECRET"] = secret
        yield
      ensure
        original.nil? ? ENV.delete("VIBER_WEBHOOK_SECRET") : ENV["VIBER_WEBHOOK_SECRET"] = original
      end

      def with_concierge_org_host(host)
        original = ENV.fetch("DECIDIM_CONCIERGE_ORG_HOST", nil)
        host.nil? ? ENV.delete("DECIDIM_CONCIERGE_ORG_HOST") : ENV["DECIDIM_CONCIERGE_ORG_HOST"] = host
        DecidimApp::Bijeljina::Concierge.reset!
        yield
      ensure
        original.nil? ? ENV.delete("DECIDIM_CONCIERGE_ORG_HOST") : ENV["DECIDIM_CONCIERGE_ORG_HOST"] = original
        DecidimApp::Bijeljina::Concierge.reset!
      end

      def webhook_secret_headers
        secret = ENV.fetch("VIBER_WEBHOOK_SECRET", nil)
        secret.present? ? { "X-Webhook-Secret" => secret } : {}
      end

      def capture_logs
        io = StringIO.new
        original_logger = Rails.logger
        Rails.logger = ActiveSupport::Logger.new(io)
        yield
        io.string
      ensure
        Rails.logger = original_logger
      end
    end
  end
end
