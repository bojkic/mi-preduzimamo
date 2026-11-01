# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    # Tests for A2: ProviderClient base class — connection builder, safe_call semantics.
    class ProviderClientTest < ActiveSupport::TestCase
      # Minimal concrete subclass for testing
      class TestClient < ProviderClient
        DEFAULT_TIMEOUT = 5

        def initialize(base_url: "https://example.com", timeout: DEFAULT_TIMEOUT)
          super
        end

        def configured?
          base_url.present?
        end

        # Expose protected methods for testing
        def public_safe_call(event_name, payload = {}, on_error: :raise, zero: nil, &)
          safe_call(event_name, payload, on_error: on_error, zero: zero, &)
        end

        def public_connection
          connection
        end
      end

      setup do
        @client = TestClient.new
      end

      test "configured? returns true when base_url is present" do
        assert @client.configured?
      end

      test "safe_call returns the block value on success" do
        result = @client.public_safe_call("test.event") { 42 }
        assert_equal 42, result
      end

      test "safe_call with on_error: :raise re-raises on failure" do
        assert_raises(RuntimeError) do
          @client.public_safe_call("test.event", on_error: :raise) { raise "boom" }
        end
      end

      test "safe_call with on_error: :swallow returns nil and logs on failure" do
        logs = capture_logs do
          result = @client.public_safe_call("test.event", on_error: :swallow) { raise "swallowed error" }
          assert_nil result
        end
        assert_match(/swallowed error/, logs)
      end

      test "safe_call with on_error: :zero returns the zero value and logs on failure" do
        logs = capture_logs do
          result = @client.public_safe_call("test.event", on_error: :zero, zero: []) { raise "zero error" }
          assert_equal [], result
        end
        assert_match(/zero error/, logs)
      end

      test "safe_call instruments the event name via AS::Notifications" do
        events = []
        subscription = ActiveSupport::Notifications.subscribe("decidim_bih.test.event") do |name, *|
          events << name
        end

        @client.public_safe_call("test.event") { "ok" }

        assert_equal 1, events.size
      ensure
        ActiveSupport::Notifications.unsubscribe(subscription) if subscription
      end

      test "build_connection returns a Faraday connection" do
        conn = @client.public_connection
        assert_kind_of Faraday::Connection, conn
      end

      private

      def capture_logs
        io = StringIO.new
        orig = Rails.logger
        Rails.logger = ActiveSupport::Logger.new(io)
        yield
        io.string
      ensure
        Rails.logger = orig
      end
    end
  end
end
