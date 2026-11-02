# frozen_string_literal: true
require "sidekiq/api"
# Executed after TSTP. The daemon has a full provider-call window to finish;
# TERM/90 s stop grace is a separate fallback, not a replacement for drain.
deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 150
loop do
  break if Sidekiq::ProcessSet.new.sum { |process| process["busy"].to_i }.zero?
  abort "Worker drain nije završen; servisi nisu prisilno zaustavljeni." if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

  sleep 1
end
puts "worker_drain=complete"
