# frozen_string_literal: true
require "test_helper"

module DecidimApp
  module Bijeljina
    class CitySourceHttpIdentityTest < ActiveSupport::TestCase
      CONTACT = "crawler@community.example.invalid"
      Policy = CitySourceRequestPolicy

      test "unconfigured collector identity never identifies the Foundation installation" do
        assert_nil Policy.contact_email({})
        assert_nil CityServiceNoticeCollector::DEFAULT_CONTACT_EMAIL
        assert_nil CityServiceSourceProbe::DEFAULT_CONTACT_EMAIL
        assert_includes Policy::USER_AGENT, "MilicaSourceCollector/"
        assert_not_includes Policy::USER_AGENT, "fondacijabijeljina"
        assert_not_includes Policy::USER_AGENT, "Mozilla"
      end

      test "only explicit source contact is used and copied as immutable data" do
        setting = CONTACT.dup
        result = Policy.contact_email({ "MI_SOURCE_CONTACT_EMAIL" => setting, "MI_PUBLIC_SUPPORT_EMAIL" => "other@community.example.invalid" })
        assert_equal CONTACT, result
        assert result.frozen?
        assert_not_same setting, result
        assert_nil Policy.contact_email({ "MI_PUBLIC_SUPPORT_EMAIL" => CONTACT })
      end

      test "invalid or injectable source contacts cannot become request headers" do
        values = [nil, false, 42, "", "  ", "a@localhost", "not-an-email", "Person <#{CONTACT}>",
                  "#{CONTACT},other@community.example.invalid", "#{CONTACT}\r\nX-Authored: injected",
                  " #{CONTACT}", "#{CONTACT} ", "a" * 255 + "@community.example.invalid", "\xff".b]
        values.each { |value| assert_nil Policy.contact_email({ "MI_SOURCE_CONTACT_EMAIL" => value }) }
      end

      test "actual collector and probe request construction omit absent or invalid From" do
        [nil, "", "bad\r\nX-Authored: value"].each do |value|
          with_contact(value) do
            [CityServiceNoticeCollector, CityServiceSourceProbe].each do |reader|
              request = capture_request(reader)
              assert_nil request["From"]
              assert_equal Policy::USER_AGENT, request["User-Agent"]
            end
          end
        end
      end

      test "actual collector and probe use only own explicit source contact" do
        with_contact(CONTACT) do
          [CityServiceNoticeCollector, CityServiceSourceProbe].each do |reader|
            request = capture_request(reader)
            assert_equal CONTACT, request["From"]
            assert_equal Policy::USER_AGENT, request["User-Agent"]
            assert_not_includes request["User-Agent"], "fondacijabijeljina"
          end
        end
      end

      private

      def with_contact(value)
        previous = ENV["MI_SOURCE_CONTACT_EMAIL"]
        value.nil? ? ENV.delete("MI_SOURCE_CONTACT_EMAIL") : ENV["MI_SOURCE_CONTACT_EMAIL"] = value
        yield
      ensure
        previous.nil? ? ENV.delete("MI_SOURCE_CONTACT_EMAIL") : ENV["MI_SOURCE_CONTACT_EMAIL"] = previous
      end

      def capture_request(reader)
        requested = []
        response = Net::HTTPOK.new("1.1", "200", "OK")
        response["Content-Type"] = "text/plain; charset=utf-8"
        response.define_singleton_method(:read_body) { |&block| block.call("Authored response") }
        http = Object.new
        http.define_singleton_method(:request) { |request, &block| requested << request; block.call(response) }
        starter = lambda do |host, port, **options, &block|
          assert_equal "source.community.example.invalid", host
          assert_equal 443, port
          assert_equal true, options.fetch(:use_ssl)
          block.call(http)
        end
        policy = Object.new
        policy.define_singleton_method(:before_request) { |_uri, timeout:| timeout }
        policy.define_singleton_method(:observe_response) { |*| nil }
        Policy.stub(:default, policy) do
          Net::HTTP.stub(:start, starter) do
            result = reader.send(:fetch_url, "https://source.community.example.invalid/authored",
              { timeout: 5, max_bytes: 128, user_agent: Policy::USER_AGENT, deadline: nil, redirects: 0 })
            assert_equal 200, result.fetch(:http_status).to_i
          end
        end
        assert_equal 1, requested.size
        requested.first
      end
    end
  end
end
