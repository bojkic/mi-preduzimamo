# frozen_string_literal: true

require "test_helper"
require "support/synthetic_messaging_configuration"
require "support/fake_redis"
require "stringio"

module Decidim
  module Bih
    module Viber
      class AccountLinkingTest < ActiveSupport::TestCase
        include SyntheticMessagingConfiguration
        include ActiveJob::TestHelper

        # Plain callable gateway (the ->(phone, text) shape): records every send.
        class StubGateway
          attr_reader :sends

          def initialize = (@sends = [])

          def call(phone, text)
            @sends << { phone: phone, text: text }
          end
        end

        # Infobip-client-shaped gateway: exposes #configured? + #send_sms so we can
        # exercise both the real-send and the unconfigured/dev-log branches.
        class StubSmsClient
          attr_reader :sends

          def initialize(configured: true)
            @configured = configured
            @sends = []
          end

          def configured? = @configured

          def send_sms(to:, text:)
            @sends << { to: to, text: text }
          end
        end

        class StubTemplateSmsClient < StubSmsClient
          def send_sms(to:, text:, viber_template: nil)
            @sends << { to:, text:, viber_template: }
          end
        end

        # Models the rollback callback surface used by OtpStore's immediate
        # Redis counters. Durable put/clear operations are covered separately by
        # capturing and dispatching their effects at the commit boundary.
        class StubTransaction
          def initialize = (@rollback_callbacks = [])

          def open? = true

          def after_rollback(&block) = @rollback_callbacks << block

          def rollback = @rollback_callbacks.reverse_each(&:call)
        end

        setup do
          clear_enqueued_jobs
          clear_performed_jobs
          @organization = create_organization
          @redis = FakeRedis.new
          @gateway = StubGateway.new
          @linking = build_linking(@gateway)
          @otp_store = @linking.instance_variable_get(:@store)
        end

        teardown do
          clear_enqueued_jobs
          clear_performed_jobs
        end

        def build_linking(gateway)
          AccountLinking.new(
            organization: @organization,
            gateway: gateway,
            otp_store: OtpStore.new(redis: @redis)
          )
        end

        def otp_key(sender) = @otp_store.send(:otp_key, sender)

        def attempts_key(sender) = @otp_store.send(:attempts_key, sender)

        # Pulls the 6-digit code out of the OTP SMS the gateway received.
        def sent_code(gateway = @gateway) = gateway.sends.last[:text][/\d{6}/]

        test "start sends the OTP and stores only a digest, never the plaintext code" do
          assert_equal :otp_sent, @linking.start(sender: "viber-1", phone: "065123456")
          assert_equal 1, @gateway.sends.size

          code = sent_code
          assert_match(/\A\d{6}\z/, code)

          raw = @redis.get(otp_key("viber-1"))
          pending = @otp_store.get(sender: "viber-1")
          assert raw.present?, "an encrypted pending OTP must be stored"
          assert_not_includes raw, code, "the plaintext OTP must never be stored"
          assert_not_includes raw, "065123456", "the phone must not be plaintext in Redis"
          assert_match(/\A[0-9a-f]{64}\z/, pending.fetch(:digest), "an HMAC-SHA256 digest must be stored")
          assert_not_equal code, pending.fetch(:digest)
          assert_not_includes otp_key("viber-1"), "viber-1", "the Redis key must use an opaque sender HMAC"
        end

        test "start passes the approved OTP template to a template-aware gateway" do
          config = Decidim::Bih::Config.infobip.merge(
            viber_otp_template_id: "otp-template-uuid",
            viber_template_language: "bs"
          )
          original = Decidim::Bih::Config.infobip
          Decidim::Bih::Config.instance_variable_set(:@infobip, config)
          gateway = StubTemplateSmsClient.new

          assert_equal :otp_sent, build_linking(gateway).start(sender: "viber-template", phone: "065123456")
          template = gateway.sends.last.fetch(:viber_template)
          assert_equal "otp-template-uuid", template.fetch(:template_id)
          assert_equal "bs", template.fetch(:language)
          assert_match(/\A\d{6}\z/, template.dig(:parameters, :pin))
        ensure
          Decidim::Bih::Config.instance_variable_set(:@infobip, original)
        end

        test "start normalizes the phone to digits before storing" do
          @linking.start(sender: "viber-1", phone: "+387 65/123-456")
          stored = @otp_store.get(sender: "viber-1")
          assert_equal "38765123456", stored.fetch(:phone)
        end

        test "start rejects an implausible phone without sending" do
          assert_equal :invalid_phone, @linking.start(sender: "viber-1", phone: "12")
          assert_empty @gateway.sends
          assert_nil @redis.get(otp_key("viber-1"))
        end

        test "verify with the correct code links the sender and clears the OTP" do
          @linking.start(sender: "viber-2", phone: "38765111222")
          code = sent_code

          assert_difference -> { Decidim::Bih::Viber::Linkage.count }, 1 do
            assert_equal :verified, @linking.verify(sender: "viber-2", code: code)
          end

          linkage = Decidim::Bih::Viber::Linkage.find_by(organization: @organization, viber_sender: "viber-2")
          assert_equal "38765111222", linkage.phone
          assert linkage.verified_at.present?
          assert_nil @redis.get(otp_key("viber-2")), "the OTP must be cleared after success"
        end

        test "verify resolves decidim_user_id when user verified with local 0-prefix format" do
          # S3: a user who typed "065123456" at SMS verification time (local BiH
          # format) must be resolved even though the Viber OTP stored "38765123456"
          # (E.164 digits-only). The resolver tries the stripped "0"+national candidate.
          user = create(:user, organization: @organization)
          # The sms auth unique_id was computed from "065123456" (as typed by user)
          local_phone = "065123456"
          unique_id = Digest::SHA256.hexdigest("#{local_phone}-#{Rails.application.secret_key_base}")
          FactoryBot.create(:authorization,
                            user: user,
                            name: "sms",
                            unique_id: unique_id,
                            granted_at: Time.current)

          # The Viber sender verified with the E.164 digits form
          e164_digits = "38765123456"
          @linking.start(sender: "viber-local", phone: e164_digits)
          code = sent_code
          assert_equal :verified, @linking.verify(sender: "viber-local", code: code)

          linkage = Decidim::Bih::Viber::Linkage.find_by(organization: @organization, viber_sender: "viber-local")
          assert_equal user.id, linkage.decidim_user_id,
                       "local 0-prefix format (065123456) must resolve to the user"
        end

        test "an old explicit linkage cannot retain an account after its phone authorization is revoked or changed" do
          user = create(:user, :confirmed, organization: @organization)
          authorization = Decidim::Authorization.create!(user:, name: "sms",
                                                         unique_id: Decidim::Bih::SmsAuthorization.unique_id_for("38765123456"), granted_at: Time.current)
          Decidim::Bih::Viber::Linkage.create!(organization: @organization, viber_sender: "old-link",
                                               phone: "38765123456", verified_at: Time.current, decidim_user_id: user.id)
          assert_equal user, @linking.linked_user(sender: "old-link")
          authorization.update!(granted_at: nil)
          assert_nil @linking.linked_user(sender: "old-link")
          assert_nil @linking.user_for_phone("38765123456")
          authorization.update!(granted_at: Time.current,
                                unique_id: Decidim::Bih::SmsAuthorization.unique_id_for("38765987654"))
          assert_nil @linking.linked_user(sender: "old-link")
        end

        test "verify does not mutate a Decidim::User even when one shares the phone" do
          # An existing account with the same phone must NOT be mutated (logged in
          # or changed): proving phone control attributes reports + optionally
          # records decidim_user_id on the Linkage, but the User is never changed.
          user = create(:user, organization: @organization)
          @linking.start(sender: "viber-2", phone: "38765111222")
          code = sent_code

          assert_no_changes -> { user.reload.attributes } do
            @linking.verify(sender: "viber-2", code: code)
          end
          # The Linkage is created; decidim_user_id is nil unless a matching
          # sms authorization exists (none in this test).
          linkage = Decidim::Bih::Viber::Linkage.find_by(viber_sender: "viber-2")
          assert linkage.present?
          assert_nil linkage.decidim_user_id,
                     "no sms authorization exists, so decidim_user_id must be nil"
        end

        test "verify with a wrong code returns :invalid and increments the attempt counter" do
          @linking.start(sender: "viber-3", phone: "065123456")
          real = sent_code
          wrong = format("%06d", (real.to_i + 1) % 1_000_000)

          assert_equal :invalid, @linking.verify(sender: "viber-3", code: wrong)

          assert_equal 1, @redis.get(attempts_key("viber-3")).to_i
        end

        test "a database rollback compensates a wrong-code attempt without clearing the OTP" do
          @linking.start(sender: "viber-rollback", phone: "065123456")
          real = sent_code
          wrong = format("%06d", (real.to_i + 1) % 1_000_000)
          transaction = StubTransaction.new

          @otp_store.stub(:active_transaction, transaction) do
            assert_equal :invalid, @linking.verify(sender: "viber-rollback", code: wrong)
            assert_equal 1, @redis.get(attempts_key("viber-rollback")).to_i
            transaction.rollback
          end

          assert_nil @redis.get(attempts_key("viber-rollback"))
          assert @otp_store.get(sender: "viber-rollback"), "rollback must preserve the pending OTP"
        end

        test "verify burns the OTP after the attempt limit is reached" do
          @linking.start(sender: "viber-3", phone: "065123456")
          real = sent_code
          wrong = format("%06d", (real.to_i + 1) % 1_000_000)

          AccountLinking::MAX_ATTEMPTS.times { @linking.verify(sender: "viber-3", code: wrong) }

          assert_nil @redis.get(otp_key("viber-3")), "the OTP must be invalidated at the attempt limit"
          # A subsequent attempt now has nothing pending.
          assert_equal :no_pending, @linking.verify(sender: "viber-3", code: real)
        end

        test "verify returns :no_pending when nothing was started" do
          assert_equal :no_pending, @linking.verify(sender: "ghost", code: "123456")
        end

        test "verify returns :expired for an OTP older than its lifetime" do
          @linking.start(sender: "viber-4", phone: "065123456")
          # Backdate the stored OTP beyond the TTL.
          key = otp_key("viber-4")
          data = @otp_store.get(sender: "viber-4")
          data[:created_at] = Time.now.to_i - OtpStore::DEFAULT_TTL - 1
          @redis.set(
            key,
            @otp_store.send(:dump, **data),
            ex: OtpStore::DEFAULT_TTL
          )

          assert_equal :expired, @linking.verify(sender: "viber-4", code: sent_code)
          assert_nil @redis.get(key)
        end

        test "the send-rate limit blocks the 4th send in the window" do
          3.times { |i| assert_equal :otp_sent, @linking.start(sender: "viber-5", phone: "06512345#{i}") }
          assert_equal :rate_limited, @linking.start(sender: "viber-5", phone: "065123459")
          assert_equal 3, @gateway.sends.size, "no SMS is dispatched once rate-limited"
        end

        test "the per-phone send limit blocks SMS-bombing one number from different senders" do
          3.times { |i| assert_equal :otp_sent, @linking.start(sender: "sender-#{i}", phone: "065111222") }
          # A fresh sender (under its own per-sender quota) is still blocked because
          # the DESTINATION number has hit its cap.
          assert_equal :rate_limited, @linking.start(sender: "sender-x", phone: "065111222")
        end

        test "a real gateway send failure returns :send_failed" do
          raising = Object.new
          def raising.configured? = true

          def raising.send_sms(**) = raise(Decidim::Bih::Infobip::Error, "token=abc123 to=38765123456")

          logs = capture_logs do
            assert_equal :send_failed, build_linking(raising).start(sender: "viber-9", phone: "065123456")
          end

          assert_not_includes logs, "abc123"
          assert_not_includes logs, "065123456"
          assert_includes logs, "[phone:***3456]"
        end

        test "linked_phone returns the verified phone, nil otherwise" do
          assert_nil @linking.linked_phone(sender: "viber-6")

          @linking.start(sender: "viber-6", phone: "38765999000")
          @linking.verify(sender: "viber-6", code: sent_code)

          assert_equal "38765999000", @linking.linked_phone(sender: "viber-6")
        end

        test "an unconfigured Infobip gateway logs but still stores the OTP (dev path)" do
          client = StubSmsClient.new(configured: false)
          linking = build_linking(client)

          logs = capture_logs do
            assert_equal :unconfigured, linking.start(sender: "viber-7", phone: "065123456")
          end

          assert_empty client.sends, "nothing is sent when the gateway is unconfigured"
          assert @redis.get(otp_key("viber-7")), "the OTP is still stored so the flow stays testable"
          assert_not_includes logs, "065123456"
          assert_includes logs, "[phone:***3456]"
        end

        test "a configured Infobip gateway delivers via send_sms" do
          client = StubSmsClient.new(configured: true)
          linking = build_linking(client)

          assert_equal :otp_sent, linking.start(sender: "viber-8", phone: "065123456")
          assert_equal 1, client.sends.size
          assert_equal "065123456", client.sends.first[:to]
        end

        test "a queued OTP gateway commits the digest before enqueueing encrypted delivery" do
          with_synthetic_sms_sender do
            gateway = QueuedPhoneMessageGateway.new(client: StubSmsClient.new(configured: true))
            linking = build_linking(gateway)
            capture = nil

            assert_no_enqueued_jobs only: Decidim::Bih::Infobip::SendPhoneMessageJob do
              capture = Decidim::Bih::DurableEffects.capture do
                assert_equal :otp_sent, linking.start(sender: "viber-10", phone: "065123456")
              end
            end

            assert_nil @otp_store.get(sender: "viber-10"), "rollback-safe effects must not reach Redis before commit"
            assert_equal(%w(redis_eval active_job), capture.effects.map { |effect| effect.fetch("type") })
            assert_equal "viber_otp_put_v1", capture.effects.first.fetch("script_id")
            assert_not_includes capture.effects.to_json, "065123456", "durable metadata must not expose the phone"

            assert_enqueued_with(job: Decidim::Bih::Infobip::SendPhoneMessageJob, queue: "authentication_critical") do
              capture.effects.each do |effect|
                Decidim::Bih::DurableEffects.dispatch!(effect, redis: @redis)
              end
            end

            pending = @otp_store.get(sender: "viber-10")
            assert_equal "065123456", pending.fetch(:phone)
            assert_match(/\A[0-9a-f]{64}\z/, pending.fetch(:digest))
          end
        end

        private

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
