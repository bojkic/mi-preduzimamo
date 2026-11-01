# frozen_string_literal: true

require "test_helper"
require "support/synthetic_messaging_configuration"
require "json"
require "time"

module Decidim
  module Bih
    module Viber
      class QueuedPhoneMessageGatewayTest < ActiveJob::TestCase
        include SyntheticMessagingConfiguration
        include ActiveJob::TestHelper

        setup do
          clear_enqueued_jobs
          clear_performed_jobs
        end

        teardown do
          clear_enqueued_jobs
          clear_performed_jobs
        end

        test "client credentials alone do not enable queued OTP without a sender" do
          with_synthetic_sms_sender(sender: nil) do
            gateway = QueuedPhoneMessageGateway.new(client: Struct.new(:configured?).new(true))
            assert_not gateway.configured?
          end
        end

        test "reports Infobip configuration from the client" do
          with_synthetic_sms_sender do
            configured = Struct.new(:configured?).new(true)
            unconfigured = Struct.new(:configured?).new(false)

            assert QueuedPhoneMessageGateway.new(client: configured).configured?
            assert_not QueuedPhoneMessageGateway.new(client: unconfigured).configured?
          end
        end

        # The queue moved in Phase 2 Task 2.7: authentication no longer shares
        # a queue with optional traffic, so a campaign backlog cannot delay a
        # sign-in code. `test/jobs/decidim/bih/job_queue_contract_test.rb` is
        # the contract; this asserts the same thing at the call site.
        test "enqueues OTP SMS on the reserved authentication queue" do
          gateway = QueuedPhoneMessageGateway.new(client: Struct.new(:configured?).new(true))

          assert_enqueued_with(job: Decidim::Bih::Infobip::SendPhoneMessageJob, queue: "authentication_critical") do
            gateway.send_sms(to: "38765111000", text: "Kod: 123456")
          end

          args = enqueued_jobs.last.fetch(:args).first
          application_keys = args.keys - ["_aj_ruby2_keywords"]
          serialized = JSON.generate(args)

          assert_equal ["encrypted_payload"], application_keys
          assert_equal ["encrypted_payload"], args.fetch("_aj_ruby2_keywords")
          assert_not_includes serialized, "38765111000"
          assert_not_includes serialized, "Kod: 123456"

          envelope = Decidim::Bih::Infobip::SendPhoneMessageJob.send(
            :decrypt_envelope,
            args.fetch("encrypted_payload")
          )
          assert_equal "38765111000", envelope.fetch("to")
          assert_equal "Kod: 123456", envelope.fetch("text")
          assert_nil envelope["viber_template"]
          assert_operator Time.iso8601(envelope.fetch("expires_at")), :>, Time.current
        end

        test "redacts enqueue failures before AccountLinking receives them" do
          gateway = QueuedPhoneMessageGateway.new(client: Struct.new(:configured?).new(true))
          failure = lambda do |**_args|
            raise "redis token=secret failed for 38765111000 with Kod: 123456"
          end

          error = assert_raises(Decidim::Bih::Infobip::Error) do
            Decidim::Bih::Infobip::SendPhoneMessageJob.stub(:perform_later, failure) do
              gateway.send_sms(to: "38765111000", text: "Kod: 123456")
            end
          end

          assert_includes error.message, "token=[REDACTED]"
          assert_includes error.message, "[phone:***1000]"
          assert_not_includes error.message, "38765111000"
          assert_not_includes error.message, "123456"
        end
      end
    end
  end
end
