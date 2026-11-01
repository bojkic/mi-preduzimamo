# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    # Owner decision 2026-10-06: a city outage notice held for review is
    # published automatically when nobody reacts within an hour, to the
    # neighbourhoods (komšiluci) it could be placed in. Boards are the smallest
    # audience, so an unplaced street does not stop the placed ones.
    #
    # Only placement doubts are waived. Safety/weather/citywide notices,
    # disabled or stale sources, duplicates and notices with no placeable
    # neighbourhood still wait for a person.
    class CityServiceHeldFallback
      VERSION = "held-fallback-v1"
      GRACE = 60.minutes
      WAIVABLE_BLOCKERS = %w(coverage_requires_review unresolved_coverage no_board_targets).freeze

      def self.publishable_blockers?(blockers) = (Array(blockers) - WAIVABLE_BLOCKERS).empty?

      def initialize(organization:, now: Time.current)
        @organization = organization
        @now = now
        @automation = CityServiceAutomation.new(organization:)
        @policy = CityServiceAutomationPolicy.new(organization:)
      end

      def call
        waiting = CityServiceWorkflow.new(organization: @organization, at: @now).ids(tab: "review")
        CityServiceEvent.for_organization(@organization).where(id: waiting).order(:id).filter_map { |event| publish(event) }
      rescue StandardError => e
        Rails.logger.warn("[CityServiceHeldFallback] skipped: #{e.class}: #{e.message}")
        []
      end

      def candidate?(event)
        event.pending_review? && event.reviewed_at.nil? && (event.ends_at.nil? || event.ends_at > @now) &&
          held_since(event) <= @now - GRACE && @policy.mode(event.source_key) == "automatic" && placeable_slugs(event).any?
      end

      private

      def publish(event)
        CityServiceIncident.synchronize(@organization) do
          event.lock!
          next unless candidate?(event)

          slugs = placeable_slugs(event)
          blockers = @automation.blockers(event)
          next unless self.class.publishable_blockers?(blockers)

          event.update!(targeting_level: "komsiluk", affected_area_slugs: slugs,
                        extraction_metadata: event.extraction_metadata.merge("held_fallback" => {
                                                                               "version" => VERSION, "waived_blockers" => blockers, "board_slugs" => slugs,
                                                                               "held_since" => held_since(event).iso8601, "published_at" => @now.iso8601
                                                                             }))
          next unless self.class.publishable_blockers?(@automation.blockers(event))

          result = CityServiceEventPublisher.new(event, actor: nil).publish_held_fallback!
          result.status == :published ? event : nil
        end
      rescue StandardError => e
        Rails.logger.warn("[CityServiceHeldFallback] event=#{event.id} error=#{e.class}")
        nil
      end

      def held_since(event)
        CityServiceAutomationDecision.where(event:, content_version: event.content_version.to_s).minimum(:created_at) || event.created_at
      end

      # Water notices name each street separately: every clause that was placed
      # contributes its boards. Other notices use the reviewed preview targets.
      def placeable_slugs(event)
        clauses = Array(event.extraction_metadata.dig("coverage", "clauses"))
        slugs = clauses.select { |row| row["status"] == "resolved" }.flat_map { |row| Array(row["board_slugs"]) }
        slugs = CityServiceEventPreview.new(event).board_target_slugs if slugs.empty?
        known = Decidim::Bih::LocalArea.where(organization: @organization, kind: "komsiluk", slug: slugs).pluck(:slug)
        slugs.uniq.sort & known
      end
    end
  end
end
