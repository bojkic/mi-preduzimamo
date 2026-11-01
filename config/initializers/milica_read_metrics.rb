# frozen_string_literal: true

# Shared engine instrumentation has a fixed scalar payload. Aggregate it without
# attaching tenant, citizen, query or conversation context.
ActiveSupport::Notifications.subscribe("milica.dialogue_stage") do |*arguments|
  event = ActiveSupport::Notifications::Event.new(*arguments)
  DecidimApp::Bijeljina::Milica::ReadMetrics.record_stage(**event.payload.slice(:stage, :status, :duration_ms))
end
