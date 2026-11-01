# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    class CityServiceIncidentReview
      def initialize(event:, actor: nil)
        @event = event
        @actor = actor
      end

      # Keep decision guards visible beside their locked mutation.
      # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
      def candidates
        return [] unless @event.starts_at && @event.ends_at

        events = CityServiceEvent.for_organization(@event.organization).where.not(id: @event.id)
                                 .where.not(state: %w(dismissed superseded)).where(superseded_by_id: nil)
                                 .where("starts_at < ? AND ends_at > ?", @event.ends_at, @event.starts_at).order(id: :desc).limit(200)
        events.filter_map do |other|
          next unless CityServiceIncidentIdentity.service(other) == CityServiceIncidentIdentity.service(@event)

          decision = decision_for(other)
          next if different_assets?(other) && !decision
          next unless comparable_place?(other)

          { event: other, reason: decision&.decision == "same" ? "confirmed_same_incident" : "overlapping_service_time_and_place",
            confidence: exact_facts?(other) ? "high" : "review", decision: decision&.decision,
            review_token: other.answer_review_token }
        end
      end
      # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

      # Keep decision guards visible beside their locked mutation.
      # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
      def resolve!(other_event_id:, decision:, review_token:, other_review_token:)
        return :not_authorized unless authorized?
        return :invalid_selection unless %w(same separate undo).include?(decision)

        CityServiceIncident.synchronize(@event.organization) do
          other = CityServiceEvent.for_organization(@event.organization).find_by(id: other_event_id)
          return :invalid_selection unless other && other.id != @event.id

          [@event, other].sort_by(&:id).each(&:lock!)
          return :stale_review unless secure_token?(@event, review_token) && secure_token?(other, other_review_token)
          return :invalid_selection unless CityServiceIncidentIdentity.service(other) == CityServiceIncidentIdentity.service(@event)

          record = decision_for(other) || CityServiceDuplicateDecision.new(decidim_organization_id: @event.decidim_organization_id,
                                                                           event_id: [@event.id, other.id].min, other_event_id: [@event.id, other.id].max)
          return :unchanged if record.persisted? && record.decision == decision

          CityServiceIncidentIdentity.attach!(@event)
          CityServiceIncidentIdentity.attach!(other)
          if decision == "same"
            merge!(other, record)
          elsif decision == "undo"
            return :invalid_selection unless record.persisted?

            return :subsequent_merge_requires_review unless undo_current?(record)

            undo!(record)
          elsif @event.incident_id == other.incident_id
            return :undo_required
          end
          record.update!(decision:, reviewer_id: @actor.id)
          Decidim::Bih::OperatorAuditEvent.record!(organization: @event.organization, actor: @actor,
                                                   event_type: "city_service_duplicate_decision", permission: "city_alerts_manage", resource: @event,
                                                   metadata: { other_event_id: other.id, decision:, previous_memberships: record.previous_memberships })
          :updated
        end
      end
      # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

      private

      def authorized?
        Decidim::Bih::OperatorAuthorization.allowed?(@actor, :city_alerts_manage, organization: @event.organization)
      end

      def secure_token?(event, token)
        ActiveSupport::SecurityUtils.secure_compare(event.answer_review_token, token.to_s)
      end

      def decision_for(other)
        CityServiceDuplicateDecision.find_by(event_id: [@event.id, other.id].min, other_event_id: [@event.id, other.id].max)
      end

      def different_assets?(other)
        %w(tj feeder).any? do |field|
          mine, theirs = [@event, other].map { |event| Decidim::Bih::Text.fold(event.extraction_metadata[field]) }
          mine.present? && theirs.present? && mine != theirs
        end
      end

      def comparable_place?(other)
        @event.area_slugs.empty? || other.area_slugs.empty? || @event.area_slugs.intersect?(other.area_slugs) ||
          @event.targeting_level == "citywide" || other.targeting_level == "citywide"
      end

      def exact_facts?(other)
        @event.area_slugs.any? && CityServiceIncidentIdentity.revision(@event) == CityServiceIncidentIdentity.revision(other)
      end

      def merge!(other, record)
        return if @event.incident_id == other.incident_id

        keep, remove = [@event.incident, other.incident].sort_by(&:id)
        members = CityServiceEvent.where(incident_id: [keep.id, remove.id]).order(:id).lock.to_a
        record.previous_memberships = members.to_h { |event| [event.id.to_s, event.incident_id] }
        delivery_groups = members.group_by { |member| CityServiceIncidentIdentity.delivery_facts(member) }.values.map do |group|
          group.map { |member| CityServiceIncidentIdentity.delivery_identity(member) }.uniq
        end
        # Resolve the delivery anchor while both captured publications and their
        # original receipt evidence still exist. The retained post must carry
        # that identity; changing its marker would invent a new capture.
        CityServiceIncidentIdentity.bind_delivery!(members)
        remove.projections.includes(:post, :komsiluk).order(:id).each do |projection|
          existing = keep.projections.find_by(komsiluk_id: projection.komsiluk_id)
          if existing
            merge_projection!(existing, projection, keep:, members:, delivery_groups:)
          else
            projection.update!(incident: keep)
          end
        end
        rebind_members!(members, keep)
        CityServiceIncidentBoardEffects.refresh!(keep)
      end

      def merge_projection!(existing, incoming, keep:, members:, delivery_groups:)
        candidates = [existing, incoming]
        candidates.map(&:post).sort_by(&:id).each(&:lock!)
        source = members.find do |member|
          %w(board_published published).include?(member.state) && member.publication_blocker.nil? &&
            Array(member.target_komsiluk_slugs).include?(incoming.komsiluk.slug)
        end
        identity = CityServiceIncidentIdentity.delivery_identity(source) if source
        retained = candidates.find { |candidate| identity.present? && candidate.post.notification_capture_identity == identity } || existing
        retired = (candidates - [retained]).sole
        cancel_corroborated_delivery!(retained.post, retired.post, delivery_groups:)
        preserve_projection_hold!(retained.post, retired.post)
        retire_projection_post!(retired.post, reason: "incident_merged")
        retired.destroy!
        retained.update!(incident: keep) unless retained.incident_id == keep.id
      end

      def cancel_corroborated_delivery!(retained, retired, delivery_groups:)
        identities = [retained.notification_capture_identity, retired.notification_capture_identity]
        return if identities.any?(&:blank?) || delivery_groups.none? { |group| (identities - group).empty? }

        receipts = Decidim::Bih::PlatformDelivery.where(organization: retained.organization)
        prior = receipts.where(komsiluk_post_id: retired.id, identity: retired.notification_capture_identity)
        current = receipts.where(komsiluk_post_id: retained.id, identity: retained.notification_capture_identity, cancelled_at: nil)
        # Keep proof on the receipt that actually reached the person. A global
        # anchor may belong to a different person than this earlier dispatch.
        current.where(decidim_user_id: dispatched_receipts(prior).select(:decidim_user_id))
               .where.not(id: dispatched_receipts(current).select(:id)).order(:id).lock.each do |receipt|
          receipt.update!(cancelled_at: Time.current, cancellation_reason: "duplicate_incident_already_dispatched")
          cancel_receipt_phone!(receipt)
        end
      end

      def dispatched_receipts(scope)
        accepted_push = Decidim::Bih::Messaging::Attempt.where(channel: "push").where.not(accepted_at: nil).select(:intent_id)
        scope.where("inbox_created_at IS NOT NULL OR notification_dispatched_at IS NOT NULL OR acknowledged_at IS NOT NULL " \
                    "OR browser_displayed_at IS NOT NULL OR inbox_read_at IS NOT NULL")
             .or(scope.where(push_intent_id: accepted_push))
      end

      def cancel_receipt_phone!(receipt)
        Decidim::Bih::KomsilukPhoneDelivery.where(platform_delivery: receipt, status: "pending").order(:id).each do |delivery|
          delivery.with_lock do
            next unless delivery.status == "pending"

            delivery.update!(status: "skipped", reason: "duplicate_incident_already_dispatched")
            Decidim::Bih::Komsiluk::NoticePhonePolicy.release_budget!(delivery)
          end
        end
      end

      def preserve_projection_hold!(retained, retired)
        return unless retired.hidden? || retired.details.dig("moderation", "source_hold") == true

        details = retained.details.deep_dup
        moderation = details.fetch("moderation", {}).merge("source_hold" => true, "merged_hold_post_id" => retired.id)
        attributes = { details: details.merge("moderation" => moderation) }
        if retired.hidden? && !retained.hidden?
          moderation["previous_status"] = retained.status
          attributes.merge!(status: "hidden", hidden_at: retired.hidden_at || Time.current, review_state: "pending")
        end
        retained.update!(attributes)
        Decidim::Bih::Komsiluk::NoticePublishing.cancel_pending_for!(post: retained, reason: "incident_merged_hold")
      end

      def rebind_members!(members, keep)
        posts_by_slug = keep.projections.includes(:komsiluk).to_h { |projection| [projection.komsiluk.slug, projection.post_id] }
        members.each do |event|
          attributes = { incident: keep, extraction_metadata: event.extraction_metadata.merge("incident_reviewed_at" => Time.current.iso8601) }
          if event.board_published? || event.published?
            attributes[:komsiluk_post_ids] = Array(event.target_komsiluk_slugs).filter_map { |slug| posts_by_slug[slug] }
            attributes[:state] = "pending_review" if attributes[:komsiluk_post_ids].empty?
          end
          event.update!(attributes)
        end
      end

      def retire_projection_post!(post, reason:)
        post.with_lock do
          post.update!(status: post.status == "hidden" ? "hidden" : "expired", expires_at: Time.current)
          Decidim::Bih::Komsiluk::NoticePublishing.cancel_pending_for!(post:, reason:)
        end
      end

      def undo_current?(record)
        memberships = record.previous_memberships
        return true if memberships.empty?

        members = CityServiceEvent.for_organization(@event.organization).where(id: memberships.keys)
        current_ids = CityServiceEvent.for_organization(@event.organization).where(incident_id: members.select(:incident_id)).pluck(:id).map(&:to_s).sort
        current_ids == memberships.keys.sort
      end

      def undo!(record)
        # Already-sent messages cannot be recalled. Reopen publication review
        # after splitting so an old projection cannot silently be reactivated.
        incident_ids = record.previous_memberships.values.uniq
        CityServiceProjection.where(incident_id: incident_ids).find_each do |projection|
          retire_projection_post!(projection.post, reason: "incident_split")
          projection.destroy!
        end
        record.previous_memberships.each do |id, incident_id|
          event = CityServiceEvent.for_organization(@event.organization).find_by(id:)
          next unless event

          event.komsiluk_post_id_values.each do |post_id|
            Decidim::Bih::KomsilukPost.where(id: post_id, decidim_organization_id: event.decidim_organization_id, decidim_user_id: nil)
                                      .find_each { |post| retire_projection_post!(post, reason: "incident_split") }
          end
          event.update!(incident_id:, state: "pending_review", komsiluk_post_ids: [], target_komsiluk_slugs: [],
                        reviewed_content_version: nil,
                        extraction_metadata: event.extraction_metadata.except("publication_revision", "incident_delivery_binding").merge("duplicate_undo" => true))
        end
      end
    end
  end
end
