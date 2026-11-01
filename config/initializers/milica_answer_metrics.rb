# frozen_string_literal: true

# Shared recorder is called at existing web, Viber and external reply boundaries.
# It emits only topic/outcome; no identity or content is forwarded to this cache.
ActiveSupport::Notifications.subscribe("milica.answer_outcome") do |*arguments|
  event = ActiveSupport::Notifications::Event.new(*arguments)
  DecidimApp::Bijeljina::Milica::AnswerMetrics.record(**event.payload.slice(:topic, :outcome))
end

Rails.application.config.after_initialize do
  metrics = DecidimApp::Bijeljina::Milica
  metrics::DimensionedAnswerMetrics.configure(
    release_sha: metrics::MetricRollup.release_sha,
    prompt_version: Decidim::Bih::Concierge::Dialogue::Contracts::VERSION
  )
end

ActiveSupport::Notifications.subscribe("milica.answer_dimensions") do |*arguments|
  event = ActiveSupport::Notifications::Event.new(*arguments)
  DecidimApp::Bijeljina::Milica::DimensionedAnswerMetrics.record(
    **event.payload.slice(:organization_id, :topic, :outcome, :facet)
  )
end
