# frozen_string_literal: true

require "json"
require "fileutils"

# Opt-in measurement collected during a required run, without a second suite.
# Each process writes its own file so parallel workers cannot truncate a peer.
module MiTimingReporter
  class Reporter < Minitest::AbstractReporter
    def initialize(path)
      super()
      @path = path
      @results = []
    end

    def record(result)
      @results << { class: result.class_name, test: result.name,
                    seconds: result.time.round(6), assertions: result.assertions,
                    failure_count: result.failures.length }
    end

    def report
      path = "#{@path}.#{Process.pid}.json"
      FileUtils.mkdir_p(File.dirname(path))
      raise "timing output must not be a symlink" if File.symlink?(path)

      File.open(path, "w", 0o640) do |file|
        file.puts(JSON.pretty_generate({ pid: Process.pid, tests: @results.sort_by { |row| -row[:seconds] } }))
      end
      puts "Test timings: #{path} (#{@results.length} tests)"
    end
  end
end

Minitest.extensions << "mi_timing"
module Minitest
  def self.plugin_mi_timing_init(_options)
    reporter << MiTimingReporter::Reporter.new(ENV.fetch("MI_TEST_TIMINGS_PATH"))
  end
end
