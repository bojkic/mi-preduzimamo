# frozen_string_literal: true

require "test_helper"
require "stringio"

module Decidim
  module Bih
    module Infobip
      class SmsDeliveryJobTest < ActiveJob::TestCase
        test "sends an SMS through Infobip when the job is still fresh" do
          sent = []
          fake_client = configured_client(send_sms: ->(**args) { sent << args })

          Decidim::Bih::Infobip::Client.stub(:new, -> { fake_client }) do
            Decidim::Bih::Infobip::SendSmsJob.perform_now(
              to: "38765111000",
              text: "Kod: 123456",
              expires_at: 5.minutes.from_now
            )
          end

          assert_equal [{ to: "38765111000", text: "Kod: 123456" }], sent
        end

        test "drops stale SMS without exposing the OTP" do
          fake_client = configured_client(send_sms: ->(**_args) { raise "stale SMS should not send" })

          logs = capture_logs do
            Decidim::Bih::Infobip::Client.stub(:new, -> { fake_client }) do
              Decidim::Bih::Infobip::SendSmsJob.perform_now(
                to: "38765111000",
                text: "Kod: 123456",
                expires_at: 1.minute.ago
              )
            end
          end

          assert_includes logs, "[phone:***1000]"
          assert_not_includes logs, "38765111000"
          assert_not_includes logs, "123456"
        end

        test "does not send when Infobip is unconfigured" do
          fake_client = Object.new
          fake_client.define_singleton_method(:configured?) { false }
          fake_client.define_singleton_method(:send_sms) { |**_args| raise "unconfigured SMS should not send" }

          logs = capture_logs do
            Decidim::Bih::Infobip::Client.stub(:new, -> { fake_client }) do
              Decidim::Bih::Infobip::SendSmsJob.perform_now(
                to: "38765111000",
                text: "Kod: 123456",
                expires_at: 5.minutes.from_now
              )
            end
          end

          assert_includes logs, "[phone:***1000]"
          assert_not_includes logs, "38765111000"
          assert_not_includes logs, "123456"
        end

        private

        def configured_client(send_sms:)
          Object.new.tap do |client|
            client.define_singleton_method(:configured?) { true }
            client.define_singleton_method(:send_sms) { |**args| send_sms.call(**args) }
          end
        end

        def capture_logs
          io = StringIO.new
          original_logger = Rails.logger
          Rails.logger = ActiveSupport::Logger.new(io)
          yield
          io.string
        ensure
          Rails.logger = original_logger
        end
      end
    end
  end
end
