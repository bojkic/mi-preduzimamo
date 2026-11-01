# frozen_string_literal: true

require "test_helper"

module DecidimApp
  module Bijeljina
    # A chat app renders a reply as plain text: no page origin to resolve a
    # root-relative path against, no chips, and a provider-specific length cap
    # that used to be applied bytewise by the send job, mid-URL if need be
    # (channels review 2026-09-12, section E, P1 rows).
    class ChatTextRenderingTest < ActiveSupport::TestCase
      HOST = "mi.example.test"
      Reply = Struct.new(:text, :quick_replies, keyword_init: true)
      # Object chips carry label and url only: `send` is never an object
      # attribute (every Ruby object already answers #send), so typed-reply
      # chips are always Hashes.
      Chip = Struct.new(:label, :url, keyword_init: true)

      test "first channel reply explains that a citizen can continue by replying" do
        reply = Reply.new(text: "Kako ti mogu pomoći?", quick_replies: [])

        first = ChatTextRendering.render(channel: "viber_bm", reply:, host: HOST, first_turn: true)
        later = ChatTextRendering.render(channel: "viber_bm", reply:, host: HOST)

        assert_includes first, ChatTextRendering::CONVERSATION_START
        assert_includes first, "Kako ti mogu pomoći?"
        assert_not_includes later, ChatTextRendering::CONVERSATION_START
      end

      # --- absolute_links -------------------------------------------------

      test "root-relative paths that start a word become absolute on the host" do
        text = "Otvori obrazac: /biceriseno/prijave/new i registruj se na /registracija"

        rendered = ChatTextRendering.absolute_links(text, host: HOST)

        assert_equal "Otvori obrazac: https://#{HOST}/biceriseno/prijave/new i registruj se na https://#{HOST}/registracija", rendered
      end

      test "a path inside an absolute URL or glued to a word is left alone" do
        text = "Vidi https://drugi.example.test/put/do i oznaku a/b, ali (/kako) radi"

        rendered = ChatTextRendering.absolute_links(text, host: HOST)

        assert_equal "Vidi https://drugi.example.test/put/do i oznaku a/b, ali (https://#{HOST}/kako) radi", rendered
      end

      test "a sentence-ending period after a path stays exactly as the copy wrote it" do
        rendered = ChatTextRendering.absolute_links("Kreni od /registracija. Zatim čekaj.", host: HOST)

        assert_equal "Kreni od https://#{HOST}/registracija. Zatim čekaj.", rendered
      end

      test "without a host or without text nothing is rewritten" do
        assert_equal "Idi na /registracija", ChatTextRendering.absolute_links("Idi na /registracija", host: nil)
        assert_equal "Idi na /registracija", ChatTextRendering.absolute_links("Idi na /registracija", host: "")
        assert_equal "", ChatTextRendering.absolute_links(nil, host: HOST)
      end

      # --- append_choices -------------------------------------------------

      test "url chips become bullet lines with absolute links" do
        chips = [
          { label: "Prijavi problem", url: "/biceriseno/prijave/new" },
          { "label" => "Doniraj", "url" => "https://donacije.example.test/projekat" }
        ]

        rendered = ChatTextRendering.append_choices("Evo pomoći.", chips, host: HOST)

        assert_equal "Evo pomoći.\n\n" \
                     "• Prijavi problem: https://#{HOST}/biceriseno/prijave/new\n" \
                     "• Doniraj: https://donacije.example.test/projekat", rendered
      end

      test "send chips become one Odgovori line quoting every executable command" do
        chips = [{ label: "Potvrdi slanje", send: "Pošalji prijavu ABC123" }, { label: "Odustani", send: "odustani" }]

        rendered = ChatTextRendering.append_choices("Pregled prijave.", chips, host: HOST)

        assert_equal "Pregled prijave.\n\nOdgovori: „Pošalji prijavu ABC123” ili „odustani”", rendered
      end

      test "a single send chip and three send chips read as a sentence" do
        one = ChatTextRendering.append_choices("T", [{ label: "Odustani", send: "odustani" }], host: HOST)
        three = ChatTextRendering.append_choices(
          "T", [{ label: "Da", send: "da" }, { label: "Ne", send: "ne" }, { label: "Kasnije", send: "kasnije" }], host: HOST
        )

        assert_equal "T\n\nOdgovori: „odustani”", one
        assert_equal "T\n\nOdgovori: „da”, „ne” ili „kasnije”", three
      end

      test "mixed chips add the bullet lines and then one Odgovori line" do
        chips = [
          Chip.new(label: "Status prijave", url: "/biceriseno/prijave/XY"),
          { label: "Odustani", send: "odustani" }
        ]

        rendered = ChatTextRendering.append_choices("Poslato.", chips, host: HOST)

        assert_equal "Poslato.\n\n• Status prijave: https://#{HOST}/biceriseno/prijave/XY\nOdgovori: „odustani”", rendered
      end

      test "only the first three chips are rendered so at most four lines are added" do
        chips = %w(Prvi Drugi Treći Četvrti Peti).map { |label| { label:, url: "/#{label.downcase}" } }
        chips << { label: "Odustani", send: "odustani" }

        rendered = ChatTextRendering.append_choices("Meni.", chips, host: HOST)
        added = rendered.delete_prefix("Meni.\n\n").lines

        assert_equal 3, added.length
        assert_equal ["• Prvi: https://#{HOST}/prvi", "• Drugi: https://#{HOST}/drugi", "• Treći: https://#{HOST}/treći"],
                     added.map(&:chomp)
        assert_not_includes rendered, "Četvrti"
        assert_not_includes rendered, "Odgovori"
      end

      test "the limit is a parameter" do
        chips = %w(A B C D).map { |label| { label:, url: "/#{label}" } }

        rendered = ChatTextRendering.append_choices("M", chips, host: HOST, limit: 4)

        assert_equal 4, rendered.delete_prefix("M\n\n").lines.length
      end

      test "chips without a label or without a target are skipped and no chips leave the text untouched" do
        chips = [{ label: "", url: "/x" }, { label: "Bez cilja" }, nil, { url: "/y" }]

        assert_equal "Tekst", ChatTextRendering.append_choices("Tekst", chips, host: HOST)
        assert_equal "Tekst", ChatTextRendering.append_choices("Tekst", [], host: HOST)
        assert_equal "Tekst", ChatTextRendering.append_choices("Tekst", nil, host: HOST)
      end

      # --- truncate_for ---------------------------------------------------

      test "the per-channel character limits are the conservative working values" do
        assert_equal({ "viber_bm" => 1000, "whatsapp" => 4096, "messenger" => 2000, "instagram" => 1000 },
                     ChatTextRendering::MAX_TEXT)
      end

      test "text within the channel limit is returned unchanged" do
        text = "Kratak odgovor. #{"x" * 900}"

        assert_same text, ChatTextRendering.truncate_for("viber_bm", text)
      end

      test "over-long text is cut at a sentence end and the first URL that was cut off follows on its own line" do
        url = "https://#{HOST}/biceriseno/otpad/raspored?dan=ponedjeljak"
        sentences = Array.new(30) { |index| "Rečenica broj #{index} govori o rasporedu odvoza otpada u tvom naselju." }
        text = "#{sentences.join(" ")} Detalji: #{url}. Zadnja napomena!"
        assert_operator text.length, :>, 1000

        rendered = ChatTextRendering.truncate_for("viber_bm", text)
        head, appended = rendered.split("\n", 2)

        assert_operator rendered.length, :<=, 1000
        assert_equal url, appended, "the first URL is appended without the sentence period that followed it"
        assert head.end_with?(". …"), "the head ends at a sentence boundary: #{head[-40..]}"
        assert text.start_with?(head.delete_suffix(" …")), "the head is a prefix of the original"
      end

      test "a first URL that survives the cut is not repeated" do
        url = "https://#{HOST}/biceriseno/prijave/new"
        text = "Obrazac: #{url}. #{Array.new(40) { "Još jedna dugačka rečenica o prijavi problema." }.join(" ")}"

        rendered = ChatTextRendering.truncate_for("instagram", text)

        assert_operator rendered.length, :<=, 1000
        assert_equal 1, rendered.scan(url).length
        assert rendered.end_with?(" …")
      end

      test "the cut never lands inside a URL" do
        url = "https://mi.fondacijabijeljina.com/biceriseno/prijave/new"
        text = "Pogledaj #{url} i onda #{"x" * 1000} kraj."

        rendered = ChatTextRendering.truncate_for("instagram", text)

        assert_equal "Pogledaj #{url} i onda …", rendered
      end

      test "text without a URL is just cut at the last sentence boundary" do
        text = Array.new(100) { |index| "Rečenica #{index} govori o rasporedu." }.join(" ")
        assert_operator text.length, :>, 2000

        rendered = ChatTextRendering.truncate_for("messenger", text)

        assert_operator rendered.length, :<=, 2000
        assert rendered.end_with?("o rasporedu. …"), rendered[-30..]
        assert_not_includes rendered, "https://"
      end

      test "a channel without its own limit falls back to the job's 4096 characters" do
        long = "#{"a" * 5000}. Kraj."
        exact = "a" * 4096

        assert_operator ChatTextRendering.truncate_for("unknown", long).length, :<=, 4096
        assert_same exact, ChatTextRendering.truncate_for("unknown", exact)
      end

      # --- render ---------------------------------------------------------

      test "render composes absolute links, choices and the channel cap" do
        reply = Reply.new(
          text: "Prijavi kroz /biceriseno/prijave/new.",
          quick_replies: [{ label: "Prijavi problem", url: "/biceriseno/prijave/new" }, { label: "Odustani", send: "odustani" }]
        )

        rendered = ChatTextRendering.render(channel: "whatsapp", reply:, host: HOST)

        assert_equal "Prijavi kroz https://#{HOST}/biceriseno/prijave/new.\n\n" \
                     "• Prijavi problem: https://#{HOST}/biceriseno/prijave/new\n" \
                     "Odgovori: „odustani”", rendered
      end

      test "impossible protected content becomes a bounded retry without partial commands or consent" do
        reply = Reply.new(text: "Pregled prijave.", quick_replies: [{ label: "Potvrdi", send: "Pošalji prijavu #{"X" * 5000}" }])
        %w(whatsapp messenger instagram viber_bm).each do |channel|
          rendered = ChatTextRendering.render(channel:, reply:, host: HOST)
          assert_equal ChatTextRendering::OVERSIZE_REPLY, rendered
          assert_operator rendered.length, :<=, ChatTextRendering::MAX_TEXT.fetch(channel)
          assert_not_includes rendered, "Pošalji"
          assert_not_includes rendered, "http"
          assert_not_includes rendered, "poslat"
        end
      end

      test "render tolerates a plain string reply and a blank reply" do
        assert_equal "Idi na https://#{HOST}/registracija", ChatTextRendering.render(channel: "viber_bm", reply: "Idi na /registracija", host: HOST)
        assert_equal "", ChatTextRendering.render(channel: "viber_bm", reply: Reply.new(text: nil, quick_replies: [{ label: "A", url: "/a" }]), host: HOST)
      end

      test "render truncates the choice block too so a Viber reply never exceeds its cap" do
        reply = Reply.new(
          text: Array.new(30) { "Duga rečenica o gradskim servisima i odvozu otpada u naselju." }.join(" "),
          quick_replies: [{ label: "Prijavi problem", url: "/biceriseno/prijave/new" }]
        )

        rendered = ChatTextRendering.render(channel: "viber_bm", reply:, host: HOST)

        assert_operator rendered.length, :<=, 1000
        assert rendered.end_with?("\nhttps://#{HOST}/biceriseno/prijave/new"), "the only link is kept: #{rendered[-80..]}"
      end
    end
  end
end
