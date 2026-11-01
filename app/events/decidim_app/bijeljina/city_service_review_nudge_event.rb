# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    # The admin bell for CityServiceReviewNudge. The resource is the admin
    # being told, as in the engine's OperatorRoleExpiryEvent; the link goes to
    # the review queue, not to one alert, because the queue is the work.
    class CityServiceReviewNudgeEvent < Decidim::Events::BaseEvent
      include Decidim::Events::NotificationEvent

      def notification_title
        ActionController::Base.helpers.sanitize(
          I18n.t("decidim_app.city_service_review_nudge.notification", count: extra["count"].to_i, title: extra["title"].to_s)
        ).html_safe
      end

      def resource_path
        Rails.application.routes.url_helpers.decidim_app_admin_city_service_events_path(tab: "review")
      end

      def resource_url
        Rails.application.routes.url_helpers.decidim_app_admin_city_service_events_url(tab: "review", host: organization&.host)
      end

      def resource_title = nil
    end
  end
end
