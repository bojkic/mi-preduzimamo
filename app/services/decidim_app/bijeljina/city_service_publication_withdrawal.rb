# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    class CityServicePublicationWithdrawal
      def self.call(event:, actor:, review_token:, note:, correct: false)
        return :not_authorized unless Decidim::Bih::OperatorAuthorization.allowed?(actor, :city_alerts_manage, organization: event.organization)
        return :note_required if note.to_s.strip.blank? || note.to_s.length > 2000

        CityServiceIncident.synchronize(event.organization) do
          event.with_lock do
            return :stale_review unless ActiveSupport::SecurityUtils.secure_compare(event.answer_review_token, review_token.to_s)
            return :not_publishable unless event.board_published? || event.published?

            from_state = event.state
            history = Array(event.extraction_metadata["publication_history"]) + [{
              "post_ids" => event.komsiluk_post_id_values, "revision" => event.publication_revision,
              "withdrawn_at" => Time.current.iso8601, "previous_state" => from_state
            }]
            metadata = event.extraction_metadata.merge("publication_revision" => SecureRandom.hex(16),
                                                       "publication_history" => history, "publication_correction_pending" => correct)
            event.update!(state: correct ? "pending_review" : "dismissed", reviewer: nil, reviewed_at: nil,
                          reviewed_content_version: nil, dismissed_at: correct ? nil : Time.current, review_note: note.to_s.strip,
                          extraction_metadata: metadata)
            # Retire the pending outbox atomically under the incident/event locks;
            # dispatch callbacks must not run for withdrawn work.
            CityServiceEffect.where(event_id: event.id, completed_at: nil)
                             .update_all(completed_at: Time.current, error_code: "source_withdrawn", updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
            CityServiceProjectionWithdrawal.call(event)
            Decidim::Bih::OperatorAuditEvent.record!(
              organization: event.organization, actor:,
              event_type: "city_service_event_withdrawn", permission: "city_alerts_manage",
              role: Decidim::Bih::OperatorAuthorization.role_for(actor, :city_alerts_manage, organization: event.organization), resource: event,
              metadata: { from_state:, to_state: event.state, correction_requested: correct, posts_count: event.komsiluk_post_id_values.size }
            )
            :withdrawn
          end
        end
      end
    end
  end
end
