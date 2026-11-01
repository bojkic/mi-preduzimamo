# frozen_string_literal: true

require "openssl"

module DecidimApp
  module Bijeljina
    # Short-lived conversational context for an opaque external-chat sender.
    # The cache key contains an HMAC, never the provider's raw user identifier.
    # No identity/linkage row or transcript is persisted in the database.
    class ExternalChatSessionStore
      MAX_TURNS = 6
      TTL = 30.minutes
      MAX_USER_TEXT_LENGTH = 500
      MAX_BOT_TEXT_LENGTH = 800
      MAX_TONE_HISTORY = 10

      def initialize(organization:, channel:, sender:, actor_id: nil, cache: Rails.cache)
        @organization = organization
        @channel = channel.to_s
        @sender = sender.to_s
        @actor_id = actor_id
        @cache = cache
      end

      def context
        sanitize_turns(Array(cache.read(cache_key))).last(MAX_TURNS)
      rescue StandardError => e
        log_cache_failure("read", e)
        []
      end

      def remember(user_text:, bot_text:, answer_intent:, location_present:, tone: nil, phrase_id: nil) # rubocop:disable Metrics/ParameterLists
        turns = context
        tone_history = conversation_tone_history(turns, tone)
        turns << {
          "user" => bounded_text(user_text, MAX_USER_TEXT_LENGTH),
          "bot" => bounded_text(bot_text, MAX_BOT_TEXT_LENGTH),
          "answer_intent" => answer_intent.to_s.presence,
          "tone" => bounded_token(tone),
          "tone_history" => tone_history,
          "phrase_id" => bounded_token(phrase_id),
          "location_present" => ActiveModel::Type::Boolean.new.cast(location_present),
          "at" => Time.current.to_i
        }.compact
        payload = turns.last(MAX_TURNS)
        Decidim::Bih::DurableEffects.cache_write(cache_key, payload, cache:, expires_in: TTL)
      rescue StandardError => e
        log_cache_failure("write", e)
        raise if Decidim::Bih::DurableEffects.active?

        false
      end

      private

      attr_reader :organization, :channel, :sender, :cache

      def cache_key
        identity = [organization.id, channel, sender]
        identity += ["actor", @actor_id] if @actor_id
        identity = identity.join("\0")
        digest = OpenSSL::HMAC.hexdigest("SHA256", Rails.application.secret_key_base.to_s, identity)
        "decidim-bih/external-chat/conversation/#{organization.id}/#{channel}/#{digest}"
      end

      def sanitize_turns(turns)
        turns.filter_map do |turn|
          next unless turn.respond_to?(:[])

          {
            "user" => bounded_text(turn["user"], MAX_USER_TEXT_LENGTH),
            "bot" => bounded_text(turn["bot"], MAX_BOT_TEXT_LENGTH),
            "answer_intent" => turn["answer_intent"].to_s.presence,
            "tone" => bounded_token(turn["tone"]),
            "tone_history" => sanitize_tone_history(turn["tone_history"]),
            "phrase_id" => bounded_token(turn["phrase_id"]),
            "location_present" => ActiveModel::Type::Boolean.new.cast(turn["location_present"]),
            "at" => turn["at"].to_i.positive? ? turn["at"].to_i : nil
          }.compact
        end
      end

      def bounded_text(value, limit)
        value.to_s.first(limit).presence
      end

      def bounded_token(value)
        token = value.to_s.first(80)
        token if token.match?(/\A[a-z0-9_.-]+\z/)
      end

      def conversation_tone_history(turns, tone)
        previous = sanitize_tone_history(turns.last&.fetch("tone_history", nil))
        previous = turns.filter_map { |turn| bounded_tone(turn["tone"]) } if previous.empty?
        (previous + [bounded_tone(tone)]).compact.last(MAX_TONE_HISTORY)
      end

      def sanitize_tone_history(value)
        Array(value).filter_map { |tone| bounded_tone(tone) }.last(MAX_TONE_HISTORY)
      end

      def bounded_tone(value)
        value.to_s if %w(core neighborly playful).include?(value.to_s)
      end

      def log_cache_failure(operation, error)
        Rails.logger.warn(
          "[ExternalChatConversation] #{operation} failed " \
          "(#{error.class}: #{Decidim::Bih::LogRedactor.error_message(error)})"
        )
      end
    end
  end
end
