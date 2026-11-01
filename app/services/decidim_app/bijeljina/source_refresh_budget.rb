# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    # Background-only monotonic budget. The citizen TurnBudget deliberately
    # caps requests at ten seconds and must not be widened for collection jobs.
    class SourceRefreshBudget
      MAX_TIMEOUT = 180.0
      attr_reader :deadline

      def initialize(timeout: 120, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
        @clock = clock
        @deadline = Float(clock.call) + duration(timeout)
      end

      def remaining_seconds
        [deadline - Float(@clock.call), 0.0].max
      end

      def expired?
        remaining_seconds <= 0
      end

      def within(seconds)
        child = self.class.new(timeout: duration(seconds), clock: @clock)
        child.instance_variable_set(:@deadline, [deadline, child.deadline].min)
        child
      end

      private

      def duration(value)
        seconds = Float(value)
        raise ArgumentError, "invalid source refresh timeout" unless seconds.finite? && seconds.positive? && seconds <= MAX_TIMEOUT

        seconds
      end
    end
  end
end
