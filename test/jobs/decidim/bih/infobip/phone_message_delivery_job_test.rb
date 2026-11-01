# frozen_string_literal: true

require "test_helper"
require "stringio"

module Decidim
  module Bih
    module Infobip
      class PhoneMessageDeliveryJobTest < ActiveJob::TestCase
        test "sends a fresh authentication message through the ordered policy" do
          sent = []
          fake_client = configured_client(send_phone_message: ->(**args) { sent << args })
          expires_at = 5.minutes.from_now

          Decidim::Bih::Infobip::Client.stub(:new, -> { fake_client }) do
            Decidim::Bih::Infobip::SendPhoneMessageJob.perform_now(
              to: "38765111000",
              text: "Kod: 123456",
              viber_text: "Viber link",
              viber_template: {
                template_id: "otp-template-uuid",
                language: "bs",
                parameters: { pin: "123456" }
              },
              otp_code: "123456",
              expires_at:
            )
          end

          assert_equal 1, sent.size
          assert_equal "38765111000", sent.first[:to]
          assert_equal "Kod: 123456", sent.first[:text]
          assert_equal "Viber link", sent.first[:viber_text]
          assert_equal "otp-template-uuid", sent.first.dig(:viber_template, :template_id)
          assert_equal "123456", sent.first[:otp_code]
          assert_equal expires_at.to_i, sent.first[:expires_at].to_i
        end

        test "drops a stale authentication message without exposing its contents" do
          fake_client = configured_client(
            send_phone_message: ->(**) { raise "stale message should not send" }
          )

          logs = capture_logs do
            Decidim::Bih::Infobip::Client.stub(:new, -> { fake_client }) do
              Decidim::Bih::Infobip::SendPhoneMessageJob.perform_now(
                to: "38765111000",
                text: "Kod: 123456",
                expires_at: 1.minute.ago
              )
            end
          end

          assert_includes logs, "channel=phone stale authentication message dropped"
          assert_not_includes logs, "38765111000"
          assert_not_includes logs, "123456"
        end

        test "does not send when Infobip is unconfigured" do
          fake_client = Object.new
          fake_client.define_singleton_method(:configured?) { false }
          fake_client.define_singleton_method(:send_phone_message) do |**|
            raise "unconfigured message should not send"
          end

          logs = capture_logs do
            Decidim::Bih::Infobip::Client.stub(:new, -> { fake_client }) do
              Decidim::Bih::Infobip::SendPhoneMessageJob.perform_now(
                to: "38765111000",
                text: "Kod: 123456",
                expires_at: 5.minutes.from_now
              )
            end
          end

          assert_includes logs, "channel=phone Infobip unconfigured; message not sent"
          assert_not_includes logs, "38765111000"
          assert_not_includes logs, "123456"
        end

        private

        def configured_client(send_phone_message:)
          Object.new.tap do |client|
            client.define_singleton_method(:configured?) { true }
            client.define_singleton_method(:send_phone_message) do |**args|
              send_phone_message.call(**args)
            end
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
