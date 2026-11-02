# frozen_string_literal: true

require "test_helper"
require Rails.root.join("installation/demo/drain_probe_job")

module DecidimApp
  class DemoDrainProbeTest < ActiveSupport::TestCase
    class FakeRedis
      attr_reader :data, :effect_writes

      def initialize
        @data = {}
        @effect_writes = 0
      end

      def incr(key) = @data[key] = @data.fetch(key, 0).to_i + 1

      def expire(*) = true

      def close = true

      def set(key, value, nx: false, **) # rubocop:disable Naming/MethodParameterName
        return if nx && @data.has_key?(key)

        @effect_writes += 1 if key.end_with?(":effect")
        @data[key] = value
      end
    end

    setup do
      @before = %w(MI_INSTALL_PROFILE MI_LOCAL_HTTP MI_INSTALL_ID).index_with { |key| ENV.fetch(key, nil) }
      ENV["MI_INSTALL_PROFILE"] = "demo"
      ENV["MI_LOCAL_HTTP"] = "true"
      ENV["MI_INSTALL_ID"] = "mi-1234567890abcdef"
    end

    teardown do
      @before.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    end

    test "probe keeps one synthetic effect while recording repeated attempts" do
      redis = FakeRedis.new
      job = MiDemoDrainProbeJob.new
      id = "a" * 32
      Redis.stub(:new, redis) do
        job.stub(:sleep, ->(seconds) { assert_equal 90, seconds }) do
          2.times { job.perform(id) }
        end
      end
      key = MiDemoDrainProbeJob.key_for(id)
      assert_equal 2, redis.data.fetch("#{key}:attempts")
      assert_equal 2, redis.data.fetch("#{key}:completions")
      assert_equal "1", redis.data.fetch("#{key}:effect")
      assert_equal 1, redis.effect_writes
      assert_not MiDemoDrainProbeJob.log_arguments
    end

    test "production and unexpected ids are rejected before creating a client" do
      Redis.stub(:new, ->(**) { flunk "No Redis client should be created" }) do
        ENV["MI_INSTALL_PROFILE"] = "production"
        assert_raises(RuntimeError) { MiDemoDrainProbeJob.new.perform("a" * 32) }
        ENV["MI_INSTALL_PROFILE"] = "demo"
        assert_raises(RuntimeError) { MiDemoDrainProbeJob.new.perform("unexpected-id") }
      end
    end
  end
end
