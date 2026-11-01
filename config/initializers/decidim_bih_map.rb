# frozen_string_literal: true

# Neutralan pregled BiH; granice, imenik i adrese uvozi vaša zajednica.
Decidim::Bih.map_default_center = [43.9159, 17.6791]
Decidim::Bih.map_default_zoom = 7
Decidim::Bih.local_address_lookup = nil
Decidim::Bih.geocoder_base_url = ENV["DECIDIM_BIH_GEOCODER_BASE_URL"].presence
Decidim::Bih.geocoder_search_path = ENV.fetch("DECIDIM_BIH_GEOCODER_SEARCH_PATH", "/search")
# Upotreba geokodiranja zahtijeva identitet operatera i uslove izabranog servisa.
Decidim::Bih.geocoder_user_agent = ENV["MI_GEOCODER_USER_AGENT"].presence
existing_images = Decidim.content_security_policies_extra["img-src"]
existing_images = existing_images.split if existing_images.is_a?(String)
Decidim.content_security_policies_extra = Decidim.content_security_policies_extra.merge(
  "img-src" => (Array(existing_images) + %w(*.tile.openstreetmap.org blob:)).uniq
)

# Empty bounds preserve generic geocoding; explicit invalid bounds fail closed.
Rails.application.config.to_prepare do
  scope = DecidimApp::Bijeljina::GeocoderScope
  scope.query_params
  geocoder = Decidim::Bih::Geo::Geocoder
  geocoder.prepend(scope) unless geocoder.ancestors.include?(scope)
end
