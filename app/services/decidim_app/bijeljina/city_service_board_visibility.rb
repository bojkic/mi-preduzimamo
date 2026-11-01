# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    # Resolve through durable source relationships, never through an authorless
    # row or client-supplied details. Callers serialize decisions with the
    # organization incident lock before taking event/post/profile locks.
    module CityServiceBoardVisibility
      module_function

      def events_for(post)
        scope = CityServiceEvent.for_organization(post.organization)
        incident_ids = CityServiceProjection.where(post_id: post.id).select(:incident_id)
        scope.where(incident_id: incident_ids).or(scope.where("komsiluk_post_ids @> ?::jsonb", [post.id].to_json))
      end

      def linked?(post)
        events_for(post).exists?
      end

      def current_for_recipient?(event:, user_id:)
        profile = Decidim::Bih::CitizenProfile.find_by(organization: event.organization, decidim_user_id: user_id)
        return false unless profile&.assigned?

        posts = Decidim::Bih::KomsilukPost.where(organization: event.organization, komsiluk_id: profile.komsiluk_id,
                                                 id: event.komsiluk_post_id_values)
        posts.any? { |post| current?(post) }
      end

      def current?(post)
        post.status == "open" && (post.expires_at.nil? || post.expires_at > Time.current) &&
          post.details.dig("moderation", "source_hold") != true
      end

      def phone_blocker(post:, user: nil)
        if post.details["source_record"].present?
          return Decidim::Bih::Komsiluk::NoticePublishing.source_current?(post) ? nil : "source_changed_or_expired"
        end
        return "source_unavailable" unless linked?(post)
        return "notice_unavailable" unless current?(post)
        return "service_alerts_disabled" unless CityServiceSources.alerts_enabled?

        members = events_for(post).where(state: %w(board_published published)).order(:id).select do |event|
          event.publication_revision.present? && event.publication_blocker.nil? &&
            event.komsiluk_post_id_values.include?(post.id) && Array(event.target_komsiluk_slugs).include?(post.komsiluk.slug)
        end
        return "source_changed_or_expired" if members.empty?
        return "source_review_required" unless members.any?(&:facts_confirmed?)

        verified = members.select { |event| event.facts_confirmed? && !CityServicePhoneDelivery.phone_audience_unverified?(event) }
        return "phone_audience_unverified" if verified.empty?
        return nil unless user
        return "recipient_area_changed" unless user.decidim_organization_id == post.decidim_organization_id &&
                                               verified.any? do |event|
                                                 current_for_recipient?(event:, user_id: user.id) &&
                                                 CityServiceAlertNotificationJob.recipient_current?(event, user.id)
                                               end

        nil
      end

      def dispatch(post:, user:)
        return KomsilukNoticeSources.with_source_lock(post:) { yield } if post.details["source_record"].present?

        CityServiceIncident.synchronize(post.organization) do
          # This lock encloses the engine's post/intent claim and provider call.
          return if phone_blocker(post: post.reload, user:)

          yield
        end
      end
    end
  end
end
