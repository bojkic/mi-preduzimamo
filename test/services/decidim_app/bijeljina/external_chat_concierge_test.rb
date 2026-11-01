# frozen_string_literal: true

require "test_helper"

module DecidimApp
  module Bijeljina
    class ExternalChatConciergeTest < ActiveSupport::TestCase
      CHANNEL = "whatsapp"

      setup do
        @organization = create_organization
        @original_env = {
          "DECIDIM_CONCIERGE_ORG_HOST" => ENV.fetch("DECIDIM_CONCIERGE_ORG_HOST", nil),
          "INFOBIP_API_KEY" => ENV.fetch("INFOBIP_API_KEY", nil),
          "INFOBIP_BASE_URL" => ENV.fetch("INFOBIP_BASE_URL", nil),
          "INFOBIP_CHAT_CHANNELS" => ENV.fetch("INFOBIP_CHAT_CHANNELS", nil),
          "INFOBIP_WHATSAPP_SENDER" => ENV.fetch("INFOBIP_WHATSAPP_SENDER", nil),
          "INFOBIP_MESSENGER_SENDER" => ENV.fetch("INFOBIP_MESSENGER_SENDER", nil),
          "INFOBIP_INSTAGRAM_SENDER" => ENV.fetch("INFOBIP_INSTAGRAM_SENDER", nil),
          "MI_CHAT_REPORT_INTAKE_CHANNELS" => ENV.fetch("MI_CHAT_REPORT_INTAKE_CHANNELS", nil),
          "MILICA_REPORT_CHAT_SUBMISSION_ENABLED" => ENV.fetch("MILICA_REPORT_CHAT_SUBMISSION_ENABLED", nil)
        }
        ENV.delete("MI_CHAT_REPORT_INTAKE_CHANNELS")
        ENV["DECIDIM_CONCIERGE_ORG_HOST"] = @organization.host
        ENV["INFOBIP_BASE_URL"] = "https://infobip.example.test"
        ENV["INFOBIP_API_KEY"] = "test-api-key"
        ENV["INFOBIP_CHAT_CHANNELS"] = CHANNEL
        ENV["INFOBIP_WHATSAPP_SENDER"] = "configured-whatsapp-sender"
        @cache = ActiveSupport::Cache::MemoryStore.new
        reset_configuration!
      end

      teardown do
        @original_env.each do |key, value|
          value.nil? ? ENV.delete(key) : ENV[key] = value
        end
        reset_configuration!
      end

      test "opaque WhatsApp STOP suppresses only its destination and leaves account topics enabled" do
        user = FactoryBot.create(:user, :confirmed, organization: @organization)
        other = FactoryBot.create(:user, :confirmed, organization: @organization)
        sender = "BA.opaque-38765123456"
        Decidim::Bih::ChannelConnection.create!(organization: @organization, user:, channel: CHANNEL,
                                                business_sender: "configured-whatsapp-sender",
                                                recipient_digest: Decidim::Bih::ChannelConnections.digest(sender),
                                                recipient_ciphertext: Decidim::Bih::ChannelConnections.encrypt(sender),
                                                verified_at: Time.current)
        Decidim::Bih::NotificationPreferences::TOPICS.each do |topic|
          [user, other].each { |account| Decidim::Bih::NotificationPreferences.set!(account, topic:, channel: CHANNEL, enabled: true) }
        end
        invoke_opt_out(sender, "sToP")
        Decidim::Bih::TopicPreferences::TOPICS.each do |topic|
          assert Decidim::Bih::TopicPreferences.enabled?(user.reload, topic:)
          assert Decidim::Bih::TopicPreferences.enabled?(other.reload, topic:)
        end
        suppression = suppression_for(kind: "channel_identity", value: sender)
        assert_equal "provider_opt_out", suppression.reason
        assert_equal user.id, suppression.decidim_user_id
        assert_equal CHANNEL, suppression.channel
        assert_not suppression_for(kind: "channel_identity", value: "different-recipient")
        assert_not suppression_for(kind: "channel_identity", value: sender, channel: "viber")
      end

      test "unlinked opaque WhatsApp STOP gives deterministic account settings guidance" do
        sender = "BA.unlinked-38765123456"
        reply = I18n.t("decidim.bih.channel_connections.opt_out_unmatched", url: "https://#{@organization.host}/biceriseno/moj-nalog/poruke")
        invoke_opt_out(sender, "STOP", expected_text: reply)
      end

      test "WhatsApp ODJAVA resolves a currently verified local phone representation" do
        user = FactoryBot.create(:user, :confirmed, organization: @organization)
        phone = "065123456"
        Decidim::Authorization.create!(user:, name: "sms", unique_id: Decidim::Bih::SmsAuthorization.unique_id_for(phone), granted_at: Time.current)
        assert Decidim::Bih::VerifiedPhone.synchronize!(user:, organization: @organization, phone:)
        Decidim::Bih::NotificationPreferences.set!(user, topic: "community_news", channel: CHANNEL, enabled: true)
        invoke_opt_out("38765123456", "ODJAVA")
        assert Decidim::Bih::TopicPreferences.enabled?(user.reload, topic: "community_news")
        assert_equal "provider_opt_out", suppression_for(kind: "phone", value: "+38765123456").reason
      end

      def suppression_for(kind:, value:, channel: CHANNEL)
        digest = Decidim::Bih::Messaging::SuppressionKey.digest(kind:, value:)
        Decidim::Bih::Messaging::Suppression.blocking_for(organization: @organization, provider: "infobip", channel:, destination_digest: digest)
      end

      test "delayed and missing provider events cannot reopen reply windows" do
        inbound = inbound_message
        concierge = ExternalChatConcierge.new(organization: @organization, message: inbound)
        old = 25.hours.ago
        inbound.stub(:occurred_at, old) do
          assert_in_delta (old + 23.hours).to_f, concierge.send(:reply_deadline, "reply").to_f, 0.01
        end
        inbound.stub(:occurred_at, nil) do
          assert_operator concierge.send(:reply_deadline, "reply"), :<=, Time.current
        end
      end

      test "adapts external identity to sender-less web guidance and queues a channel reply" do
        inbound = inbound_message
        store = ExternalChatSessionStore.new(
          organization: @organization,
          channel: CHANNEL,
          sender: inbound.sender,
          cache: @cache
        )
        seen = nil
        queued = []
        reply = Decidim::Bih::Concierge::Responder::Reply.new(
          text: "Odgovor gradskog servisa",
          report: nil,
          quick_replies: [],
          answer_intent: "service",
          sticker: :milica_map,
          tone: "playful",
          phrase_id: "location.03"
        )

        resolver = lambda do |web_message, channel:, trusted_context:|
          seen = web_message
          assert_equal CHANNEL, channel
          assert_same trusted_context, web_message.trusted_context
          assert trusted_context.allows?("public_reads")
          assert_not trusted_context.allows?("write_report")
          reply
        end
        WebConcierge.stub(:respond, resolver) do
          Decidim::Bih::Infobip::SendChatTextJob.stub(:perform_later, ->(**args) { queued << args }) do
            assert_difference -> { Decidim::Bih::ConciergeUsageAggregate.sum(:requests_count) }, 1 do
              ExternalChatConcierge.call(organization: @organization, message: inbound, session_store: store)
            end
          end
        end

        assert_instance_of Decidim::Bih::Concierge::WebMessage, seen
        assert_not_respond_to seen, :sender
        assert_nil seen.user
        assert_not seen.location_context?
        assert_equal [], seen.conversation_context
        assert_equal 1, queued.size
        assert_equal(
          {
            channel: CHANNEL,
            to: inbound.sender,
            text: "Možeš razgovarati s Milicom ovdje — samo odgovori na ovu poruku.\n\n#{reply.text}",
            organization_id: @organization.id,
            media_id: "milica_map"
          },
          queued.first.except(:expires_at)
        )
        assert_in_delta 23.hours.from_now.to_f, queued.first.fetch(:expires_at).to_f, 2

        aggregate = Decidim::Bih::ConciergeUsageAggregate.order(:id).last
        assert_equal CHANNEL, aggregate.channel
        assert_equal "service", aggregate.answer_intent
        assert_equal 1, store.context.length
        assert_equal inbound.text, store.context.first.fetch("user")
        assert_equal "playful", store.context.first.fetch("tone")
        assert_equal "location.03", store.context.first.fetch("phrase_id")
        assert_not_includes cache_keys.to_json, inbound.sender
      end

      test "verified WhatsApp provider identity reaches report scope without granting private reads" do
        user = create(:user, :confirmed, organization: @organization)
        phone = "38765123456"
        Decidim::Authorization.create!(user:, name: "sms",
                                       unique_id: Decidim::Bih::SmsAuthorization.unique_id_for(phone), granted_at: Time.current)
        message = Decidim::Bih::Infobip::InboundMessage.from_primitives(channel: CHANNEL, sender: phone,
                                                                        recipient: "configured-whatsapp-sender", message_id: SecureRandom.uuid, type: "TEXT",
                                                                        text: "Prijavi problem", occurred_at: Time.current.iso8601(6))
        resolver = lambda do |web_message, channel:, trusted_context:|
          assert_equal CHANNEL, channel
          assert_equal user, web_message.user
          assert_equal user.id, trusted_context.actor_id
          assert trusted_context.allows?("report_guidance")
          assert_not trusted_context.allows?("own_report_reads")
          assert_not trusted_context.allows?("write_report")
          guidance_reply
        end
        WebConcierge.stub(:respond, resolver) do
          Decidim::Bih::Infobip::SendChatTextJob.stub(:perform_later, ->(**) {}) do
            ExternalChatConcierge.call(organization: @organization, message:)
          end
        end
      end

      test "external memory cannot cross anonymous linked and different linked actor scopes" do
        options = { organization: @organization, channel: CHANNEL, sender: "opaque-same-sender", cache: @cache }
        anonymous = ExternalChatSessionStore.new(**options)
        citizen = ExternalChatSessionStore.new(**options, actor_id: 101)
        other = ExternalChatSessionStore.new(**options, actor_id: 202)
        anonymous.remember(user_text: "Anonymous draft", bot_text: "Preview", answer_intent: "report", location_present: false)
        assert_empty citizen.context
        citizen.remember(user_text: "Private draft", bot_text: "Preview", answer_intent: "report", location_present: false)
        assert_equal "Anonymous draft", anonymous.context.sole.fetch("user")
        assert_equal "Private draft", citizen.context.sole.fetch("user")
        assert_empty other.context
      end

      test "intercepts social registration before concierge and forwards Messenger phone request" do
        inbound = messenger_inbound_message
        queued = []
        intake_reply = SocialRegistrationIntake::IntakeReply.new(
          text: "Za registraciju posalji broj.",
          answer_intent: "registration_intake",
          request_phone: true,
          expires_at: 10.minutes.from_now
        )

        SocialRegistrationIntake.stub(:call, intake_reply) do
          WebConcierge.stub(:respond, ->(*) { flunk "general concierge must not run" }) do
            Decidim::Bih::Infobip::SendChatTextJob.stub(:perform_later, ->(**args) { queued << args }) do
              assert_same intake_reply, ExternalChatConcierge.call(
                organization: @organization,
                message: inbound
              )
            end
          end
        end

        assert_equal true, queued.sole.fetch(:request_phone)
        assert_equal "registration_intake", intake_reply.answer_intent
        assert_in_delta 10.minutes.from_now.to_f, queued.sole.fetch(:expires_at).to_f, 2
      end

      test "bounds a social registration durable effect to the intake deadline" do
        inbound = messenger_inbound_message
        intake_reply = SocialRegistrationIntake::IntakeReply.new(
          text: "Za registraciju posalji broj.",
          answer_intent: "registration_intake",
          request_phone: true,
          expires_at: 10.minutes.from_now
        )

        capture = Decidim::Bih::DurableEffects.capture do
          SocialRegistrationIntake.stub(:call, intake_reply) do
            WebConcierge.stub(:respond, ->(*) { flunk "general concierge must not run" }) do
              ExternalChatConcierge.call(organization: @organization, message: inbound)
            end
          end
        end

        effect = capture.effects.sole
        assert_equal "active_job", effect.fetch("type")
        assert_in_delta 10.minutes.from_now.to_f,
                        Decidim::Bih::DurableEffects.deadline_at(effect).to_f,
                        2
      end

      test "preserves only the newest six short-lived turns" do
        inbound = inbound_message
        store = ExternalChatSessionStore.new(
          organization: @organization,
          channel: CHANNEL,
          sender: inbound.sender,
          cache: @cache
        )

        7.times do |index|
          store.remember(
            user_text: "question-#{index}",
            bot_text: "answer-#{index}",
            answer_intent: "service",
            tone: index.even? ? "playful" : "neighborly",
            location_present: false
          )
        end

        assert_equal 6, store.context.length
        assert_equal "question-1", store.context.first.fetch("user")
        assert_equal "question-6", store.context.last.fetch("user")
        assert_equal 7, store.context.last.fetch("tone_history").length
        assert_not_includes cache_keys.to_json, inbound.sender
      end

      test "captures a conversation turn as a durable inbound effect" do
        inbound = inbound_message
        store = ExternalChatSessionStore.new(
          organization: @organization,
          channel: CHANNEL,
          sender: inbound.sender,
          cache: @cache
        )
        capture = Decidim::Bih::DurableEffects.capture do
          store.remember(
            user_text: "question",
            bot_text: "answer",
            answer_intent: "service",
            location_present: false
          )
        end

        assert_empty store.context
        assert_equal ["cache_write"], (capture.effects.map { |effect| effect.fetch("type") })
        Decidim::Bih::DurableEffects.dispatch!(capture.effects.first, cache: @cache)
        assert_equal "question", store.context.first.fetch("user")
      end

      test "captures the reply and conversation turn with a capture-time reply deadline" do
        inbound = inbound_message
        store = ExternalChatSessionStore.new(
          organization: @organization,
          channel: CHANNEL,
          sender: inbound.sender,
          cache: @cache
        )
        reply = Decidim::Bih::Concierge::Responder::Reply.new(
          text: "Odgovor gradskog servisa",
          report: nil,
          quick_replies: [],
          answer_intent: "service"
        )

        capture = WebConcierge.stub(:respond, reply) do
          Decidim::Bih::DurableEffects.capture do
            ExternalChatConcierge.call(organization: @organization, message: inbound, session_store: store)
          end
        end

        assert_equal %w(active_job cache_write), (capture.effects.map { |effect| effect.fetch("type") })
        job_effect = capture.effects.first
        assert_equal "Decidim::Bih::Infobip::SendChatTextJob", job_effect.fetch("job_class")
        assert job_effect.fetch("arguments").is_a?(Array)
        serialized_effect = job_effect.to_json
        assert_not_includes serialized_effect, inbound.sender
        assert_not_includes serialized_effect, reply.text
      end

      test "discarding a captured turn leaves conversation context unchanged" do
        inbound = inbound_message
        store = ExternalChatSessionStore.new(
          organization: @organization,
          channel: CHANNEL,
          sender: inbound.sender,
          cache: @cache
        )
        Decidim::Bih::DurableEffects.capture do
          store.remember(
            user_text: "question",
            bot_text: "answer",
            answer_intent: "service",
            location_present: false
          )
        end

        assert_empty store.context
      end

      test "fails closed when the receipt organization differs from configured concierge organization" do
        other_organization = create_organization
        queued = false

        Decidim::Bih::Infobip::SendChatTextJob.stub(:perform_later, ->(**) { queued = true }) do
          assert_raises(ExternalChatConcierge::ChannelBoundaryError) do
            ExternalChatConcierge.call(organization: other_organization, message: inbound_message)
          end
        end

        assert_not queued
      end

      test "fails closed when the payload recipient differs from the configured sender" do
        queued = false
        inbound = inbound_message(recipient: "another-account")

        Decidim::Bih::Infobip::SendChatTextJob.stub(:perform_later, ->(**) { queued = true }) do
          assert_raises(ExternalChatConcierge::ChannelBoundaryError) do
            ExternalChatConcierge.call(organization: @organization, message: inbound)
          end
        end

        assert_not queued
      end

      test "fails closed when the payload recipient is missing" do
        queued = false
        inbound = inbound_message(recipient: nil)

        Decidim::Bih::Infobip::SendChatTextJob.stub(:perform_later, ->(**) { queued = true }) do
          assert_raises(ExternalChatConcierge::ChannelBoundaryError) do
            ExternalChatConcierge.call(organization: @organization, message: inbound)
          end
        end

        assert_not queued
      end

      # A voice note, sticker, reaction or bare document arrives with no text and
      # nothing to answer. The help menu it used to trigger was a billed message
      # per event on a paid channel (review 2026-09-07, lane 4 H1).
      test "a non-text inbound is recorded but never answered" do
        inbound = blank_inbound_message
        store = ExternalChatSessionStore.new(
          organization: @organization, channel: CHANNEL, sender: inbound.sender, cache: @cache
        )
        queued = []
        reply = Decidim::Bih::Concierge::Responder::Reply.new(
          text: "Mogu da pomognem oko prijava, komsiluka i gradskih servisa.",
          report: nil, quick_replies: [], answer_intent: "fallback", sticker: nil, tone: "core", phrase_id: nil
        )

        WebConcierge.stub(:respond, ->(_message, **) { reply }) do
          Decidim::Bih::Infobip::SendChatTextJob.stub(:perform_later, ->(**args) { queued << args }) do
            assert_difference -> { Decidim::Bih::ConciergeUsageAggregate.sum(:requests_count) }, 1 do
              ExternalChatConcierge.call(organization: @organization, message: inbound, session_store: store)
            end
          end
        end

        assert_empty queued, "a blank inbound must not buy a paid reply"
        assert_equal "blank", Decidim::Bih::ConciergeUsageAggregate.order(:id).last.outcome
      end

      # The brain writes root-relative paths for the web widget. A chat app has
      # no origin to resolve them against, so the citizen was handed links they
      # could not tap (review 2026-09-07, lane 4 H2).
      test "links in a chat reply are absolute on the organization host" do
        inbound = inbound_message
        store = ExternalChatSessionStore.new(
          organization: @organization, channel: CHANNEL, sender: inbound.sender, cache: @cache
        )
        queued = []
        reply = Decidim::Bih::Concierge::Responder::Reply.new(
          text: "Otvori obrazac: /biceriseno/prijave/new i registruj se na /registracija",
          report: nil, quick_replies: [], answer_intent: "report_guidance", sticker: nil, tone: "core", phrase_id: nil
        )

        WebConcierge.stub(:respond, ->(_message, **) { reply }) do
          Decidim::Bih::Infobip::SendChatTextJob.stub(:perform_later, ->(**args) { queued << args }) do
            ExternalChatConcierge.call(organization: @organization, message: inbound, session_store: store)
          end
        end

        text = queued.sole.fetch(:text)

        assert_includes text, "https://#{@organization.host}/biceriseno/prijave/new"
        assert_includes text, "https://#{@organization.host}/registracija"
        assert_no_match(%r{(\A|\s)/biceriseno}, text, "no bare path may survive")
      end

      # WhatsApp shows text only: the chips the web widget draws as buttons
      # were dropped, so an answer whose next step lived in a chip had none
      # on a phone (channels review 2026-09-12, section E, P1).
      test "a WhatsApp reply with chips carries the choices as lines" do
        inbound = inbound_message
        store = ExternalChatSessionStore.new(
          organization: @organization, channel: CHANNEL, sender: inbound.sender, cache: @cache
        )
        queued = []
        reply = Decidim::Bih::Concierge::Responder::Reply.new(
          text: "Pregled prijave: rupa na putu.",
          report: nil,
          quick_replies: [{ label: "Prijavi problem", url: "/biceriseno/prijave/new" },
                          { label: "Potvrdi slanje", send: "Pošalji prijavu ABC123" },
                          { label: "Odustani", send: "odustani" }],
          answer_intent: "report_guidance", sticker: nil, tone: "core", phrase_id: nil
        )

        WebConcierge.stub(:respond, ->(_message, **) { reply }) do
          Decidim::Bih::Infobip::SendChatTextJob.stub(:perform_later, ->(**args) { queued << args }) do
            ExternalChatConcierge.call(organization: @organization, message: inbound, session_store: store)
          end
        end

        assert_equal "Možeš razgovarati s Milicom ovdje — samo odgovori na ovu poruku.\n\nPregled prijave: rupa na putu.\n\n" \
                     "• Prijavi problem: https://#{@organization.host}/biceriseno/prijave/new\n" \
                     "Odgovori: „Pošalji prijavu ABC123” ili „odustani”",
                     queued.sole.fetch(:text)
        assert_equal "Pregled prijave: rupa na putu.", store.context.first.fetch("bot"),
                     "the conversation memory keeps the brain's own text, not the channel rendering"
      end

      test "report intake off still permits anonymous public conversation scope without write authority" do
        inbound = inbound_message
        seen = nil
        capture = lambda do |_message, **options|
          seen = options
          guidance_reply
        end
        WebConcierge.stub(:respond, capture) do
          Decidim::Bih::Infobip::SendChatTextJob.stub(:perform_later, ->(**) {}) do
            assert_no_difference -> { Decidim::Bih::Report.count } do
              ExternalChatConcierge.call(organization: @organization, message: inbound)
            end
          end
        end

        assert_equal CHANNEL, seen.fetch(:channel)
        assert seen.fetch(:trusted_context).allows?("public_reads")
        assert_nil seen.fetch(:trusted_context).actor_id
        assert_not seen.fetch(:trusted_context).allows?("write_report")
      end

      test "a listed channel is handed an anonymous report scope bound to its own sender" do
        ENV["MI_CHAT_REPORT_INTAKE_CHANNELS"] = CHANNEL
        ENV["MILICA_REPORT_CHAT_SUBMISSION_ENABLED"] = "true"
        inbound = inbound_message
        seen = nil
        capture = lambda do |_message, **options|
          seen = options
          guidance_reply
        end
        WebConcierge.stub(:respond, capture) do
          Decidim::Bih::Infobip::SendChatTextJob.stub(:perform_later, ->(**) {}) do
            assert_no_difference -> { Decidim::Bih::Report.count } do
              ExternalChatConcierge.call(organization: @organization, message: inbound)
            end
          end
        end

        context = seen.fetch(:trusted_context)
        assert_instance_of Decidim::Bih::Concierge::Dialogue::Contracts::TrustedContext, context
        assert_equal @organization.id, context.organization_id
        assert_nil context.actor_id
        assert_not context.allows?("write_report")
        assert_equal Milica::ChatReportIntake.conversation_key(
          organization: @organization, channel: CHANNEL, sender: inbound.sender
        ), context.conversation_key
        assert_not_equal context.conversation_key,
                         Milica::ChatReportIntake.conversation_key(
                           organization: @organization, channel: "messenger", sender: inbound.sender
                         )
      end

      test "normalized external channels retain identity boundaries and essential long reply through send job" do
        %w(whatsapp messenger instagram).each do |channel|
          ENV["INFOBIP_CHAT_CHANNELS"] = channel
          ENV["INFOBIP_#{channel.upcase}_SENDER"] = "configured-#{channel}-sender"
          reset_configuration!
          inbound = Decidim::Bih::Infobip::InboundMessage.parse(
            {
              "integrationType" => channel.upcase,
              "contact" => { "userId" => "same-opaque-sender" },
              "to" => "configured-#{channel}-sender",
              "messageId" => SecureRandom.uuid,
              "receivedAt" => Time.current.iso8601(6),
              "message" => { "type" => "TEXT", "text" => "Ja sam na Viberu. Prijavi problem." }
            }, route_channel: channel
          )
          store = ExternalChatSessionStore.new(organization: @organization, channel:, sender: inbound.sender, cache: @cache)
          assert_empty store.context, "same opaque sender must have separate channel history"
          command = "Pošalji prijavu QA1234"
          consent = "Ne šalji bez saglasnosti da tačna lokacija bude javna."
          reply = Decidim::Bih::Concierge::Responder::Reply.new(
            text: ("Објашњење градске услуге. " * 200) + consent,
            quick_replies: [{ label: "Otvori mapu", url: "/biceriseno/mapa?stanica=nas" },
                            { label: "Potvrdi slanje", send: command }], answer_intent: "report_guidance"
          )
          sent = []
          client = Object.new
          client.define_singleton_method(:chat_channel_configured?) { |_channel| true }
          client.define_singleton_method(:send_chat_text) { |**attributes| sent << attributes }
          resolver = lambda do |web_message, **options|
            assert_equal channel, options.fetch(:channel), "citizen prose cannot change ingress channel"
            assert_nil web_message.user
            assert_not options.fetch(:trusted_context).allows?("write_report"), "public context cannot grant a write scope"
            assert_not web_message.location_context?, "text-only ingress must not invent GPS"
            reply
          end
          dispatch = lambda do |**attributes|
            Decidim::Bih::Infobip::SendChatTextJob.new.perform(**attributes)
          end
          WebConcierge.stub(:respond, resolver) do
            Decidim::Bih::Infobip::Client.stub(:new, client) do
              Decidim::Bih::Infobip::SendChatTextJob.stub(:perform_later, dispatch) do
                assert_no_difference -> { Decidim::Bih::Report.count } do
                  ExternalChatConcierge.call(organization: @organization, message: inbound, session_store: store)
                end
              end
            end
          end
          outgoing = sent.sole
          assert_equal channel, outgoing.fetch(:channel)
          assert_equal inbound.sender, outgoing.fetch(:to)
          text = outgoing.fetch(:text)
          assert text.valid_encoding?
          assert_operator text.bytesize, :<=, Decidim::Bih::Infobip::SendChatTextJob::MAX_REPLY_TEXT_BYTES
          assert_operator text.length, :<=, ChatTextRendering::MAX_TEXT.fetch(channel)
          [consent, command, "https://#{@organization.host}/biceriseno/mapa?stanica=nas"].each do |part|
            assert_includes text, part
          end
        end
      end

      private

      def guidance_reply
        Decidim::Bih::Concierge::Responder::Reply.new(
          text: "Prijavi problem na /biceriseno/prijave/new", report: nil,
          quick_replies: [], answer_intent: "report_guidance", tone: "core"
        )
      end

      def invoke_opt_out(sender, text, expected_text: I18n.t("decidim.bih.channel_connections.opted_out"))
        message = Decidim::Bih::Infobip::InboundMessage.from_primitives(
          channel: CHANNEL, sender:, recipient: "configured-whatsapp-sender",
          message_id: SecureRandom.uuid, type: "TEXT", text:, occurred_at: Time.current.iso8601(6)
        )
        queued = []
        WebConcierge.stub(:respond, ->(*) { flunk "opt-out must not enter the chatbot" }) do
          Decidim::Bih::Infobip::SendChatTextJob.stub(:perform_later, ->(**args) { queued << args }) do
            ExternalChatConcierge.call(organization: @organization, message:)
          end
        end
        assert_equal 1, queued.length
        assert_equal sender, queued.first.fetch(:to)
        assert_equal "Možeš razgovarati s Milicom ovdje — samo odgovori na ovu poruku.\n\n#{expected_text}", queued.first.fetch(:text)
      end

      def messenger_inbound_message
        ENV["INFOBIP_CHAT_CHANNELS"] = "whatsapp,messenger"
        ENV["INFOBIP_MESSENGER_SENDER"] = "configured-messenger-sender"
        reset_configuration!
        Decidim::Bih::Infobip::InboundMessage.from_primitives(
          channel: "messenger", sender: "opaque-messenger-sender",
          recipient: "configured-messenger-sender", message_id: SecureRandom.uuid, occurred_at: Time.current.iso8601(6),
          type: "TEXT", text: "Želim da otvorim nalog"
        )
      end

      def inbound_message(recipient: "configured-whatsapp-sender")
        Decidim::Bih::Infobip::InboundMessage.parse(
          {
            "integrationType" => "WHATSAPP",
            "contact" => { "userId" => "opaque-private-sender" },
            "to" => recipient,
            "messageId" => SecureRandom.uuid,
            "receivedAt" => Time.current.iso8601(6),
            "message" => {
              "type" => "LOCATION",
              "text" => "Gdje je maticna sluzba?",
              "location" => { "latitude" => 44.75, "longitude" => 19.21 }
            }
          },
          route_channel: CHANNEL
        )
      end

      # An inbound MO event with a sender and a messageId but nothing to read:
      # what a voice note, a sticker or a reaction looks like to the parser.
      def blank_inbound_message
        Decidim::Bih::Infobip::InboundMessage.parse(
          {
            "integrationType" => "WHATSAPP",
            "contact" => { "userId" => "opaque-private-sender" },
            "to" => "configured-whatsapp-sender",
            "messageId" => SecureRandom.uuid,
            "receivedAt" => Time.current.iso8601(6),
            "message" => { "type" => "AUDIO" }
          },
          route_channel: CHANNEL
        )
      end

      def cache_keys
        @cache.instance_variable_get(:@data).keys
      end

      def reset_configuration!
        Decidim::Bih::Config.reset!
        Concierge.reset!
        WebConcierge.reset!
      end
    end
  end
end
