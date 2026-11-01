# frozen_string_literal: true

require_relative "decidim_bih_apply_setting"

# Trka komšiluka i lansiranje 17.9.2026 — vrijednosti Lokalne fondacije Bijeljina.
# Engine defaults live in Decidim::Bih::Race::Config and
# Decidim::Bih::Launch::InvitationWaves; this file is the foundation's copy.
#
# WARNING: the host app and the decidim-bih engine deploy through SEPARATE git
# operations, and production loads the engine's working tree directly (see
# CLAUDE.md — "Production loads the engine's working tree directly"). That
# means a moment can exist where this host ships before the engine gains a
# setting below, or the engine gets rolled back after this host is already
# live. If an initializer just assigns unconditionally, that moment turns a
# `NoMethodError` at boot into a TOTAL SITE OUTAGE over a feature toggle,
# instead of the feature quietly running on its default.
#
# So every assignment here is guarded, through the shared
# DecidimBihSettings.apply: apply it only when the running engine actually
# defines the setter, and log once (not raise) when one is skipped, so version
# skew shows up in the log rather than killing boot.
#
# Reassuring note: the engine's own defaults for the race window/weights/caps
# are deliberately identical to the values assigned below, and
# `launch_invitation_waves` defaulting to nil falls back to the very same
# 310-in-one-wave schedule (see Decidim::Bih::Launch::InvitationWaves::
# DEFAULT_WAVES). So a skipped assignment here degrades to the same observed
# behaviour, not a silently wrong campaign.
DecidimBihSettings.apply("decidim_bih_race", :race_window_from, "2026-09-06 00:00:00")
DecidimBihSettings.apply("decidim_bih_race", :race_window_to, "2026-10-14 20:00:00")
DecidimBihSettings.apply("decidim_bih_race", :race_weights, { registered: 1, report: 2, proposal: 3 })
DecidimBihSettings.apply("decidim_bih_race", :race_caps, { report: 5, proposal: 3 })

# ODLUKA naručioca (2026-08-31): 310 pozivnica u JEDNOM talasu, od 6.9.
# Vraćanje na tri talasa je izmjena OVE liste, ne izmjena koda.
DecidimBihSettings.apply(
  "decidim_bih_race",
  :launch_invitation_waves,
  [{ "starts_on" => "2026-09-06", "quantity" => 310 }]
)
DecidimBihSettings.apply("decidim_bih_race", :launch_invitation_reward_key, "pozivnica_lansiranje")
