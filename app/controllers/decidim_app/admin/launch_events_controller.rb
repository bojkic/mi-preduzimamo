# frozen_string_literal: true

module DecidimApp
  module Admin
    class LaunchEventsController < Decidim::Bih::Admin::ApplicationController
      before_action -> { require_bih_permission!(:broadcast_send_viber) }

      def show
        @event_configuration = LaunchEvent.configuration(current_organization)
        @event_key = LaunchEvent.event_key(current_organization, configuration: @event_configuration)
        @previews = LaunchEvent::MESSAGES.keys.index_with { |key| LaunchEvent.preview(current_organization, key, configuration: @event_configuration) }
      end

      def send_message
        key = params[:message_key].to_s
        return head :bad_request unless LaunchEvent::MESSAGES.has_key?(key)
        return head :unprocessable_entity unless params[:confirm] == "1"

        queued = LaunchEvent.enqueue!(organization: current_organization, key:, actor: current_user, expected_event_key: params[:event_key].to_s)
        redirect_to main_app.launch_event_admin_path, notice: "Poruka je zakazana za #{queued} korisnika. Ranije poslati primjerci neće se ponavljati."
      rescue ArgumentError, ActiveRecord::RecordInvalid => e
        redirect_to main_app.launch_event_admin_path, alert: e.is_a?(ActiveRecord::RecordInvalid) || e.message == "Event changed" ? I18n.t("mi_launch_event.changed") :
            (e.message == "Event is closed" ? I18n.t("mi_launch_event.not_open") : "Poruka nije zakazana.")
      end

      def test_message
        key = params[:message_key].to_s
        return head :bad_request unless LaunchEvent::MESSAGES.has_key?(key)

        queued = LaunchEvent.enqueue!(organization: current_organization, key:, actor: current_user, expected_event_key: params[:event_key].to_s, test_user: current_user)
        redirect_to main_app.launch_event_admin_path,
                    notice: queued.positive? ? "Probna poruka je zakazana samo za tvoj broj." : "Probna poruka je već poslata ili tvoj broj nije dostupan."
      rescue ArgumentError, ActiveRecord::RecordInvalid => e
        redirect_to main_app.launch_event_admin_path,
                    alert: e.is_a?(ActiveRecord::RecordInvalid) || e.message == "Event changed" ? I18n.t("mi_launch_event.changed") : I18n.t("mi_launch_event.not_open")
      end
    end
  end
end
