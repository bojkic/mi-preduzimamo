# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    class ReportRolloutReadinessEvent < Decidim::Events::BaseEvent
      include Decidim::Events::NotificationEvent

      def notification_title
        helpers = ActionController::Base.helpers
        text = I18n.t("decidim_app.report_rollout_readiness.notification", stage: extra.fetch("stage"),
                                                                           label: I18n.t("decidim_app.report_rollout_readiness.stages.#{extra.fetch("stage")}"))
        link = helpers.link_to(I18n.t("decidim_app.report_rollout_readiness.review"), resource_path)
        helpers.safe_join([helpers.sanitize(text), link], " ")
      end

      def resource_path = "/admin/bih/governance"

      def resource_url = "https://#{organization.host}#{resource_path}"

      def resource_title = nil
    end
  end
end
