# frozen_string_literal: true

# Local-only fixture for the worker shutdown contract. No provider calls or
# citizen records; the sole synthetic effect is an idempotent Redis marker.
class MiDemoDrainProbeJob < ApplicationJob
  self.log_arguments = false
  queue_as :default

  def self.key_for(id)
    unless ENV["MI_INSTALL_PROFILE"] == "demo" && ENV["MI_LOCAL_HTTP"] == "true" && ENV.fetch("MI_INSTALL_ID", "").match?(/\Ami-[0-9a-f]{16}\z/)
      raise "Worker probe requires an explicit local demo installation"
    end
    raise "Invalid probe identity" unless id.to_s.match?(/\A[0-9a-f]{32}\z/)

    "mi-install:#{ENV.fetch("MI_INSTALL_ID")}:worker-probe:#{id}"
  end

  def perform(id)
    key = self.class.key_for(id)
    redis = Redis.new(url: ENV.fetch("REDIS_URL"))
    redis.incr("#{key}:attempts")
    redis.expire("#{key}:attempts", 3600)
    redis.set("#{key}:started", "1", ex: 3600)
    sleep 90
    redis.set("#{key}:effect", "1", nx: true, ex: 3600)
    redis.incr("#{key}:completions")
    redis.expire("#{key}:completions", 3600)
  ensure
    redis&.close
  end
end
