# frozen_string_literal: true

module DecidimApp
  class KomsilukContextController < Decidim::ApplicationController
    before_action :authenticate_user!
    before_action :require_membership

    def services
      @entries = Bijeljina::CityDirectory.for(current_organization).all
      response.headers["Cache-Control"] = "private, no-store"
    end

    def notice_help
      @post = Decidim::Bih::KomsilukPost.visible.where(organization: current_organization, komsiluk_id: @profile.komsiluk_id).find(params[:id])
      if Bijeljina::KomsilukNoticePublicSource.call(organization: current_organization, post: @post)[:updating]
        redirect_to Decidim::Bih::Engine.routes.url_helpers.komsiluk_board_path(@post, script_name: Decidim::Bih.normalized_public_mount_path), alert: I18n.t("decidim_app.komsiluk_boards.context.source_changed")
        return
      end
      @prompt = I18n.t("decidim_app.komsiluk_boards.context.read_reference", id: @post.id)
      response.headers["Cache-Control"] = "private, no-store"
    end

    private

    def require_membership
      @profile = Decidim::Bih::CitizenProfile.find_by(organization: current_organization, user: current_user)
      return if current_user.decidim_organization_id == current_organization.id && @profile&.assigned?

      redirect_to Decidim::Bih::Engine.routes.url_helpers.edit_komsiluk_path(script_name: Decidim::Bih.normalized_public_mount_path)
    end
  end
end
