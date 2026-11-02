# frozen_string_literal: true

require Rails.root.join("installation/demo/drain_probe_job")
action, id = ARGV
key = MiDemoDrainProbeJob.key_for(id)
if action == "enqueue"
  MiDemoDrainProbeJob.perform_later(id)
  puts JSON.generate(probe_id: id, action: "queued", duration_seconds: 90, simulated: true)
elsif action == "status"
  redis = Redis.new(url: ENV.fetch("REDIS_URL"))
  begin
    values = %w(started attempts completions effect).index_with { |name| redis.get("#{key}:#{name}").to_i }
    puts JSON.generate(probe_id: id, simulated: true, **values)
  ensure
    redis.close
  end
else
  abort "Use enqueue/status with a probe id"
end
