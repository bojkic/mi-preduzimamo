# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    module Milica
      # Reads grouped labels/counts from the existing anonymous rating table.
      # Never selects transcripts, reply/session IDs or a citizen identity, and
      # never persists a second feedback copy or infers topics from raw text.
      class FeedbackTopicSummary
        def initialize(model: Decidim::Bih::ConciergeFeedback)
          @model = model
        end

        def call(organization:, now: Time.current, hours: 24)
          raise ArgumentError, "hours must be 1..48" unless (1..48).cover?(hours)

          rows = grouped_ratings(organization, now, hours).each_with_object({}) do |((topic, intent, value), count), output|
            attributed = Decidim::Bih::Concierge::AnswerOutcome.topic(topic, answer_intent: intent)
            attribution = topic_attribution(topic, attributed)
            key = [attributed, attribution]
            row = output[key] ||= { topic: attributed, attribution:, helpful: 0, not_helpful: 0 }
            row[value.to_sym] += count
          end.values
          { status: "ok", scope: "organization_existing_web_feedback", hours:, rows:,
            interpretation: "Current votes on ratings created in the window; no new transcript copies. " \
                            "Historical service/fallback labels do not identify a civic topic. Votes are self-selected feedback, not an accuracy rate." }
        rescue ActiveRecord::ActiveRecordError
          { status: "unavailable", scope: "organization_existing_web_feedback", rows: [] }
        end

        private

        def grouped_ratings(organization, now, hours)
          topic = allowed_metadata("topic", Decidim::Bih::Concierge::Dialogue::Contracts::TOPICS)
          intent = allowed_metadata("answer_intent", Decidim::Bih::Concierge::AnswerIntents::VALUES)
          @model.where(organization:, created_at: (now - hours.hours)...now, value: %w(helpful not_helpful))
                .group(Arel.sql(topic), Arel.sql(intent), :value).count
        end

        def allowed_metadata(key, values)
          quoted = values.map { |value| @model.connection.quote(value) }.join(", ")
          "CASE WHEN metadata->>'#{key}' IN (#{quoted}) THEN metadata->>'#{key}' ELSE 'unknown' END"
        end

        def topic_attribution(recorded, attributed)
          return "recorded_typed_topic" unless recorded == "unknown"

          attributed == "unknown" ? "unknown" : "bounded_answer_intent_mapping"
        end
      end
    end
  end
end
