# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    # Retire one source observation, keeping a board projection only when a
    # currently published corroborating observation still supports that board.
    # Caller holds the organization incident lock before event/post locks.
    class CityServiceProjectionWithdrawal
      def self.call(event)
        posts = Decidim::Bih::KomsilukPost.where(decidim_organization_id: event.decidim_organization_id,
                                                 decidim_user_id: nil, id: event.komsiluk_post_id_values)
        posts.order(:id).each do |post|
          replacement = supporting_event(event, post)
          if replacement
            refresh_projection(event, post, replacement)
          else
            post.update!(status: post.status == "hidden" ? "hidden" : "expired", expires_at: Time.current)
            Decidim::Bih::Komsiluk::NoticePublishing.cancel_pending_for!(post:, reason: "source_withdrawn")
          end
        end
        CityServiceIncidentBoardEffects.refresh!(event.incident) if event.incident_id
      end

      def self.supporting_event(event, post)
        return unless event.incident_id

        event.incident.events.where.not(id: event.id).where(state: %w(board_published published)).order(:id).detect do |member|
          member.publication_blocker.nil? && Array(member.target_komsiluk_slugs).include?(post.komsiluk.slug)
        end
      end

      def self.refresh_projection(event, post, replacement)
        post.correct!(by: nil, expected_revision: post.content_revision, notify: false,
                      attributes: { title: replacement.title.truncate(Decidim::Bih::KomsilukPost::TITLE_MAX),
                                    body: replacement.summary.truncate(Decidim::Bih::KomsilukPost::BODY_MAX),
                                    expires_at: replacement.ends_at,
                                    details: post.details.merge("source" => CityServiceBoardMetadata.for_event(replacement)) })
        identity = CityServiceIncidentIdentity.delivery_identity(replacement)
        if post.notification_capture_identity == identity && CityServiceBoardVisibility.current?(post)
          CityServiceBoardPublication.publish!(post:, identity:, expires_at: replacement.ends_at,
                                               context: { event_id: replacement.id, event_revision: replacement.publication_revision })
        end
        event.incident.projections.find_by(post:)&.update!(revision: replacement.publication_revision || CityServiceIncidentIdentity.revision(replacement))
      end
    end
  end
end
