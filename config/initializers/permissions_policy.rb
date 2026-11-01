# Be sure to restart your server when you modify this file.

# frozen_string_literal: true

# Browser security headers that are safe for Decidim's current public/admin UI.
# Keep `unload=(self)`: Decidim uses it for unsaved-form protection and only
# adds its fallback header when no Permissions-Policy is already present.
Rails.application.config.action_dispatch.default_headers.merge!(
  "Cross-Origin-Opener-Policy" => "same-origin-allow-popups",
  "Permissions-Policy" => [
    "camera=()",
    "microphone=()",
    "payment=()",
    "usb=()",
    "gyroscope=()",
    "geolocation=(self)",
    "fullscreen=(self)",
    "unload=(self)"
  ].join(", "),
  "Referrer-Policy" => "strict-origin-when-cross-origin",
  "X-Content-Type-Options" => "nosniff",
  "X-Download-Options" => "noopen",
  "X-Permitted-Cross-Domain-Policies" => "none",
  "X-Frame-Options" => "SAMEORIGIN"
)
