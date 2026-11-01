# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    # Called under the organization incident lock. Refresh only board intent;
    # external fallback authorization remains bound to its original observation.
    class CityServiceIncidentBoardEffects
      def self.refresh!(incident)
        members = incident.events.where(state: %w(board_published published)).order(:id).select { |event| event.publication_blocker.nil? }
        incident.projections.includes(:post, :komsiluk).order(:id).each do |projection|
          next unless CityServiceBoardVisibility.current?(projection.post)

          event = members.find { |member| Array(member.target_komsiluk_slugs).include?(projection.komsiluk.slug) }
          next unless event

          refresh_projection!(projection, event)
        end
      end

      def self.refresh_projection!(projection, event)
        identity = CityServiceIncidentIdentity.delivery_identity(event)
        effect = CityServiceEffect.find_or_initialize_by(identity: "#{identity}:board:#{projection.post_id}")
        return if effect.persisted? && effect.completed_at && effect.error_code.nil?

        # A prior stale observation may have completed this intent without
        # delivery. Rebind it to surviving support; receipt uniqueness still
        # prevents another push/inbox for recipients already reached.
        effect.assign_attributes(event:, kind: "board", completed_at: nil, error_code: nil,
                                 payload: { "post_id" => projection.post_id, "board_url" => board_url(event, projection.post),
                                            "event_revision" => event.publication_revision, "delivery_identity" => identity })
        existed = effect.persisted?
        effect.save!
        ActiveRecord.after_all_transactions_commit { effect.enqueue } if existed
      end

      def self.board_url(event, post)
        Decidim::Bih::Engine.routes.url_helpers.komsiluk_board_url(
          post, script_name: Decidim::Bih.normalized_public_mount_path, host: event.organization.host, protocol: Rails.application.config.force_ssl ? "https" : "http"
        )
      end
    end
  end
end
