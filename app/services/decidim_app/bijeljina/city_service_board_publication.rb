# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    module CityServiceBoardPublication
      module_function

      def publish!(post:, identity:, expires_at:, context:)
        post.with_lock do
          if identity.present? && post.notification_capture_identity == identity
            revised = Decidim::Bih::PlatformDelivery.where(organization: post.organization, identity:, komsiluk_post_id: post.id)
                                                    .where.not(publication_revision: post.content_revision).exists?
            Decidim::Bih::Komsiluk::NoticePublishing.cancel_pending_phone_for!(post:, reason: "source_corrected") if revised
            # A surviving source can reword a placement without becoming a new
            # audience. Preserve every delivery/cancellation timestamp.
            Decidim::Bih::PlatformDelivery.where(organization: post.organization, identity:, komsiluk_post_id: post.id,
                                                 cancelled_at: nil).find_each do |receipt|
              receipt.with_lock do
                receipt.update!(publication_revision: post.content_revision,
                                expires_at: [receipt.expires_at, expires_at].compact.min,
                                fallback_context: receipt.fallback_context.merge(context.stringify_keys))
              end
            end
          else
            context = context.merge("notice_update" => true) if post.notification_capture_identity.present?
            Decidim::Bih::Komsiluk::NoticePublishing.publish!(post:, identity:, expires_at:, context:)
          end
        end
      end
    end
  end
end
