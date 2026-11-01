# frozen_string_literal: true

module DecidimApp
  class LaunchEventPollsController < Decidim::ApplicationController
    layout "decidim/application"
    before_action :authenticate_user!, only: :vote
    before_action :uncached_response

    def show
      @event_configuration = LaunchEvent.configuration(current_organization)
      @event_key = LaunchEvent.event_key(current_organization, configuration: @event_configuration)
      @event_phase = @event_configuration&.enabled? ? @event_configuration.phase(now: Time.current) : "unavailable"
      @vote = votes(@event_key).find_by(user: current_user) if current_user && @event_key
      @results = LaunchEvent.results(current_organization)
    end

    def results
      if params.key?(:event_key) && params[:event_key].to_s != LaunchEvent.event_key(current_organization).to_s
        return render json: { error: I18n.t("mi_launch_event.changed") }, status: :conflict
      end
      render json: LaunchEvent.results(current_organization)
    end

    def vote
      unless current_user.decidim_organization_id == current_organization.id &&
             LaunchEvent.phone_for(current_user, current_organization).present?
        return render json: { error: "Za glasanje je potreban potvrđen broj telefona." }, status: :forbidden
      end
      identity = params[:event_key].to_s
      unless LaunchEvent.current_event?(current_organization, identity, now: Time.current)
        return render json: { error: I18n.t("mi_launch_event.changed") }, status: :unprocessable_entity
      end

      choice = params[:choice].to_s
      return render json: { error: "Izaberi jedan odgovor." }, status: :unprocessable_entity unless LaunchEvent::CHOICES.has_key?(choice)

      # Database uniqueness, not a cookie or a prior count, enforces one vote.
      @vote = votes(identity).create_or_find_by!(user: current_user) { |record| record.choice = choice }
      respond_to do |format|
        format.json { render json: LaunchEvent.results(current_organization).merge(voted: @vote.choice) }
        format.html { redirect_to main_app.launch_event_poll_path, notice: I18n.t("mi_launch_event.recorded") }
      end
    rescue ActiveRecord::RecordInvalid
      render json: { error: I18n.t("mi_launch_event.changed") }, status: :unprocessable_entity
    end

    private

    def votes(identity)
      LaunchEventVote.where(organization: current_organization, event_key: identity)
    end

    def uncached_response
      response.cache_control.replace(no_store: true, private: true)
    end
  end
end
