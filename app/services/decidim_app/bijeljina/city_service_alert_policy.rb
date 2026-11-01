# frozen_string_literal: true

require "digest"
require_relative "city_service_sources"

module DecidimApp
  module Bijeljina
    # Conservative policy gate for future service-alert Viber jobs.
    module CityServiceAlertPolicy
      AUTOMATIC_PUSH_SEVERITIES = %w(service_outage safety emergency).freeze
      OPT_OUT_TOPIC = :city_service_alerts
      OPT_OUT_CHANNEL = :viber
      OPT_OUT_KEY = Decidim::Bih::NotificationPreferences.key(topic: OPT_OUT_TOPIC, channel: OPT_OUT_CHANNEL)
      LEGACY_OPT_OUT_KEY = Decidim::Bih::NotificationPreferences::LEGACY_LOCAL_ALERTS_KEY

      class << self
        def evaluate(source_key:, event_type:, severity:, **options)
          source = CityServiceSources.find(source_key)
          return rejected(source_key:, event_type:, severity:, reason: "unknown_source") unless source
          return rejected_from_source(source, event_type:, severity:, reason: "source_disabled_by_owner") unless CityServiceSources.enabled?(source_key)

          viber = source.fetch(:viber)
          return rejected_from_source(source, event_type:, severity:, reason: "on_demand_only") unless viber.fetch(:eligible)

          event_type = event_type.to_s
          severity = severity.to_s
          return rejected_from_source(source, event_type:, severity:, reason: "event_type_not_alertable") unless viber.fetch(:event_types).include?(event_type)
          return rejected_from_source(source, event_type:, severity:, reason: "severity_not_alertable") unless viber.fetch(:severities).include?(severity)

          operator_approved = options.fetch(:operator_approved, false)
          target_area_slugs = options.fetch(:target_area_slugs, [])
          target_slugs = normalized_targets(target_area_slugs)
          if viber.fetch(:target) == CityServiceSources::AREA_REQUIRED && target_slugs.empty?
            return rejected_from_source(source, event_type:, severity:, reason: "target_area_required")
          end

          automatic_push = automatic_push?(severity)
          requires_operator_review = requires_operator_review?(viber:)
          delivery = delivery_for(requires_operator_review:, operator_approved:)
          dedupe_payload = {
            source_key: source.fetch(:key),
            event_type:,
            severity:,
            target_slugs:,
            fingerprint: options[:fingerprint],
            starts_at: options[:starts_at]
          }

          {
            source_key: source.fetch(:key),
            source_label: source.fetch(:label),
            event_type:,
            severity:,
            viber_candidate: true,
            automatic_push_candidate: automatic_push,
            send_now: delivery == "viber_alert",
            delivery:,
            reason: delivery_reason(delivery),
            target_area_slugs: target_slugs,
            dedupe_key: dedupe_key(dedupe_payload),
            cooldown_minutes: viber.fetch(:cooldown_minutes),
            max_per_area_per_day: viber.fetch(:max_per_area_per_day),
            requires_operator_review:,
            honor_opt_out: true,
            opt_out_key: OPT_OUT_KEY,
            legacy_opt_out_key: LEGACY_OPT_OUT_KEY,
            opt_out_topic: OPT_OUT_TOPIC.to_s,
            opt_out_channel: OPT_OUT_CHANNEL.to_s
          }
        end

        # The pilot cohort for this sender, as several numbers that must never
        # be collapsed into one. The arithmetic lives in {PilotAudience}, which
        # computes the same shape for every candidate class so two candidates
        # can actually be compared; this is the named entry point the Phase 2
        # plan binds to.
        def effective_audience(organization:, area_ids:, modes: PilotAudience::MODES)
          PilotAudience.city_service_alert(organization:, area_ids:, modes:)
        end

        private

        def automatic_push?(severity)
          AUTOMATIC_PUSH_SEVERITIES.include?(severity.to_s)
        end

        def requires_operator_review?(viber:)
          viber.fetch(:requires_operator_review)
        end

        def delivery_for(requires_operator_review:, operator_approved:)
          return "operator_review" if requires_operator_review && !operator_approved
          return "dry_run" unless CityServiceSources.alerts_enabled?

          "viber_alert"
        end

        def delivery_reason(delivery)
          case delivery
          when "operator_review"
            "operator_review_required"
          when "dry_run"
            "alerts_disabled"
          else
            "ready"
          end
        end

        def rejected_from_source(source, event_type:, severity:, reason:)
          rejected(source_key: source.fetch(:key), source_label: source.fetch(:label), event_type:, severity:, reason:)
        end

        def rejected(source_key:, event_type:, severity:, reason:, source_label: nil)
          {
            source_key: source_key.to_s,
            source_label: source_label.to_s,
            event_type: event_type.to_s,
            severity: severity.to_s,
            viber_candidate: false,
            automatic_push_candidate: false,
            send_now: false,
            delivery: CityServiceSources::ON_DEMAND,
            reason:,
            target_area_slugs: [],
            dedupe_key: nil,
            cooldown_minutes: nil,
            max_per_area_per_day: 0,
            requires_operator_review: true,
            honor_opt_out: true,
            opt_out_key: OPT_OUT_KEY,
            legacy_opt_out_key: LEGACY_OPT_OUT_KEY,
            opt_out_topic: OPT_OUT_TOPIC.to_s,
            opt_out_channel: OPT_OUT_CHANNEL.to_s
          }
        end

        def normalized_targets(target_area_slugs)
          Array(target_area_slugs).map { |slug| slug.to_s.strip }.compact_blank.uniq.sort
        end

        def dedupe_key(event)
          raw = [
            event.fetch(:source_key),
            event.fetch(:event_type),
            event.fetch(:severity),
            event.fetch(:target_slugs).join("+"),
            event.fetch(:fingerprint).presence || starts_at_key(event.fetch(:starts_at))
          ].join("|")

          "city_service_alert:#{Digest::SHA256.hexdigest(raw)[0, 24]}"
        end

        def starts_at_key(starts_at)
          return "unscheduled" if starts_at.blank?

          starts_at.respond_to?(:iso8601) ? starts_at.iso8601 : starts_at.to_s
        end
      end
    end
  end
end
