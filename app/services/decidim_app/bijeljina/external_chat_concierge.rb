# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    # Authenticated provider adapter. A scoped verified identity can attribute
    # confirmed reports; it does not enable private-account reads or bypass the
    # independent report-intake switches. Viber BM keeps its native adapter.
    class ExternalChatConcierge
      ChannelBoundaryError = Class.new(StandardError)

      class << self
        def call(organization:, message:, session_store: nil)
          new(organization:, message:, session_store:).call
        end
      end

      def initialize(organization:, message:, session_store: nil)
        @organization = organization
        @message = message
        @session_store = session_store
      end

      def call
        validate_boundaries!
        @report_actor = ProviderReportIdentity.call(organization:, message:)
        @session_store ||= ExternalChatSessionStore.new(organization:, channel: message.channel,
                                                        sender: message.sender, actor_id: @report_actor&.id)
        opt_out_reply = ChannelNotificationOptOut.reply(organization:, message:)
        if opt_out_reply
          enqueue_reply(opt_out_reply)
          return opt_out_reply
        end
        connection_reply = Decidim::Bih::ChannelConnections.observe!(organization:, message:)
        if connection_reply
          enqueue_reply(connection_reply)
          return connection_reply
        end
        intake_reply = SocialRegistrationIntake.call(organization:, message:)
        if intake_reply
          enqueue_reply(intake_reply)
          return intake_reply
        end

        web_message = build_web_message
        reply = WebConcierge.respond(web_message, **concierge_options)
        # A voice note, a sticker, a reaction or a bare document arrives with no
        # text and nothing to answer. Replying anyway sent the help menu — a
        # billed message per event on a paid channel, and one the citizen never
        # asked for (review 2026-09-07, lane 4 H1). The usage aggregate still
        # records the turn as "blank".
        enqueue_reply(reply) unless blank_inbound?
        record_usage(reply)
        remember_turn(reply)
        reply
      end

      private

      attr_reader :organization, :message, :session_store

      def validate_boundaries!
        configured_organization = Concierge.organization
        raise ChannelBoundaryError, "external chat organization mismatch" unless
          configured_organization && configured_organization.id == organization.id

        config = Decidim::Bih::Config.infobip
        channel = message.channel.to_s
        raise ChannelBoundaryError, "viber_bm is a full concierge channel" if
          channel == Concierge::BUSINESS_MESSAGES_CHANNEL

        configured_sender = config[:"#{channel}_sender"]
        unless Decidim::Bih::Infobip::InboundMessage::CHANNELS.include?(channel) &&
               Decidim::Bih::Infobip::Client.new.chat_channel_configured?(channel) &&
               message.sender.present?
          raise ChannelBoundaryError, "external chat channel is not configured"
        end
        return if message.recipient.present? && message.recipient.to_s == configured_sender.to_s

        raise ChannelBoundaryError, "external chat recipient mismatch"
      end

      # Public conversation continuity is independent of permission to submit
      # reports. Opaque channel IDs do not confer account authorization.
      def concierge_options
        { channel: message.channel, trusted_context: conversation_context }
      end

      def conversation_context
        @conversation_context ||= Milica::ChannelConversationContext.call(
          organization:, channel: message.channel, sender: message.sender, user: @report_actor, private_reads: false
        )
      end

      def build_web_message
        Decidim::Bih::Concierge::WebMessage.new(
          message.text,
          user: @report_actor,
          trusted_context: conversation_context,
          location: message_location,
          conversation_context: session_store.context
        )
      end

      def message_location
        return unless message.respond_to?(:location?) && message.location?

        return unless Decidim::Bih::Concierge::WebMessage.location_requested?(message.text.to_s)

        { latitude: message.latitude, longitude: message.longitude,
          purpose: "current_location", consent: true, provenance: "external_explicit_location",
          retain_for_conversation: true }
      end

      # The brain writes for the web widget (root-relative links, chips); the
      # channel renderer turns that into text a phone messenger can show and
      # keeps it under the channel's cap. See ChatTextRendering.
      def enqueue_reply(reply)
        text = ChatTextRendering.render(channel: message.channel.to_s, reply:, host: organization.host,
                                        first_turn: session_store.context.empty? && !reply.respond_to?(:request_phone))
        return if text.blank?

        deadline = reply_deadline(reply)
        return if deadline <= Time.current

        arguments = {
          channel: message.channel.to_s,
          to: message.sender,
          text:,
          expires_at: deadline,
          effect_expires_at: deadline
        }
        arguments[:request_phone] = true if reply_request_phone(reply)
        if reply_sticker(reply).present?
          arguments[:organization_id] = organization.id
          arguments[:media_id] = reply_sticker(reply).to_s
        end
        Decidim::Bih::DurableEffects.enqueue(
          Decidim::Bih::Infobip::SendChatTextJob,
          **arguments
        )
      end

      def record_usage(reply)
        typed_outcome = typed_reply_outcome(reply) unless blank_inbound?
        Decidim::Bih::Concierge::UsageAggregateRecorder.call(
          organization:,
          channel: message.channel.to_s,
          outcome: reply_outcome(reply),
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
        Rails.logger.warn(
          "[ExternalChatUsageAggregate] #{e.class}: #{Decidim::Bih::LogRedactor.error_message(e)}"
        )
      end

      def remember_turn(reply)
        session_store.remember(
          user_text: message.text,
          bot_text: reply_text(reply),
          answer_intent: reply_answer_intent(reply),
          tone: reply_tone(reply),
          phrase_id: reply_phrase_id(reply),
          location_present: message.respond_to?(:location?) && message.location?
        )
      end

      def reply_outcome(reply)
        return "blank" if blank_inbound?

        typed = typed_reply_outcome(reply)
        return Decidim::Bih::Concierge::Dialogue::Resolution.succeeded?(typed.dimensions.resolution) ? "success" : "fallback" if typed
        return "fallback" if reply_answer_intent(reply) == "fallback"

        "success"
      end

      def typed_reply_outcome(reply)
        return unless reply.respond_to?(:dialogue_outcome)

        Decidim::Bih::Concierge::ReplyOutcome.from(reply.dialogue_outcome)
      end

      def blank_inbound?
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
        reply.respond_to?(:quick_replies) ? Array(reply.quick_replies) : []
      end

      def reply_request_phone(reply)
        reply.respond_to?(:request_phone) && reply.request_phone == true
      end

      def reply_deadline(reply)
        interaction = message.respond_to?(:occurred_at) ? message.occurred_at : nil
        # Missing/untrusted event time means no automatic reply; processing time
        # must never create a new Meta customer-service session.
        return Time.current unless interaction && interaction <= Time.current

        deadline = interaction + Decidim::Bih::Infobip::SendChatTextJob::SESSION_REPLY_TTL
        requested = reply.respond_to?(:expires_at) ? reply.expires_at : nil
        requested.present? ? [requested.to_time, deadline].min : deadline
      rescue ArgumentError, NoMethodError
        Time.current
      end

      def reply_sticker(reply)
        reply.respond_to?(:sticker) ? reply.sticker : nil
      end

      def reply_tone(reply)
        reply.respond_to?(:tone) ? reply.tone.to_s.presence : nil
      end

      def reply_phrase_id(reply)
        reply.respond_to?(:phrase_id) ? reply.phrase_id.to_s.presence : nil
      end
    end
  end
end
