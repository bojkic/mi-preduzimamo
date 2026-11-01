# frozen_string_literal: true

# Viber-specific configuration for the MI PRE(D)UZIMAMO! bot.
# Sets the bot's chat URI (from the Infobip Viber Business Account portal)
# so the SMS verification page can offer a "Verifikuj se preko Vibera" deep link.
#
# VIBER_BOT_URI — the chatURI segment from the viber://pa deep link, e.g.
#   "mipreduzimamo" (without the scheme or query params). Get it from the
#   Infobip portal under Viber Business Messages → your channel → "Chat URI".
#   When blank/unset, the deep-link block is simply hidden on the verify page.
Decidim::Bih.viber_bot_uri = ENV.fetch("VIBER_BOT_URI", nil)

# Public Viber onboarding on `/biceriseno/mi-bot` is intentionally separate
# from VIBER_BOT_URI. Keep it disabled until live Infobip inbound/outbound
# verification has passed and LFBN is ready to promote Viber publicly.
Decidim::Bih.viber_public_onboarding_enabled =
  Decidim::Bih::Config.viber[:public_onboarding_enabled]
