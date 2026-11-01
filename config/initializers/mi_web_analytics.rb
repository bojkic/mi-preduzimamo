# frozen_string_literal: true

# Analitika nije uključena u referentnoj instalaciji.
# Prije aktiviranja definišite sopstvene identifikatore i pravila saglasnosti.
Decidim.consent_cookie_name = "mi-consent-v2"
Decidim.consent_categories.each do |category|
  Array(category[:items]).each do |item|
    item[:name] = Decidim.consent_cookie_name if item[:name] == "decidim-consent"
  end
end

Rails.application.config.x.mi_web_analytics = {
  ga4_enabled: false,
  ga4_id: "",
  cookie_domain: "",
  google_ads_id: "",
  cookie_name: Decidim.consent_cookie_name,
  cloudflare_token: "",
  paths: [].freeze
}.freeze
