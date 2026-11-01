# frozen_string_literal: true

# Route Decidim's SMS verification (and any OTP the platform sends) through the
# Infobip gateway provided by the decidim-bih engine. Infobip is the regional
# (Croatian) omnichannel provider chosen for the Bosnian market — see the roadmap.
#
# Unlike the DECIDIM_AVAILABLE_LOCALES env vars (which Decidim memoizes at boot
# and so must be set in config/application.rb), the gateway service is read when
# a code is sent, so configuring it here is correct.
#
# Live delivery needs INFOBIP_BASE_URL / INFOBIP_API_KEY / INFOBIP_SMS_SENDER in
# the deploy environment; without them the gateway logs the code (dev fallback).
Decidim.sms_gateway_service = "Decidim::Bih::Sms::InfobipGateway"
