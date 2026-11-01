# frozen_string_literal: true

require "date"
require "yaml"

module DecidimApp
  module Bijeljina
    # Host reminder lines for the weekly analytics digest
    # (Decidim::Bih.analytics_digest_reminders_provider). Aggregate operational
    # text only: a date, a day count and an admin URL — never citizen data.
    #
    # Today it watches one thing: the foundation call-status review window that
    # Milica::FoundationRead enforces. The effective expiry is the APPROVED
    # FoundationStatusOverride when one exists, otherwise the shipped
    # `config/milica/foundation_sources.yml` — exactly the value FoundationRead
    # itself would use, so the reminder can never disagree with the answer.
    module ContentReviewReminders
      WINDOW_DAYS = 14
      ADMIN_PATH = "/admin/bih/foundation-status"

      class << self
        def call(organization:, today: Date.current)
          expires_on = effective_foundation_expiry(organization)
          return [] unless expires_on

          days_left = (expires_on - today).to_i
          return [] if days_left > WINDOW_DAYS

          key = days_left.negative? ? "expired" : "expiring"
          [
            I18n.t("decidim_app.admin.foundation_status.digest_reminder.#{key}",
                   date: expires_on.strftime("%d.%m.%Y."), days: days_left,
                   url: "https://#{organization.host}#{ADMIN_PATH}")
          ]
        end

        def effective_foundation_expiry(organization)
          return if DecidimApp::Bijeljina::Milica::FoundationRead::METADATA_PATH.empty?

          override = DecidimApp::Bijeljina::FoundationStatusOverride.approved_for(organization)
          return override.review_expires_on if override&.review_expires_on

          shipped = YAML.safe_load_file(DecidimApp::Bijeljina::Milica::FoundationRead::METADATA_PATH, aliases: false)
          Date.iso8601(shipped.fetch("review_expires_on"))
        end
      end
    end
  end
end
