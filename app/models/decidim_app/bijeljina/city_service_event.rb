# frozen_string_literal: true

require "digest"

module DecidimApp
  module Bijeljina
    class CityServiceEvent < ApplicationRecord
      self.table_name = "decidim_app_city_service_events"

      STATES = %w(pending_review answer_approved board_published published dismissed failed superseded).freeze
      LIFECYCLES = %w(scheduled ongoing resolved cancelled superseded unknown).freeze
      CITIZEN_VISIBLE_STATES = %w(answer_approved board_published published).freeze
      SEVERITIES = DecidimApp::Bijeljina::CityServiceNoticeClassifier::SEVERITIES

      belongs_to :organization,
                 class_name: "Decidim::Organization",
                 foreign_key: "decidim_organization_id"
      belongs_to :reviewer,
                 class_name: "Decidim::User",
                 foreign_key: "reviewed_by_id",
                 optional: true

      belongs_to :incident, class_name: "DecidimApp::Bijeljina::CityServiceIncident", optional: true

      validates :source_key, :source_fingerprint, :event_type, :severity,
                :targeting_level, :title, :summary, :parser_version, presence: true
      validates :state, inclusion: { in: STATES }
      validates :lifecycle, inclusion: { in: LIFECYCLES }
      validate :valid_occurrence_window, if: -> { new_record? || starts_at_changed? || ends_at_changed? }
      validates :severity, inclusion: { in: SEVERITIES }
      validates :source_fingerprint, uniqueness: { scope: [:decidim_organization_id, :source_key] }

      scope :for_organization, ->(organization) { where(decidim_organization_id: organization.id) }
      scope :pending_review, -> { where(state: "pending_review") }
      scope :citizen_visible, lambda {
        where(state: CITIZEN_VISIBLE_STATES).where.not(lifecycle: %w(cancelled superseded)).where(superseded_by_id: nil)
                                            .where("state <> :approved OR (content_version IS NOT NULL AND reviewed_content_version = content_version)",
                                                   approved: "answer_approved")
      }
      # Public source evidence is available to on-demand answers immediately.
      # Review and publication states govern operator work and outbound delivery.
      scope :milica_available, lambda {
        where(state: %w(pending_review failed answer_approved board_published published))
          .where.not(lifecycle: %w(cancelled superseded)).where(superseded_by_id: nil)
          .where.not(event_type: %w(not_relevant routine_service_info))
          .where("COALESCE(extraction_metadata ->> 'publication_correction_pending', 'false') <> 'true'")
          .where("starts_at IS NULL OR ends_at IS NULL OR ends_at > starts_at")
      }

      scope :reviewed_facts, -> { where("reviewed_at IS NOT NULL AND reviewed_by_id IS NOT NULL AND content_version IS NOT NULL AND reviewed_content_version = content_version") }
      scope :awaiting_review, lambda {
        where("NOT COALESCE(reviewed_at IS NOT NULL AND reviewed_by_id IS NOT NULL AND content_version IS NOT NULL AND reviewed_content_version = content_version, false)")
      }
      scope :not_ended, -> { where("ends_at IS NULL OR ends_at > ?", Time.current).where.not(lifecycle: %w(cancelled resolved superseded)) }
      scope :ended, -> { where("ends_at <= ? OR lifecycle IN (?)", Time.current, %w(cancelled resolved superseded)) }

      def publication_blocker
        return :invalid_lifecycle unless %w(scheduled ongoing).include?(lifecycle) && superseded_by_id.nil?
        return :weather_region_review_changed unless weather_region_review_current?
        return :incomplete_source unless source_evidence_complete?
        return :missing_time unless starts_at && ends_at
        return :invalid_time unless ends_at > starts_at
        return :expired if ends_at <= Time.current

        nil
      end

      def publication_revision
        extraction_metadata["publication_revision"]
      end

      def delivery_current?(revision)
        revision.present? && publication_revision == revision && published? && publication_blocker.nil?
      end

      def facts_confirmed?
        weather_region_review_current? && reviewed_at.present? && reviewed_by_id.present? && content_version.present? && reviewed_content_version == content_version
      end

      scope :current_at, lambda { |time|
        where("starts_at IS NULL OR starts_at <= ?", time)
          .where("ends_at IS NULL OR ends_at > ?", time)
      }

      STATES.each { |value| define_method(:"#{value}?") { state == value } }

      def source
        DecidimApp::Bijeljina::CityServiceSources.find(source_key)
      end

      def source_label_text
        source_label.presence || source&.fetch(:label) || source_key
      end

      def area_slugs
        Array(affected_area_slugs).map(&:to_s).compact_blank.uniq.sort
      end

      def komsiluk_post_id_values
        Array(komsiluk_post_ids).map(&:to_i).select(&:positive?).uniq
      end

      def current_source_reviewed?
        weather_region_review_current? && content_version.present? && reviewed_at.present? && reviewed_by_id.present? && reviewed_content_version == content_version
      end

      def mark_reviewed!(actor:, note: nil)
        update!(reviewer: actor, reviewed_at: Time.current, reviewed_content_version: content_version,
                review_note: note.presence || review_note)
      end

      # Bind the form to both the provider revision and the facts the operator
      # actually saw. A concurrent local edit must also invalidate that form.
      def answer_review_token
        fields = %w(id incident_id state content_version source_key source_url source_label provider parser_version source_published_at source_updated_at
                    title summary viber_text recommended_action affected_text
                    starts_at ends_at event_type severity targeting_level affected_area_slugs
                    extraction_metadata lifecycle superseded_by_id)
        boundaries = Decidim::Bih::LocalArea.where(decidim_organization_id: decidim_organization_id).order(:id).pluck(:id, :slug, :boundary)
        value = canonical_review_value(attributes.slice(*fields)).to_json + boundaries.to_json
        if source_key == "weather_warnings"
          value += ":weather-region-review:#{current_weather_region_review&.identity || 'unavailable'}"
        end
        Digest::SHA256.hexdigest(value)
      end

      def approve_answers!(actor:, expected_version:, review_token:)
        return :not_authorized unless Decidim::Bih::OperatorAuthorization.allowed?(actor, :city_alerts_manage, organization:)

        reconciliation = CityServiceReviewedSourceReconciliation.new(self)
        reconciliation.with_document_lock do
          with_lock do
            return :stale_review unless answer_review_current?(expected_version, review_token)
            return :incomplete_evidence unless answer_approvable?

            from_state = state
            update!(state: "answer_approved", reviewer: actor, reviewed_at: Time.current, reviewed_content_version: content_version)
            Decidim::Bih::OperatorAuditEvent.record!(
              organization:, actor:, event_type: "city_service_event_answers_approved", permission: "city_alerts_manage",
              role: Decidim::Bih::OperatorAuthorization.role_for(actor, :city_alerts_manage, organization:), resource: self,
              metadata: { from_state:, to_state: state, content_version:, scope: "on_demand_answers" }
            )
            reconciliation.reconcile!
            :approved
          end
        end
      end

      def revoke_answers!(actor:, expected_version:, review_token:)
        return :not_authorized unless Decidim::Bih::OperatorAuthorization.allowed?(actor, :city_alerts_manage, organization:)

        with_lock do
          return :stale_review unless answer_approved? && answer_review_current?(expected_version, review_token)

          previous_review = attributes.slice("reviewed_at", "reviewed_by_id", "reviewed_content_version")
          update!(state: "pending_review", reviewer: nil, reviewed_at: nil, reviewed_content_version: nil)
          Decidim::Bih::OperatorAuditEvent.record!(
            organization:, actor:, event_type: "city_service_event_answers_revoked", permission: "city_alerts_manage",
            role: Decidim::Bih::OperatorAuthorization.role_for(actor, :city_alerts_manage, organization:), resource: self,
            metadata: { from_state: "answer_approved", to_state: state, content_version:, previous_review: }
          )
          :revoked
        end
      end

      def answer_approvable?
        %w(pending_review failed).include?(state) && content_version.present? && complete_answer_evidence? &&
          valid_time_window? && starts_at.present? && ends_at.present? && answerable_lifecycle? && valid_answer_area? && valid_answer_type?
      end

      def valid_time_window?
        starts_at.nil? || ends_at.nil? || ends_at > starts_at
      end

      def weather_region_review_current?
        return true unless source_key == "weather_warnings"

        review = current_weather_region_review
        return false unless review

        review.matches_metadata?(extraction_metadata, organization_host: organization&.host, source_url:,
                                          day: Time.current.in_time_zone("Europe/Sarajevo").to_date)
      end

      def source_evidence_complete?
        return false unless weather_region_review_current?

        # Historical records predate extraction metadata. Only an explicitly
        # incomplete observation blocks the normal review/publication path.
        operator_corrected_facts? || (extraction_metadata["source_snapshot_complete"] != false && extraction_metadata["complete"] != false)
      end

      def operator_corrected_facts?
        return false if extraction_metadata["source_document_complete"] == false

        review = extraction_metadata["operator_review"].to_h
        raw_complete = extraction_metadata["source_document_complete"] == true &&
                       %w(ambiguous_local_time nonexistent_local_time unknown_clock invalid_clock unknown_date unresolved_schedule).include?(extraction_metadata["temporal_status"])
        (extraction_metadata["source_snapshot_complete"] == true || raw_complete) && review["provenance"] == "operator_correction" &&
          review["source_content_version"] == content_version && review["reviewed_by_id"].present?
      end

      # Document history deliberately makes no claim of one-to-one row identity.
      def review_document_history
        url = extraction_metadata["source_document_url"].presence || source_url
        return [] if url.blank?

        self.class.where(decidim_organization_id:, source_key:, state: "superseded")
            .where(id: ...id)
            .where("extraction_metadata -> 'source_withdrawal' ->> 'document_url' = ?", url)
            .order(id: :desc).limit(8).to_a
      end

      def supersede_with!(replacement)
        raise ArgumentError, "Replacement must belong to the same source and organization" unless
          replacement.decidim_organization_id == decidim_organization_id && replacement.source_key == source_key

        CityServiceIncident.synchronize(organization) do
          with_lock do
            next if dismissed? || superseded?

            update!(state: "superseded", lifecycle: "superseded", superseded_by_id: replacement.id)
            expire_generated_posts!
          end
        end
      end

      # Withdrawal means that a newer complete source document no longer supports
      # these facts. It deliberately does not invent a replacement occurrence.
      def withdraw_source_version!(document_url:, document_version:, observed_at:, reason:)
        CityServiceIncident.synchronize(organization) do
          with_lock do
            next if dismissed? || superseded?

            metadata = extraction_metadata.merge("source_withdrawal" => {
                                                   "document_url" => document_url, "observed_version" => document_version,
                                                   "observed_at" => observed_at.iso8601, "reason" => reason
                                                 })
            update!(state: "superseded", lifecycle: "superseded", extraction_metadata: metadata)
            expire_generated_posts!
          end
        end
      end

      private

      def current_weather_region_review
        return unless source_key == "weather_warnings" && CityServiceSources.enabled?(source_key)

        current_source = source
        return unless current_source

        review = WeatherRegionConfiguration.for_source(source_url: current_source.fetch(:source_url),
                                                       day: Time.current.in_time_zone("Europe/Sarajevo").to_date)
        review if review.bound_to?(organization_host: organization&.host, source_url:)
      rescue WeatherRegionConfiguration::InvalidConfiguration
        nil
      end

      def canonical_review_value(value)
        case value
        when Hash then value.keys.sort.index_with { |key| canonical_review_value(value.fetch(key)) }
        when Array then value.map { |item| canonical_review_value(item) }
        when Time, ActiveSupport::TimeWithZone then value.in_time_zone("UTC").iso8601(6)
        when DateTime then value.new_offset(0).iso8601(6)
        else value
        end
      end

      def answer_review_current?(expected_version, token)
        content_version.present? && expected_version.to_s == content_version &&
          ActiveSupport::SecurityUtils.secure_compare(answer_review_token, token.to_s)
      end

      def complete_answer_evidence?
        source_evidence_complete? && (operator_corrected_facts? || extraction_metadata["source_snapshot_complete"] == true || extraction_metadata["complete"] == true)
      end

      def answerable_lifecycle?
        return false if superseded_by_id || %w(cancelled superseded unknown).include?(lifecycle)

        lifecycle == "resolved" || ends_at > Time.current
      end

      def valid_answer_type?
        source.present? && CityServiceNoticeClassifier::EVENT_TYPES.include?(event_type) &&
          %w(not_relevant routine_service_info).exclude?(event_type)
      end

      def valid_answer_area?
        return area_slugs.empty? if targeting_level == "citywide"
        return false unless %w(mz komsiluk).include?(targeting_level) && area_slugs.any?

        Decidim::Bih::LocalArea.where(decidim_organization_id:, kind: targeting_level, slug: area_slugs).count == area_slugs.size
      end

      def expire_generated_posts!
        CityServiceProjectionWithdrawal.call(self)
      end

      def valid_occurrence_window
        errors.add(:ends_at, "must follow the start of the occurrence") unless valid_time_window?
      end
    end
  end
end
