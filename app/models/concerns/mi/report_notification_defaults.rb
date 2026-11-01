# frozen_string_literal: true

module Mi
  # Compatibility for older operator calls. New accounts inherit all topics
  # enabled; registration records its own explicit four-topic choice.
  module ReportNotificationDefaults
    extend ActiveSupport::Concern

    ORGANIZATION_HOST = "mi.fondacijabijeljina.com"

    def apply_report_notification_defaults(overwrite: false)
      return unless organization&.host == ORGANIZATION_HOST
      return unless persisted? && overwrite
      # The legacy overwrite flag cannot replace an explicit topic decision.
      return if Decidim::Bih::Messaging::Preference.exists?(user: self, topic: "report_updates")

      Decidim::Bih::TopicPreferences.set!(self, topic: :report_updates, enabled: true, source: "organization_default")
    end

    def apply_and_mirror_report_notification_defaults!(overwrite: false)
      apply_report_notification_defaults(overwrite:)
      self
    end
  end
end
