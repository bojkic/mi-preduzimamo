# frozen_string_literal: true

require_relative "decidim_bih_apply_setting"

# Phone-first registration for mi.fondacijabijeljina.com (odluka 5.9.2026):
# the account is active at once, the phone is the verified identity, the
# e-mail is not confirmed at sign-up and cannot reset a password until it is.
#
# Both assignments go through DecidimBihSettings.apply — see
# config/initializers/decidim_bih_apply_setting.rb for why an unguarded
# assignment here is an outage risk.
DecidimBihSettings.apply("decidim_bih_registration", :phone_first_registration, true)
DecidimBihSettings.apply("decidim_bih_registration", :simplified_registration, true)

# The instant phone-first went live, in UTC. Accounts whose confirmed_at
# predates it went through the Devise e-mail link (or an admin) and stay
# e-mail-confirmed for password recovery; anything confirmed after it was
# confirmed by skip_confirmation! and proves nothing about the address.
#
# This is NOT optional company to the switch above. Decidim::Bih::
# EmailConfirmation#grandfathered? fails closed when phone_first_registration
# is on and the cutoff is nil: with no cutoff, no confirmed_at can be trusted,
# and every account that predates the switch loses password recovery. The two
# lines change together.
#
# PLACEHOLDER — Task 19 replaces this with the real deploy instant. It is
# deliberately in the PAST: a future value would grandfather every account
# created between now and then, handing a proven e-mail to accounts that never
# proved one.
DecidimBihSettings.apply("decidim_bih_registration", :phone_first_registration_since, "2026-09-05 00:00:00")

# Isporuka D: registration is one step and it lives at a ROOT path.
#
# TWO settings, and they change together or not at all:
#
#   registration_path      — where every "register" link points (the hero CTAs,
#                            the header, the onboarding guide, Milica), and the
#                            sentinel DecidimApp::Bijeljina::SocialRegistrationHandoff
#                            reads before it will arm the social entry at all.
#   registration_base_path — what the engine builds the REST of the flow from
#                            (the pending page, resend, the typed code, the
#                            status poll, and the resume link in the e-mail).
#
# Setting only the first would send citizens to /registracija and then walk
# them under /biceriseno halfway through; setting only the second would leave
# every register link on Decidim's old sign-up form. config/routes.rb declares
# the matching root routes, and config/initializers/rack_attack.rb reads
# Decidim::Bih.registration_path_for so the throttles follow this value rather
# than a second copy of it.
DecidimBihSettings.apply("decidim_bih_registration", :registration_path, "/registracija")
DecidimBihSettings.apply("decidim_bih_registration", :registration_base_path, "/registracija")

# Initial selection only; submitted opt-outs remain authoritative.
DecidimBihSettings.apply("decidim_bih_registration", :registration_newsletter_default, true)
