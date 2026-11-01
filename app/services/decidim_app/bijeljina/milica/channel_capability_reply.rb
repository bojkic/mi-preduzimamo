# frozen_string_literal: true

require_relative "../chat_text_rendering"

module DecidimApp
  module Bijeljina
    module Milica
      # Explains where to continue without turning configuration into evidence
      # of delivery. The existing public introduction owns launch approval and
      # safe entry links; this reply never reproduces private provider settings.
      module ChannelCapabilityReply
        CHANNEL_WORD = /(?:messenger\p{L}*|instagram\p{L}*|viber\p{L}*|whatsapp\p{L}*|kanal\p{L}*|channels?)/i
        AVAILABILITY = /(?:milic\p{L}*.{0,45}(?:radi|dostup|podrz|work|availab))|
          (?:(?:radi|dostup\p{L}*|podrz\p{L}*|work\p{L}*|availab\p{L}*).{0,60}#{CHANNEL_WORD})|
          (?:#{CHANNEL_WORD}.{0,25}(?:radi|work\p{L}*|available))|
          (?:(?:provjer\p{L}*|prover\p{L}*|potvrd\p{L}*|verified|tested|confirm\p{L}*).{0,70}(?:poruk\p{L}*|odgovor\p{L}*|kanal\p{L}*|messages?|channels?))|
          (?:poruke\ stizu|messages\ arrive)/ix
        CHANNEL_NAMES = { "web_chat" => "web chat", "messenger" => "Messenger", "instagram" => "Instagram",
                          "whatsapp" => "WhatsApp", "viber_bm" => "Viber", "viber" => "Viber" }.freeze
        COPY = {
          "sr" => ["Ovaj razgovor: %{channel}. Možeš nastaviti ovdje.",
                   "Opcije za javljanje Milici: %{url}",
                   "Nemam potvrdu da su poruke i odgovori provjereni na svakom drugom kanalu."],
          "sr-Cyrl" => ["Овај разговор: %{channel}. Можеш наставити овдје.",
                        "Опције за јављање Милици: %{url}",
                        "Немам потврду да су поруке и одговори провјерени на сваком другом каналу."],
          "en" => ["This conversation: %{channel}. You can continue here.",
                   "Ways to contact Milica: %{url}",
                   "I cannot confirm that messages and replies have been verified on every other channel."]
        }.freeze

        IDENTITY_QUESTION = /\A
          (?:(?:pisem|javljam\ se|na|i\ am\ writing)\s+(?:iz|preko|s|sa|on|from)?\s*
            (?:facebook\s+)?(?:instagram\w*|messenger\w*|viber\w*|whatsapp\w*)(?:\s+sam)?\s+)?
          (?:(?:vidis|vidite|znas|znate)\s+li(?:\s+sada)?\s+(?:moj\s+broj(?:\s+telefona)?|moj\s+telefon)
            \s+i\s+koliko\s+imam\s+(?:bodova|poena)|
            (?:can|do)\s+you\s+(?:see|know)\s+my\s+phone\s+number\s+and\s+how\s+many\s+points\s+i\s+have)
          \z/x
        PUBLIC_TRANSPORT_WITHOUT_PHONE = /\A(?:
          (?:ne\s+zelim|necu)\s+(?:dijeliti|deliti|dati|slati)\s+(?:svoj\s+)?broj(?:\s+telefona)?\s+
            mogu\s+li\s+(?:ipak\s+)?pitati\s+(?:za|o)\s+(?:autobus\w*|javni\s+prevoz|javni\s+prijevoz)|
          i\s+don\s*t\s+want\s+to\s+share\s+my\s+phone\s+number\s+can\s+i\s+still\s+ask\s+about\s+(?:buses|public\s+transport)
          )\z/x
        PUBLIC_TRANSPORT_COPY = {
          "sr" => "Da, možeš pitati za autobus bez dijeljenja broja telefona ili prijave na nalog. Od kojeg stajališta ili mjesta krećeš i gdje želiš stići?",
          "sr-Cyrl" => "Да, можеш питати за аутобус без дијељења броја телефона или пријаве на налог. Од којег стајалишта или мјеста крећеш и гдје желиш стићи?",
          "hr" => "Da, možeš pitati za autobus bez dijeljenja broja telefona ili prijave na račun. Od kojeg stajališta ili mjesta krećeš i kamo želiš stići?",
          "en" => "Yes, you can ask about buses without sharing a phone number or signing in. Which stop or place are you leaving from, and where would you like to go?"
        }.freeze
        IDENTITY_COPY = {
          "sr" => ["Naziv aplikacije u poruci ne potvrđuje tvoj MI nalog. Ni broj koji kanal eventualno proslijedi nije dovoljan za pristup bodovima.",
                   "Ovaj razgovor nema potvrđenu vezu s tvojim MI nalogom, pa ne mogu prikazati tvoje bodove. Prijavi se: %{url}",
                   "Za javna pitanja, poput reda vožnje, nije potrebno dijeliti broj telefona.",
                   "Trenutno ne mogu pouzdano provjeriti tvoje bodove. Pogledaj svoj nalog: %{url}"],
          "sr-Cyrl" => ["Назив апликације у поруци не потврђује твој МИ налог. Ни број који канал евентуално прослиједи није довољан за приступ бодовима.",
                        "Овај разговор нема потврђену везу с твојим МИ налогом, па не могу приказати твоје бодове. Пријави се: %{url}",
                        "За јавна питања, попут реда вожње, није потребно дијелити број телефона.",
                        "Тренутно не могу поуздано провјерити твоје бодове. Погледај свој налог: %{url}"],
          "hr" => ["Naziv aplikacije u poruci ne potvrđuje tvoj MI račun. Ni broj koji kanal eventualno proslijedi nije dovoljan za pristup bodovima.",
                   "Ovaj razgovor nema potvrđenu vezu s tvojim MI računom, pa ne mogu prikazati tvoje bodove. Prijavi se: %{url}",
                   "Za javna pitanja, poput voznog reda, nije potrebno dijeliti broj telefona.",
                   "Trenutno ne mogu pouzdano provjeriti tvoje bodove. Pogledaj svoj račun: %{url}"],
          "en" => ["Naming an app does not verify your MI account. A phone number the channel may provide is not enough to access your points.",
                   "This conversation has no verified link to your MI account, so I cannot show your points. Sign in: %{url}",
                   "You do not need to share a phone number to ask public questions such as bus timetables.",
                   "I cannot reliably check your points right now. View your account: %{url}"]
        }.freeze

        module_function

        def call(message:, channel:, organization:)
          return unless question?(message.text.to_s)
          return if Decidim::Bih::Concierge::EmergencySignal.assess(message.text.to_s)
          return unless organization && organization.host.to_s.present?

          locale = locale_for(message.text.to_s)
          name = CHANNEL_NAMES.fetch(channel.to_s, locale == "en" ? "this chat" : "chat")
          url = "https://#{organization.host}#{Decidim::Bih.public_path("mi-bot")}"
          text = COPY.fetch(locale).map { |line| format(line, channel: name, url:) }.join("\n\n")
          Decidim::Bih::Concierge::Responder::Reply.new(text:, report: nil, quick_replies: [], answer_intent: "setup", tone: "core", locale:)
        end

        def question?(text)
          folded = Decidim::Bih::Text.fold(text)
          return false if folded.match?(/\A(?:posalji prijavu|submit report|odustani)\b/)

          folded.match?(CHANNEL_WORD) && folded.match?(AVAILABILITY)
        end

        def identity_question?(text)
          text.is_a?(String) && text.length.between?(1, 300) && IDENTITY_QUESTION.match?(Decidim::Bih::Text.fold(text))
        end

        def identity_locale_for(text)
          return "en" if text.match?(/\b(?:can|do)\s+(?:you|i)\b/i)

          return "sr-Cyrl" if text.match?(/\p{Cyrillic}/)
          return I18n.locale.to_s if %w(bs hr en).include?(I18n.locale.to_s)

          "sr"
        end

        def identity_reply(message:, organization:, linked:, balance_reply: nil)
          return unless organization && organization.host.to_s.present?

          locale = identity_locale_for(message.text.to_s)
          copy = IDENTITY_COPY.fetch(locale == "bs" ? "sr" : locale)
          account = identity_account_text(organization:, linked:, balance_reply:, copy:)
          account = ChatTextRendering.absolute_links(account, host: organization.host)
          text = [copy.fetch(0), account, copy.fetch(2)].join("\n\n")
          intent = linked && balance_reply.nil? ? "fallback" : "setup"
          Decidim::Bih::Concierge::Responder::Reply.new(text:, report: nil, quick_replies: [], answer_intent: intent, tone: "core", locale:)
        end

        def identity_account_text(organization:, linked:, balance_reply:, copy:)
          return balance_reply.text if balance_reply

          path = linked ? Decidim::Bih.public_path("moj-nalog") : "/users/sign_in"
          format(copy.fetch(linked ? 3 : 1), url: "https://#{organization.host}#{path}")
        end

        def public_transport_without_phone?(text)
          text.is_a?(String) && text.length.between?(1, 300) && PUBLIC_TRANSPORT_WITHOUT_PHONE.match?(Decidim::Bih::Text.fold(text))
        end

        def public_transport_permission_reply(message:)
          locale = identity_locale_for(message.text.to_s)
          text = PUBLIC_TRANSPORT_COPY.fetch(locale == "bs" ? "sr" : locale)
          Decidim::Bih::Concierge::Responder::Reply.new(text:, report: nil, quick_replies: [], answer_intent: "service", tone: "core", locale:)
        end

        def locale_for(text)
          return "sr-Cyrl" if text.match?(/\p{Cyrillic}/)
          return "en" if text.match?(/\b(?:does|which|available|verified|tested|messages|channels)\b/i)

          "sr"
        end
      end
    end
  end
end
