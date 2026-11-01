# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    module Milica
      # Only native identity/media controls. Ordinary questions never enter the
      # retired Responder handler chain, and no model can trigger an OTP effect.
      class ViberProtectedPrelude
        PHONE_STATE = "awaiting_phone"
        CODE_STATE = "awaiting_code"
        CATEGORY_PREFIX = "awaiting_komsiluk_category:"
        CATEGORY_CHOICES = %w(1 2 3 4 izgubljen ljubimac nestao macka mace bezbjednost bezbednost opasnost upozorenje sigurnost aktivnost druzenje akcija dogadjaj radionica opste
                              opsta ostalo).freeze
        LINK_COMMAND = /\A(?:(?:molim(?:\s+te)?|zelim\s+da)\s+)?(?:povezi|verifikuj|registruj)(?:\s+(?:me|moj\s+nalog|nalog|moj\s+broj|broj|telefon))?[.!?]*\z/

        def initialize(identity:, session_store:, controls: Decidim::Bih::Concierge::Dialogue::Coordinator, production: nil)
          @identity = identity
          @store = session_store
          @controls = controls
          @production = production.nil? ? (defined?(Rails) && Rails.respond_to?(:env) && Rails.env.production?) : production
        end

        # Explicit precedence mirrors protected effects, not ordinary intent routing.
        def call(message:, report_location: false) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
          locale = @controls.locale_for(message)
          # Safety precedes credentials: prose containing six digits is not OTP.
          if @controls.safety?(message, nil)
            text = @controls.control_emergency_card(message) || I18n.t("decidim.bih.dialogue.safety", locale:)
            return reply(text:, locale:, intent: "safety")
          end
          if @controls.cancelled?(message)
            clear_pending(message.sender)
            return nil # The coordinator clears the separate CAS task/frame.
          end
          state = @store.get(sender: message.sender)
          text = message.text.to_s.strip
          key = @controls.control_key(message)
          return @controls.control_reply(message:) if key == "allegation"
          return verify_code(message.sender, text, locale) if state == CODE_STATE && text.match?(/\A\d{6}\z/)
          return submit_phone(message.sender, text, locale) if state == PHONE_STATE && phone?(text) && !attachment?(message)
          return @controls.control_reply(message:) if key == "credentials"

          if attachment?(message, report_location:)
            @store.clear(sender: message.sender) if state.to_s.start_with?(CATEGORY_PREFIX)
            return photo_guidance(locale)
          end

          if LINK_COMMAND.match?(fold(text)) || fold(text) == "prijava naloga"
            @store.set(sender: message.sender, state: PHONE_STATE)
            return translated("link.ask_phone", locale)
          end
          return unless state.to_s.start_with?(CATEGORY_PREFIX)

          @store.clear(sender: message.sender)
          return unless CATEGORY_CHOICES.include?(fold(text))

          translated("komsiluk.post.web_guidance", locale, intent: "komsiluk_post", url: routes.komsiluk_board_index_path)
        end

        private

        def verify_code(sender, code, locale)
          status = @identity.verify(sender:, code:)
          @store.clear(sender:) unless status == :invalid
          key = { verified: "verified", invalid: "invalid_code" }.fetch(status, "expired")
          translated("link.#{key}", locale)
        end

        def submit_phone(sender, phone, locale)
          status = @identity.start(sender:, phone:)
          if status == :otp_sent || (status == :unconfigured && !@production)
            @store.set(sender:, state: CODE_STATE)
            return translated("link.code_sent", locale)
          end
          key = { rate_limited: "rate_limited", send_failed: "send_failed", unconfigured: "send_failed" }.fetch(status, "invalid_phone")
          translated("link.#{key}", locale)
        end

        def clear_pending(sender)
          state = @store.get(sender:)
          @store.clear(sender:) if [PHONE_STATE, CODE_STATE].include?(state) || state.to_s.start_with?(CATEGORY_PREFIX)
        end

        def phone?(text)
          text.match?(%r{\A\+?[\d\s()./-]+\z}) && text.gsub(/\D/, "").length.between?(8, 15)
        end

        # Only the server-owned channel report flag can let a location pin
        # reach the existing preview/confirmation boundary. Photos stay here.
        def attachment?(message, report_location: false)
          (message.respond_to?(:image_url) && !message.image_url.to_s.empty?) ||
            (!report_location && message.respond_to?(:location?) && message.location? && !(message.respond_to?(:location_context?) && message.location_context?))
        end

        def photo_guidance(locale)
          url = routes.new_report_path
          reply(text: I18n.t("decidim.bih.concierge.report_guidance.answer", locale:, url:), locale:, intent: "report_guidance",
                quick_replies: [{ label: I18n.t("decidim.bih.concierge.widget.quick.report", locale:), url: }])
        end

        def routes
          Decidim::Bih::Engine.routes.url_helpers
        end

        def fold(text)
          Decidim::Bih::Text.fold(text).strip.gsub(/\s+/, " ")
        end

        def translated(key, locale, intent: "account_linking", **values)
          reply(text: I18n.t("decidim.bih.concierge.#{key}", locale:, **values), locale:, intent:)
        end

        def reply(text:, locale:, intent:, quick_replies: [])
          Decidim::Bih::Concierge::Responder::Reply.new(text:, report: nil, locale:, answer_intent: intent, tone: "core", quick_replies:)
        end
      end
    end
  end
end
