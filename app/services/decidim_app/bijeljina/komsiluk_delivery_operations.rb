# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    # Reuse the canonical source workflow. Only public event references and
    # counts cross this seam; no recipients, source copy or provider errors.
    class KomsilukDeliveryOperations
      def self.call(organization:, actor:)
        return [] unless Decidim::Bih::OperatorAuthorization.allowed?(actor, :city_alerts_manage, organization:)

        workflow = CityServiceWorkflow.new(organization:)
        entries = workflow.current_entries.index_by { |entry| entry.event.id }
        effects = CityServiceEffect.where(event_id: entries.keys, kind: "board", completed_at: nil)
        failed = entries.filter_map { |id, entry| id if entry.event.state == "failed" }
        failed |= effects.where.not(error_code: [nil, ""]).distinct.pluck(:event_id)
        stalled = effects.where("last_attempt_at < :cutoff OR (last_attempt_at IS NULL AND created_at < :cutoff)", cutoff: 15.minutes.ago)
                         .distinct.pluck(:event_id)
        expired = entries.filter_map { |id, entry| id if entry.reason == "expired_unpublished" }
        { "source_failed" => failed, "source_stalled" => stalled, "source_expired" => expired }.map do |kind, ids|
          links = ids.sort.reverse.first(10).map do |id|
            { id:, path: route(tab: entries.fetch(id).tab, event_id: id, anchor: "city-service-event-#{id}") }
          end
          { kind:, count: ids.size, links:, path: route(tab: kind == "source_expired" ? "done" : "review") }
        end
      end

      def self.route(**query)
        Rails.application.routes.url_helpers.decidim_app_admin_city_service_events_path(**query)
      end
      private_class_method :route
    end
  end
end
