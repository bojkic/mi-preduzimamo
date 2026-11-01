# frozen_string_literal: true

require "test_helper"
require "yaml"

class DecidimBihBijeljinaCopyTest < ActiveSupport::TestCase
  MILICA_GESTURES = %w(wave tablet map heart sleeves thumbs_up).freeze

  test "registration verification uses the generic engine wording in every locale" do
    latin = "MI: %{code} je tvoj kod. Ne dijeli ga. Potvrda jednim dodirom: %{url} (vazi 24 sata)"
    expected = {
      bs: latin, hr: latin, sr: latin,
      "sr-Cyrl": "МИ: %{code} је твој код. Не дијели га. Потврда једним додиром: %{url} (вази 24 сата)",
      en: "MI: %{code} is your code. Do not share it. Confirm with one tap: %{url} (valid 24 hours)"
    }
    host_copy = YAML.safe_load_file(Rails.root.join("config/locales/decidim_bih_bijeljina_copy.yml"))
    interpolation = { code: "123456", url: "https://example.test/v/synthetic-test" }

    expected.each do |locale, copy|
      assert_nil host_copy.dig(locale.to_s, "decidim", "bih", "sms", "verification_link"), locale.to_s
      assert_equal %w(code url), copy.scan(/%\{([^}]+)\}/).flatten.sort
      assert_equal copy, I18n.t("decidim.bih.sms.verification_link", locale:)
      assert_equal copy % interpolation, I18n.t("decidim.bih.sms.verification_link", locale:, **interpolation)
    end
  end

  test "host locale overrides preserve community citizen-facing copy" do
    assert_nil Decidim::Bih.mi_bot_sms_shortcode
    assert_equal "asistent platforme", Decidim::Bih.mi_bot_showcase_assistant_name
    assert_equal "PREUZIMAMO", Decidim::Bih.mi_bot_showcase_sticker_text

    assert_equal "Portal va\u0161e zajednice", I18n.t("decidim.bih.content_blocks.mi_hero.eyebrow", locale: :bs)
    assert_equal "#MojaZajednica", I18n.t("decidim.bih.content_blocks.mi_cta.hashtag", locale: :bs)
    assert_equal "npr. Izmi\u0161ljena ulica 12, va\u0161a zajednica", I18n.t("decidim.bih.komsiluk.edit.address_placeholder", locale: :bs)
    assert_equal "MI", I18n.t("decidim.bih.content_blocks.mi_hub.tiles.prefix", locale: :bs)
    assert_equal "Milica", I18n.t("decidim.bih.menu.mi_bot", locale: :bs)
    assert_equal "Milica", I18n.t("decidim.bih.menu.mi_bot_short", locale: :bs)
    assert_equal "Pitaj Milicu", I18n.t("decidim.bih.public_actions.bot", locale: :bs)
    assert_equal "Komšinica Milica", I18n.t("decidim.bih.concierge.widget.header_title", locale: :bs)
    assert_equal(
      "Ćao! Ja sam Komšinica Milica. Ti objasni ljudski, ja ću prevesti na formularski — " \
      "bez šaltera i lutanja po portalu. 😄 Od čega krećemo?",
      I18n.t("decidim.bih.concierge.widget.greeting", locale: :bs)
    )
    assert_equal "Brži pristup prijavama, bodovima i Milici — direktno s početnog ekrana.", I18n.t("decidim.bih.pwa.install_text", locale: :bs)
    assert_equal "MI! kao aplikacija", I18n.t("decidim.bih.pwa.install_title", locale: :bs)
    assert_equal "Problem", I18n.t("decidim.bih.mobile_nav.report", locale: :bs)
    assert_equal "Uloguj se", I18n.t("layouts.decidim.header.log_in", locale: :bs)
    # "MI!:" read as a typo, the URL carried a sentence-ending period some
    # clients tap into the link, and the code travelled with no "never share
    # it" line — the only defence at the citizen's end against being talked
    # into reading it out. Still one GSM-7 segment (review 2026-09-07).
    assert_equal "Tvoj link za prijavu na MI pre(d)uzimamo: %{url} Vrijedi 10 minuta. Možeš razgovarati s Milicom ovdje — odgovori na ovu poruku.",
                 I18n.t("decidim.bih.sms.login_link", locale: :bs)
    assert_equal "MI: link za prijavu: %{url} Rezervni kod: %{code}. Vrijedi 10 min. Ne dijeli ga.",
                 I18n.t("decidim.bih.sms.login_link_and_code", locale: :bs)
    assert_equal "Asistent platforme va\u0161e zajednice", I18n.t("decidim.bih.mi_bot.show.signoff.line", locale: :bs)
    assert_equal "Milica", I18n.t("decidim.bih.mi_bot.show.phone_header", locale: :bs)
    assert_equal "Probaj Milicu", I18n.t("decidim.bih.mi_bot.show.cta.try_bot", locale: :bs)
    assert_equal "Pridruži se zajednici Mi pre(d)uzimamo! 👋", I18n.t("decidim.bih.goodwill.invite.share_message", locale: :bs)
    assert_equal "Tvoj verifikacioni kod za Mi pre(d)uzimamo! je %{code}. Važi 10 minuta.", I18n.t("decidim.bih.concierge.link.sms", locale: :bs)
    assert_equal "Mapa prijava — Biće riješeno!", I18n.t("decidim.bih.reports_map.show.title", locale: :bs)
    assert_equal "Pitaj Milicu", I18n.t("decidim.bih.onboarding.guide.actions.bot.title", locale: :bs)
    assert_equal "LFBN analitički izvozi", I18n.t("decidim.bih.admin.analytics.index.title", locale: :bs)
    assert_equal "Red za pregled odgovora Milice", I18n.t("decidim.bih.admin.analytics.index.mi_bot_review_title", locale: :bs)
    assert_equal "Korištenje Milice", I18n.t("decidim.bih.admin.analytics.datasets.mi_bot_usage", locale: :bs)
    assert_equal(
      "Nisam prona\u0161la stavku \u201Eprevoz\u201C u podacima koje trenutno imamo. Poku\u0161aj s nazivom oblasti ili ustanove.",
      I18n.t("decidim.bih.concierge.budget.not_found", category: "prevoz", locale: :bs)
    )
    assert_equal(
      "Nisam pronašla rezultat u obrađenom katalogu Službenog glasnika. To ne dokazuje da odluka ne postoji; " \
      "pokušaj s drugom temom, godinom ili brojem izdanja.",
      I18n.t("decidim.bih.concierge.gazette.not_found", locale: :bs)
    )
    assert_equal(
      "Za poslanu lokaciju nisam na\u0161la MZ/Kom\u0161iluk u mapi koju imam. Provjeri adresu na stranici Kom\u0161iluk: /komsiluk",
      I18n.t("decidim.bih.concierge.local_area_guidance.location_not_found", url: "/komsiluk", locale: :bs)
    )
    assert_equal "Verifikacioni kod je poslan SMS-om. Pošalji šestocifreni kod.", I18n.t("decidim.bih.concierge.link.code_sent", locale: :bs)
    assert_equal(
      "Nisam prona\u0161la prijavu BR-2026-0001. Provjeri broj \u2014 format je BR-GGGG-NNNN.",
      I18n.t("decidim.bih.concierge.status.not_found", reference: "BR-2026-0001", locale: :bs)
    )
    assert_equal(
      "Nisam prona\u0161la pouzdan raspored odvoza za \u201EIzmišljeno polje\u201C. Provjeri ta\u010Dan naziv ulice ili naselja.",
      I18n.t("decidim.bih.concierge.waste.not_found", area: "Izmišljeno polje", locale: :bs)
    )
    assert_includes I18n.t("decidim.bih.concierge.help", locale: :bs), "prijava problema"
    assert_includes I18n.t("decidim.bih.concierge.help", locale: :bs), "Komšiluk"
    assert_includes I18n.t("decidim.bih.concierge.help", locale: :bs), "volontiranje"
    assert_not_includes I18n.t("decidim.bih.concierge.help", locale: :bs), "#jervolimbijeljinu"
    assert_equal "Report %{reference} — status: %{status}.", I18n.t("decidim.bih.reporter_mailer.status_update.viber_text", locale: :en)
    assert_equal "Join the Mi pre(d)uzimamo! community 👋", I18n.t("decidim.bih.goodwill.invite.share_message", locale: :en)
    assert_equal "Milica", I18n.t("decidim.bih.menu.mi_bot", locale: :en)
    assert_equal "Milica", I18n.t("decidim.bih.menu.mi_bot_short", locale: :en)
    assert_equal "Ask Milica", I18n.t("decidim.bih.public_actions.bot", locale: :en)
    assert_equal "Komšinica Milica", I18n.t("decidim.bih.concierge.widget.header_title", locale: :en)
    assert_equal "Reports map — Biće riješeno!", I18n.t("decidim.bih.reports_map.show.title", locale: :en)
    assert_equal "Ask Milica", I18n.t("decidim.bih.onboarding.guide.actions.bot.title", locale: :en)
    assert_equal "LFBN analytics exports", I18n.t("decidim.bih.admin.analytics.index.title", locale: :en)
    assert_equal "Milica answer review queue", I18n.t("decidim.bih.admin.analytics.index.mi_bot_review_title", locale: :en)
    assert_equal "Milica usage", I18n.t("decidim.bih.admin.analytics.datasets.mi_bot_usage", locale: :en)
    assert_equal(
      "Record the manual grant/bookkeeping reference after LFBN pays an approved match request.",
      I18n.t("decidim.bih.admin.goodwill.index.match_payouts_intro", locale: :en)
    )
    assert_equal "\u041F\u043E\u0440\u0442\u0430\u043B \u0432\u0430\u0448\u0435 \u0437\u0430\u0458\u0435\u0434\u043D\u0438\u0446\u0435", I18n.t("decidim.bih.content_blocks.mi_hero.eyebrow", locale: :"sr-Cyrl")
    assert_equal "МИ", I18n.t("decidim.bih.content_blocks.mi_hub.tiles.prefix", locale: :"sr-Cyrl")
    assert_equal "Милица", I18n.t("decidim.bih.menu.mi_bot", locale: :"sr-Cyrl")
    assert_equal "Милица", I18n.t("decidim.bih.menu.mi_bot_short", locale: :"sr-Cyrl")
    assert_equal "Питај Милицу", I18n.t("decidim.bih.public_actions.bot", locale: :"sr-Cyrl")
    assert_equal "Мапа пријава — Биће ријешено!", I18n.t("decidim.bih.reports_map.show.title", locale: :"sr-Cyrl")
    assert_equal "Питај Милицу", I18n.t("decidim.bih.onboarding.guide.actions.bot.title", locale: :"sr-Cyrl")
    assert_equal "ЛФБН аналитички извози", I18n.t("decidim.bih.admin.analytics.index.title", locale: :"sr-Cyrl")
    assert_equal "Ред за преглед одговора Милице", I18n.t("decidim.bih.admin.analytics.index.mi_bot_review_title", locale: :"sr-Cyrl")

    sms_copy = {
      bs: "SMS koristimo za verifikacione kodove, linkove za prijavu i obavještenja. Milici možeš odgovoriti na dostupnom kanalu ili pisati na sajtu.",
      hr: "SMS koristimo za verifikacijske kodove, poveznice za prijavu i obavijesti. Milici možeš odgovoriti na dostupnom kanalu ili pisati na stranici.",
      sr: "SMS koristimo za verifikacione kodove, linkove za prijavu i obavještenja. Milici možeš odgovoriti na dostupnom kanalu ili pisati na sajtu.",
      "sr-Cyrl": "СМС користимо за верификационе кодове, линкове за пријаву и обавјештења. Милици можеш одговорити на доступном каналу или писати на сајту.",
      en: "SMS is used for verification codes, sign-in links and notifications. Reply to Milica on an available channel or chat on the website."
    }
    sms_copy.each do |locale, copy|
      assert_equal copy, I18n.t("decidim.bih.content_blocks.mi_hub.omni.sms_html", locale:)
      assert_equal copy, I18n.t("decidim.bih.concierge.mi_hub.omni.sms_html", locale:)
    end

    external_chat_copy = {
      bs: [
        "Razgovaraj sa Komšinicom Milicom u aplikaciji koju već koristiš",
        "Milica odgovara na pitanja. Na WhatsAppu i Messengeru prijava nastaje tek nakon pregleda i potvrde porukom; na Instagramu Milica daje smjernice. Razgovor ne povezuje tvoj nalog."
      ],
      hr: [
        "Razgovaraj s Komšinicom Milicom u aplikaciji koju već koristiš",
        "Milica odgovara na pitanja. Na WhatsAppu i Messengeru prijava nastaje tek nakon pregleda i potvrde porukom; na Instagramu Milica daje smjernice. Razgovor ne povezuje tvoj račun."
      ],
      sr: [
        "Razgovaraj sa Komšinicom Milicom u aplikaciji koju već koristiš",
        "Milica odgovara na pitanja. Na WhatsAppu i Messengeru prijava nastaje tek nakon pregleda i potvrde porukom; na Instagramu Milica daje smjernice. Razgovor ne povezuje tvoj nalog."
      ],
      "sr-Cyrl": [
        "Разговарај са Комшиницом Милицом у апликацији коју већ користиш",
        "Милица одговара на питања. На WhatsAppu и Messengeru пријава настаје тек након прегледа и потврде поруком; на Instagramu Милица даје смјернице. Разговор не повезује твој налог."
      ],
      en: [
        "Chat with Komšinica Milica in an app you already use",
        "Milica answers questions. On WhatsApp and Messenger, a report requires a preview and message confirmation; Instagram offers guidance. Chat does not link your account."
      ]
    }
    external_chat_copy.each do |locale, (title, boundary)|
      assert_equal title, I18n.t("decidim.bih.mi_bot.show.external_chat_onboarding.title", locale:)
      assert_equal boundary, I18n.t("decidim.bih.mi_bot.show.external_chat_onboarding.boundary_body", locale:)
      assert_equal "WhatsApp", I18n.t("decidim.bih.mi_bot.show.external_chat_onboarding.channels.whatsapp", locale:)
    end
  end

  test "Milica gesture assets are local bounded and accessibility-labelled" do
    MILICA_GESTURES.each do |gesture|
      gif = Rails.root.join("public/mi/milica/#{gesture}.gif")
      jpg = Rails.root.join("public/mi/milica/#{gesture}.jpg")

      assert_path_exists gif
      assert_path_exists jpg
      assert_operator File.size(gif), :<=, 1.megabyte
      assert_operator File.size(jpg), :<=, 1.megabyte
      assert_equal "GIF8", File.binread(gif, 4)
      assert_equal "\xFF\xD8".b, File.binread(jpg, 2)
      assert_predicate I18n.t("decidim.bih.concierge.media.milica_#{gesture}.alt", locale: :bs), :present?
    end
  end
  # Reviewed neutral host text retains every original P8/P11 field and locale.
  # It promises no event date, funding amount or response deadline.
  test "launch campaign P8/P11 override carries neutral community wording" do
    p8_viber = "U pregledanim podacima ima %{broj} prijava; zapis ne potvr\u0111uje proslje\u0111ivanje ili rje\u0161enje. Kom\u0161iluk %{komsiluk}, zabilje\u017Eeni poredak %{mjesto}. Pravila i aktuelni pregled: %{link}"

    p11_subject = "Poziv za uklju\u010Divanje u platformu zajednice"

    p11_email = "Pozivamo vas da otvorite nalog: %{link}\nTim zajednice prije pokretanja objavljuje odgovornosti i postupak obrade prijava. Ovaj obrazac ne potvr\u0111uje datum doga\u0111aja, finansiranje niti rok odgovora."

    [:bs, :hr, :sr].each do |locale|
      assert_equal p8_viber, I18n.t("decidim.bih.launch.messages.p8.viber", locale:).strip
      assert_equal p11_subject, I18n.t("decidim.bih.launch.messages.p11.email_subject", locale:)
      assert_equal p11_email, I18n.t("decidim.bih.launch.messages.p11.email", locale:).strip
    end

    cyrl_p8_viber = "\u0423 \u043F\u0440\u0435\u0433\u043B\u0435\u0434\u0430\u043D\u0438\u043C \u043F\u043E\u0434\u0430\u0446\u0438\u043C\u0430 \u0438\u043C\u0430 %{broj} \u043F\u0440\u0438\u0458\u0430\u0432\u0430; \u0437\u0430\u043F\u0438\u0441 \u043D\u0435 \u043F\u043E\u0442\u0432\u0440\u0452\u0443\u0458\u0435 \u043F\u0440\u043E\u0441\u0459\u0435\u0452\u0438\u0432\u0430\u045A\u0435 \u0438\u043B\u0438 \u0440\u0458\u0435\u0448\u0435\u045A\u0435. \u041A\u043E\u043C\u0448\u0438\u043B\u0443\u043A %{komsiluk}, \u0437\u0430\u0431\u0438\u0459\u0435\u0436\u0435\u043D\u0438 \u043F\u043E\u0440\u0435\u0434\u0430\u043A %{mjesto}. \u041F\u0440\u0430\u0432\u0438\u043B\u0430 \u0438 \u0430\u043A\u0442\u0443\u0435\u043B\u043D\u0438 \u043F\u0440\u0435\u0433\u043B\u0435\u0434: %{link}"

    cyrl_p11_subject = "\u041F\u043E\u0437\u0438\u0432 \u0437\u0430 \u0443\u043A\u0459\u0443\u0447\u0438\u0432\u0430\u045A\u0435 \u0443 \u043F\u043B\u0430\u0442\u0444\u043E\u0440\u043C\u0443 \u0437\u0430\u0458\u0435\u0434\u043D\u0438\u0446\u0435"

    cyrl_p11_email = "\u041F\u043E\u0437\u0438\u0432\u0430\u043C\u043E \u0432\u0430\u0441 \u0434\u0430 \u043E\u0442\u0432\u043E\u0440\u0438\u0442\u0435 \u043D\u0430\u043B\u043E\u0433: %{link}\n\u0422\u0438\u043C \u0437\u0430\u0458\u0435\u0434\u043D\u0438\u0446\u0435 \u043F\u0440\u0438\u0458\u0435 \u043F\u043E\u043A\u0440\u0435\u0442\u0430\u045A\u0430 \u043E\u0431\u0458\u0430\u0432\u0459\u0443\u0458\u0435 \u043E\u0434\u0433\u043E\u0432\u043E\u0440\u043D\u043E\u0441\u0442\u0438 \u0438 \u043F\u043E\u0441\u0442\u0443\u043F\u0430\u043A \u043E\u0431\u0440\u0430\u0434\u0435 \u043F\u0440\u0438\u0458\u0430\u0432\u0430. \u041E\u0432\u0430\u0458 \u043E\u0431\u0440\u0430\u0437\u0430\u0446 \u043D\u0435 \u043F\u043E\u0442\u0432\u0440\u0452\u0443\u0458\u0435 \u0434\u0430\u0442\u0443\u043C \u0434\u043E\u0433\u0430\u0452\u0430\u0458\u0430, \u0444\u0438\u043D\u0430\u043D\u0441\u0438\u0440\u0430\u045A\u0435 \u043D\u0438\u0442\u0438 \u0440\u043E\u043A \u043E\u0434\u0433\u043E\u0432\u043E\u0440\u0430."

    assert_equal cyrl_p8_viber, I18n.t("decidim.bih.launch.messages.p8.viber", locale: :"sr-Cyrl").strip
    assert_equal cyrl_p11_subject, I18n.t("decidim.bih.launch.messages.p11.email_subject", locale: :"sr-Cyrl")
    assert_equal cyrl_p11_email, I18n.t("decidim.bih.launch.messages.p11.email", locale: :"sr-Cyrl").strip

    # The supplied community link survives as a copy-pasteable Latin
    # token; no inherited Foundation domain or event invitation is assumed, never rendered
    # as Cyrillic nonsense.
    public_link = "https://community.example.invalid/invitation"
    assert_includes I18n.t("decidim.bih.launch.messages.p11.email", locale: :"sr-Cyrl", link: public_link), public_link
  end

  test "the host's login SMS copy still fits one GSM-7 segment in every SMS locale" do
    # The engine guards its own decidim.bih.sms.* copy this way
    # (rails_test/message_templates_test.rb). This file OVERRIDES that copy, so
    # the engine's guard says nothing about what Bijeljina actually sends — and
    # the failure mode is money, not aesthetics: one š, ć or Cyrillic letter
    # switches the message from GSM-7 to UCS-2, which cuts a segment from 160
    # characters to 70 and doubles or triples the price of every login SMS.
    #
    # sr-Cyrl is deliberately absent: Cyrillic is UCS-2 by definition, and the
    # gateway sends this key in Latin (see the engine's SMS_LOCALES).
    sms_locales = %w(sr bs hr en)

    # The longest link production can mint: "https://" + a 25-character host +
    # "/v/" + the 32 characters of SecureRandom.urlsafe_base64(24) = 68.
    longest_link = "https://#{"h" * 25}/v/#{"t" * 32}"
    assert_equal 68, longest_link.length

    sms_locales.each do |locale|
      text = I18n.t("decidim.bih.sms.login_link_and_code", url: longest_link, code: "123456", locale:)
      result = Decidim::Bih::Sms::SegmentCounter.for(text)

      assert_equal :gsm7, result[:encoding],
                   "#{locale}: this SMS must carry no diacritics — UCS-2 doubles the price of every login"
      assert_equal 1, result[:segments],
                   "#{locale}: #{result[:characters]} characters spills the login SMS into a second segment"
    end
  end
end
