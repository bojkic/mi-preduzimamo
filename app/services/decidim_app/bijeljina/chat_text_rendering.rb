# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    # Renders a concierge reply as the plain text a phone messenger can show.
    #
    # The brain writes for the web widget: root-relative paths that the page
    # origin resolves, and quick-reply chips the widget draws as buttons. A
    # chat app has neither. Viber Business Messages, WhatsApp, Messenger and
    # Instagram all get the same three-step rendering here — links made
    # absolute on the organization host, chips written out as lines, and the
    # text capped per channel at a sentence boundary that never loses the
    # first link (channels review 2026-09-12, section E, P1 rows; spec 1.6).
    #
    # This module owns its citizen-facing copy: the bullet, the "Odgovori:"
    # prompt and the Serbian quotation marks are literals, not i18n keys.
    module ChatTextRendering
      # Characters, not bytes. These are conservative working values, not
      # documented provider maxima — the repository records no per-product
      # limit, and the channels review deliberately asserts none.
      # Decidim::Bih::Infobip::SendChatTextJob still cuts at 4096 BYTES as the
      # last line of defence; the shared limiter applies that byte cap here
      # too, preserving links and instructions before enqueueing.
      MAX_TEXT = {
        "viber_bm" => 1000,
        "whatsapp" => 4096,
        "messenger" => 2000,
        "instagram" => 1000
      }.freeze
      DEFAULT_MAX_TEXT = 4096

      # The pattern matches any path-shaped token that starts a word. A path
      # already inside an absolute URL cannot match: the "/" after the host is
      # preceded by a letter, not by a space or a bracket.
      #
      # A sentence-ending period lands inside the character class, so
      # "…/registracija." keeps its period — exactly as the copy wrote it. That
      # is a copy question (put the link last, or follow it with a space, as
      # the SMS texts do) and belongs to whoever owns the copy, not here.
      ROOT_RELATIVE_PATH = %r{(?<=\A|[\s(])(/[A-Za-z0-9][A-Za-z0-9\-_./?=&%]*)}

      CHOICE_BULLET = "• "
      CHOICES_PROMPT = "Odgovori:"
      CHOICE_LIST_SEPARATOR = ", "
      CHOICE_LAST_SEPARATOR = " ili "
      OPEN_QUOTE = "„"
      CLOSE_QUOTE = "”"
      CHOICES_GAP = "\n\n"
      DEFAULT_CHOICE_LIMIT = 3
      OVERSIZE_REPLY = "Odgovor je predugačak za ovu poruku. Napiši kraće pitanje ili izdvoji jedan korak."
      CONVERSATION_START = "Možeš razgovarati s Milicom ovdje — samo odgovori na ovu poruku."

      module_function

      # The full rendering for one outbound message. +reply+ is a String or
      # anything with #text (and optionally #quick_replies).
      def render(channel:, reply:, host:, first_turn: false)
        text = reply_text(reply)
        return text if text.blank?

        text = "#{CONVERSATION_START}\n\n#{text}" if first_turn
        truncate_for(channel, append_choices(absolute_links(text, host:), reply_quick_replies(reply), host:))
      rescue Decidim::Bih::Infobip::BoundedChatText::TooLong
        safe_channel = MAX_TEXT.has_key?(channel.to_s) ? channel.to_s : "unknown"
        Rails.logger.warn("[ChatTextRendering] required_content_overflow channel=#{safe_channel}") if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
        OVERSIZE_REPLY
      end

      def absolute_links(text, host:)
        text = text.to_s
        return text if host.blank?

        text.gsub(ROOT_RELATIVE_PATH) { "https://#{host}#{Regexp.last_match(1)}" }
      end

      # Chips are Hashes (symbol or string keys) with +label+ and either +url+
      # (absolute or root-relative) or +send+ (the text the citizen types
      # back); an object with #label and #url is accepted as a url chip. Url
      # chips become one bullet line each; send chips share one "Odgovori:"
      # line. At most +limit+ chips are used, so at most +limit+ + 1 lines are
      # added.
      def append_choices(text, quick_replies, host:, limit: DEFAULT_CHOICE_LIMIT)
        chips = normalize_chips(quick_replies).first(limit)
        return text if chips.empty?

        lines = chips.filter_map { |chip| chip[:url] && "#{CHOICE_BULLET}#{chip[:label]}: #{absolute_url(chip[:url], host:)}" }
        typed = chips.filter_map { |chip| chip[:send] }
        lines << "#{CHOICES_PROMPT} #{quoted_alternatives(typed)}" if typed.any?
        "#{text.to_s.rstrip}#{CHOICES_GAP}#{lines.join("\n")}"
      end

      # Reserve links, exact commands and qualifications before shortening
      # prose against both the channel character cap and the send-job byte cap.
      def truncate_for(channel, text)
        Decidim::Bih::Infobip::BoundedChatText.call(
          text, max_chars: MAX_TEXT.fetch(channel.to_s, DEFAULT_MAX_TEXT)
        )
      end

      def reply_text(reply)
        reply.respond_to?(:text) ? reply.text.to_s : reply.to_s
      end

      def reply_quick_replies(reply)
        reply.respond_to?(:quick_replies) ? Array(reply.quick_replies) : []
      end

      def normalize_chips(quick_replies)
        Array(quick_replies).filter_map do |chip|
          next if chip.blank?

          label = chip_value(chip, :label).to_s.strip
          url = chip_value(chip, :url).to_s.strip
          typed = chip_value(chip, :send).to_s.strip
          next if label.blank? || (url.blank? && typed.blank?)

          { label:, url: url.presence, send: typed.presence }
        end
      end

      # +send+ is read from Hashes only: every Ruby object already answers
      # #send, so on an object it can never mean a chip attribute.
      def chip_value(chip, key)
        if chip.respond_to?(:key?)
          chip[key] || chip[key.to_s]
        elsif key != :send && chip.respond_to?(key)
          chip.public_send(key)
        end
      end

      def absolute_url(url, host:)
        url.start_with?("/") ? absolute_links(url, host:) : url
      end

      def quoted_alternatives(labels)
        quoted = labels.map { |label| "#{OPEN_QUOTE}#{label}#{CLOSE_QUOTE}" }
        return quoted.first if quoted.one?

        "#{quoted[0...-1].join(CHOICE_LIST_SEPARATOR)}#{CHOICE_LAST_SEPARATOR}#{quoted.last}"
      end
    end
  end
end
