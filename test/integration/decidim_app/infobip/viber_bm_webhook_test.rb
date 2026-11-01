# frozen_string_literal: true

require "test_helper"

module DecidimApp
  module Infobip
    # Viber Business Messages is the live MIlica transport. Unlike the other
    # Infobip chat channels it is MSISDN-addressed and routes to the FULL
    # concierge, while report requests currently remain guidance-only official
    # form handoffs. The carrier-supplied phone is retained for this channel
    # without any Viber Bot involvement.
    class ViberBmWebhookTest < ActionDispatch::IntegrationTest
      include ActiveJob::TestHelper

      CHANNEL = "viber_bm"
      SENDER = "configured-viber-bm-sender"
      SECRET = "configured-viber-bm-secret"
      CITIZEN_MSISDN = "38765123456"

      ENV_KEYS = %w(
        DECIDIM_CONCIERGE_ORG_HOST INFOBIP_API_KEY INFOBIP_BASE_URL
        INFOBIP_CHAT_CHANNELS INFOBIP_VIBER_BM_SENDER VIBER_BM_WEBHOOK_SECRET
        DECIDIM_BIH_VIBER_BOT_ENABLED
        MI_CHAT_REPORT_INTAKE_CHANNELS MILICA_REPORT_CHAT_SUBMISSION_ENABLED
        MILICA_DIALOGUE_ENABLED MILICA_DIALOGUE_AUDIENCE MILICA_CONVERSATION_ARCHITECTURE MILICA_CONVERSATIONAL_WRITES_ENABLED
      ).freeze
      REPORT_INTAKE_KEYS = %w(
        MI_CHAT_REPORT_INTAKE_CHANNELS MILICA_REPORT_CHAT_SUBMISSION_ENABLED
        MILICA_DIALOGUE_ENABLED MILICA_DIALOGUE_AUDIENCE MILICA_CONVERSATION_ARCHITECTURE MILICA_CONVERSATIONAL_WRITES_ENABLED
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
        ENV["INFOBIP_CHAT_CHANNELS"] = CHANNEL
        ENV["INFOBIP_VIBER_BM_SENDER"] = SENDER
        ENV["VIBER_BM_WEBHOOK_SECRET"] = SECRET
        # The Bot stays off throughout: none of this needs it.
        ENV.delete("DECIDIM_BIH_VIBER_BOT_ENABLED")
        # Report intake from chat is off unless a test opts in.
        REPORT_INTAKE_KEYS.each { |key| ENV.delete(key) }
        reset_configuration!
        Rails.cache.clear

        @queue_adapter = ActiveJob::Base.queue_adapter
        @previous_perform_enqueued_jobs = @queue_adapter.perform_enqueued_jobs
        @previous_filter = @queue_adapter.filter
        @queue_adapter.perform_enqueued_jobs = true
        @queue_adapter.filter = [DecidimApp::Infobip::ProcessInboundDeliveryJob]
      end

      teardown do
        clear_enqueued_jobs
        clear_performed_jobs
        @original_env.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
        reset_configuration!
        @queue_adapter.perform_enqueued_jobs = @previous_perform_enqueued_jobs
        @queue_adapter.filter = @previous_filter
      end

      test "an authenticated Business Messages inbound is accepted and answered" do
        replies = []

        Decidim::Bih::Infobip::SendChatTextJob.stub(:perform_later, ->(**args) { replies << args }) do
          assert_difference -> { Decidim::Bih::Viber::InboundDelivery.count }, 1 do
            post_webhook(payload)
          end
        end

        assert_response :ok
        assert_equal 1, replies.size
        # SendChatTextJob seals its arguments before enqueue, so the recipient
        # and channel are only readable through the envelope.
        envelope = decrypted_reply(replies.first)
        assert_equal CHANNEL, envelope.fetch("channel")
        assert_equal CITIZEN_MSISDN, envelope.fetch("to")
        assert envelope.fetch("text").present?
      end

      test "Business Messages ODJAVA suppresses the verified destination before the chatbot" do
        user = FactoryBot.create(:user, :confirmed, organization: @organization)
        Decidim::Authorization.create!(user:, name: "sms", unique_id: Decidim::Bih::SmsAuthorization.unique_id_for("+#{CITIZEN_MSISDN}"), granted_at: Time.current)
        assert Decidim::Bih::VerifiedPhone.synchronize!(user:, organization: @organization, phone: "+#{CITIZEN_MSISDN}")
        Decidim::Bih::NotificationPreferences.set!(user, topic: "community_news", channel: "viber", enabled: true)
        replies = []
        DecidimApp::Bijeljina::WebConcierge.stub(:dialogue_turn, ->(**) { flunk "opt-out must not enter the chatbot" }) do
          Decidim::Bih::Infobip::SendChatTextJob.stub(:perform_later, ->(**args) { replies << args }) do
            post_webhook(payload(text: "ODJAVA"))
          end
        end
        assert_response :ok
        assert Decidim::Bih::TopicPreferences.enabled?(user.reload, topic: "community_news")
        digest = Decidim::Bih::Messaging::SuppressionKey.digest(kind: "phone", value: CITIZEN_MSISDN)
        suppression = Decidim::Bih::Messaging::Suppression.blocking_for(
          organization: @organization, provider: "infobip", channel: "viber", destination_digest: digest
        )
        assert_equal "provider_opt_out", suppression.reason
        assert_equal user.id, suppression.decidim_user_id
        assert_equal 1, replies.length
        assert_equal I18n.t("decidim.bih.channel_connections.opted_out"), decrypted_reply(replies.first).fetch("text")
      end

      test "unmatched Business Messages STOP gives account settings guidance without claiming opt-out" do
        replies = []
        DecidimApp::Bijeljina::WebConcierge.stub(:dialogue_turn, ->(**) { flunk "STOP must not enter the chatbot" }) do
          Decidim::Bih::Infobip::SendChatTextJob.stub(:perform_later, ->(**args) { replies << args }) do
            post_webhook(payload(text: "STOP"))
          end
        end
        assert_response :ok
        assert_equal 1, replies.length
        text = decrypted_reply(replies.first).fetch("text")
        assert_includes text, "/biceriseno/moj-nalog/poruke"
        assert_not_equal I18n.t("decidim.bih.channel_connections.opted_out"), text
      end

      test "missing Business Messages recipient scope produces guidance and never changes preferences" do
        message = Struct.new(:channel, :sender, :text).new(CHANNEL, CITIZEN_MSISDN, "STOP")
        Decidim::Bih::NotificationPreferences.stub(:set!, ->(*) { flunk "unproven business scope must not change preferences" }) do
          reply = DecidimApp::Bijeljina::ChannelNotificationOptOut.reply(organization: @organization, message:)
          assert_includes reply, "/biceriseno/moj-nalog/poruke"
        end
      end

      test "the receipt is recorded on the Business Messages channel" do
        Decidim::Bih::Infobip::SendChatTextJob.stub(:perform_later, ->(**_args) {}) do
          post_webhook(payload)
        end

        assert_equal CHANNEL, Decidim::Bih::Viber::InboundDelivery.last.channel
      end

      test "a problem report request returns official form guidance without a report" do
        replies = []

        Decidim::Bih::Infobip::SendChatTextJob.stub(:perform_later, ->(**args) { replies << args }) do
          assert_difference -> { Decidim::Bih::Viber::InboundDelivery.count }, 1 do
            assert_no_difference -> { Decidim::Bih::Report.count } do
              assert_no_difference -> { Decidim::Bih::Viber::Linkage.count } do
                post_webhook(location_payload)
              end
            end
          end
        end

        assert_response :ok
        assert_equal 1, replies.size
        envelope = decrypted_reply(replies.first)
        assert_equal CHANNEL, envelope.fetch("channel")
        assert_equal CITIZEN_MSISDN, envelope.fetch("to")
        assert_equal SENDER, envelope.fetch("sender")
        # Business Messages shows plain text with no page origin, so the form
        # link is absolute and the "report" chip follows as a line
        # (channels review 2026-09-12, section E, P1).
        form_path = Decidim::Bih::Engine.routes.url_helpers.new_report_path
        form_url = "https://#{@organization.host}#{form_path}"
        expected_text = I18n.t(
          "decidim.bih.concierge.report_guidance.answer",
          locale: @organization.default_locale,
          url: form_url
        )
        chip_label = I18n.t("decidim.bih.concierge.widget.quick.report", locale: @organization.default_locale)
        assert_equal "#{DecidimApp::Bijeljina::ChatTextRendering::CONVERSATION_START}\n\n#{expected_text}\n\n• #{chip_label}: #{form_url}", envelope.fetch("text")
        assert_no_match(%r{(\A|\s)/biceriseno}, envelope.fetch("text"), "no bare path may reach Viber")

        receipt = Decidim::Bih::Viber::InboundDelivery.order(:id).last
        assert_equal CHANNEL, receipt.channel
        assert_equal "processed", receipt.state
        assert_nil receipt.encrypted_payload
        assert_nil receipt.sender_digest
      end

      test "the guidance-only external chat concierge refuses Business Messages" do
        # Defence in depth: if viber_bm were ever mis-routed to the WhatsApp-style
        # adapter it would bypass the full adapter's MSISDN handling. Report
        # requests remain guidance-only, but this channel boundary stays explicit.
        message = Decidim::Bih::Infobip::InboundMessage.parse(
          location_payload.deep_stringify_keys, route_channel: CHANNEL
        )

        assert_raises(DecidimApp::Bijeljina::ExternalChatConcierge::ChannelBoundaryError) do
          DecidimApp::Bijeljina::ExternalChatConcierge.call(organization: @organization, message:)
        end
      end

      test "usage is recorded against the Business Messages channel" do
        Decidim::Bih::Infobip::SendChatTextJob.stub(:perform_later, ->(**_args) {}) do
          post_webhook(payload)
        end

        assert Decidim::Bih::ConciergeUsageAggregate.exists?(channel: CHANNEL)
      end

      test "a wrong webhook secret is rejected" do
        assert_no_difference -> { Decidim::Bih::Viber::InboundDelivery.count } do
          post webhook_path, params: payload, headers: { "X-Webhook-Secret" => "wrong" }, as: :json
        end

        assert_response :unauthorized
      end

      test "a payload addressed to another Viber sender is rejected" do
        assert_no_difference -> { Decidim::Bih::Viber::InboundDelivery.count } do
          post_webhook(payload(recipient: "someone-elses-sender"))
        end

        assert_response :ok
      end

      test "the channel stays inert until it is listed in INFOBIP_CHAT_CHANNELS" do
        ENV["INFOBIP_CHAT_CHANNELS"] = ""
        reset_configuration!

        assert_no_difference -> { Decidim::Bih::Viber::InboundDelivery.count } do
          post_webhook(payload)
        end

        assert_response :ok
      end

      test "Business Messages report intake is off until the owner lists the channel" do
        assert_not DecidimApp::Bijeljina::Milica::ChatReportIntake.enabled?(CHANNEL)

        # Listing the channel alone is not enough: the master switch governs it.
        ENV["MI_CHAT_REPORT_INTAKE_CHANNELS"] = CHANNEL
        assert_not DecidimApp::Bijeljina::Milica::ChatReportIntake.enabled?(CHANNEL)

        Decidim::Bih::Infobip::SendChatTextJob.stub(:perform_later, ->(**_args) {}) do
          DecidimApp::Bijeljina::WebConcierge.stub(:dialogue_turn, ->(**) { flunk "the dialogue must not run" }) do
            assert_no_difference -> { Decidim::Bih::Report.count } do
              post_webhook(location_payload)
            end
          end
        end

        assert_response :ok
      end

      test "a listed Business Messages channel previews instead of filing, and files nothing without confirmation" do
        enable_report_intake!
        replies = []
        outcome = report_ready_outcome
        preview_turn = lambda do |**|
          [Decidim::Bih::Concierge::Responder::Reply.new(text: "razumijem", report: nil, answer_intent: "report_guidance"), outcome]
        end

        Decidim::Bih::Infobip::SendChatTextJob.stub(:perform_later, ->(**args) { replies << args }) do
          DecidimApp::Bijeljina::WebConcierge.stub(:dialogue_turn, preview_turn) do
            assert_no_difference -> { Decidim::Bih::Report.count } do
              post_webhook(location_payload)
              # A second ordinary message, and a confirmation-shaped one with a
              # code that belongs to no draft, still file nothing (hazard F03).
              post_webhook(payload(text: "da, posalji"))
              post_webhook(payload(text: "Pošalji prijavu #{"0" * 12}"))
            end
          end
        end

        assert_response :ok
        assert_equal 3, replies.size
        preview = decrypted_reply(replies.first).fetch("text")
        assert_includes preview, "Potvrdi prijavu DA"
        assert_no_match(/Pošalji prijavu [a-f0-9]{12}/, preview)
        assert_includes preview, I18n.t("bijeljina.milica_report.location_notice", locale: "sr")
        assert_includes preview, I18n.t("bijeljina.milica_report.anonymous_notice", locale: "sr")
        assert_not_includes preview, I18n.t("bijeljina.milica_report.confirm_button", locale: "sr")
        assert_includes decrypted_reply(replies.last).fetch("text"), I18n.t("bijeljina.milica_report.expired", locale: "sr")
      end

      test "enabled location preview grants submission only for the exact current confirmation and replays its receipt" do
        enable_report_intake!
        replies = []
        submissions = []
        submitter = Object.new
        submitter.define_singleton_method(:call) do |**arguments|
          submissions << arguments
          Decidim::Bih::Concierge::ConfirmedReportSubmission::Receipt.new(reference: "TEST-REPORT-001", replayed: false)
        end
        turn = ->(**) { [Decidim::Bih::Concierge::Responder::Reply.new(text: "razumijem", report: nil, answer_intent: "report_guidance"), report_ready_outcome] }
        service = Decidim::Bih::Concierge::ConfirmedReportSubmission

        service.stub(:new, -> { submitter }) do
          Decidim::Bih::Infobip::SendChatTextJob.stub(:perform_later, ->(**args) { replies << args }) do
            DecidimApp::Bijeljina::WebConcierge.stub(:dialogue_turn, turn) { post_webhook(location_payload) }
            command = decrypted_reply(replies.last).fetch("text")[/Potvrdi prijavu DA/]
            assert command, "an enabled raw location must reach the protected preview"
            assert_empty submissions
            DecidimApp::Bijeljina::WebConcierge.stub(:dialogue_turn, ->(**) { flunk "exact confirmation must bypass model" }) do
              2.times { post_webhook(payload(text: command)) }
            end
          end
        end

        assert_response :ok
        assert_equal 1, submissions.size
        submitted = submissions.first
        assert submitted.fetch(:context).allows?("write_report")
        assert_equal @organization.id, submitted.fetch(:context).organization_id
        assert_nil submitted.fetch(:author)
        assert_equal service::DISCLOSURE_VERSION, submitted.fetch(:draft).fetch("disclosure_version")
        assert_includes decrypted_reply(replies[-2]).fetch("text"), "TEST-REPORT-001"
        assert_includes decrypted_reply(replies[-1]).fetch("text"), "TEST-REPORT-001"
      end

      test "enabled report intake preserves photo guidance without fetching or entering the model" do
        enable_report_intake!
        body = payload
        body[:results].first[:message] = { type: "IMAGE", url: "https://images.example.test/report.jpg", text: "Fotografija problema" }
        replies = []
        Decidim::Bih::Infobip::SendChatTextJob.stub(:perform_later, ->(**args) { replies << args }) do
          DecidimApp::Bijeljina::WebConcierge.stub(:dialogue_turn, ->(**) { flunk "photo restriction must precede model" }) do
            assert_no_difference -> { Decidim::Bih::Report.count } do
              post_webhook(body)
            end
          end
        end
        assert_response :ok
        assert_equal 1, replies.size
        assert_includes decrypted_reply(replies.first).fetch("text"), "/prijave/new"
      end

      private

      def enable_report_intake!
        ENV["MI_CHAT_REPORT_INTAKE_CHANNELS"] = CHANNEL
        ENV["MILICA_REPORT_CHAT_SUBMISSION_ENABLED"] = "true"
        ENV["MILICA_DIALOGUE_ENABLED"] = "true"
        ENV["MILICA_DIALOGUE_AUDIENCE"] = "public"
        ENV["MILICA_CONVERSATION_ARCHITECTURE"] = "model_led"
        ENV["MILICA_CONVERSATIONAL_WRITES_ENABLED"] = "false"
        reset_configuration!
      end

      def report_ready_outcome
        Data.define(:state, :resolution, :fact_ids).new(
          state: { "version" => 0, "active_task" => "report_problem", "pending_slot" => nil,
                   "report_handoff_offered" => true, "locale" => "sr",
                   "entities" => { "description" => "Velika divlja deponija pored puta kod skole",
                                   "address" => "Ulica Svetog Save 12" } },
          resolution: "handoff", fact_ids: []
        )
      end

      def webhook_path
        "/biceriseno/viber-bm/webhook"
      end

      def post_webhook(body)
        post webhook_path, params: body, headers: { "X-Webhook-Secret" => SECRET }, as: :json
      end

      # A shared location pin is the report signal, matching the Bot-era fixture.
      def location_payload(recipient: SENDER)
        {
          results: [{
            integrationType: "VIBER",
            from: CITIZEN_MSISDN,
            to: recipient,
            messageId: "viber-bm-#{SecureRandom.uuid}",
            message: {
              type: "LOCATION",
              text: "Velika divlja deponija pored puta kod skole",
              location: { latitude: 44.7569, longitude: 19.2143 }
            }
          }]
        }
      end

      def payload(recipient: SENDER, text: "Kada je odvoz smeca u mom naselju?")
        {
          results: [{
            integrationType: "VIBER",
            from: CITIZEN_MSISDN,
            to: recipient,
            messageId: "viber-bm-#{SecureRandom.uuid}",
            message: { type: "TEXT", text: }
          }]
        }
      end

      def decrypted_reply(arguments)
        encrypted_payload = arguments[:encrypted_payload] || arguments["encrypted_payload"]
        Decidim::Bih::Infobip::SendChatTextJob.send(:decrypt_envelope, encrypted_payload)
      end

      def reset_configuration!
        Decidim::Bih::Config.reset!
        DecidimApp::Bijeljina::Concierge.reset!
        DecidimApp::Bijeljina::WebConcierge.reset!
      end
    end
  end
end
