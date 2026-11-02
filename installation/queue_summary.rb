# frozen_string_literal: true

require "sidekiq/api"
require "json"

# Intentionally no job arguments, recipient identities or message bodies.
class_counts = Hash.new(0)
queues = Sidekiq::Queue.all.map do |queue|
  queue.each do |job|
    name = job.item["wrapped"] || job.klass
    label = name.to_s.match?(/\A[A-Z]\w*(?:::[A-Z]\w*)*\z/) ? name : "unknown"
    class_counts[label] += 1
  end
  { name: queue.name.match?(/\A[a-z_-]{1,64}\z/) ? queue.name : "custom", jobs: queue.size, latency_seconds: queue.latency.round(1) }
end
puts JSON.generate(status: "quarantined_queue_inventory", queues:, classes: class_counts, retry: Sidekiq::RetrySet.new.size,
                   scheduled: Sidekiq::ScheduledSet.new.size, dead: Sidekiq::DeadSet.new.size,
                   boundary: "Inventory only. Review intended recipients/integrations privately before processing; no jobs were performed or removed.")
