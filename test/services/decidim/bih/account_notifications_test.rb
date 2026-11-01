# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    class AccountNotificationsTest < ActiveJob::TestCase
      class ClientDouble
        attr_accessor :error, :reports, :response
        attr_reader :calls

        def initialize = @calls = []

        def configured? = true

        def viber_business_configured? = true

        def chat_channel_configured?(_channel) = false

        def message_delivery_reports(**) = { "results" => Array(reports) }

        def send_phone_message(**options)
          @calls << options
          raise error if error

          response || { "messages" => [{ "messageId" => "provider-1" }] }
        end
      end

      setup do
        @organization = create_organization
        @user = FactoryBot.create(:user, :confirmed, organization: @organization)
        @client = ClientDouble.new
        NotificationPreferences.set!(@user, topic: :report_updates, channel: :viber, enabled: true)
      end

      test "push goes first and one durable phone reminder waits a full day" do
        travel_to Time.current.change(usec: 0) do
          message, notification = push_followup
          assert_equal %w(viber whatsapp), notification.payload.fetch("channels")
          assert_equal 24.hours.from_now, ReportPushFollowup.scheduled_at(notification)
          assert_equal "push", Decidim::Notification.where(user: @user).last.extra["proactive_channel"]
          assert_enqueued_with(job: AccountNotificationJob, args: [notification.id], at: 24.hours.from_now)
          with_delivery { AccountNotifications.dispatch!(notification) }
          assert_empty @client.calls
          assert_equal "pending", notification.reload.status
          assert_no_difference "AccountNotification.count" do
            ReportCaseMessageJob.perform_now(message.id)
          end
          travel 24.hours
          with_delivery { 2.times { AccountNotificationJob.perform_now(notification.id) } }
          assert_equal 1, @client.calls.size
          assert_equal [:viber], @client.calls.first[:channels]
          assert_equal "accepted", notification.reload.status
        end
      end

      test "opening answering or replacing a push message cancels its reminder" do
        %i(open answer replace).each do |action|
          message, notification = push_followup
          case action
          when :open then message.update!(read_at: Time.current)
          when :answer then message.report.case_messages.create!(actor_role: "citizen", kind: "reply", body: "Here is the detail")
          when :replace then message.report.case_messages.create!(actor_role: "staff", kind: "update", body: "Updated request")
          end
          travel 25.hours do
            with_delivery { AccountNotifications.dispatch!(notification) }
          end
          assert_equal "skipped", notification.reload.status
          assert_equal "report_message_opened_answered_or_replaced", notification.reason
        end
        assert_empty @client.calls
      end

      test "opening after the send claim still cancels before the provider request" do
        message, notification = push_followup
        travel 25.hours do
          # This is the gap between the committed claim and guarded transport.
          notification.update!(status: "sending", attempted_at: Time.current)
          message.update!(read_at: Time.current)
          with_delivery { AccountNotifications.send(:deliver, notification, notification.payload) }
        end
        assert_empty @client.calls
        assert_equal "skipped", notification.reload.status
      end

      test "reminder respects a subsequent opt out without email or SMS fallback" do
        _message, notification = push_followup
        NotificationPreferences.set!(@user, topic: :report_updates, channel: :viber, enabled: false)
        travel 25.hours do
          assert_no_difference "ActionMailer::Base.deliveries.size" do
            with_delivery { AccountNotifications.dispatch!(notification) }
          end
        end
        assert_empty @client.calls
        assert_equal "skipped", notification.reload.status
      end

      test "recovery waits until reminders are due and uncertain sends are not repeated" do
        _message, notification = push_followup
        travel 2.minutes do
          clear_enqueued_jobs
          AccountNotifications.recover_pending!
          assert_no_enqueued_jobs only: AccountNotificationJob
        end
        travel 25.hours do
          clear_enqueued_jobs
          AccountNotifications.recover_pending!
          assert_enqueued_with(job: AccountNotificationJob, args: [notification.id])
          @client.error = Infobip::Error.new("transport timeout")
          with_delivery { 2.times { AccountNotifications.dispatch!(notification.reload) } }
          assert_equal "unknown", notification.reload.status
          assert_equal 1, @client.calls.size
        end
      end

      test "durable intent encrypts content and deduplicates enqueue and execution" do
        notification = nil
        assert_difference "AccountNotification.count", 1 do
          notification = enqueue
          assert_equal notification.id, enqueue.id
        end
        assert_not_includes notification.payload_ciphertext, "Private status"
        assert_not_includes enqueued_jobs.inspect, "Private status"
        with_delivery do
          2.times { AccountNotifications.dispatch!(notification.reload) }
        end
        assert_equal 1, @client.calls.size
        assert_equal "accepted", notification.reload.status
        assert_equal ["provider-1"], notification.provider_message_ids
        assert_equal false, @client.calls.first[:final_sms]
        assert_equal [:viber], @client.calls.first[:channels]
      end

      test "opt out after enqueue is checked at execution" do
        notification = enqueue
        NotificationPreferences.set!(@user, topic: :report_updates, channel: :viber, enabled: false)
        with_delivery { AccountNotifications.dispatch!(notification) }
        assert_empty @client.calls
        assert_equal "skipped", notification.reload.status
      end

      test "revoked phone prevents queued delivery" do
        notification = enqueue
        with_delivery(phone: nil) { AccountNotifications.dispatch!(notification) }
        assert_empty @client.calls
        assert_equal "skipped", notification.reload.status
      end

      test "unknown provider outcome is never retried or independently failed over" do
        notification = enqueue
        @client.error = Infobip::Error.new("transport timeout")
        with_delivery { 2.times { AccountNotifications.dispatch!(notification.reload) } }
        assert_equal 1, @client.calls.size
        assert_equal "unknown", notification.reload.status
      end

      test "definitive provider rejection is distinguishable from unknown" do
        notification = enqueue
        @client.error = Infobip::Error.new("refused", http_status: 403)
        with_delivery { AccountNotifications.dispatch!(notification) }
        assert_equal "rejected", notification.reload.status
      end

      test "expired and already claimed deliveries cannot restart" do
        notification = enqueue
        notification.update!(expires_at: 1.minute.ago)
        with_delivery { AccountNotifications.dispatch!(notification) }
        assert_equal "skipped", notification.reload.status
        notification.update!(status: "sending", expires_at: 1.hour.from_now)
        with_delivery { AccountNotifications.dispatch!(notification) }
        assert_empty @client.calls
      end

      test "cross organization enqueue is rejected" do
        assert_raises(ArgumentError) do
          AccountNotifications.enqueue!(user: @user, organization: create_organization, topic: :report_updates,
                                        text: "private", deduplication_key: "cross-tenant")
        end
      end

      test "new WhatsApp consent does not inherit Viber or legacy defaults" do
        NotificationPreferences.set!(@user, topic: :report_updates, channel: :whatsapp, enabled: true)
        with_delivery do
          result = AccountNotifications.preview(user: @user, organization: @organization,
                                                topic: :report_updates, text: "Private status", channels: ["whatsapp"])
          assert_equal "template_required", result[:reasons]["whatsapp"]
        end
      end

      test "one-time test records consent without subscribing and respects later optout" do
        @user.update!(notification_settings: {})
        notification = AccountNotifications.enqueue_test!(user: @user, organization: @organization, channel: "viber", text: "Test")
        assert_equal notification.id, AccountNotifications.enqueue_test!(user: @user, organization: @organization, channel: "viber", text: "Test").id
        assert NotificationPreferences.permitted?(@user, topic: :community_news, channel: :viber)
        NotificationPreferences.set!(@user, topic: :community_news, channel: :viber, enabled: false)
        with_delivery { AccountNotifications.dispatch!(notification) }
        assert_empty @client.calls
        assert_equal "skipped", notification.reload.status
      end

      test "one-time test sends without modifying topic permissions" do
        @user.update!(notification_settings: {})
        TopicPreferences.set!(@user, topic: :community_news, enabled: false)
        notification = AccountNotifications.enqueue_test!(user: @user, organization: @organization, channel: "viber", text: "Test")
        with_delivery { AccountNotifications.dispatch!(notification) }
        assert_equal "accepted", notification.reload.status
        assert_not NotificationPreferences.permitted?(@user.reload, topic: :community_news, channel: :viber)
      end

      test "eligibility loss between claim and final check persists skipped" do
        notification = enqueue
        original_guard = AccountNotifications.delivery_guard
        AccountNotifications.delivery_guard = lambda do |notification:, **_options, &delivery|
          TopicPreferences.set!(notification.user, topic: :report_updates, enabled: false)
          delivery.call
        end
        with_delivery { AccountNotifications.dispatch!(notification) }
        assert_equal "skipped", notification.reload.status
        assert_equal "eligibility_changed", notification.reason
        assert_empty @client.calls
      ensure
        AccountNotifications.delivery_guard = original_guard
      end

      test "reconciliation only accepts matching handset confirmation and never sends" do
        notification = enqueue
        notification.update!(status: "accepted", provider_message_ids: ["provider-1"])
        @client.reports = [{ "messageId" => "another-id", "status" => { "name" => "DELIVERED_TO_HANDSET" } }]
        with_delivery { AccountNotifications.reconcile!(notification) }
        assert_equal "accepted", notification.reload.status
        @client.reports = [{ "messageId" => "provider-1", "status" => { "name" => "DELIVERED_TO_HANDSET" } }]
        with_delivery { AccountNotificationReconciliationJob.perform_now(notification.id, 0) }
        assert_equal "delivered", notification.reload.status
        assert notification.delivered_at
        assert_empty @client.calls
      end

      test "pending recovery never restarts an uncertain or accepted send" do
        pending = enqueue
        pending.update!(created_at: 2.minutes.ago)
        uncertain = AccountNotifications.enqueue!(user: @user, organization: @organization, topic: :report_updates,
                                                  text: "Private", deduplication_key: "uncertain", enqueue_job: false)
        uncertain.update!(status: "sending", attempted_at: 31.minutes.ago)
        clear_enqueued_jobs
        assert_enqueued_with(job: AccountNotificationJob, args: [pending.id]) do
          AccountNotifications.recover_pending!
        end
        assert_equal "unknown", uncertain.reload.status
        assert_not(enqueued_jobs.any? { |job| job[:args] == [uncertain.id] })
      end

      test "deleting an account removes its encrypted notification intents" do
        notification = enqueue
        @user.update!(deleted_at: Time.current)
        assert_not AccountNotification.exists?(notification.id)
      end

      test "provider rejection inside an HTTP success does not claim acceptance" do
        notification = enqueue
        @client.response = { "messages" => [{ "messageId" => "provider-1", "status" => { "groupName" => "REJECTED" } }] }
        with_delivery { AccountNotifications.dispatch!(notification) }
        assert_equal "failed", notification.reload.status
        assert_equal "provider_rejected", notification.reason
        assert_equal 1, @client.calls.size
      end

      test "terminal single-channel failure remains failed without retrying" do
        notification = enqueue
        notification.update!(status: "accepted", channels: ["viber"], provider_message_ids: ["provider-1"])
        @client.reports = [{ "messageId" => "provider-1", "status" => { "groupName" => "UNDELIVERABLE" } }]
        with_delivery { AccountNotifications.reconcile!(notification) }
        assert_equal "failed", notification.reload.status
        assert_equal "provider_undeliverable", notification.reason
        with_delivery { AccountNotifications.dispatch!(notification) }
        assert_empty @client.calls
      end

      test "corrupt pending ciphertext becomes terminal without transport or retry" do
        notification = enqueue
        notification.update!(payload_ciphertext: "corrupted-envelope")
        with_delivery { 2.times { AccountNotifications.dispatch!(notification.reload) } }
        assert_equal "skipped", notification.reload.status
        assert_equal "payload_unreadable", notification.reason
        assert_empty @client.calls
      end

      test "malformed decoded payloads terminate without transport" do
        [[], { "text" => "private", "channels" => "viber" }].each_with_index do |payload, index|
          notification = AccountNotifications.enqueue!(user: @user, organization: @organization, topic: :report_updates,
                                                       text: "private", channels: ["viber"], deduplication_key: "malformed-#{index}")
          notification.update!(payload:)
          with_delivery { AccountNotifications.dispatch!(notification) }
          assert_equal "skipped", notification.reload.status
          assert_equal "payload_unreadable", notification.reason
        end
        assert_empty @client.calls
      end

      test "expired and claimed intents never decode corrupt ciphertext" do
        notification = enqueue
        notification.update!(payload_ciphertext: "corrupted-envelope", expires_at: 1.minute.ago)
        with_delivery { AccountNotifications.dispatch!(notification) }
        assert_equal "expired", notification.reload.reason
        %w(accepted sending).each do |status|
          notification.update!(status:, reason: nil, expires_at: 1.hour.from_now)
          with_delivery { AccountNotifications.dispatch!(notification) }
          assert_equal status, notification.reload.status
          assert_nil notification.reason
        end
        assert_empty @client.calls
      end

      test "transient infrastructure errors do not falsely mark payload unreadable" do
        notification = enqueue
        notification.stub(:payload, -> { raise ActiveRecord::ConnectionNotEstablished, "temporary outage" }) do
          with_delivery { AccountNotifications.dispatch!(notification) }
        end
        assert_equal "pending", notification.reload.status
        assert_nil notification.reason
        assert_empty @client.calls
      end

      test "one-time permission expiring after claim cannot reach any transport" do
        notification = AccountNotifications.enqueue_test!(user: @user, organization: @organization, channel: "viber", text: "Test")
        original_preview = AccountNotifications.method(:preview)
        delayed_preview = lambda do |**options|
          decision = original_preview.call(**options)
          travel_to(notification.expires_at + 1.second)
          decision
        end

        with_delivery do
          AccountNotifications.stub(:preview, delayed_preview) do
            AccountNotifications.dispatch!(notification)
          end
        end
        assert_equal "skipped", notification.reload.status
        assert_equal "expired", notification.reason
        assert notification.attempted_at, "the intent must have passed its initial claim before expiring"
        assert_empty @client.calls
        assert_empty notification.provider_message_ids
      ensure
        travel_back
      end

      test "a proven email is selected ahead of paid channels and delivered once without provider reconciliation" do
        EmailConfirmation.mark_confirmed!(@user)
        notification = AccountNotifications.enqueue!(user: @user, organization: @organization, topic: :community_news,
                                                     text: "Community notice", deduplication_key: "email-route", enqueue_job: false)
        ActionMailer::Base.deliveries.clear
        with_delivery { 2.times { AccountNotifications.dispatch!(notification.reload) } }
        assert_equal ["email"], notification.reload.channels
        assert_equal "accepted", notification.status
        assert_equal 1, ActionMailer::Base.deliveries.size
        assert_equal [@user.email], ActionMailer::Base.deliveries.last.to
        assert_includes ActionMailer::Base.deliveries.last.body.decoded, "Community notice"
        assert_empty @client.calls
        assert_not(enqueued_jobs.any? { |job| job[:job] == AccountNotificationReconciliationJob })
      end

      test "routed external copies use the same proven email selection" do
        EmailConfirmation.mark_confirmed!(@user)
        Setting.put(@organization, "messaging", "mode.komsiluk.area_broadcast", "target")
        notification = AccountNotifications.enqueue!(user: @user, organization: @organization, topic: :neighborhood_info,
                                                     text: "Neighborhood notice", deduplication_key: "routed-email", enqueue_job: false,
                                                     message_class: "komsiluk.area_broadcast")
        ActionMailer::Base.deliveries.clear
        with_delivery { AccountNotifications.dispatch!(notification) }
        assert_equal ["email"], notification.reload.channels
        assert_equal "accepted", notification.status
        assert_equal 1, ActionMailer::Base.deliveries.size
        assert_empty @client.calls
      end

      test "email topic refusal at execution prevents mail and does not fall through to a paid channel" do
        EmailConfirmation.mark_confirmed!(@user)
        notification = AccountNotifications.enqueue!(user: @user, organization: @organization, topic: :community_news,
                                                     text: "Community notice", deduplication_key: "email-refused", enqueue_job: false)
        TopicPreferences.set!(@user, topic: :community_news, enabled: false)
        assert_no_difference "ActionMailer::Base.deliveries.size" do
          with_delivery { AccountNotifications.dispatch!(notification) }
        end
        assert_equal "skipped", notification.reload.status
        assert_empty @client.calls
      end

      test "a suppressed email is ineligible and routing may choose an eligible phone instead" do
        EmailConfirmation.mark_confirmed!(@user)
        Messaging::TransportSuppression.ingest!(organization: @organization, provider: "smtp", channel: "email",
                                                destination: { kind: "email", value: @user.email }, reason: "hard_bounce",
                                                source: "provider_webhook", user: @user)
        with_delivery do
          decision = AccountNotifications.preview(user: @user, organization: @organization, topic: :community_news,
                                                  text: "Community notice", channels: %w(email viber))
          assert_equal ["viber"], decision[:channels]
          assert_equal "email_unavailable", decision[:reasons]["email"]
        end
      end

      private

      # The approved template is a REDUCED variant, not a translation of the
      # Viber text: Meta approved a reference and a status and nothing else.
      # The staff body and the private reply link are deliberately absent, so
      # nothing in the platform may promise identical content across channels.
      test "the configured whatsapp report template carries a reference and a status and nothing else" do
        template = AccountNotifications.template_resolver.call(
          topic: "report_updates", text: "Staff wrote this private body", reference: "PR-1", status: "u obradi"
        )

        assert_equal "mi_status_prijave_v1", template[:name]
        assert_equal %w(1 2), template[:body].keys.sort
        assert_equal "PR-1", template[:body]["1"]
        assert_equal "u obradi", template[:body]["2"]
        assert_not_includes template.to_s, "Staff wrote this private body"
        assert_no_match(%r{https?://}, template.to_s)
      end

      def push_followup
        report = Report.create!(organization: @organization, author: @user, description: "Container location")
        message = report.case_messages.create!(actor_role: "staff", kind: "question", body: "Please confirm the location")
        WebPush.stub(:available_for?, true) { ReportCaseMessageJob.perform_now(message.id) }
        [message, message.reload.account_notification]
      end

      def enqueue
        AccountNotifications.enqueue!(user: @user, organization: @organization, topic: :report_updates,
                                      text: "Private status", deduplication_key: "report-123", channels: ["viber"])
      end

      def with_delivery(phone: "+38765111001", &block)
        Infobip::Client.stub(:new, @client) do
          VerifiedPhone.stub(:delivery_phone_for, phone, &block)
        end
      end
    end
  end
end
