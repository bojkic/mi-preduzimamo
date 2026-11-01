# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    class CityServiceBoardModeration
      def self.around_decision(post:, **_kwargs)
        return yield unless CityServiceBoardVisibility.linked?(post)

        CityServiceIncident.synchronize(post.organization) { yield }
      end

      def self.after_decision(post:, action:, **_kwargs)
        return unless CityServiceBoardVisibility.linked?(post)

        if action == :hide || action == :restore
          metadata = post.details.deep_dup
          metadata["moderation"] = metadata.fetch("moderation", {}).merge("source_hold" => action == :hide)
          post.update!(details: metadata)
        end
        Decidim::Bih::Komsiluk::NoticePublishing.cancel_pending_for!(post:, reason: "projection_hidden") if action == :hide
      end

      def self.review_links(post:, user:, organization:)
        return [] unless Decidim::Bih::OperatorAuthorization.allowed?(user, :city_alerts_manage, organization:)
        return [] unless CityServiceBoardVisibility.linked?(post)

        [{ label: I18n.t("decidim_app.komsiluk_boards.manage_source"),
           url: Rails.application.routes.url_helpers.decidim_app_admin_komsiluk_source_path(post) }]
      end
    end
  end
end
