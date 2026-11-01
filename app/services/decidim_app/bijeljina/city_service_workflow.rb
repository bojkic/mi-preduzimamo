# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    # One snapshot drives the operator badge, queues, counts and available actions.
    # Source/publication history stays intact; expiry does not require a cron write.
    class CityServiceWorkflow
      STATUSES = %w(review ready published finished).freeze
      TABS = { "review" => %w(review ready), "automatic" => %w(published), "done" => %w(published finished) }.freeze
      Entry = Struct.new(:event, :status, :reason, :blocker, :delivery_counts, :automatic_decision, :decision, keyword_init: true) do
        def tab
          return "review" if %w(review ready).include?(status)
          return "automatic" if automatic_unchecked? && status == "published"

          "done"
        end

        def automatic_unchecked?
          automatic_decision.present? && !automatic_decision.checked_for?(event)
        end

        def editable?
          %w(review ready).include?(status) && %w(pending_review failed).include?(event.state)
        end

        def publishable?
          %w(review ready).include?(status) && blocker.nil?
        end

        def withdrawable?
          status == "published"
        end

        def delivery_status
          priorities = { "error" => %w(rejected failed), "unknown" => %w(unknown), "queued" => %w(pending sending),
                         "accepted" => %w(accepted), "delivered" => %w(delivered), "skipped" => %w(skipped) }
          match = priorities.find { |_label, states| states.any? { |state| delivery_counts.fetch(state, 0).positive? } }
          return match.first if match

          event.viber_jobs_count.to_i.positive? ? "requested" : "not_requested"
        end

        def delivery_action?
          status == "published" && event.board_published?
        end
      end

      # The one definition of "awaiting review". The operations dashboard reads
      # the queue through this method rather than counting `pending_review`
      # rows, so the tile and the review tab cannot drift apart: an event that
      # expired before anyone looked at it is finished, not pending.
      def self.review_count(organization:, at: Time.current)
        new(organization:, at:).ids(tab: "review").size
      end

      # Alerts whose window passed while they were still waiting. They are out
      # of the queue because nothing can be done about them now — which is
      # exactly why they need somewhere else to be seen.
      def self.expired_unpublished_count(organization:, at: Time.current)
        new(organization:, at:).expired_unpublished_count
      end

      attr_reader :entries

      def initialize(organization:, at: Time.current)
        @at = at
        events = CityServiceEvent.for_organization(organization).to_a
        @visible_ids = Decidim::Bih::KomsilukPost.where(decidim_organization_id: organization.id, decidim_user_id: nil, status: "open")
                                                 .where("expires_at IS NULL OR expires_at > ?", at).pluck(:id).to_set
        @targets = {}
        digests = events.filter_map { |event| delivery_digest(event) }
        @deliveries = Decidim::Bih::AccountNotification.where(organization:, topic: "city_service_alerts", deduplication_digest: digests)
                                                       .group(:deduplication_digest, :status).count
        @automation_decisions = CityServiceAutomationDecision.where(event_id: events.map(&:id)).order(id: :desc).group_by(&:event_id)
        @entries = events.index_with { |event| build_entry(event) }.transform_keys(&:id)
      end

      def current_entries
        entries.values.reject { |entry| entry.event.superseded_by_id.present? }
      end

      def counts
        current_entries.map(&:status).tally
      end

      def lane_counts
        current_entries.map(&:tab).tally
      end

      def expired_unchecked_count
        current_entries.count { |entry| entry.reason == "expired" && entry.automatic_unchecked? }
      end

      def expired_unpublished_count
        current_entries.count { |entry| entry.reason == "expired_unpublished" }
      end

      def ids(tab:, status: nil)
        current_entries.select do |entry|
          matching_lane = if tab == "published"
                            entry.status == "published"
                          elsif tab == "history"
                            entry.status == "finished"
                          else
                            entry.tab == tab
                          end
          matching_lane && (status.blank? || entry.status == status)
        end
                       .map { |entry| entry.event.id }
      end

      private

      def build_entry(event)
        reason = finished_reason(event)
        blocker = event.publication_blocker || (:no_target unless valid_targets?(event))
        status = if reason
                   "finished"
                 elsif event.board_published? || event.published?
                   "published"
                 elsif event.facts_confirmed? && blocker.nil?
                   "ready"
                 else
                   "review"
                 end
        decisions = @automation_decisions.fetch(event.id, [])
        automatic = decisions.find { |item| item.outcome == "published" && item.publication_revision.present? && item.publication_revision == event.publication_revision }
        current = decisions.find { |item| item.policy_version == CityServiceAutomationPolicy::VERSION && item.content_version == event.content_version }
        Entry.new(event:, status:, reason:, blocker:, delivery_counts: delivery_counts(event), automatic_decision: automatic, decision: current)
      end

      def delivery_counts(event)
        event_digest = delivery_digest(event)
        @deliveries.filter_map { |(digest, delivery_state), count| [delivery_state, count] if digest == event_digest }.to_h
      end

      def finished_reason(event)
        terminal_reason(event) || publication_end_reason(event)
      end

      def terminal_reason(event)
        return "replaced" if event.superseded_by_id.present? || event.superseded? || event.lifecycle == "superseded"
        return "cancelled" if event.lifecycle == "cancelled"
        return unless event.dismissed?

        Array(event.extraction_metadata["publication_history"]).any? ? "withdrawn" : "dismissed"
      end

      def publication_end_reason(event)
        return expiry_reason(event) if event.ends_at && event.ends_at <= @at
        return "resolved" if event.lifecycle == "resolved"
        return unless event.board_published? || event.published?

        "not_visible" if event.publication_blocker || event.komsiluk_post_id_values.none? { |id| @visible_ids.include?(id) }
      end

      # An alert that ran its course after publication and one whose window
      # passed while it sat in the queue are both finished, but only the second
      # is a miss: citizens were never told. They must not share a label.
      def expiry_reason(event)
        ever_published?(event) ? "expired" : "expired_unpublished"
      end

      def ever_published?(event)
        event.board_published? || event.published? || Array(event.extraction_metadata["publication_history"]).any?
      end

      def delivery_digest(event)
        Digest::SHA256.hexdigest("city_service_alerts:city-alert:#{event.viber_dedupe_key}") if event.viber_dedupe_key.present?
      end

      def valid_targets?(event)
        return false unless %w(citywide mz komsiluk).include?(event.targeting_level)
        return false if event.targeting_level != "citywide" && event.area_slugs.empty?

        @targets.fetch([event.targeting_level, event.area_slugs]) do |key|
          @targets[key] = CityServiceEventPreview.new(event).board_target_slugs.any?
        end
      end
    end
  end
end
