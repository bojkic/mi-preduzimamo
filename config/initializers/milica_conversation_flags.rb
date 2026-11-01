# frozen_string_literal: true

# Detect a split rollout before any request writes conversation slots or calls
# the new planner. Puma and Sidekiq must receive the same enabled values.
slots = ENV["MILICA_CONVERSATION_SLOTS_ENABLED"] == "1"
defaults = ENV["MILICA_AREA_DEFAULT_STOPS_ENABLED"] == "true"
planner = ENV["MILICA_JOURNEY_PLANNER_V2_ENABLED"] == "true"
exact = ENV["MILICA_CONVERSATION_LOCATION_ENABLED"] == "1"
typed_address = ENV["MILICA_TYPED_ADDRESS_ENABLED"] == "1"

if exact && !slots
  raise ArgumentError, "MILICA_CONVERSATION_LOCATION_ENABLED requires MILICA_CONVERSATION_SLOTS_ENABLED=1"
end
if defaults && !slots
  raise ArgumentError, "MILICA_AREA_DEFAULT_STOPS_ENABLED requires MILICA_CONVERSATION_SLOTS_ENABLED=1"
end
if planner && !defaults
  raise ArgumentError, "MILICA_JOURNEY_PLANNER_V2_ENABLED requires MILICA_AREA_DEFAULT_STOPS_ENABLED=true"
end

if typed_address && !exact
  raise ArgumentError, "MILICA_TYPED_ADDRESS_ENABLED requires MILICA_CONVERSATION_LOCATION_ENABLED=1"
end
