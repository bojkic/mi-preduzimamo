# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    class KomsilukBoardContext
      def self.call(organization:, user:, komsiluk:, post: nil)
        return [] unless user && user.decidim_organization_id == organization.id && komsiluk&.decidim_organization_id == organization.id

        routes = Decidim::Bih::Engine.routes.url_helpers
        host = Rails.application.routes.url_helpers
        mount = { script_name: Decidim::Bih.normalized_public_mount_path }
        readable_post = post&.current? && post.komsiluk_id == komsiluk.id
        links = [
          { label: I18n.t("decidim_app.komsiluk_boards.context.services"), url: host.komsiluk_services_path },
          { label: I18n.t("decidim_app.komsiluk_boards.context.reports"), url: routes.reports_path(**mount) },
          { label: I18n.t("decidim_app.komsiluk_boards.context.projects"), url: routes.community_projects_path(**mount),
            description: I18n.t("decidim_app.komsiluk_boards.context.citywide") },
          { label: I18n.t("decidim_app.komsiluk_boards.context.volunteer"), url: routes.volunteer_path(**mount) }
        ]
        opportunities = Decidim::Bih::VolunteerOpportunity.publicly_visible.where(organization:, komsiluk_id: komsiluk.id, cancelled_at: nil)
                                                          .where("ends_at IS NULL OR ends_at > ?", Time.current).order(starts_at: :asc, id: :desc).limit(3)
        links += opportunities.map do |opportunity|
          { label: opportunity.title, url: routes.volunteer_path(**mount, opportunity_id: opportunity.id, anchor: "volunteer-opportunity-#{opportunity.id}") }
        end
        source = readable_post ? KomsilukNoticePublicSource.call(organization:, post:) : { updating: false, url: nil }
        actions = [{ label: I18n.t("decidim_app.komsiluk_boards.context.ask"),
                     url: readable_post && !source[:updating] ? host.komsiluk_notice_help_path(post) : routes.mi_bot_path(**mount) }]
        if readable_post
          actions << { label: I18n.t("decidim_app.komsiluk_boards.context.report_problem"), url: routes.new_report_path(**mount) }
          if source[:url].present? && !source[:updating]
            actions << { label: I18n.t("decidim_app.komsiluk_boards.context.source_record"), url: source[:url] }
          end
        end
        (actions + links).uniq { |item| item.fetch(:url) }
      end
    end
  end
end
