# frozen_string_literal: true

require_relative "decidim_bih_apply_setting"

# LFBN (Lokalna fondacija Bijeljina) tuning of the generic goodwill points
# ledger that lives in the decidim-bih engine. The engine's built-in defaults
# (Decidim::Bih::Goodwill::EarningRules::DEFAULT_SCHEDULE / DEFAULT_DAILY_CAPS)
# already match the agreed schedule, so this file is the single, documented
# place to adjust foundation-specific values. Editing the numbers here changes
# the live economy without touching the engine.
Decidim::Bih.goodwill_earning_schedule = {
  volunteer_hour: 100, # prethodna politika; ostaje za stare knjižene dodjele i neaktiviran prelaz
  volunteer_day: 100, # potvrđen volonterski dan; jednom po osobi i sarajevskom datumu
  volunteer_opportunity: 25, # predložena volonterska prilika (poslije odobrenja)
  proposal: 25,
  referral: 25, # verifikovan poziv komšiji
  report: 20,
  debate: 15, # pokretanje rasprave
  contribution_offer: 15, # priznata ponuda doprinosa
  postal_verified: 40, # jednokratno; verifikacija adrese pismom
  komsiluk_selected: 10, # jednokratno; odabir komšiluka
  verification: 10, # jednokratna dobrodošlica na prvu verifikaciju telefona
  volunteer_availability: 10, # izjava o dostupnosti za volontiranje
  komsiluk_post: 10,
  budget_vote: 5, # završen checkout participativnog budžeta
  comment: 3,
  vote: 2,
  like: 1
}

# Dnevne granice (max bodovanih dodjela po korisniku po danu, Europe/Sarajevo).
# Radnja preko granice se NORMALNO izvršava, samo ne nosi bodove.
Decidim::Bih.goodwill_daily_caps = {
  like: 10,
  vote: 10,
  comment: 5,
  # Zadržano protiv farmanja: dvije prijave bi inače same dosegle prag od 40.
  report: 5,
  proposal: 5,
  debate: 3,
  komsiluk_post: 3,
  budget_vote: 20
}

# Season start — the wallet page surfaces a "Ova sezona" score (goodwill points
# earned since this date) alongside the all-time contribution. There is no extra
# cached column: the figure is aggregated live from the immutable ledger by
# Decidim::Bih::Goodwill::Streaks.season_score. "Resetting" a season is just
# bumping this date. When nil the season block is hidden (Nil semantics:
# Decidim::Bih.goodwill_season_started_at accessor — see decidim-bih/lib/decidim/bih.rb:89).
Decidim::Bih.goodwill_season_started_at = Date.new(2026, 1, 1)

# Symbolic rewards citizens can redeem wallet points for (names from i18n:
# decidim.bih.goodwill.rewards.<key>). Kept modest by design — recognition,
# not cash-equivalence.
Decidim::Bih.goodwill_rewards_catalog = [
  { key: "naljepnice", cost: 150 },
  { key: "zahvalnica", cost: 200 },
  { key: "torba", cost: 300 },
  { key: "pozivnica", cost: 400 },
  { key: "majica", cost: 500 },
  { key: "partner_kupon", cost: 600 },
  { key: "radionica", cost: 700 },
  { key: "termos", cost: 800 },
  { key: "godisnje_priznanje", cost: 1200 }
]

# The invite link citizens share is the short form https://<host>/p/<nadimak>
# (config/routes.rb declares the route; the engine controller redirects to
# /registracija?ref=). Guarded through DecidimBihSettings.apply so an engine
# that predates the setting boots and keeps the long ?ref= link.
DecidimBihSettings.apply("decidim_bih_goodwill", :invite_short_path, "/p")
