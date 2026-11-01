# frozen_string_literal: true

require "timeout"

module DecidimApp
  module Bijeljina
    module Milica
      # Retain the existing narrow emergency policy without the old topic router.
      # Rendering precedes best-effort CAS; a cache failure never hides the card.
      class EmergencyContinuation
        Dialogue = Decidim::Bih::Concierge::Dialogue
        Turn = Struct.new(:text, :context, :state, :store, keyword_init: true) do
          def cancelled? = Dialogue::Coordinator.cancelled?(Struct.new(:text).new(text))

          def accept(candidate)
            saved = store.write(context:, state: candidate.state, expected_version: state.fetch("version"))
            saved == :saved ? candidate : nil
          end
        end

        def self.call(message:, context:, store:)
          signal = Decidim::Bih::Concierge::EmergencySignal
          text = message.text.to_s
          assessment = signal.assess(text)
          return opened_danger(assessment, message:, context:, store:) if assessment

          if Dialogue::Coordinator.cancelled?(message) && Dialogue::Coordinator.control_key(message) == "safety"
            return cancelled_safety(message:, context:, store:)
          end

          return unless signal.follow_up(text) || signal.service_request(text)

          state = store.read(context:) || store.empty_state(context)
          Dialogue::EmergencyStage.call(Turn.new(text: message.text.to_s, context:, state:, store:))
        rescue StandardError
          nil
        end

        # Compose the card before touching state. A bounded best-effort CAS
        # retains emergency continuity and cancellation when Redis is fast;
        # a slow or corrupt state can delay delivery by at most this tiny cap.
        def self.opened_danger(assessment, message:, context:, store:)
          immediate = immediate_danger(assessment, message.text.to_s)
          return unless immediate

          begin
            Timeout.timeout(0.03) do
              state = store.read(context:) || store.empty_state(context)
              saved = Dialogue::EmergencyStage.call(Turn.new(text: message.text.to_s, context:, state:, store:))
              return saved if saved
            end
          rescue Timeout::Error, StandardError
            nil
          end
          immediate
        end

        # Fresh danger is fully answerable from reviewed emergency contacts.
        # Avoid even a bounded Redis read before returning the card; optional
        # location/ciphertext and a failed store can never delay this path.
        def self.immediate_danger(assessment, text)
          locale = Decidim::Bih::Concierge::EmergencyCard.locale_for(text, fallback: "sr")
          card = Decidim::Bih::Concierge::EmergencyCard.call(assessment, locale:)
          return unless card

          reply = Decidim::Bih::Concierge::Responder::Reply.new(
            text: card, report: nil, quick_replies: [], answer_intent: "safety", tone: "core"
          )
          Dialogue::ProcedureRunner::Result.new(
            state: nil, reply:, resolution: "safety_guidance", fact_ids: [],
            handoff_offered: false, handoff_completed: false
          )
        end

        # Broader danger wording (for example threats) can use the safety card
        # without opening EmergencyStage's bounded contact context. Cancellation
        # still clears the protected draft with CAS before returning that card.
        def self.cancelled_safety(message:, context:, store:)
          reply = Dialogue::Coordinator.control_reply(message:)
          saved = nil
          begin
            previous = store.read(context:)
            if previous
              candidate = store.empty_state(context).merge(previous.slice("version", "created_at", "locale"))
              saved = candidate if store.write(context:, state: candidate, expected_version: previous.fetch("version")) == :saved
            end
          rescue StandardError
            # The safety answer remains available during a state-store outage.
            saved = nil
          end
          Dialogue::ProcedureRunner::Result.new(state: saved, reply:, resolution: "safety_guidance", fact_ids: [],
                                                handoff_offered: false, handoff_completed: false)
        end
      end
    end
  end
end
