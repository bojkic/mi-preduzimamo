# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    module Milica
      # All-channel answer-boundary aggregates. These counters have no tenant,
      # actor, query, channel, location, conversation or evidence-ID dimension.
      module AnswerMetrics
        RETENTION = 48.hours
        UNMET_OUTCOMES = %w(unsupported source_unavailable provider_unavailable busy delivery_failed fallback error).freeze

        module_function

        def record(topic:, outcome:, now: Time.current)
          return unless topics.include?(topic) && outcomes.include?(outcome)

          Rails.cache.increment(cache_key(now, topic, outcome), 1, expires_in: RETENTION)
        rescue StandardError
          nil
        end

        def snapshot(now: Time.current, hours: 24)
          raise ArgumentError, "hours must be 1..48" unless (1..48).cover?(hours)

          rows = topics.filter_map do |topic|
            keys = outcomes.flat_map { |outcome| hours.times.map { |offset| cache_key(now - offset.hours, topic, outcome) } }
            # Rails.cache.increment writes the counter as a raw integer, so a
            # read without raw: true deserializes nothing and every bucket reads
            # as absent. Keep these two in step.
            values = Rails.cache.read_multi(*keys, raw: true)
            counts = outcomes.index_with do |outcome|
              hours.times.sum { |offset| values.fetch(cache_key(now - offset.hours, topic, outcome), 0).to_i }
            end
            next unless counts.values.sum.positive?

            { topic:, recorded_answers: counts.values.sum, outcomes: counts,
              unmet_demand_proxy_count: UNMET_OUTCOMES.sum { |outcome| counts.fetch(outcome) } }
          end
          { scope: "all_instrumented_answer_boundaries_global", hours:, rows:,
            interpretation: "Unmet-demand proxies are technical outcomes, not factual accuracy or satisfaction. Clarification and handoff are separate outcomes. " \
                            "Unknown topics and legacy success retain unknown attribution; missing counters do not establish zero demand." }
        end

        def topics = Decidim::Bih::Concierge::Dialogue::Contracts::TOPICS

        def outcomes = Decidim::Bih::Concierge::AnswerOutcome::OUTCOMES

        def cache_key(now, topic, outcome)
          "milica/answer-metrics/v1/#{now.getutc.strftime("%Y%m%d%H")}/#{topic}/#{outcome}"
        end
      end
    end
  end
end
