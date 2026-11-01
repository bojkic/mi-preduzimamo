# frozen_string_literal: true

# The weekly analytics digest (decidim_bih:analytics:digest) appends the host's
# content-review reminders: today, the foundation call-status review window
# when it is within 14 days of expiry (or already expired). Aggregate lines
# only — a date, a day count and the admin URL.
Decidim::Bih.analytics_digest_reminders_provider = lambda do |organization:|
  DecidimApp::Bijeljina::ContentReviewReminders.call(organization:)
end
