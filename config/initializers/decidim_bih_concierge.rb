# frozen_string_literal: true

# Optional reference adapter: explicit activation only. Resolve the host lazily
# after boot/reload; this initializer never queries a tenant or contacts a provider.
Rails.application.config.to_prepare do
  Decidim::Bih.concierge_resolver = if ENV["MI_ENABLE_REFERENCE_CONCIERGE"] == "true"
                                      -> { DecidimApp::Bijeljina::WebConcierge }
                                    end
end
