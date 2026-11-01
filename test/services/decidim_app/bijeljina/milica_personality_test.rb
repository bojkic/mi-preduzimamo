# frozen_string_literal: true

require "test_helper"
require "yaml"

module DecidimApp
  module Bijeljina
    class MilicaPersonalityTest < ActiveSupport::TestCase
      Message = Struct.new(:text, :conversation_context, keyword_init: true)
      BARE_ANSWER = "Checked and calm answer."

      setup do
        MilicaPersonality.reset!
      end

      test "catalog contains every approved section-six source phrase" do
        source = Rails.root.join("docs/Komsinica_Milica_banka_fraza_v1_1.md").read
        section = source.split("## 6. Proširena šaljiva i opuštena banka fraza", 2).last
                        .split("## 7. Fraze koje treba ukloniti ili ograničiti", 2).first
        approved = section.scan(/^- \*\*(.+)\*\*$/).flatten
        catalog = MilicaPersonality.config.fetch("phrases").values.flatten

        assert_operator approved.length, :>=, 160
        assert_empty approved - catalog
      end

      test "a neighborhood clarification cannot acquire an unrelated gazette or transport request" do
        question = "Šta želiš pogledati: javne prijave, servisne informacije ili objave članova?"
        reply = build_reply(text: question, answer_intent: "komsiluk_read")
        reply.tone = "playful"
        result = I18n.with_locale(:sr) { apply(message: "Šta ima u mom komšiluku?", reply:, answer_intent: "komsiluk_read") }

        assert_equal "clarify_generic.01", result.phrase_id
        assert_equal "Daj mi još jednu mrvu podatka pa nastavljamo.\n\n#{question}", result.text
        assert_equal 1, result.text.count("?")
        assert_no_match(/glasnik|autobus|parking|broj prijave/i, result.text)
      end

      test "safe replies follow the configured forty forty-five fifteen mix" do
        counts = Hash.new(0)

        I18n.with_locale(:sr) do
          600.times do |index|
            result = apply(message: "obično pitanje #{index}")
            counts[result.tone] += 1
          end
        end

        assert_in_delta 0.40, counts["playful"] / 600.0, 0.06
        assert_in_delta 0.45, counts["neighborly"] / 600.0, 0.06
        assert_in_delta 0.15, counts["core"] / 600.0, 0.05
      end

      test "red-zone text is fixed core and receives neither phrase nor media" do
        I18n.with_locale(:sr) do
          [
            "Neko mi prijeti i u opasnosti sam",
            "Moj JMBG je 123",
            "OVO NE RADI OPET",
            "Jebeno sam ljut"
          ].each do |text|
            result = apply(message: text, answer_intent: "safety")

            assert_equal "core", result.tone
            assert_nil result.phrase_id
            assert_nil result.sticker
            assert_equal "Provjeren i miran odgovor.", result.text
          end
        end
      end

      test "verification and negative-status replies remain core without explicit intent metadata" do
        I18n.with_locale(:sr) do
          [
            ["poveži nalog", "Verifikacioni kod je poslan SMS-om."],
            ["provjeri BR-2026-0001", "Prijava je odbijena jer nije moguće postupiti."]
          ].each do |message, reply_text|
            result = apply(
              message:,
              answer_intent: nil,
              reply: build_reply(text: reply_text, answer_intent: nil)
            )

            assert_equal "core", result.tone
            assert_nil result.phrase_id
            assert_nil result.sticker
            assert_equal reply_text, result.text
          end
        end
      end

      test "formal prompts cap playful variants at fifteen percent" do
        playful = I18n.with_locale(:sr) do
          400.times.count do |index|
            apply(message: "Poštovani, možete li provjeriti podatak #{index}?").tone == "playful"
          end
        end

        assert_operator playful / 400.0, :<=, 0.20
      end

      test "four playful replies in ten force the next safe reply to neighborly" do
        context = 4.times.map do |index|
          { "user" => "pitanje #{index}", "bot" => "odgovor", "tone" => "playful", "phrase_id" => "search.0#{index + 1}" }
        end

        result = I18n.with_locale(:sr) { apply(message: "još jedno pitanje", context:) }

        assert_equal "neighborly", result.tone
        assert_nil result.phrase_id
        assert_nil result.sticker
      end

      test "compact ten-turn tone history enforces the limit beyond retained transcript turns" do
        context = [
          {
            "user" => "najnovije pitanje",
            "bot" => "najnoviji odgovor",
            "tone" => "neighborly",
            "tone_history" => %w(playful neighborly playful core playful neighborly playful)
          }
        ]

        result = I18n.with_locale(:sr) { apply(message: "još jedno pitanje", context:) }

        assert_equal "neighborly", result.tone
        assert_nil result.phrase_id
      end

      test "playful selection does not repeat six recent phrases or a session nickname" do
        context = [
          { "bot" => "Mica je tu.", "tone" => "playful", "phrase_id" => "search.01" },
          { "bot" => "ranije", "tone" => "playful", "phrase_id" => "search.02" },
          { "bot" => "ranije", "tone" => "neighborly", "phrase_id" => "search.03" }
        ]
        reply = build_reply(tone: "playful")

        result = I18n.with_locale(:sr) { apply(message: "nađi podatak", context:, reply:) }

        assert_not_includes %w(search.01 search.02 search.03), result.phrase_id
        assert_no_match(/\b(?:Mica|Mil['’]ca)\b/i, result.text)
      end

      test "duplicate phrase text cannot repeat under a different cue id" do
        context = [
          { "bot" => "Klik je dobar početak; zasukani rukavi su još bolji.", "phrase_id" => "community.04" },
          { "bot" => "ranije", "phrase_id" => "action.02" },
          { "bot" => "ranije", "phrase_id" => "action.03" },
          { "bot" => "ranije", "phrase_id" => "action.04" },
          { "bot" => "ranije", "phrase_id" => "action.05" }
        ]
        reply = build_reply(answer_intent: "volunteer_guidance", tone: "playful")

        result = I18n.with_locale(:sr) { apply(message: "želim volontirati", context:, reply:) }

        assert_nil result.phrase_id
        assert_equal "Provjeren i miran odgovor.", result.text
      end

      test "a completed answer with one question never receives a second question" do
        reply = build_reply(text: "Na koju ulicu se pitanje odnosi?", tone: "playful")

        result = I18n.with_locale(:sr) { apply(message: "parking", reply:) }

        assert_equal 1, result.text.count("?")
      end

      # The voice is the same everywhere; the persona IMAGE is not. It travels as
      # a second Infobip message, so on a paid channel it doubles the outbound
      # count for a gesture nobody asked for (review 2026-09-07, lane 4 M4).
      test "the approved phrase reaches every channel, the persona image only the web widget" do
        I18n.with_locale(:sr) do
          MilicaPersonality::CHANNELS.each do |channel|
            result = apply(message: "pronađi podatak", reply: build_reply(tone: "playful"), channel:)

            assert result.phrase_id.present?, channel

            if MilicaPersonality::MEDIA_CHANNELS.include?(channel)
              assert_includes Decidim::Bih::Concierge::Stickers::PERSONA_IDS, result.sticker, channel
            else
              assert_nil result.sticker, "#{channel} must not pay for a second message"
            end
          end
        end
      end

      test "Cyrillic prompt receives a Cyrillic approved phrase" do
        result = I18n.with_locale(:"sr-Cyrl") do
          apply(message: "Пронађи податак", reply: build_reply(tone: "playful"))
        end

        assert_match(/\p{Cyrillic}/, result.text.lines.first)
        assert_no_match(/[A-Za-z]{4}/, result.text.lines.first)
      end

      test "a waste fact draws its phrase from the waste cue, never a bus or parking line" do
        seen = false
        I18n.with_locale(:sr) do
          40.times do |index|
            reply = build_reply(text: "Odvoz otpada za „Karađorđeva“: srijeda.", answer_intent: "waste")
            result = apply(message: "kad se odvozi smece u Karadjordjevoj #{index}", reply: with_topic(reply, "waste"))
            next unless result.tone == "playful"

            seen = true
            assert result.phrase_id.start_with?("waste."), result.phrase_id
            phrase = result.text.split("\n\n", 2).first
            assert_includes MilicaPersonality.config.dig("phrases", "waste"), phrase
            refute_match(/autobus|polazak|parking|zona/i, phrase)
          end
        end
        assert seen, "the deterministic mix must select playful for some waste messages"
      end

      test "green-zone service facts speak with the approved voice from the topic's cue" do
        tones = Hash.new(0)
        I18n.with_locale(:sr) do
          40.times do |index|
            reply = build_reply(text: "Centar: crvena zona, 1 KM po satu.", answer_intent: "service")
            result = apply(message: "koliko kosta parking u centru #{index}", reply: with_topic(reply, "parking"))

            tones[result.tone] += 1
            # The configured 40/45/15 mix applies: playful, neighborly or plain core.
            assert_includes %w(core neighborly playful), result.tone
            assert_includes result.text, "Centar: crvena zona, 1 KM po satu."
            next unless result.tone == "playful"

            assert result.phrase_id.start_with?("parking."), result.phrase_id
            phrase = result.text.split("\n\n", 2).first
            assert_includes MilicaPersonality.config.dig("phrases", "parking"), phrase
            assert_equal "#{phrase}\n\nCentar: crvena zona, 1 KM po satu.", result.text
          end
        end
        assert_operator tones["playful"], :>, 0, "the deterministic mix must select playful for some messages"

        budget = I18n.with_locale(:sr) do
          apply(message: "budzet za sport 7", reply: with_topic(build_reply(text: "Sport: 300.000 KM.", answer_intent: "service", tone: "playful"), "budget"))
        end
        assert budget.phrase_id.start_with?("public_data."), budget.phrase_id
      end

      test "other service topics and setup stay factual and red-zone rules are unchanged" do
        I18n.with_locale(:sr) do
          electricity_reply = build_reply(text: "Nema najavljenih isključenja.", answer_intent: "service", tone: "playful")
          electricity = apply(message: "ima li struje u dvorovima", reply: with_topic(electricity_reply, "electricity"))
          assert_equal "neighborly", electricity.tone
          assert_nil electricity.phrase_id
          assert_equal "Nema najavljenih isključenja.", electricity.text

          setup_reply = apply(message: "kako da se registrujem", reply: with_topic(build_reply(text: "Nalog otvaraš ovdje.", answer_intent: "setup", tone: "playful"), "parking"))
          assert_equal "neighborly", setup_reply.tone
          assert_nil setup_reply.phrase_id

          untopiced = apply(message: "koliko kosta parking", reply: build_reply(text: "Centar: crvena zona.", answer_intent: "service", tone: "playful"))
          assert_nil untopiced.phrase_id, "without a dialogue outcome a service reply stays factual"

          angry = apply(message: "OVO NE RADI OPET", reply: with_topic(build_reply(text: "Centar: crvena zona.", answer_intent: "service"), "parking"))
          assert_equal "core", angry.tone
          assert_nil angry.phrase_id
        end
      end

      # Task 7: the persona layer is the last one to run and only ever adds,
      # so it is the one place that can check the finished text. A flourish is
      # optional; the answer fitting in a citizen's screen is not.
      test "a phrase is dropped when the decorated reply would not fit the concise budget" do
        I18n.with_locale(:sr) do
          long = "Obavještenje o radovima u komšiluku. " * 16

          assert_operator long.length, :>, MilicaPersonality::CONCISE_BUDGET - 80

          result = apply(message: "sta ima novo u komsiluku", reply: build_reply(text: long, tone: "playful"))

          assert_equal long, result.text, "the decorated text would have exceeded the budget"
          assert_nil result.phrase_id
        end
      end

      test "a short reply still gets its phrase" do
        I18n.with_locale(:sr) do
          result = apply(message: "sta ima novo", reply: build_reply(text: "Kratko i jasno.", tone: "playful"))

          assert result.phrase_id.present?, "a reply well inside the budget keeps the voice"
          assert result.text.end_with?("Kratko i jasno.")
          assert_operator result.text.length, :<=, MilicaPersonality::CONCISE_BUDGET
        end
      end

      # Emergencies were already core; corrections and procedures were not.
      test "corrections and procedures get the plain voice even when asked for playful" do
        I18n.with_locale(:sr) do
          correction = apply(message: "Ispravka: treba mi za Baje Pivljanina.",
                             reply: build_reply(text: "Prekid vode je najavljen do 14:30.", tone: "playful"))

          assert_equal "neighborly", correction.tone
          assert_nil correction.phrase_id

          procedure = apply(message: "kako da prijavim problem",
                            reply: build_reply(text: "Prijavu otvaraš ovdje.", answer_intent: "report_guidance", tone: "playful"))

          assert_equal "neighborly", procedure.tone
          assert_nil procedure.phrase_id

          emergency = apply(message: "Neko mi prijeti", reply: build_reply(text: "Zovi 122.", answer_intent: "safety", tone: "playful"))

          assert_equal "core", emergency.tone, "an upstream playful tone never survives the red zone"
          assert_nil emergency.phrase_id
        end
      end

      # R7. Measured on production on 14.09.2026: an English question about
      # waste collection came back as
      #
      #   Da vidimo kad kese zvanično kreću na put.
      #
      #   Notices below are quoted in Serbian, exactly as the source published
      #   them.
      #
      #   Waste collection for "Patkovaca": srijeda, četvrtak. …
      #
      # The phrase bank is Serbian and this site is Serbian, so I18n.locale
      # said "sr" however the citizen wrote — I18n.locale is the language of
      # the PAGE. The coordinator now stamps every reply with the language it
      # actually wrote, and that is what decides the voice.
      test "an english reply never receives the serbian phrase bank" do
        decorated = 0
        I18n.with_locale(:sr) do
          60.times do |index|
            result = MilicaPersonality.call(
              reply: stamped_reply("en"),
              message: Message.new(text: "when is the garbage collected #{index}", conversation_context: []),
              channel: "web_chat"
            )
            decorated += 1 unless result.text == BARE_ANSWER
            assert_nil result.phrase_id, result.text
            assert_not_equal "playful", result.tone, result.text
          end
        end

        assert_equal 0, decorated
      end

      # The same messages, the same site, the same deterministic tone draw —
      # only the language the reply was written in differs. Without this the
      # test above would pass on a phrase bank that had simply stopped working.
      test "the same replies in a local language still get the voice" do
        %w(sr sr-Cyrl bs hr).each do |locale|
          decorated = 0
          I18n.with_locale(:sr) do
            60.times do |index|
              result = MilicaPersonality.call(
                reply: stamped_reply(locale),
                message: Message.new(text: "when is the garbage collected #{index}", conversation_context: []),
                channel: "web_chat"
              )
              decorated += 1 unless result.text == BARE_ANSWER
            end
          end

          assert_operator decorated, :>, 0, locale
        end
      end

      # Viber and the legacy brain build replies that state no language. They
      # must keep behaving exactly as they did, on the request's locale.
      test "a reply that states no language keeps the request locale" do
        decorated = 0
        I18n.with_locale(:sr) do
          60.times do |index|
            result = apply(message: "kada se odvozi smeće #{index}")
            decorated += 1 unless result.text == "Provjeren i miran odgovor."
          end
        end

        assert_operator decorated, :>, 0
      end

      private

      def with_topic(reply, topic)
        outcome = Decidim::Bih::Concierge::Dialogue::ProcedureRunner::Result.new(
          state: { "topic" => topic }, reply:, resolution: "answered", fact_ids: ["fact:1"], handoff_offered: false, handoff_completed: false
        )
        reply.define_singleton_method(:dialogue_outcome) { outcome }
        reply
      end


      # Measured on production: a 392-character schedule answer came back at
      # 456 after "Kraće molim." - the persona phrase was the entire
      # difference. A citizen asking for LESS must never receive MORE.
      test "a brevity request never gets a persona phrase" do
        ["Kraće molim.", "Još kraće, u jednoj rečenici.", "Skrati to.", "Ukratko?",
         "Can you answer briefly?"].each do |ask|
          decorated = apply(message: ask, reply: build_reply(text: "Odgovor.", answer_intent: "launch"))

          assert_equal "Odgovor.", decorated.text, "decorated a brevity request: #{ask}"
        end
      end

      # The guard must not swallow ordinary turns. Decoration itself is
      # probabilistic, so assert the PREDICATE rather than the outcome.
      test "an ordinary question is not read as a brevity request" do
        ["Kada je lansiranje platforme?", "Kako da se registrujem?",
         "Koliko traje link za potvrdu?", "Gdje je kratka ulica?"].each do |ordinary|
          personality = MilicaPersonality.new(
            reply: build_reply(text: "Odgovor."), message: Message.new(text: ordinary, conversation_context: []), channel: "web_chat"
          )

          refute personality.send(:brevity_request?), "wrongly read as a brevity request: #{ordinary}"
        end
      end

      # These phrase-bank tests need an ordinary search-cue intent. Service
      # answers deliberately bypass optional personality decoration.
      def apply(message:, context: [], answer_intent: "launch", reply: nil, channel: "web_chat")
        reply ||= build_reply(answer_intent:)
        MilicaPersonality.call(
          reply:,
          message: Message.new(text: message, conversation_context: context),
          channel:
        )
      end

      # The reply the coordinator hands the voice, carrying the language it
      # was written in.
      def stamped_reply(locale)
        Decidim::Bih::Concierge::Responder::Reply.new(
          text: BARE_ANSWER, report: nil, quick_replies: [], answer_intent: "launch", locale:
        )
      end

      def build_reply(text: "Provjeren i miran odgovor.", answer_intent: "launch", tone: nil)
        Decidim::Bih::Concierge::Responder::Reply.new(
          text:,
          report: nil,
          quick_replies: [],
          answer_intent:,
          tone:
        )
      end
    end
  end
end
