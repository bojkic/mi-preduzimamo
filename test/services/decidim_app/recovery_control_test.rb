# frozen_string_literal: true

require "test_helper"
require Rails.root.join("installation/lib/recovery_fingerprint")

module DecidimApp
  class RecoveryControlTest < ActiveSupport::TestCase
    class FakeRedis
      attr_reader :value, :writes

      def initialize
        @value = nil
        @writes = 0
      end

      def get(*) = @value

      def close = true

      def set(_key, value)
        @value = value
        @writes += 1
      end
    end

    setup do
      @before = ENV.fetch("MI_INSTALL_ID", nil)
      @argv = ARGV.dup
      ENV["MI_INSTALL_ID"] = "mi-1234567890abcdef"
      @redis = FakeRedis.new
      @fingerprint = Object.new
      @fingerprint.define_singleton_method(:call) { { format: 1, database: {}, storage: {} } }
    end

    teardown do
      @before ? ENV["MI_INSTALL_ID"] = @before : ENV.delete("MI_INSTALL_ID")
      ARGV.replace(@argv)
    end

    test "restore verification refuses a missing Redis marker without manufacturing one" do
      ARGV.clear
      Redis.stub(:new, @redis) do
        capture_io do
          assert_raises(SystemExit) { load Rails.root.join("installation/recovery_probe.rb") }
        end
      end
      assert_equal 0, @redis.writes
    end

    test "backup preparation makes a fresh noncredential control and exposes only its digest" do
      ARGV.replace(["prepare"])
      output, = capture_io do
        Redis.stub(:new, @redis) do
          MiRecoveryFingerprint.stub(:new, -> { @fingerprint }) do
            load Rails.root.join("installation/recovery_probe.rb")
          end
        end
      end
      assert_equal 1, @redis.writes
      assert_match(/\A[0-9a-f]{64}\z/, @redis.value)
      assert_equal Digest::SHA256.hexdigest(@redis.value), JSON.parse(output).fetch("redis_control_sha256")
      assert_not_includes output, @redis.value
    end
  end
end
