# frozen_string_literal: true

require "test_helper"
require "stringio"

module Decidim
  module Bih
    module Infobip
      class ViberDeliveryJobsTest < ActiveJob::TestCase
        include ActiveJob::TestHelper

        setup do
          clear_enqueued_jobs
          clear_performed_jobs
          @organization = create_organization(host: "mi.test")
          # This deployment runs Viber Business Messages only, so the Bot is off
          # by default. These tests cover the dormant transport so it still
          # works if revived, and therefore switch it on explicitly. The
          # switched-off behaviour has its own test at the bottom of this file.
          @original_bot_enabled = ENV.fetch("DECIDIM_BIH_VIBER_BOT_ENABLED", nil)
          ENV["DECIDIM_BIH_VIBER_BOT_ENABLED"] = "true"
          Decidim::Bih::Config.reset!
        end

        teardown do
          clear_enqueued_jobs
          clear_performed_jobs
          if @original_bot_enabled.nil?
            ENV.delete("DECIDIM_BIH_VIBER_BOT_ENABLED")
          else
            ENV["DECIDIM_BIH_VIBER_BOT_ENABLED"] = @original_bot_enabled
          end
          Decidim::Bih::Config.reset!
        end

        test "text delivery sends via Infobip and enqueues the sticker after success" do
          sent = []
          fake_client = configured_client(
            send_viber_bot: ->(**args) { sent << args },
            send_viber_bot_image: ->(**_args) { true }
          )

          Decidim::Bih::Infobip::Client.stub(:new, -> { fake_client }) do
            assert_enqueued_with(job: Decidim::Bih::Infobip::SendViberImageJob, queue: "integrations") do
              Decidim::Bih::Infobip::SendViberTextJob.perform_now(
                organization_id: @organization.id,
                to: "opaque-viber-bot-user-A_42",
                text: "Hvala na prijavi.",
                sticker: "prijavljeno"
              )
            end
          end

          assert_equal [{ to: "opaque-viber-bot-user-A_42", text: "Hvala na prijavi." }], sent
        end

        test "text delivery does not enqueue a sticker when Infobip is unconfigured" do
          fake_client = Object.new
          fake_client.define_singleton_method(:viber_bot_configured?) { false }
          fake_client.define_singleton_method(:viber_bot_active?) { false }

          logs = capture_logs do
            Decidim::Bih::Infobip::Client.stub(:new, -> { fake_client }) do
              assert_no_enqueued_jobs(only: Decidim::Bih::Infobip::SendViberImageJob) do
                Decidim::Bih::Infobip::SendViberTextJob.perform_now(
                  organization_id: @organization.id,
                  to: "38765111000",
                  text: "Hvala na prijavi.",
                  sticker: "prijavljeno"
                )
              end
            end
          end

          assert_includes logs, "Viber Bot unconfigured; reply not sent"
          assert_not_includes logs, "38765111000"
          assert_not_includes logs, "Hvala na prijavi."
        end

        test "legacy unscoped business delivery cannot send an old raw destination" do
          sent = []
          fake_client = Object.new
          fake_client.define_singleton_method(:viber_business_configured?) { true }
          fake_client.define_singleton_method(:send_viber_business) { |**args| sent << args }

          Decidim::Bih::Infobip::Client.stub(:new, -> { fake_client }) do
            Decidim::Bih::Infobip::SendViberBusinessTextJob.perform_now(
              organization_id: @organization.id,
              to: "066900004",
              text: "Nova vijest"
            )
          end

          assert_empty sent
        end

        test "image delivery resolves the host sticker URL" do
          sent = []
          fake_client = configured_client(
            send_viber_bot: ->(**_args) { true },
            send_viber_bot_image: ->(**args) { sent << args }
          )

          Decidim::Bih::Infobip::Client.stub(:new, -> { fake_client }) do
            Decidim::Bih::Infobip::SendViberImageJob.perform_now(
              organization_id: @organization.id,
              to: "opaque-viber-bot-user-A_42",
              sticker: "prijavljeno"
            )
          end

          assert_equal [
            {
              to: "opaque-viber-bot-user-A_42",
              image_url: "https://mi.test/mi/stickers/prijavljeno.png"
            }
          ], sent
        end

        test "image delivery failure logs sanitized sender and provider error" do
          fake_client = configured_client(
            send_viber_bot: ->(**_args) { true },
            send_viber_bot_image: lambda { |**_args|
              raise Decidim::Bih::Infobip::Error.new(
                "token=secret to=38765111000 failed for 38765111000",
                http_status: 503,
                error_code: "IMAGE_FAILED",
                error_group: "REJECTED"
              )
            }
          )

          logs = capture_logs do
            Decidim::Bih::Infobip::Client.stub(:new, -> { fake_client }) do
              Decidim::Bih::Infobip::SendViberImageJob.perform_now(
                organization_id: @organization.id,
                to: "38765111000",
                sticker: "prijavljeno"
              )
            end
          end

          assert_includes logs, "channel=viber status=503 code=IMAGE_FAILED group=REJECTED"
          assert_not_includes logs, "38765111000"
          assert_not_includes logs, "token=secret"
        end

        private

        test "a switched-off Viber Bot drops the reply quietly instead of raising" do
          # Business-Messages-only is the launch posture: the Bot being off is a
          # decision, not a misconfiguration, so it must not raise or alarm.
          ENV.delete("DECIDIM_BIH_VIBER_BOT_ENABLED")
          Decidim::Bih::Config.reset!

          sent = []
          fake_client = configured_client(
            send_viber_bot: ->(**args) { sent << args },
            send_viber_bot_image: ->(**_args) { true }
          )

          logs = capture_logs do
            Decidim::Bih::Infobip::Client.stub(:new, -> { fake_client }) do
              assert_no_enqueued_jobs(only: Decidim::Bih::Infobip::SendViberImageJob) do
                Decidim::Bih::Infobip::SendViberTextJob.perform_now(
                  organization_id: @organization.id,
                  to: "opaque-viber-bot-user-A_42",
                  text: "Hvala na prijavi.",
                  sticker: "prijavljeno"
                )
              end
            end
          end

          assert_empty sent
          assert_includes logs, "Viber Bot disabled; reply not sent"
          assert_not_includes logs, "Hvala na prijavi."
        end

        def configured_client(send_viber_bot:, send_viber_bot_image:)
          Object.new.tap do |client|
            client.define_singleton_method(:viber_bot_configured?) { true }
            client.define_singleton_method(:viber_bot_active?) { true }
            client.define_singleton_method(:send_viber_bot) { |**args| send_viber_bot.call(**args) }
            client.define_singleton_method(:send_viber_bot_image) { |**args| send_viber_bot_image.call(**args) }
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
