# frozen_string_literal: true

module DecidimApp
  module Admin
    class KomsilukSourcesController < Decidim::Bih::Admin::ApplicationController
      before_action -> { require_bih_permission!(:city_alerts_manage) }
      before_action :load_source

      def show
        response.headers["Cache-Control"] = "private, no-store"
        @events = @actions.events.to_a
        @posts = @actions.posts.to_a
        @action_token = @actions.token
        receipts = Decidim::Bih::PlatformDelivery.where(organization: current_organization, komsiluk_post_id: @posts.map(&:id))
        @pending_count = receipts.where(cancelled_at: nil, inbox_created_at: nil).count
        @phone_handoffs = receipts.where.not(account_notification_id: nil).count
      end

      def update
        result = @actions.call(action: params[:source_action].to_s, event_id: params[:event_id], token: params[:action_token], note: params[:review_note])
        if result == :withdrawn && params[:source_action] == "correct_source"
          redirect_to decidim_app_admin_city_service_events_path(tab: "review", event_id: params[:event_id]),
                      notice: t("decidim_app.komsiluk_boards.results.correction")
        else
          redirect_to decidim_app_admin_komsiluk_source_path(@post),
                      **{ (result == :withdrawn ? :notice : :alert) => t("decidim_app.komsiluk_boards.results.#{result}") }
        end
      end

      private

      def load_source
        @post = Decidim::Bih::KomsilukPost.where(organization: current_organization).find(params[:id])
        @actions = DecidimApp::Bijeljina::CityServiceBoardActions.new(post: @post, actor: current_user)
        raise ActiveRecord::RecordNotFound unless @actions.events.exists?
      end
    end
  end
end
