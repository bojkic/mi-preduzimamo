# frozen_string_literal: true

require_relative "milica/emergency_continuation"

module DecidimApp
  module Bijeljina
    # Model-led public conversation wiring. Identity and report confirmation
    # remain server-owned; provider failures never enter another conversation brain.
    module WebConcierge
      class << self
        # ReportConversation alone owns report preview and exact confirmation.
        def respond(message, channel: "web_chat", trusted_context: nil)
          context = trusted_context || dialogue_context(message)
          begin
            reply, outcome = if report_submission_enabled?(message, context:, channel:)
                               Milica::ReportConversation.new(typed_confirmation: channel.to_s != "web_chat")
                                                         .call(message:, context:) { route(message, context:, channel:) }
                             else
                               route(message, context:, channel:)
                             end
          rescue StandardError
            # Never retry an admitted conversation through the legacy model path
            # after a coordinator/runtime failure. Keep the existing reply shape
            # with a deterministic, source-aware fallback instead.
            reply = runtime_failure_reply(message, status: :unavailable)
            outcome = nil
          end
          # The outcome is attached first so the voice can read the topic.
          reply.text = ChatTextRendering.absolute_links(reply.text, host: Concierge.organization.host) if reply&.answer_intent == "report_guidance"
          reply = attach_dialogue_outcome(reply, outcome)
          MilicaPersonality.call(reply:, message:, channel:)
        end

        # Shared by deterministic web controls and native responder preludes.
        # Callers own the branch; arbitrary model text cannot select this type.
        def safety_guidance_outcome(reply)
          Decidim::Bih::Concierge::Dialogue::ProcedureRunner::Result.new(
            state: nil, reply:, resolution: Decidim::Bih::Concierge::Dialogue::Resolution::SAFETY_GUIDANCE,
            fact_ids: [], handoff_offered: false, handoff_completed: false
          )
        end

        # Called with the OLD trusted scope on clear, sign-in or actor change,
        # including when report submission is currently disabled.
        def clear_conversation(context:)
          Milica::ReportConversationStore.new.revoke(context:)
        ensure
          # Independent stores: failure in report cleanup cannot leave a
          # previously issued authentication-return ticket usable.
          Milica::RegistrationHandoffStore.new.revoke(context:)
        end

        def registration_handoff(organization:)
          Milica::RegistrationHandoff.new(organization:)
        end

        # Clear organization-bound runtime instances after configuration changes.
        def reset!
          @coordinators = nil
        end

        # Used after a native adapter has validated its provider and identity.
        def dialogue_enabled?(context:)
          model_led_enabled?(context:)
        end

        # Native channels share this path and receive an explicit failure reply
        # when unavailable; there is no retry through the retired router.
        def dialogue_turn(message:, context:, channel: "web_chat")
          return [runtime_failure_reply(message, status: :unavailable), nil] unless model_led_enabled?(context:)

          emergency = Milica::EmergencyContinuation.call(message:, context:, store: Decidim::Bih::Concierge::Dialogue::StateStore.new)
          return [emergency.reply, emergency] if emergency

          outcome = coordinator_for(context:).call(message:, context:, channel:)
          reply = outcome.respond_to?(:reply) ? outcome.reply : nil
          raise "Conversation returned no reply" unless reply

          [reply, outcome]
        rescue StandardError
          [runtime_failure_reply(message, status: :unavailable), nil]
        end

        private

        # Report-only effect boundary. MILICA_REPORT_CHAT_SUBMISSION_ENABLED is
        # the master switch for reports from chat; the web is always in scope
        # once it is on, and an EXTERNAL channel additionally has to be listed
        # in MI_CHAT_REPORT_INTAKE_CHANNELS (empty by default, so no channel
        # changes behaviour until the owner names it). Other conversational
        # writes and communication-channel activation remain disabled and
        # independently owned.
        def report_submission_enabled?(message, context:, channel:)
          enabled = if channel.to_s == "web_chat"
                      ENV[Milica::ChatReportIntake::MASTER_FLAG] == "true"
                    else
                      Milica::ChatReportIntake.enabled?(channel)
                    end

          enabled && enabled_for?(context:, user: message_user(message))
        end

        # The controller may pass the server-built TrustedContext directly, or
        # a future WebMessage may expose it as dialogue_context. A generic
        # message without either value receives an unavailable reply.
        def dialogue_context(message)
          return message.trusted_context if message.respond_to?(:trusted_context)
          return message.dialogue_context if message.respond_to?(:dialogue_context)

          nil
        end

        def route(message, context:, channel: "web_chat")
          enabled = enabled_for?(context:, user: message_user(message))
          if enabled
            emergency = Milica::EmergencyContinuation.call(message:, context:, store: Decidim::Bih::Concierge::Dialogue::StateStore.new)
            return [emergency.reply, emergency] if emergency
          end
          control = immediate_control_reply(message, enabled:)
          return [control, control.answer_intent == "safety" ? safety_guidance_outcome(control) : nil] if control

          return [runtime_failure_reply(message, status: :unavailable), nil] unless enabled

          coordinator = coordinator_for(context:)
          outcome = coordinator.call(message:, context:, channel:)
          reply = outcome.respond_to?(:reply) ? outcome.reply : nil
          raise "Dialogue coordinator returned no reply" unless reply

          [reply, outcome]
        end

        def immediate_control_reply(message, enabled:)
          klass = coordinator_class
          return unless klass.respond_to?(:control_reply)
          return if enabled

          return unless %w(safety credentials allegation).include?(klass.control_key(message))

          klass.control_reply(message:)
        end

        def enabled_for?(context:, user:)
          return false unless model_led_enabled?(context:)
          return !user if context.actor_id.nil?

          user && user.id == context.actor_id && user.decidim_organization_id == context.organization_id
        end

        def model_led_enabled?(context:)
          context.is_a?(Decidim::Bih::Concierge::Dialogue::Contracts::TrustedContext) &&
            ENV["MILICA_DIALOGUE_ENABLED"] == "true" &&
            ENV["MILICA_CONVERSATION_ARCHITECTURE"] == "model_led" &&
            ENV.fetch("MILICA_CONVERSATIONAL_WRITES_ENABLED", "false") == "false"
        end

        def coordinator_class
          Decidim::Bih::Concierge::Dialogue::Coordinator
        rescue NameError
          nil
        end

        def message_user(message)
          message.respond_to?(:user) ? message.user : nil
        end

        def coordinator_for(context:)
          organization = Concierge.organization
          raise "Conversation organization mismatch" unless context.organization_id == organization.id

          @coordinators ||= {}
          cache_key = [organization.id, Milica::ModelLedCoordinator::MODEL]
          @coordinators[cache_key] ||= build_coordinator(organization:)
        end

        def build_coordinator(organization:)
          Milica::ModelLedCoordinator.new(organization:)
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
            text:, report: nil, quick_replies: fallback_quick_replies(locale:), answer_intent: "fallback", tone: "core"
          )
        rescue StandardError
          Decidim::Bih::Concierge::Responder::Reply.new(
            text: "Trenutno ne mogu pouzdano obraditi razgovor. Pokušaj ponovo uskoro.",
            report: nil, answer_intent: "fallback", tone: "core"
          )
        end

        def attach_dialogue_outcome(reply, outcome)
          return reply unless reply && outcome
          return reply if reply.respond_to?(:dialogue_outcome)

          outcome.freeze if outcome.respond_to?(:freeze)
          reply.define_singleton_method(:dialogue_outcome) { outcome }
          reply
        rescue StandardError
          # Outcome metadata is best-effort. Never hide a successful receipt or
          # re-run its submission because an instrumentation attachment failed.
          reply
        end

        # Native channels attach the outcome AFTER their report boundary has
        # returned, so previews and durable receipts retain the correct type.
        public :attach_dialogue_outcome

        def fallback_quick_replies(locale: I18n.locale.to_s)
          Decidim::Bih::Concierge::CivicShortcuts.new(organization: Concierge.organization, locale:).chips
        rescue StandardError
          []
        end
      end
    end
  end
end
