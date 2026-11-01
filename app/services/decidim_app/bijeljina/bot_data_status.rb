# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    # Citizen-safe answer to "which data and integrations does MI! have?".
    #
    # == What it deliberately does NOT say any more
    #
    # This answer reaches an ANONYMOUS visitor on the public web chat and on
    # Viber. It used to be a ~1.200-character operational inventory: how many
    # rows every catalogue holds, how many sources are configured and on what
    # scrape cadence, how many are Viber candidates, how many freshness checks
    # are OK/warn/fail, and the NAMES of the sources currently failing. None of
    # that answers the citizen's question, and the stale-source names in
    # particular tell a stranger which parts of the platform are not being
    # watched right now.
    #
    # What stays: the kinds of reviewed data Milica draws on, the integration
    # names (already published in the privacy and data-processing pages), how
    # freshness is handled per answer, and the honest limits. The operational
    # figures are unchanged and still available to an operator, where they
    # belong: CityDataFreshness, CityServiceSources.summary and
    # /admin/bih/city-alerts.
    #
    # It still exposes no credentials, no chat prompts, no private records and
    # no operator-only refresh commands.
    class BotDataStatus
      # +organization+ is the tenant scope both wirings pass. Nothing in the
      # narrowed answer is tenant-specific any more, and it is kept rather than
      # dropped so the two call sites and any per-organization statement added
      # later still have it.
      def initialize(organization:)
        @organization = organization
      end

      def answer(locale: I18n.locale)
        localize(
          [
            "MI! koristim samo pregledane podatke o Bijeljini: imenik gradskih usluga i procedura, raspored odvoza otpada, " \
            "parking zone, gradski budžet, Službeni glasnik, mjesne zajednice i objavljena servisna obavještenja.",
            "Integracije dostupne botu: #{integration_summary}.",
            "Svježina podataka: uz svaki odgovor pišem izvor i vrijeme provjere. Kada podatak nije provjeren ili više ne važi, " \
            "kažem ti to umjesto da nagađam.",
            "Ograničenja: #{gap_summary}."
          ].join("\n"),
          locale:
        )
      end

      private

      def integration_summary
        "Gemini pomaže razumjeti namjeru kada je uključen; Infobip nosi Viber i SMS verifikaciju; " \
          "Odoo daje keširane podatke o donacijama; Sistem 48 je tok za prijave; geokoder pomaže " \
          "kod adresa i MZ prepoznavanja"
      end

      def gap_summary
        "servisni FAQ je proširen, ali nije kompletan katalog svih gradskih procedura; " \
          "dio užeg centra za odvoz otpada još nema pouzdanu uličnu mapu; servisna obavještenja " \
          "prikazujem tek kada su pregledana i objavljena"
      end

      def localize(text, locale:)
        return text unless locale.to_s == Decidim::Bih::Concierge::Responder::CYRILLIC_LOCALE

        Decidim::Bih::Transliterator.call(text)
      end
    end
  end
end
