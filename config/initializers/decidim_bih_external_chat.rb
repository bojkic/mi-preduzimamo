# frozen_string_literal: true

# Public entry links for Infobip-managed citizen chat channels. Each channel is
# independently launch-gated: keep its flag false until provider onboarding,
# webhook authentication, a real inbound/reply exchange, and owner approval all
# pass. The engine additionally hides a link unless its sender is in the
# explicit INFOBIP_CHAT_CHANNELS allowlist and is configured.
external_chat_enabled = lambda do |channel|
  ENV.fetch("DECIDIM_BIH_#{channel.upcase}_PUBLIC_ONBOARDING_ENABLED", "false")
     .match?(/\A(true|1|yes|on)\z/i)
end

# A public entry must not appear when the matching inbound route would reject
# authenticated provider traffic. The readiness smoke enforces the same
# minimum length without ever printing the configured value.
external_chat_secret_ready = lambda do |channel|
  channel_secret = ENV.fetch("#{channel.upcase}_WEBHOOK_SECRET", nil).to_s
  shared_secret = ENV.fetch("INFOBIP_CHAT_WEBHOOK_SECRET", nil).to_s
  channel_secret.length >= 16 || shared_secret.length >= 16
end

external_chat_url = lambda do |channel|
  next unless external_chat_enabled.call(channel) && external_chat_secret_ready.call(channel)

  ENV.fetch("DECIDIM_BIH_#{channel.upcase}_CHAT_URL", nil)
end

Decidim::Bih.external_chat_onboarding_links = {
  whatsapp: external_chat_url.call("whatsapp"),
  messenger: external_chat_url.call("messenger"),
  instagram: external_chat_url.call("instagram")
}.compact
