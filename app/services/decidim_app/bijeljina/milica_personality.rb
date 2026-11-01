# frozen_string_literal: true

require "digest"
require "yaml"

module DecidimApp
  module Bijeljina
    # Applies the approved Komšinica Milica voice to a completed concierge
    # reply without touching facts, statuses, sources, URLs or civic actions.
    # All playful language comes from the reviewed host phrase bank; red-zone
    # conversations stay fixed, neutral and media-free.
    class MilicaPersonality
      # viber_bm (Business Messages) is the live Viber transport and shares the
      # Bot's voice; an unknown channel falls back to the web_chat tone.
      CHANNELS = %w(web_chat viber viber_bm whatsapp messenger instagram).freeze

      # The persona image is a SECOND Infobip message: roughly 40% of replies
      # carry one, so on a paid channel it doubles the outbound message count for
      # a gesture nobody asked for. The web widget renders it for free, so that
      # is where it stays (review 2026-09-07, lane 4 M4). The phrase itself — the
      # voice — is unchanged on every channel.
      MEDIA_CHANNELS = %w(web_chat).freeze
      CORE_INTENTS = %w(account_linking moderation privacy safety).freeze
      FACTUAL_INTENTS = %w(service setup).freeze
      # Owner decision 2026-09-12: the approved phrase bank (§4.3 green zone)
      # wins over the earlier "service stays factual" rule for these topics.
      # `setup` and every other service topic stay factual; the yellow and
      # red zones are untouched.
      GREEN_TOPICS = %w(waste parking transport budget gazette).freeze
      CUE_BY_TOPIC = {
        "parking" => "parking", "transport" => "transport", "waste" => "waste",
        "budget" => "public_data", "gazette" => "public_data"
      }.freeze
      YELLOW_INTENTS = %w(city_event donation report status komsiluk_post).freeze
      FAILED_INTENTS = %w(fallback unknown).freeze
      MAX_PLAYFUL_IN_TEN = 4
      RECENT_PHRASE_WINDOW = 6
      # A concise answer is the product; the persona phrase is the optional
      # part of it. This layer runs last and only ever ADDS, so it is the one
      # place that can check the finished text — and when the phrase would put
      # a reply past the budget it was composed to, the phrase is what goes.
      CONCISE_BUDGET = 600
      # Procedures get the plain voice: a citizen following steps is reading
      # for instructions, not for character. `setup` is already factual;
      # naming the rest keeps the rule in one list.
      PROCEDURE_INTENTS = %w(setup report_guidance status local_area_guidance).freeze
      # A citizen correcting us has already not been understood once. Adding a
      # flourish to the second attempt reads as not listening. Every phrase
      # here is long enough not to match inside an unrelated word.
      CORRECTION_TERMS = [
        "nije korisno", "to nije korisno", "ispravka", "ispravljam", "ispravi", "nisam pitao", "nisam pitala", "ne treba mi",
        "pogresno si", "pogrešno si", "nije tacno", "nije tačno", "opet isto", "rekao sam",
        "rekla sam", "correction", "that is wrong", "that's wrong", "not what i asked", "i already said"
      ].freeze
      # A citizen asking for LESS must never receive MORE. A brevity request is
      # a presentation operation on an answer already given: the words are the
      # thing being complained about, so a persona gesture on top of them is
      # the opposite of listening. Measured on production: a 392-character
      # schedule answer came back at 456 after "Kraće molim." - the phrase was
      # the entire difference.
      BREVITY_TERMS = [
        "kraće", "krace", "kraći", "kraci", "kratko i jasno", "skrati", "sažmi", "sazmi", "ukratko",
        "u jednoj rečenici", "u jednoj recenici", "jednom rečenicom", "jednom recenicom",
        "samo mi reci", "bez detalja", "shorter", "briefly", "in one sentence", "tl;dr"
      ].freeze

      CUE_BY_INTENT = {
        "help" => "help", "fallback" => "help", "setup" => "help",
        "budget" => "public_data", "gazette" => "public_data", "data_status" => "public_data", "service" => "public_data",
        "waste" => "waste", "local_area_guidance" => "location",
        "report" => "reports", "report_guidance" => "reports", "komsiluk_post" => "reports", "komsiluk_read" => "reports",
        "participation_guidance" => "participation", "volunteer_guidance" => "action",
        "goodwill" => "community", "donation" => "community"
      }.freeze

      RED_ZONE_TERMS = %w(
        prijet prijetnj pretnj nasilj povred povrijed nesrec opasnost dijete djeca deca
        diskrimin uznemir mrznj korupc kriminal zloupotreb polic civiln zastit vodostaj
        upozorenj jmbg lozink password kartic zdravstv moderacij odbijen zalb žalb uklonjen
        gresk grešk neuspjel neuspel izgubljen uplata payment refund verifikacion verifikacij
        verify povez povež telefon phone login nalog account
      ).freeze
      FRUSTRATION_TERMS = %w(
        ljut bijesan besan nervira uzas užas sramota glupost ne radi opet treci treći
        third time useless angry frustrated
      ).freeze
      PROFANITY_TERMS = %w(jeb sran govn pizd kurac mater).freeze
      FORMAL_TERMS = [
        "poštovani", "postovani", "molim vas", "možete li", "mozete li", "želio bih",
        "zelio bih", "željela bih", "zeljela bih", "please", "could you", "would you"
      ].freeze
      POSITIVE_TERMS = %w(hvala super odlicno odlično bravo haha hehe thanks great).freeze

      class << self
        def call(reply:, message:, channel:)
          new(reply:, message:, channel:).call
        end

        def config
          @config ||= YAML.safe_load_file(config_path, aliases: false).deep_stringify_keys.freeze
        end

        def reset!
          @config = nil
        end

        private

        def config_path
          Rails.root.join("config/milica/personality.yml")
        end
      end

      def initialize(reply:, message:, channel:)
        @reply = reply
        @message = message
        @channel = CHANNELS.include?(channel.to_s) ? channel.to_s : "web_chat"
      end

      def call
        return reply unless decoratable?
        return factual_reply if factual? || plain_voice_required?

        reply.tone = selected_tone if reply.respond_to?(:tone=) && reply.tone.blank?
        return reply unless reply.respond_to?(:tone) && reply.tone == "playful"

        phrase = select_phrase
        decorate_with_phrase(phrase) if phrase
        attach_media
        reply
      end

      private

      attr_reader :reply, :message, :channel

      def decoratable?
        reply.respond_to?(:text) && reply.text.to_s.strip.present?
      end

      # An emergency, a correction or a procedure is never an occasion for a
      # flourish — and an upstream "playful" tone does not override that,
      # because this is the layer that sees the finished reply.
      def plain_voice_required?
        red_zone? || correction? || brevity_request? || PROCEDURE_INTENTS.include?(intent)
      end

      # See BREVITY_TERMS.
      def brevity_request?
        contains_any?(message_text, BREVITY_TERMS)
      end

      def correction?
        contains_any?(message_text, CORRECTION_TERMS)
      end

      # Utility facts and setup instructions should speak for themselves, even
      # when an upstream reply already requested a playful tone. Keep functional
      # stickers/actions; only the optional persona gesture is decoration.
      # The length check is on the DECORATED text, not the bare reply: what a
      # citizen receives is what has to fit.
      def decorate_with_phrase(phrase)
        decorated = "#{localized(phrase.fetch("text"))}\n\n#{reply.text}"
        return false if decorated.length > CONCISE_BUDGET

        reply.text = decorated
        reply.phrase_id = phrase.fetch("id") if reply.respond_to?(:phrase_id=)
        true
      end

      def factual_reply
        reply.tone = reply.tone == "core" || red_zone? ? "core" : "neighborly" if reply.respond_to?(:tone=)
        reply.phrase_id = nil if reply.respond_to?(:phrase_id=)
        reply.sticker = nil if reply.respond_to?(:sticker=) && Decidim::Bih::Concierge::Stickers::PERSONA_IDS.any? { |id| id.to_s == reply.sticker.to_s }
        reply
      end

      def selected_tone
        return "core" if red_zone?
        return "neighborly" unless phrase_locale?
        return "neighborly" if yellow_zone? || playful_limit_reached?

        return "playful" if deterministic_percent < playful_probability
        return "neighborly" if deterministic_percent < 85

        "core"
      end

      def red_zone?
        CORE_INTENTS.include?(intent) || uppercase_distress? || two_failed_attempts? ||
          contains_any?(message_text, RED_ZONE_TERMS) ||
          contains_any?(message_text, FRUSTRATION_TERMS) ||
          contains_any?(message_text, PROFANITY_TERMS) ||
          contains_any?(reply.text, %w(neuspjel neuspel gresk grešk nije sacuvan nije sačuvan istekao)) ||
          contains_any?(reply.text, [
                          "nije moguće", "nije moguce", "ne može", "ne moze", "odbijen", "odbijena",
                          "uklonjen", "uklonjena", "verifikacioni kod", "verifikacijski kod", "verification code",
                          "broj telefona", "phone number", "kod je istekao", "code expired"
                        ])
      end

      def yellow_zone?
        YELLOW_INTENTS.include?(intent) || contains_any?(message_text, %w(novac donacij plat uplata))
      end

      def playful_probability
        return 15 if formal_message?
        return 50 if positive_message? || tone_history.include?("playful")

        40
      end

      def playful_limit_reached?
        tone_history.last(10).count("playful") >= MAX_PLAYFUL_IN_TEN
      end

      def tone_history
        @tone_history ||= begin
          stored = Array(context.last&.fetch("tone_history", nil)).filter_map { |tone| bounded_tone(tone) }
          stored.presence || context.filter_map { |turn| bounded_tone(turn["tone"]) }
        end
      end

      def bounded_tone(value)
        value.to_s if %w(core neighborly playful).include?(value.to_s)
      end

      def two_failed_attempts?
        recent = context.last(2)
        recent.length == 2 && recent.all? do |turn|
          FAILED_INTENTS.include?(turn["answer_intent"].to_s) ||
            contains_any?(turn["bot"], %w(nisam pronasla nisam pronašla nije uspjelo nije uspelo zapelo))
        end
      end

      def select_phrase
        candidates = phrase_entries(cue).reject { |entry| ineligible_phrase?(entry) }
        return if candidates.empty?

        candidates.fetch(deterministic_index(candidates.length))
      end

      def ineligible_phrase?(entry)
        recent_phrase?(entry) || repeated_nickname?(entry) || extra_question?(entry)
      end

      def recent_phrase?(entry)
        recent = context.last(RECENT_PHRASE_WINDOW)
        return true if recent.filter_map { |turn| turn["phrase_id"].presence }.include?(entry.fetch("id"))

        phrase = Decidim::Bih::Text.fold(localized(entry.fetch("text")))
        recent.filter_map { |turn| turn["bot"].presence }.any? do |text|
          Decidim::Bih::Text.fold(text).include?(phrase)
        end
      end

      def repeated_nickname?(entry)
        nickname_text?(entry.fetch("text")) && context.any? { |turn| nickname_text?(turn["bot"]) }
      end

      # A completed civic answer may already need one clarifying question. The
      # personality layer never adds a second one just for character.
      def extra_question?(entry)
        reply.text.to_s.include?("?") && entry.fetch("text").include?("?")
      end

      def phrase_entries(group)
        Array(self.class.config.dig("phrases", group)).each_with_index.map do |text, index|
          { "id" => "#{group}.#{format("%02d", index + 1)}", "text" => text.to_s }
        end
      end

      def attach_media
        return unless MEDIA_CHANNELS.include?(channel)
        return unless reply.respond_to?(:sticker=) && reply.sticker.blank?

        media_id = self.class.config.dig("media", cue).to_s.presence
        reply.sticker = media_id.to_sym if media_id && Decidim::Bih::Concierge::Stickers::IDS.include?(media_id.to_sym)
      end

      def cue
        return "empty" if empty_result?
        # A question mark identifies a clarification, not its topic. The full
        # phrase bank also contains requests specific to gazettes, transport
        # and reports; those must not add a different task to this question.
        return "clarify_generic" if clarification_reply?
        return CUE_BY_TOPIC.fetch(topic) { CUE_BY_INTENT.fetch(intent) } if intent == "service"

        CUE_BY_INTENT.fetch(intent, "search")
      end

      # The typed outcome owns clarification. A URL query ("?tab=kako") or
      # a quoted question in a completed answer must not ask for more input.
      def clarification_reply?
        outcome = reply.dialogue_outcome if reply.respond_to?(:dialogue_outcome)
        return outcome.resolution == "clarification" if outcome.respond_to?(:resolution)

        reply.text.to_s.gsub(%r{(?:https?://|/)[^\s]+}, "").include?("?")
      end

      def factual?
        FACTUAL_INTENTS.include?(intent) && !green_zone_service?
      end

      def green_zone_service?
        intent == "service" && GREEN_TOPICS.include?(topic)
      end

      # The dialogue outcome travels on the reply (WebConcierge attaches it
      # before the voice runs); read it the way the web chat controller does.
      def topic
        @topic ||= begin
          outcome = reply.dialogue_outcome if reply.respond_to?(:dialogue_outcome)
          Decidim::Bih::Concierge::ReplyOutcome.from(outcome)&.topic || "unknown"
        rescue StandardError
          "unknown"
        end
      end

      def empty_result?
        contains_any?(reply.text, [
                        "nisam pronašla", "nisam pronašao", "nemam pouzdan", "nema pouzdan",
                        "nije pronađen", "nije pronadjen", "could not find", "no reliable"
                      ])
      end

      def deterministic_percent
        @deterministic_percent ||= deterministic_number(100)
      end

      def deterministic_index(size)
        deterministic_number(size, salt: cue)
      end

      def deterministic_number(modulo, salt: "tone")
        source = [channel, intent, message_text, context.length, salt].join("\0")
        Digest::SHA256.hexdigest(source).first(12).to_i(16) % modulo
      end

      def formal_message?
        contains_any?(message_text, FORMAL_TERMS)
      end

      def positive_message?
        contains_any?(message_text, POSITIVE_TERMS)
      end

      def uppercase_distress?
        letters = message_text.scan(/\p{L}/)
        letters.length >= 6 && letters.count { |letter| letter == letter.upcase } * 100 / letters.length >= 80
      end

      def contains_any?(value, terms)
        folded = Decidim::Bih::Text.fold(value.to_s)
        Array(terms).any? { |term| folded.include?(Decidim::Bih::Text.fold(term.to_s)) }
      end

      def nickname_text?(value)
        value.to_s.match?(/\b(?:Mica|Mil['’]ca)\b/i)
      end

      def localized(text)
        return text unless cyrillic_message?

        Decidim::Bih::Transliterator.call(text)
      end

      def cyrillic_message?
        cyrillic = message_text.scan(/\p{Cyrillic}/).size
        latin = message_text.scan(/[A-Za-z]/).size
        cyrillic > latin
      end

      # The phrase bank is written once, in Serbian Latin. It reads naturally
      # in every language that is a script or dialect away from it, and in no
      # other — so an English reply must never be given one.
      #
      # The locale that decides this is the REPLY's, not I18n's. I18n.locale is
      # the language of the page the widget is embedded in, and this site is
      # Serbian: an English-speaking visitor reading a Serbian page still had
      # I18n.locale == "sr", so every English answer opened with an
      # untranslated Serbian line ("Da vidimo kad kese zvanično kreću na put."
      # above an otherwise fully English waste answer, measured on production
      # 14.09.2026). The coordinator stamps the reply with the language it
      # actually wrote, and that is what is read here. A reply that states no
      # locale falls back to I18n.locale exactly as before.
      PHRASE_LOCALES = %w(sr sr-Cyrl bs hr).freeze

      def phrase_locale?
        PHRASE_LOCALES.include?(reply_locale)
      end

      def reply_locale
        locale = reply.locale if reply.respond_to?(:locale)
        locale.to_s.presence || I18n.locale.to_s
      end

      def context
        @context ||= if message.respond_to?(:conversation_context)
                       Array(message.conversation_context).last(10).filter_map do |turn|
                         turn.to_h.deep_stringify_keys if turn.respond_to?(:to_h)
                       end
                     else
                       []
                     end
      end

      def message_text
        message.respond_to?(:text) ? message.text.to_s : ""
      end

      def intent
        Decidim::Bih::Concierge::AnswerIntents.sanitize(reply.answer_intent)
      end
    end
  end
end
