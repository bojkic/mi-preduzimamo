# frozen_string_literal: true

require "test_helper"
require "sidekiq/api"
require "json"

module DecidimApp
  class RecoveryQueueSummaryTest < ActiveSupport::TestCase
    test "queue inventory excludes job arguments and unexpected class labels" do
      secret = "synthetic private message to recipient@example.invalid"
      jobs = [
        Struct.new(:item, :klass).new({ "wrapped" => "Example::NotificationJob", "args" => [secret] }, "Wrapper"),
        Struct.new(:item, :klass).new({ "wrapped" => secret, "args" => [secret] }, "Wrapper")
      ]
      queue = Object.new
      queue.define_singleton_method(:name) { "authentication_critical" }
      queue.define_singleton_method(:size) { jobs.length }
      queue.define_singleton_method(:latency) { 2.1 }
      queue.define_singleton_method(:each) { |&block| jobs.each(&block) }
      count = Object.new
      count.define_singleton_method(:size) { 3 }
      output, = capture_io do
        Sidekiq::Queue.stub(:all, [queue]) do
          Sidekiq::RetrySet.stub(:new, count) do
            Sidekiq::ScheduledSet.stub(:new, count) do
              Sidekiq::DeadSet.stub(:new, count) do
                load Rails.root.join("installation/queue_summary.rb")
              end
            end
          end
        end
      end
      result = JSON.parse(output)
      assert_equal "quarantined_queue_inventory", result.fetch("status")
      assert_equal({ "Example::NotificationJob" => 1, "unknown" => 1 }, result.fetch("classes"))
      assert_equal 2, result.fetch("queues").first.fetch("jobs")
      assert_equal 3, result.fetch("retry")
      assert_not_includes output, secret
      assert_not_includes output, "args"
      assert_not_includes output, "recipient@example.invalid"
    end
  end
end
