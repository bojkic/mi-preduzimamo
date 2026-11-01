# frozen_string_literal: true

# For tuning the Content Security Policy, check the Decidim documentation site
# https://docs.decidim.org/en/develop/customize/content_security_policy

# Keep this incremental: Decidim core/admin still relies on inline script/style
# allowances, but these directives are compatible with the current public/admin
# UI and reduce legacy embedding/base-URL attack surface.
Decidim.content_security_policies_extra = Decidim.content_security_policies_extra.merge(
  "base-uri" => "'self'",
  "manifest-src" => "'self'",
  "object-src" => "'none'"
)

# Consent-based analytics and campaign measurement. Exact vendor hosts only; no HTTPS wildcard.
{
  "script-src" => %w(https://www.googletagmanager.com https://static.cloudflareinsights.com https://www.googleadservices.com https://googleads.g.doubleclick.net https://www.google.com),
  "frame-src" => %w(https://www.googletagmanager.com),
  "connect-src" => %w(https://ad.doubleclick.net https://www.googletagmanager.com https://www.google-analytics.com https://region1.google-analytics.com https://analytics.google.com https://region1.analytics.google.com https://cloudflareinsights.com https://www.googleadservices.com https://www.google.com https://googleads.g.doubleclick.net https://stats.g.doubleclick.net https://pagead2.googlesyndication.com https://www.google.ba https://www.google.rs https://www.google.hr https://www.google.de),
  "img-src" => %w(https://ad.doubleclick.net https://www.googletagmanager.com https://www.google-analytics.com https://region1.google-analytics.com https://analytics.google.com https://region1.analytics.google.com https://www.googleadservices.com https://www.google.com https://googleads.g.doubleclick.net https://stats.g.doubleclick.net https://pagead2.googlesyndication.com https://www.google.ba https://www.google.rs https://www.google.hr https://www.google.de)
}.each do |directive, sources|
  existing = Decidim.content_security_policies_extra[directive]
  existing = existing.split if existing.is_a?(String)
  Decidim.content_security_policies_extra[directive] = (Array(existing) + sources).uniq
end
