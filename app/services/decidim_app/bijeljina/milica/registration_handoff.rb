# frozen_string_literal: true

require "openssl"
require_relative "registration_handoff_store"
require_relative "registration_port"

module DecidimApp
  module Bijeljina
    module Milica
      # Controller-owned session bridge. Nothing here accepts a token, actor or
      # successful-auth claim from chat text or request parameters.
      class RegistrationHandoff
        SESSION_KEY = :milica_registration_handoff

        def initialize(organization:, store: RegistrationHandoffStore.new, port: nil)
          @organization = organization
          @store = store
          @port = port || RegistrationPort.new(organization:)
        end

        def prepare(reply:, action:, context:, state:, session:)
          return reply unless reply.respond_to?(:text) && state.is_a?(Hash)

          prepared = @port.prepare_web_handoff(action:, context:, state:, reply_text: reply.text,
                                              locale: state.fetch("locale"), store: @store)
          return reply unless prepared

          answer = reply.clone(freeze: false)
          answer.text = reply.text.gsub(prepared.original_destination, prepared.handoff.destination)
          manual = I18n.t("decidim.bih.dialogue.resume_manual", locale: state.fetch("locale"), default: "")
          answer.text = answer.text.gsub("\n\n#{manual}", "") unless manual.empty?
          session[SESSION_KEY] = prepared.ticket
          answer
        rescue StandardError => error
          log_failure(error)
          reply
        end

        def start(session:, user:, secret:)
          entry = session[SESSION_KEY]
          raw_id = session[:decidim_bih_web_chat_id]
          return unless raw_id.is_a?(String) && raw_id.match?(/\A[0-9a-f]{32}\z/)

          context = Decidim::Bih::Concierge::Dialogue::Contracts::TrustedContext.new(
            organization_id: @organization.id, actor_id: user&.id,
            conversation_key: OpenSSL::HMAC.hexdigest("SHA256", secret, raw_id)
          )
          @store.start(entry:, context:)
        rescue StandardError => error
          log_failure(error)
          nil
        end

        def authenticated(entry:, session:, user:)
          if @store.authenticated(entry:, user:, organization_id: @organization.id)
            session[SESSION_KEY] = entry
            true
          else
            session.delete(SESSION_KEY)
            false
          end
        rescue StandardError => error
          session.delete(SESSION_KEY)
          log_failure(error)
          false
        end

        def consume(session:, context:, user:)
          entry = session[SESSION_KEY]
          return unless entry

          task = @store.consume(entry:, context:, user:)
          session.delete(SESSION_KEY) if task && session[SESSION_KEY] == entry
          task
        rescue StandardError => error
          log_failure(error)
          nil
        end

        def cancel(session:)
          entry = session.delete(SESSION_KEY)
          @store.revoke_entry(entry:) if entry
        rescue StandardError => e
          log_failure(e)
          nil
        end

        private

        def log_failure(error)
          Rails.logger.warn("[MilicaRegistrationHandoff] #{error.class.name}") if defined?(Rails) && Rails.respond_to?(:logger)
        end
      end
    end
  end
end
