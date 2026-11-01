# frozen_string_literal: true

require "delegate"
require_relative "milica/viber_protected_prelude"

module DecidimApp
  module Bijeljina
    # Bijeljina Viber adapter. Ordinary turns use the shared model-led dialogue;
    # server-only preludes retain identity linking, safety and photo guidance.
    # Existing delivery jobs and report confirmation boundaries own effects.
    #
    # TWO VIBER TRANSPORTS, ONE BRAIN:
    #   "viber_bm" — Viber Business Messages, the live channel. MSISDN-addressed,
    #                so the sender is a carrier-proven phone and attribution
    #                needs no OTP. Replies go out through SendChatTextJob.
    #   "viber"    — the Viber Bot, a separately-billed product that is switched
    #                off (Decidim::Bih::Config.viber_bot_enabled?). Kept working
    #                so it can be re-enabled, never used at launch.
    # Everything else — intents, reports, goodwill, personality — is shared.
    #
    #   DecidimApp::Bijeljina::Concierge.handle_inbound(infobip_webhook_hash)
    #
    # ORGANIZATION RESOLUTION: ENV["DECIDIM_CONCIERGE_ORG_HOST"] selects the org
    # by host. When the key is absent we fall back only if exactly one organization
    # exists; zero/multiple organizations and an explicitly unresolved host fail
    # closed instead of routing citizen chat under the wrong tenant. The
    # identity adapter is memoized; call .reset! after the org changes.
    module Concierge
      # Viber Business Messages: the live two-way transport.
      BUSINESS_MESSAGES_CHANNEL = "viber_bm"
      # The dormant Viber Bot transport.
      BOT_CHANNEL = "viber"

      # Adds bounded conversation context without changing the provider value
      # object or exposing a new citizen identifier to the shared responder.
      class ContextualMessage < SimpleDelegator
        attr_reader :conversation_context, :user, :trusted_context, :channel

        def initialize(message, conversation_context:, user: nil, trusted_context: nil, channel: nil)
          super(message)
          @conversation_context = Array(conversation_context)
          @user = user
          @trusted_context = trusted_context
          @channel = channel.to_s
        end

        # This point is available only to public reads. ReportConversation
        # continues to inspect its separate dialogue_location preview input.
        # A bare native pin remains a report signal, never conversation consent.
        def public_read_location
          return unless channel == BUSINESS_MESSAGES_CHANNEL && __getobj__.respond_to?(:location?) && __getobj__.location?
          return unless Decidim::Bih::Concierge::WebMessage.location_requested?(text.to_s)

          latitude = Float(__getobj__.latitude)
          longitude = Float(__getobj__.longitude)
          return unless latitude.finite? && latitude.between?(-90, 90) && longitude.finite? && longitude.between?(-180, 180)

          { latitude:, longitude:, accuracy: nil, purpose: "current_location", consent: true,
            provenance: "native_explicit_public_read" }
        rescue ArgumentError, TypeError
          nil
        end

        def location_context?
          !public_read_location.nil?
        end

        def location_retention_consent?
          !public_read_location.nil?
        end
      end

      class << self
        # Routes an already-parsed message object through the brain.
        def respond(message)
          civic_reply(message, channel: message_channel(message))
        end

        # Parses an Infobip Viber inbound webhook Hash, composes a reply, and
        # delivers it back over Viber (skipping the send when Infobip is
        # unconfigured, so dev/test work offline). Returns the Reply.
        #
        # Viber-first verification (Round 10 item 6): a message starting with
        # "verify_<token>" is intercepted BEFORE the normal intent chain so it
        # never reaches the report catch-all. The token is consumed atomically;
        # on success the Linkage is created/updated and the reply is sent.
        def handle_inbound(payload_hash)
          Decidim::Bih::Viber::InboundMessage.parse_all(payload_hash).map { |message| process_message(message) }.last
        end

        # Processes one message that has already been durably accepted by the
        # host webhook. Provider deduplication and retries belong to
        # Viber::InboundDelivery, so this method contains only the civic work.
        def process_message(message)
          channel = message_channel(message)
          if channel == BUSINESS_MESSAGES_CHANNEL
            opt_out_text = ChannelNotificationOptOut.reply(organization:, message:)
            if opt_out_text
              reply = Decidim::Bih::Concierge::Responder::Reply.new(text: opt_out_text, quick_replies: [])
              deliver(message, reply, channel:)
              return reply
            end
          end
          store = conversation_store(message, channel:)
          contextual_message = ContextualMessage.new(message, conversation_context: store.context)
          reply = magic_link_verify_reply(message, channel:)
          reply ||= civic_reply(contextual_message, channel:)
          reply = MilicaPersonality.call(reply:, message: contextual_message, channel:)
          record_usage(message, reply, channel:)
          remember_business_contact(message) if channel == BUSINESS_MESSAGES_CHANNEL
          deliver(message, reply, channel:, first_turn: store.context.empty?)
          remember_turn(store, message, reply)
          reply
        end

        # The identity adapter for a channel. On Business Messages the sender is
        # the citizen's own carrier-proven phone, so it wraps the OTP linker in
        # the adapter that reads the number directly; the explicit "link a
        # different number" flow still delegates through. The Bot uses the OTP
        # linker as-is, because its sender is an opaque id.
        def identity_for(channel)
          @identities ||= {}
          @identities[channel.to_s] ||= begin
            linking = Decidim::Bih::Viber::AccountLinking.new(
              organization: organization,
              gateway: Decidim::Bih::Viber::QueuedPhoneMessageGateway.new
            )

            if channel.to_s == BUSINESS_MESSAGES_CHANNEL
              Decidim::Bih::Viber::BusinessMessageIdentity.new(
                organization: organization,
                account_linking: linking
              )
            else
              linking
            end
          end
        end

        # Drops memoized identities after organization changes.
        def reset!
          @identities = nil
        end

        # The organization the concierge serves.
        def organization
          # A missing host is safe only on a true single-tenant deployment.
          host = ENV.fetch("DECIDIM_CONCIERGE_ORG_HOST", nil).presence
          if host.blank?
            organizations = Decidim::Organization.order(:id).limit(2).to_a
            return organizations.first if organizations.one?

            raise ActiveRecord::RecordNotFound,
                  "DECIDIM_CONCIERGE_ORG_HOST is required unless exactly one organization exists"
          end

          Decidim::Organization.find_by(host: host) ||
            raise(ActiveRecord::RecordNotFound, "No Decidim organization for DECIDIM_CONCIERGE_ORG_HOST")
        end

        private

        # Every enabled native channel uses the model-led public brain. Identity,
        # emergency and attachment handling remain deterministic server controls.
        def civic_reply(message, channel:) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity -- protected prelude and independent report authority
          raise ArgumentError, "Unsupported native channel" unless [BOT_CHANNEL, BUSINESS_MESSAGES_CHANNEL].include?(channel.to_s)

          prelude = protected_prelude(message, channel:)
          if prelude
            remember_emergency(message, channel:) if prelude.answer_intent == "safety"
            return prelude
          end

          user = identity_for(channel).linked_user(sender: message.sender)
          context = Milica::ChannelConversationContext.call(organization:, channel:, sender: message.sender, user:)
          message = ContextualMessage.new(message, conversation_context: message.respond_to?(:conversation_context) ? message.conversation_context : [],
                                                   user:, trusted_context: context, channel:)
          if Milica::ChatReportIntake.enabled?(channel)
            reply, outcome = Milica::ReportConversation.new(typed_confirmation: true).call(message:, context:) do
              report_aware_turn(message, context:)
            end
          else
            reply, outcome = report_aware_turn(message, context:)
          end
          WebConcierge.attach_dialogue_outcome(reply, outcome) || runtime_failure_reply(message, status: :unavailable)
        rescue StandardError => e
          Rails.logger.warn("[ViberModelLed] failure=#{e.class.name}") if defined?(Rails) && Rails.respond_to?(:logger)
          runtime_failure_reply(message, status: :unavailable)
        end

        def remember_emergency(message, channel:)
          user = identity_for(channel).linked_user(sender: message.sender)
          context = Milica::ChannelConversationContext.call(organization:, channel:, sender: message.sender, user:)
          Milica::EmergencyContinuation.call(message:, context:, store: Decidim::Bih::Concierge::Dialogue::StateStore.new)
        rescue StandardError
          nil # The prelude card is already rendered and must still be delivered.
        end

        def protected_prelude(message, channel:)
          reply = Milica::ViberProtectedPrelude.new(
            identity: identity_for(channel),
            session_store: Decidim::Bih::Concierge::SessionStore.new.for_organization(organization.id)
          ).call(message:, report_location: Milica::ChatReportIntake.enabled?(channel))
          return unless reply
          return reply unless reply.answer_intent == "safety"

          WebConcierge.attach_dialogue_outcome(reply, WebConcierge.safety_guidance_outcome(reply))
        end

        def report_aware_turn(message, context:)
          WebConcierge.dialogue_turn(message:, context:, channel: message_channel(message)) || [runtime_failure_reply(message, status: :unavailable), nil]
        end

        def coordinator_class
          Decidim::Bih::Concierge::Dialogue::Coordinator
        rescue NameError
          nil
        end

        def runtime_failure_reply(message, status:)
          locale = if coordinator_class.respond_to?(:locale_for)
                     coordinator_class.locale_for(message)
                   else
                     I18n.locale.to_s
                   end
          key = status.to_s == "capacity" ? "busy" : "context_unavailable"
          fallback = I18n.t("decidim.bih.concierge.web_fallback", locale: locale)
          text = I18n.t("decidim.bih.dialogue.#{key}", locale:, default: fallback)
          Decidim::Bih::Concierge::Responder::Reply.new(
            text:, report: nil, quick_replies: [], answer_intent: "fallback", tone: "core"
          )
        rescue StandardError
          Decidim::Bih::Concierge::Responder::Reply.new(
            text: "Trenutno ne mogu pouzdano obraditi razgovor. Pokušaj ponovo uskoro.",
            report: nil, quick_replies: [], answer_intent: "fallback", tone: "core"
          )
        end

        # Enqueues the reply on the transport the message arrived on. When the
        # channel is unconfigured we log instead of enqueueing (dev/test),
        # preserving offline development while keeping configured webhook
        # requests free of outbound HTTP.
        def deliver(message, reply, channel:, first_turn: false)
          return if reply.nil? || message.sender.blank?

          if channel == BUSINESS_MESSAGES_CHANNEL
            deliver_business_message(message, reply, first_turn:)
          else
            deliver_bot_message(message, reply)
          end
        end

        def deliver_business_message(message, reply, first_turn: false)
          client = Decidim::Bih::Infobip::Client.new
          unless client.chat_channel_configured?(BUSINESS_MESSAGES_CHANNEL)
            Rails.logger.info(
              "[Concierge] Viber Business Messages not enabled; would reply to " \
              "#{Decidim::Bih::LogRedactor.mask_identifier(message.sender)}"
            )
            return
          end

          deadline = Decidim::Bih::Infobip::SendChatTextJob::SESSION_REPLY_TTL.from_now
          # Business Messages shows plain text: links must be absolute, chips
          # become lines and the text stays under Viber's cap. The web widget
          # keeps the raw reply; see ChatTextRendering.
          arguments = {
            channel: BUSINESS_MESSAGES_CHANNEL,
            organization_id: organization.id,
            to: message.sender,
            text: ChatTextRendering.render(channel: BUSINESS_MESSAGES_CHANNEL, reply:, host: organization.host, first_turn:),
            sender: Decidim::Bih::Config.infobip[:viber_bm_sender],
            expires_at: deadline,
            effect_expires_at: deadline
          }
          # Viber supports images natively, so MIlica keeps her stickers on
          # Business Messages exactly as she had them on the Bot. The job sends
          # media best-effort, so a rejected sticker never costs the reply.
          sticker = reply_sticker(reply)
          arguments[:media_id] = sticker.to_s if sticker.present?

          Decidim::Bih::DurableEffects.enqueue(
            Decidim::Bih::Infobip::SendChatTextJob,
            **arguments
          )
        end

        def deliver_bot_message(message, reply)
          client = Decidim::Bih::Infobip::Client.new
          unless client.viber_bot_active?
            Rails.logger.info(
              "[Concierge] Viber Bot inactive; would send bot reply to " \
              "#{Decidim::Bih::LogRedactor.mask_identifier(message.sender)}"
            )
            return
          end

          deadline = Decidim::Bih::Infobip::SendViberTextJob::SESSION_REPLY_TTL.from_now
          Decidim::Bih::DurableEffects.enqueue(
            Decidim::Bih::Infobip::SendViberTextJob,
            organization_id: organization.id,
            to: message.sender,
            text: reply.text,
            sticker: reply_sticker(reply),
            expires_at: deadline,
            effect_expires_at: deadline
          )
        end

        def record_usage(message, reply, channel:)
          typed_outcome = typed_reply_outcome(reply) unless blank_inbound?(message)
          Decidim::Bih::Concierge::UsageAggregateRecorder.call(
            organization: organization,
            channel: channel,
            outcome: reply_outcome(message, reply),
            topic: typed_outcome&.topic,
            outcome_dimensions: typed_outcome&.dimensions,
            answer_intent: reply_answer_intent(reply),
            facet: Decidim::Bih::Concierge::Dialogue::QuestionFacet.call(message.text.to_s),
            locale: I18n.locale.to_s,
            message_length: message.text.to_s.length,
            reply_length: reply_text(reply).length,
            quick_replies_count: reply_quick_replies(reply).length,
            sticker_present: reply_sticker(reply).present?
          )
        rescue StandardError => e
          Rails.logger.warn("[ViberUsageAggregate] #{e.class}: #{Decidim::Bih::LogRedactor.error_message(e)}")
        end

        def reply_outcome(message, reply)
          return "blank" if blank_inbound?(message)

          typed = typed_reply_outcome(reply)
          return Decidim::Bih::Concierge::Dialogue::Resolution.succeeded?(typed.dimensions.resolution) ? "success" : "fallback" if typed
          return "fallback" if reply_answer_intent(reply) == "fallback"

          "success"
        end

        def typed_reply_outcome(reply)
          return unless reply.respond_to?(:dialogue_outcome)

          Decidim::Bih::Concierge::ReplyOutcome.from(reply.dialogue_outcome)
        end

        def blank_inbound?(message)
          message.text.to_s.strip.blank? &&
            message.image_url.blank? &&
            !(message.respond_to?(:location?) && message.location?)
        end

        def reply_answer_intent(reply)
          intent = reply.respond_to?(:answer_intent) ? reply.answer_intent : nil
          Decidim::Bih::Concierge::AnswerIntents.sanitize(intent)
        end

        def reply_text(reply)
          reply.respond_to?(:text) ? reply.text.to_s : reply.to_s
        end

        def reply_quick_replies(reply)
          return [] unless reply.respond_to?(:quick_replies)

          Array(reply.quick_replies)
        end

        def reply_sticker(reply)
          reply.respond_to?(:sticker) ? reply.sticker : nil
        end

        # The magic-link verify flow belongs to the Bot transport, where the
        # sender is an opaque id and the token is the only way to tie it to a
        # phone. Business Messages senders are already carrier-proven numbers,
        # so the flow is skipped there rather than intercepting citizen text.
        def magic_link_verify_reply(message, channel:)
          return unless channel == BOT_CHANNEL

          Decidim::Bih::Viber::ViberVerifyFlow.new(organization:).call(message, strict: true)
        end

        # A citizen who writes to us on Business Messages has handed us a
        # carrier-proven number on a channel they chose. Record it as their
        # Viber delivery address so operator broadcasts and city-service alerts
        # can reach them without the (switched-off) Bot's OTP linkage.
        #
        # Only for a resolvable account — an anonymous sender gets no stored
        # row. Whether anything is actually SENT stays with the
        # mi_city_service_alerts_viber notification setting.
        def remember_business_contact(message)
          sender = message.respond_to?(:sender) ? message.sender : nil
          return if sender.blank?

          user = identity_for(BUSINESS_MESSAGES_CHANNEL).linked_user(sender:)
          return if user.blank?

          Decidim::Bih::Viber::BusinessContact.record!(user:, phone: sender)
        rescue StandardError => e
          Rails.logger.warn(
            "[Concierge] business contact record failed: " \
            "#{Decidim::Bih::LogRedactor.error_message(e)}"
          )
        end

        # The channel the message arrived on. Messages built by older unit
        # helpers may not carry one; those are Bot-era fixtures.
        def message_channel(message)
          value = message.channel.to_s if message.respond_to?(:channel)
          value.presence || BOT_CHANNEL
        end

        def conversation_store(message, channel:)
          ExternalChatSessionStore.new(
            organization: organization,
            channel: channel,
            sender: message.sender
          )
        end

        def remember_turn(store, message, reply)
          # This legacy store supplies presentation context only. Native secrets
          # and protected private responses must not be copied into generic chat
          # history. Model-led public history lives in the actor-scoped CAS frame.
          return unless reply_answer_intent(reply) == "service"
          return if Decidim::Bih::Concierge::Dialogue::StateStore.sensitive_text?(message.text.to_s)

          store.remember(
            user_text: message.text,
            bot_text: reply_text(reply),
            answer_intent: reply_answer_intent(reply),
            tone: reply.respond_to?(:tone) ? reply.tone : nil,
            phrase_id: reply.respond_to?(:phrase_id) ? reply.phrase_id : nil,
            location_present: message.respond_to?(:location?) && message.location?
          )
        end
      end
    end
  end
end
