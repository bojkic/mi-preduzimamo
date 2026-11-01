# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    class CityServiceEventPublisher
      def initialize(event, actor:, review_token: event.answer_review_token)
        @event = event
        @actor = actor
        @review_token = review_token.to_s
      end

      def publish_board!(viber_fallback: false, channels: ["viber"], template: nil)
        return publish_with_viber_review!(channels:, template:) if viber_fallback

        publish!(delivery_recommendation: "board_only", next_state: "board_published", operator_approved: false)
      end

      def publish_with_viber_review!(channels: ["viber"], template: nil)
        @delivery_channels = channels
        @delivery_template = template
        publish!(delivery_recommendation: "viber_alert", next_state: "published", operator_approved: true)
      end

      def publish_automatically!(policy_version:)
        @automation_version = policy_version
        publish!(delivery_recommendation: "board_only", next_state: "board_published", operator_approved: false)
      end

      # Board only, after an hour without a staff reaction (CityServiceHeldFallback).
      def publish_held_fallback!
        @automation_version = CityServiceHeldFallback::VERSION
        publish!(delivery_recommendation: "board_only", next_state: "board_published", operator_approved: false)
      end

      private

      attr_reader :event, :actor

      def publish!(delivery_recommendation:, next_state:, operator_approved:)
        CityServiceIncident.synchronize(event.organization) { publish_locked!(delivery_recommendation:, next_state:, operator_approved:) }
      end

      def publish_locked!(delivery_recommendation:, next_state:, operator_approved:)
        event.with_lock do
          event.reload
          refusal = publication_refusal(next_state)
          return refusal if refusal

          from_state = event.state
          CityServiceIncidentIdentity.attach!(event)
          prepare_publication_revision!
          result = CityServiceNoticePublisher.new(
            organization: event.organization,
            classifier: StaticClassifier.new(event:, delivery_recommendation:),
            operator_approved:,
            delivery_options: {
              publish_board: publish_board_posts_for?(next_state),
              event_id: event.id, event_revision: event.publication_revision, expires_at: event.ends_at,
              existing_post_ids: event.komsiluk_post_id_values,
              incident_id: event.incident_id, delivery_identity: CityServiceIncidentIdentity.delivery_identity(event),
              delivery_channels: @delivery_channels || ["viber"], delivery_template: @delivery_template
            }
          ).call(notice: notice_payload)

          if result.status == :published
            event.update!(
              state: publication_state(next_state, result),
              extraction_metadata: event.extraction_metadata.merge("board_audience_identity" => CityServiceIncidentIdentity.delivery_identity(event)),
              reviewer: actor,
              reviewed_at: actor ? Time.current : nil,
              reviewed_content_version: actor ? event.content_version : nil,
              published_at: Time.current,
              komsiluk_post_ids: result.post_ids,
              target_komsiluk_slugs: result.target_komsiluk_slugs,
              affected_area_slugs: published_area_slugs(result),
              viber_delivery: result.policy_decision&.fetch(:delivery, nil),
              viber_dedupe_key: result.policy_decision&.fetch(:dedupe_key, nil),
              viber_jobs_count: result.viber_jobs_count,
              viber_recipients_count: result.viber_recipients_count,
              policy_snapshot: result.policy_decision || {}
            )
          else
            record_publication_failure(result)
          end

          record_audit!(result, from_state:)

          result
        end
      end

      def publication_refusal(next_state)
        return not_publishable_result(:source_disabled_by_owner) unless CityServiceSources.enabled?(event.source_key)

        if @automation_version
          policy = CityServiceAutomationPolicy.new(organization: event.organization)
          blockers = CityServiceAutomation.new(organization: event.organization).blockers(event)
          authorized = policy.mode(event.source_key) == "automatic" &&
                       ((@automation_version == CityServiceAutomationPolicy::VERSION && blockers.empty?) ||
                        (@automation_version == CityServiceHeldFallback::VERSION && CityServiceHeldFallback.publishable_blockers?(blockers)))
          return not_publishable_result(:not_authorized) unless authorized
        else
          return not_publishable_result(:not_authorized) unless Decidim::Bih::OperatorAuthorization.allowed?(actor, :city_alerts_manage, organization: event.organization)
        end
        return not_publishable_result(:stale_review) unless ActiveSupport::SecurityUtils.secure_compare(event.answer_review_token, @review_token)
        if next_state == "published" && CityServicePhoneDelivery.phone_audience_unverified?(event)
          return not_publishable_result(:phone_audience_unverified)
        end
        if Array(@delivery_channels).include?("whatsapp") &&
           (@delivery_template.blank? ||
            CityServicePhoneDelivery.template_digest(@delivery_template) != CityServicePhoneDelivery.template_digest(CityServicePhoneDelivery.template(event)))
          return not_publishable_result(:stale_review)
        end
        return already_published_result if already_published_for?(next_state)

        not_publishable_result unless publishable_state?
      end

      def prepare_publication_revision!
        return if event.board_published? && event.publication_revision.present?

        event.update!(extraction_metadata: event.extraction_metadata.merge("publication_revision" => CityServiceIncidentIdentity.revision(event)).merge(
          @automation_version ? { "automation_publication" => { "policy_version" => @automation_version, "published_at" => Time.current.iso8601 } } : {}
        ))
      end

      def publication_state(next_state, result)
        next_state == "published" && result.viber_jobs_count.zero? ? "board_published" : next_state
      end

      def record_publication_failure(result)
        attributes = { policy_snapshot: { status: result.status } }
        attributes.merge!(state: "failed", reviewer: actor, reviewed_at: Time.current, reviewed_content_version: nil) unless event.answer_approved?
        event.update!(attributes)
      end

      def publishable_state?
        event.publication_blocker.nil? &&
          (event.pending_review? || event.failed? || event.answer_approved? || event.board_published?)
      end

      def already_published_for?(next_state)
        event.published? || (event.board_published? && next_state == "board_published")
      end

      def publish_board_posts_for?(next_state)
        next_state == "board_published" || !event.board_published?
      end

      def published_area_slugs(_result)
        # Notification candidates may overlap an MZ without being affected in
        # full. Keep them in target_komsiluk_slugs, never in factual coverage.
        event.area_slugs
      end

      def already_published_result
        CityServiceNoticePublisher::Result.new(
          status: :already_published,
          classification: nil,
          policy_decision: event.policy_snapshot.presence,
          posts_count: event.komsiluk_post_id_values.size,
          post_ids: event.komsiluk_post_id_values,
          viber_jobs_count: event.viber_jobs_count,
          viber_recipients_count: event.viber_recipients_count,
          target_area_slugs: event.area_slugs,
          target_komsiluk_slugs: Array(event.target_komsiluk_slugs).map(&:to_s).compact_blank.uniq.sort
        )
      end

      def not_publishable_result(status = :not_publishable)
        CityServiceNoticePublisher::Result.new(
          status:,
          classification: nil,
          policy_decision: { state: event.state, reason: event.publication_blocker || status },
          posts_count: 0,
          post_ids: [],
          viber_jobs_count: 0,
          viber_recipients_count: 0,
          target_area_slugs: event.area_slugs,
          target_komsiluk_slugs: Array(event.target_komsiluk_slugs).map(&:to_s).compact_blank.uniq.sort
        )
      end

      def notice_payload
        {
          source_key: event.source_key,
          title: event.title,
          body: event.summary,
          url: event.source_url,
          fingerprint: event.source_fingerprint
        }
      end

      def record_audit!(result, from_state:)
        Decidim::Bih::OperatorAuditEvent.record!(
          organization: event.organization,
          actor: actor,
          event_type: "city_service_event_published",
          permission: "city_alerts_manage",
          role: "city_alert_operator",
          resource: event,
          metadata: {
            from_status: from_state,
            to_status: event.state,
            delivery: result.policy_decision&.fetch(:delivery, nil),
            posts_count: result.posts_count,
            recipients_count: result.viber_recipients_count,
            automation_policy_version: @automation_version
          }.compact
        )
      end

      class StaticClassifier
        def initialize(event:, delivery_recommendation:)
          @event = event
          @delivery_recommendation = delivery_recommendation
        end

        def call(source_key:, title:, body:, url:, known_areas:)
          raise "wrong source" unless source_key == event.source_key
          raise "missing title" if title.blank? || body.blank? || url.blank?
          raise "no known areas available" if known_areas.blank?

          CityServiceNoticeClassifier::Result.new(
            source_key: event.source_key,
            publish: true,
            event_type: event.event_type,
            severity: event.severity,
            targeting_level: event.targeting_level,
            target_area_slugs: event.area_slugs,
            title: event.title,
            body: event.summary,
            viber_text: event.viber_text.to_s,
            delivery_recommendation: @delivery_recommendation,
            confidence: event.confidence.to_f,
            starts_at: event.starts_at&.iso8601.to_s,
            ends_at: event.ends_at&.iso8601.to_s,
            fingerprint: event.source_fingerprint,
            needs_review: false,
            reasons: ["operator_approved"]
          )
        end

        private

        attr_reader :event
      end
    end
  end
end
