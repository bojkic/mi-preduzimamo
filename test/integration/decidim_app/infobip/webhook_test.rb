# frozen_string_literal: true

require "test_helper"
require "stringio"
require_relative "../../../support/native_milica_provider"

module DecidimApp
  module Infobip
    class WebhookTest < ActionDispatch::IntegrationTest
      include ActiveJob::TestHelper
      include NativeMilicaProvider

      CHANNELS = %w(whatsapp messenger instagram).freeze
      ENV_KEYS = %w(
        DECIDIM_CONCIERGE_ORG_HOST
        INFOBIP_API_KEY
        INFOBIP_BASE_URL
        INFOBIP_CHAT_CHANNELS
        INFOBIP_CHAT_WEBHOOK_SECRET
        INFOBIP_WHATSAPP_SENDER
        INFOBIP_MESSENGER_SENDER
        INFOBIP_INSTAGRAM_SENDER
        WHATSAPP_WEBHOOK_SECRET
        MESSENGER_WEBHOOK_SECRET
        INSTAGRAM_WEBHOOK_SECRET
      ).freeze

      setup do
        clear_enqueued_jobs
        clear_performed_jobs
        @organization = create_organization
        host! @organization.host
        @original_env = ENV_KEYS.index_with { |key| ENV.fetch(key, nil) }
        ENV["DECIDIM_CONCIERGE_ORG_HOST"] = @organization.host
        ENV["INFOBIP_BASE_URL"] = "https://infobip.example.test"
        ENV["INFOBIP_API_KEY"] = "test-api-key"
        ENV["INFOBIP_CHAT_CHANNELS"] = CHANNELS.join(",")
        CHANNELS.each do |channel|
          ENV["INFOBIP_#{channel.upcase}_SENDER"] = sender_for(channel)
          ENV["#{channel.upcase}_WEBHOOK_SECRET"] = secret_for(channel)
        end
        reset_configuration!
        Rails.cache.clear
        install_native_provider

        @queue_adapter = ActiveJob::Base.queue_adapter
        @previous_perform_enqueued_jobs = @queue_adapter.perform_enqueued_jobs
        @previous_filter = @queue_adapter.filter
        @queue_adapter.perform_enqueued_jobs = true
        @queue_adapter.filter = [DecidimApp::Infobip::ProcessInboundDeliveryJob]
      end

      teardown do
        uninstall_native_provider
        clear_enqueued_jobs
        clear_performed_jobs
        @original_env.each do |key, value|
          value.nil? ? ENV.delete(key) : ENV[key] = value
        end
        reset_configuration!
        @queue_adapter.perform_enqueued_jobs = @previous_perform_enqueued_jobs
        @queue_adapter.filter = @previous_filter
      end

      CHANNELS.each do |channel|
        test "#{channel} accepts a matching authenticated message as guidance-only chat" do
          replies = []
          @native_provider.queue_public("read_procedure", { key: "maticar" })

          Decidim::Bih::Infobip::SendChatTextJob.stub(:perform_later, ->(**args) { replies << args }) do
            assert_difference -> { Decidim::Bih::Viber::InboundDelivery.count }, 1 do
              assert_no_difference -> { Decidim::Bih::Report.count } do
                assert_difference -> { Decidim::Bih::ConciergeUsageAggregate.sum(:requests_count) }, 1 do
                  post_webhook(channel, payload_for(channel))
                end
              end
            end
          end

          assert_response :ok
          delivery = Decidim::Bih::Viber::InboundDelivery.order(:id).last
          assert_equal channel, delivery.channel
          assert_equal "processed", delivery.state
          assert_nil delivery.encrypted_payload
          assert_nil delivery.sender_digest

          aggregate = Decidim::Bih::ConciergeUsageAggregate.order(:id).last
          assert_equal channel, aggregate.channel
          assert_equal @organization, aggregate.organization
          assert_equal "success", aggregate.outcome

          assert_equal 1, replies.length
          reply = decrypted_reply(replies.first)
          assert_equal channel, reply.fetch("channel")
          assert_equal citizen_for(channel), reply.fetch("to")
          assert reply.fetch("text").present?
          assert_not reply.has_key?("sender")
          assert_not_includes replies.first.to_json, citizen_for(channel)
          assert_not_includes replies.first.to_json, reply.fetch("text")
        end
      end

      test "authenticated missing or delayed provider timestamps cannot open a reply session" do
        CHANNELS.each do |channel|
          [nil, 25.hours.ago.iso8601(6)].each do |occurred_at|
            payload = payload_for(channel)
            payload[:results].first[:receivedAt] = occurred_at
            replies = []
            Decidim::Bih::Infobip::SendChatTextJob.stub(:perform_later, ->(**args) { replies << args }) do
              assert_difference -> { Decidim::Bih::Viber::InboundDelivery.count }, 1 do
                post_webhook(channel, payload)
              end
            end
            assert_response :ok
            delivery = Decidim::Bih::Viber::InboundDelivery.order(:id).last
            assert_equal "processed", delivery.state
            assert_empty replies, "#{channel} must retain the original customer-service deadline"
          end
        end
      end

      test "a report-like message returns form guidance without persisting a report" do
        @native_provider.queue_public("read_platform_guidance", { subject: "reports" }) do |_envelope|
          "Prijavu popuni ovdje: https://#{@organization.host}/biceriseno/prijave/new"
        end
        replies = []
        payload = payload_for(
          "whatsapp",
          text: "hocu da prijavim problem na ovoj lokaciji",
          location: { latitude: 44.7569, longitude: 19.2143 }
        )

        Decidim::Bih::Infobip::SendChatTextJob.stub(:perform_later, ->(**args) { replies << args }) do
          assert_no_difference -> { Decidim::Bih::Report.count } do
            post_webhook("whatsapp", payload)
          end
        end

        assert_response :ok
        assert_equal 1, replies.length
        assert_includes decrypted_reply(replies.first).fetch("text"), "/prijave/new"
        aggregate = Decidim::Bih::ConciergeUsageAggregate.order(:id).last
        assert_equal "whatsapp", aggregate.channel
        assert_equal "service", aggregate.answer_intent
      end

      test "rapid same-sender batch preserves processing and conversation order" do
        first_text = "prvo pitanje o gradskoj usluzi"
        second_text = "a gdje se to nalazi"
        payload = {
          results: [
            payload_for("whatsapp", text: first_text)[:results].first.merge(messageId: "ordered-batch-1"),
            payload_for("whatsapp", text: second_text)[:results].first.merge(messageId: "ordered-batch-2")
          ]
        }
        perform_enqueued_jobs = @queue_adapter.perform_enqueued_jobs
        begin
          @queue_adapter.perform_enqueued_jobs = false
          assert_difference -> { Decidim::Bih::Viber::InboundDelivery.count }, 2 do
            post_webhook("whatsapp", payload)
          end
          assert_response :ok
        ensure
          @queue_adapter.perform_enqueued_jobs = perform_enqueued_jobs
        end

        deliveries = Decidim::Bih::Viber::InboundDelivery
                     .where(organization: @organization, channel: "whatsapp")
                     .order(:received_at, :id)
                     .last(2)
        earlier, later = deliveries
        clear_enqueued_jobs

        assert_no_difference -> { Decidim::Bih::ConciergeUsageAggregate.sum(:requests_count) } do
          assert_enqueued_with(job: DecidimApp::Infobip::ProcessInboundDeliveryJob, args: [later.id]) do
            DecidimApp::Infobip::ProcessInboundDeliveryJob.perform_now(later.id)
          end
        end
        assert_equal "pending", later.reload.state
        assert_equal 0, later.attempts
        clear_enqueued_jobs

        seen_messages = []
        reply = Decidim::Bih::Concierge::Responder::Reply.new(
          text: "Odgovor",
          report: nil,
          quick_replies: [],
          answer_intent: "service"
        )
        resolver = lambda do |web_message, channel:, trusted_context:|
          assert_instance_of Decidim::Bih::Concierge::Dialogue::Contracts::TrustedContext, trusted_context
          assert_equal "whatsapp", channel
          seen_messages << web_message
          reply
        end

        conversation_cache = ActiveSupport::Cache::MemoryStore.new
        Rails.stub(:cache, conversation_cache) do
          DecidimApp::Bijeljina::WebConcierge.stub(:respond, resolver) do
            Decidim::Bih::Infobip::SendChatTextJob.stub(:perform_later, ->(**) {}) do
              assert_no_difference -> { Decidim::Bih::Report.count } do
                assert_difference -> { Decidim::Bih::ConciergeUsageAggregate.sum(:requests_count) }, 2 do
                  DecidimApp::Infobip::ProcessInboundDeliveryJob.perform_now(earlier.id)
                  DecidimApp::Infobip::ProcessInboundDeliveryJob.perform_now(later.id)
                end
              end
            end
          end
        end

        assert_equal %w(processed processed), (deliveries.map { |delivery| delivery.reload.state })
        assert_equal 2, seen_messages.length
        assert_equal [], seen_messages.first.conversation_context
        assert_equal first_text, seen_messages.second.conversation_context.last.fetch("user")
      end

      test "route and payload channel mismatch is acknowledged without accepting a receipt" do
        assert_no_difference -> { Decidim::Bih::Viber::InboundDelivery.count } do
          post_webhook("whatsapp", payload_for("whatsapp", declared_channel: "messenger"))
        end

        assert_response :ok
      end

      test "recipient from another configured account is rejected per item" do
        assert_no_difference -> { Decidim::Bih::Viber::InboundDelivery.count } do
          post_webhook("instagram", payload_for("instagram", recipient: "other-instagram-account"))
        end

        assert_response :ok
      end

      test "missing payload recipient is rejected because the configured account cannot be proven" do
        assert_no_difference -> { Decidim::Bih::Viber::InboundDelivery.count } do
          post_webhook("messenger", payload_for("messenger", recipient: nil))
        end

        assert_response :ok
      end

      test "a disabled channel is acknowledged without accepting a receipt" do
        ENV["INFOBIP_CHAT_CHANNELS"] = "messenger,instagram"
        reset_configuration!

        assert_no_difference -> { Decidim::Bih::Viber::InboundDelivery.count } do
          post_webhook("whatsapp", payload_for("whatsapp"))
        end

        assert_response :ok
      end

      test "an enabled channel without its configured sender is rejected" do
        ENV.delete("INFOBIP_MESSENGER_SENDER")
        reset_configuration!

        assert_no_difference -> { Decidim::Bih::Viber::InboundDelivery.count } do
          post_webhook("messenger", payload_for("messenger"))
        end

        assert_response :ok
      end

      test "an enabled channel without provider credentials is rejected" do
        ENV.delete("INFOBIP_API_KEY")
        reset_configuration!

        assert_no_difference -> { Decidim::Bih::Viber::InboundDelivery.count } do
          post_webhook("instagram", payload_for("instagram"))
        end

        assert_response :ok
      end

      test "configured secret rejects missing wrong and query-string credentials" do
        payload = payload_for("whatsapp")

        post webhook_path("whatsapp"), params: payload, as: :json
        assert_response :unauthorized

        post webhook_path("whatsapp"),
             params: payload,
             headers: { "X-Webhook-Secret" => "wrong" },
             as: :json
        assert_response :unauthorized

        post "#{webhook_path("whatsapp")}?secret=#{secret_for("whatsapp")}", params: payload, as: :json
        assert_response :unauthorized
      end

      test "a weak configured webhook secret is rejected even when the header matches" do
        ENV["WHATSAPP_WEBHOOK_SECRET"] = "too-short"

        assert_no_difference -> { Decidim::Bih::Viber::InboundDelivery.count } do
          post_webhook("whatsapp", payload_for("whatsapp"))
        end

        assert_response :unauthorized
      end

      test "a weak channel secret does not shadow a strong shared fallback" do
        ENV["WHATSAPP_WEBHOOK_SECRET"] = "too-short"
        ENV["INFOBIP_CHAT_WEBHOOK_SECRET"] = "strong-shared-chat-secret"

        assert_difference -> { Decidim::Bih::Viber::InboundDelivery.count }, 1 do
          post webhook_path("whatsapp"),
               params: payload_for("whatsapp"),
               headers: { "X-Webhook-Secret" => "strong-shared-chat-secret" },
               as: :json
        end

        assert_response :ok
      end

      test "shared secret is used only as a header fallback" do
        ENV.delete("MESSENGER_WEBHOOK_SECRET")
        ENV["INFOBIP_CHAT_WEBHOOK_SECRET"] = "shared-chat-secret"

        assert_difference -> { Decidim::Bih::Viber::InboundDelivery.count }, 1 do
          post webhook_path("messenger"),
               params: payload_for("messenger"),
               headers: { "X-Webhook-Secret" => "shared-chat-secret" },
               as: :json
        end

        assert_response :ok
      end

      test "active channel with unknown configured organization host fails closed and asks for retry" do
        ENV["DECIDIM_CONCIERGE_ORG_HOST"] = "missing-org-host.example.test"
        reset_configuration!

        assert_no_difference -> { Decidim::Bih::Viber::InboundDelivery.count } do
          post_webhook("instagram", payload_for("instagram"))
        end

        assert_response :service_unavailable
      end

      test "active channel with an unset organization host and multiple organizations asks for retry" do
        create_organization
        ENV.delete("DECIDIM_CONCIERGE_ORG_HOST")
        reset_configuration!

        assert_no_difference -> { Decidim::Bih::Viber::InboundDelivery.count } do
          post_webhook("whatsapp", payload_for("whatsapp"))
        end

        assert_response :service_unavailable
      end

      test "a disabled channel is acknowledged before organization resolution" do
        ENV["DECIDIM_CONCIERGE_ORG_HOST"] = "missing-org-host.example.test"
        ENV["INFOBIP_CHAT_CHANNELS"] = ""
        reset_configuration!

        assert_no_difference -> { Decidim::Bih::Viber::InboundDelivery.count } do
          post_webhook("instagram", payload_for("instagram"))
        end

        assert_response :ok
      end

      test "a receipt persistence failure returns service unavailable for provider retry" do
        failure = ActiveRecord::ConnectionNotEstablished.new("private database detail")

        logs = capture_logs do
          Decidim::Bih::Viber::InboundDelivery.stub(:accept!, ->(**) { raise failure }) do
            post_webhook("whatsapp", payload_for("whatsapp"))
          end
        end

        assert_response :service_unavailable
        assert_includes logs, "ActiveRecord::ConnectionNotEstablished"
        assert_not_includes logs, "private database detail"
        assert_not_includes logs, citizen_for("whatsapp")
      end

      test "malformed JSON is acknowledged without accepting a receipt" do
        assert_no_difference -> { Decidim::Bih::Viber::InboundDelivery.count } do
          post webhook_path("whatsapp"),
               params: "not-json",
               headers: webhook_headers("whatsapp").merge("Content-Type" => "application/json")
        end

        assert_response :ok
      end

      test "oversized webhook body is rejected before parsing or persistence" do
        padding = "x" * (DecidimApp::BoundedWebhookBody::MAX_WEBHOOK_BODY_BYTES + 1)

        assert_no_difference -> { Decidim::Bih::Viber::InboundDelivery.count } do
          post webhook_path("whatsapp"),
               params: %({"padding":"#{padding}"}),
               headers: webhook_headers("whatsapp").merge("Content-Type" => "application/json")
        end

        assert_response :payload_too_large
      end

      # Rails logs the parsed request body at :info before the action runs, so
      # the sender id, the message id and the citizen's text land in
      # production.log unless filter_parameters covers those keys. The
      # controllers' own redaction cannot reach that line.
      test "the request log carries neither the sender, the message id nor the text" do
        payload = payload_for("whatsapp")
        result = payload[:results].first

        logs = capture_logs { post_webhook("whatsapp", payload) }

        assert_includes logs, "Processing by DecidimApp::Infobip::WebhookController",
                        "the request line is what this test reads"
        assert_not_includes logs, citizen_for("whatsapp")
        assert_not_includes logs, result[:messageId]
        assert_not_includes logs, result[:message][:text]
      end

      private

      def decrypted_reply(arguments)
        encrypted_payload = arguments[:encrypted_payload] || arguments["encrypted_payload"]
        Decidim::Bih::Infobip::SendChatTextJob.send(:decrypt_envelope, encrypted_payload)
      end

      def post_webhook(channel, payload)
        post webhook_path(channel), params: payload, headers: webhook_headers(channel), as: :json
      end

      def webhook_path(channel)
        "/biceriseno/#{channel}/webhook"
      end

      def webhook_headers(channel)
        { "X-Webhook-Secret" => secret_for(channel) }
      end

      def payload_for(channel, declared_channel: channel, recipient: sender_for(channel),
                      text: "Gdje mogu dobiti izvod iz maticne knjige rodjenih?", location: nil)
        message = { type: location ? "LOCATION" : "TEXT", text: }
        message[:location] = location if location
        {
          results: [{
            integrationType: declared_channel.upcase,
            contact: { userId: citizen_for(channel) },
            to: recipient,
            messageId: "#{channel}-#{SecureRandom.uuid}",
            receivedAt: Time.current.iso8601(6),
            message:
          }]
        }
      end

      def citizen_for(channel)
        "opaque-#{channel}-citizen"
      end

      def sender_for(channel)
        "configured-#{channel}-sender"
      end

      def secret_for(channel)
        "configured-#{channel}-secret"
      end

      def reset_configuration!
        Decidim::Bih::Config.reset!
        DecidimApp::Bijeljina::Concierge.reset!
        DecidimApp::Bijeljina::WebConcierge.reset!
      end

      # BOTH loggers: Rails' request line ("Processing by ... Parameters: {...}")
      # is written through ActionController::Base.logger, a separate reference,
      # so swapping only Rails.logger left every no-PII assertion in this file
      # blind to the one place the citizen's number actually appeared.
      def capture_logs
        io = StringIO.new
        logger = ActiveSupport::Logger.new(io)
        original_rails = Rails.logger
        original_controller = ActionController::Base.logger
        Rails.logger = logger
        ActionController::Base.logger = logger
        yield
        io.string
      ensure
        Rails.logger = original_rails
        ActionController::Base.logger = original_controller
      end
    end
  end
end
