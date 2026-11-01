# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/synthetic_event_source_registry"
require_relative "../../../support/city_service_captured_publication_fixture"

module DecidimApp
  module Bijeljina
    class CityServiceAlertNotificationJobTest < ActiveJob::TestCase
      include SyntheticEventSourceRegistry
      include CityServiceCapturedPublicationFixture

      class ClientDouble
        attr_reader :calls

        def initialize = @calls = []

        def viber_business_configured? = true

        def configured? = false

        def chat_channel_configured?(_channel) = false

        def send_phone_message(**options)
          @calls << options
          { "messages" => [{ "messageId" => "provider-1" }] }
        end
      end

      setup do
        @organization = create_organization
        @recipient = FactoryBot.create(:user, :confirmed, organization: @organization)
        Decidim::Bih::NotificationPreferences.set!(@recipient, topic: :city_service_alerts, channel: :viber, enabled: true)
        @area = Decidim::Bih::LocalArea.create!(organization: @organization, kind: "komsiluk", slug: "komsiluk-alert-test", name: { "sr" => "Komšiluk" })
        Decidim::Bih::CitizenProfile.for_user(@recipient, organization: @organization).assign_komsiluk!(@area, source: "dropdown")
        @event = CityServiceEvent.create!(organization: @organization, source_key: "electricity_outages", source_url: "https://example.test/outages",
                                          source_fingerprint: "queued-test", parser_version: "test", event_type: "planned_outage", severity: "service_outage",
                                          title: "Source notice", summary: "Source facts", targeting_level: "komsiluk", state: "published", lifecycle: "scheduled",
                                          starts_at: 1.hour.ago, ends_at: 1.hour.from_now, extraction_metadata: { publication_revision: "revision-1" },
                                          affected_area_slugs: [@area.slug], viber_dedupe_key: "notice-123")
        @opted_out = FactoryBot.create(:user, :confirmed, organization: @organization)
        Decidim::Bih::CitizenProfile.for_user(@opted_out, organization: @organization).assign_komsiluk!(@area, source: "dropdown")
        Decidim::Bih::NotificationPreferences.set!(@opted_out, topic: :city_service_alerts, channel: :viber, enabled: false)
        @opts = { organization_id: @organization.id, user_ids: [@recipient.id], text: "Planirano iskljucenje", dedupe_key: "notice-123",
                  event_id: @event.id, event_revision: "revision-1" }
        @previous_switch = ENV.fetch("MI_CITY_SERVICE_VIBER_ALERTS_ENABLED", nil)
        ENV["MI_CITY_SERVICE_VIBER_ALERTS_ENABLED"] = "1"
        @client = ClientDouble.new
        capture_city_publication!
      end

      teardown do
        @previous_switch.nil? ? ENV.delete("MI_CITY_SERVICE_VIBER_ALERTS_ENABLED") : ENV["MI_CITY_SERVICE_VIBER_ALERTS_ENABLED"] = @previous_switch
      end

      test "city alert creates deduplicated bounded account intents and respects explicit opt out" do
        @opts[:user_ids] << @opted_out.id
        assert Decidim::Bih::PlatformDelivery.exists?(user: @opted_out, identity: CityServiceIncidentIdentity.delivery_identity(@event))
        assert_difference "Decidim::Bih::AccountNotification.count", 1 do
          2.times { perform_job(@opts) }
        end
        notification = Decidim::Bih::AccountNotification.last
        assert_equal @recipient, notification.user
        assert_equal @event.ends_at, notification.expires_at
        assert_equal @event.publication_revision, notification.payload.dig("context", "event_revision")
        assert_not_includes enqueued_jobs.inspect, "Planirano iskljucenje"
        dispatch(notification)
        assert_equal 1, @client.calls.size
        assert_equal @event.ends_at, @client.calls.first[:expires_at]
      end

      test "legacy unbound and wrong tenant queued jobs fail closed" do
        assert_no_difference "Decidim::Bih::AccountNotification.count" do
          perform_job(@opts.except(:event_id, :event_revision))
          perform_job(@opts.merge(organization_id: create_organization.id))
          perform_job(@opts.merge(event_revision: "old-revision"))
        end
      end

      test "cancelled superseded withdrawn and elapsed events do not enqueue" do
        [{ lifecycle: "cancelled" }, { lifecycle: "superseded" }, { lifecycle: "scheduled", state: "dismissed" },
         { state: "published", ends_at: 1.minute.ago }].each do |attributes|
          @event.update!(attributes)
          assert_no_difference("Decidim::Bih::AccountNotification.count") { perform_job(@opts) }
        end
      end

      test "cancellation after first queue but before provider dispatch stops the message" do
        perform_job(@opts)
        notification = Decidim::Bih::AccountNotification.last
        @event.update!(lifecycle: "cancelled")
        dispatch(notification)
        assert_empty @client.calls
        assert_equal "skipped", notification.reload.status
      end

      test "revision replacement after intent creation stops the message" do
        perform_job(@opts)
        notification = Decidim::Bih::AccountNotification.last
        @event.update!(extraction_metadata: { publication_revision: "revision-2" })
        dispatch(notification)
        assert_empty @client.calls
        assert_equal "skipped", notification.reload.status
      end

      test "shortened deadline is rechecked before provider dispatch" do
        perform_job(@opts)
        notification = Decidim::Bih::AccountNotification.last
        @event.update!(ends_at: 5.minutes.from_now)
        dispatch(notification)
        assert_empty @client.calls
        assert_equal "skipped", notification.reload.status
      end

      test "expiry between claiming and the final send is enforced" do
        perform_job(@opts)
        notification = Decidim::Bih::AccountNotification.last
        travel_to @event.ends_at + 1.second do
          dispatch(notification)
        end
        assert_empty @client.calls
        assert_equal "skipped", notification.reload.status
      end

      test "disabling service alerts after enqueue stops pending provider requests" do
        perform_job(@opts)
        notification = Decidim::Bih::AccountNotification.last
        ENV["MI_CITY_SERVICE_VIBER_ALERTS_ENABLED"] = "0"
        dispatch(notification)
        assert_empty @client.calls
        assert_equal "skipped", notification.reload.status
      end

      test "queue acceptance is not delivery and fallback waits for the acknowledgment deadline" do
        Decidim::Bih::WebPush.stub(:enqueue, true) { CityServiceAlertNotificationJob.perform_now(@opts) }
        receipt = current_receipt
        assert_nil receipt.acknowledged_at
        assert_no_difference "Decidim::Bih::AccountNotification.count" do
          CityServiceFallbackJob.perform_now(receipt.id)
        end
        travel_to receipt.deadline_at + 1.second do
          assert_difference "Decidim::Bih::AccountNotification.count", 1 do
            2.times { CityServiceFallbackJob.perform_now(receipt.id) }
          end
          assert_equal ["viber"], Decidim::Bih::AccountNotification.last.payload["channels"]
        end
      end

      test "changed WhatsApp template cannot replace the operator-approved queued copy" do
        approved = { name: CityServicePhoneDelivery::TEMPLATE_NAME, language: "sr", body: { "1" => "Voda", "2" => "dio komšiluka", "3" => "danas" } }
        changed = approved.merge(body: approved.fetch(:body).merge("2" => "drugo područje"))
        CityServiceAlertNotificationJob.perform_now(@opts.merge(channels: %w(viber whatsapp), template: approved))
        receipt = current_receipt
        assert_equal approved.deep_stringify_keys, receipt.fallback_context.fetch("template")
        receipt.update!(deadline_at: 1.second.ago)

        CityServicePhoneDelivery.stub(:template, changed) do
          CityServiceFallbackJob.perform_now(receipt.id)
        end
        notification = Decidim::Bih::AccountNotification.last
        assert_equal ["viber"], notification.payload.fetch("channels")
        assert_nil notification.payload["template"]
      end

      test "final guard refuses the whole phone chain after channel authorization is revoked" do
        perform_job
        notification = Decidim::Bih::AccountNotification.last
        Decidim::Bih::Infobip::Client.stub(:new, @client) do
          Decidim::Bih::VerifiedPhone.stub(:delivery_phone_for, "+12025550101") do
            CityServicePhoneDelivery.stub(:channels, []) do
              Decidim::Bih::AccountNotifications.dispatch!(notification)
            end
          end
        end

        assert_empty @client.calls
        assert_equal "skipped", notification.reload.status
        assert_equal "delivery_channel_revoked", notification.reason
      end

      test "final guard never yields a queued WhatsApp failover after its approval is revoked" do
        approved = { name: CityServicePhoneDelivery::TEMPLATE_NAME, language: "sr", body: { "1" => "Voda", "2" => "dio komšiluka", "3" => "danas" } }
        CityServicePhoneDelivery.stub(:template, approved) do
          perform_job(@opts.merge(channels: %w(viber whatsapp), template: approved))
        end
        notification = Decidim::Bih::AccountNotification.last
        assert_equal %w(viber whatsapp), notification.payload.fetch("channels")
        notification.update!(channels: %w(viber whatsapp))
        called = false
        CityServicePhoneDelivery.stub(:template, approved) do
          CityServicePhoneDelivery.stub(:channels, ["viber"]) do
            CityServiceDeliveryGuard.call(notification:, payload: notification.payload) do
              called = true
            end
          end
        end

        assert_not called
        assert_equal "skipped", notification.reload.status
        assert_equal "delivery_channel_revoked", notification.reason
      end

      test "display and inbox acknowledgments each suppress fallback" do
        %w(browser_display inbox_read).each do |kind|
          @event.update!(summary: "Source facts #{kind}")
          capture_city_publication!
          CityServiceAlertNotificationJob.perform_now(@opts)
          receipt = current_receipt
          receipt.acknowledge!(kind)
          travel_to receipt.deadline_at + 1.second do
            assert_no_difference("Decidim::Bih::AccountNotification.count") { CityServiceFallbackJob.perform_now(receipt.id) }
          end
        end
      end

      test "late acknowledgment after external enqueue suppresses provider dispatch" do
        perform_job(@opts)
        receipt = current_receipt
        receipt.acknowledge!("browser_display")
        notification = Decidim::Bih::AccountNotification.last
        dispatch(notification)
        assert_empty @client.calls
        assert_equal "platform_delivery_confirmed", notification.reload.reason
      end

      test "receipt expiry caps the acknowledgment window and prevents timeout sends" do
        @event.update!(ends_at: 3.minutes.from_now)
        capture_city_publication!
        CityServiceAlertNotificationJob.perform_now(@opts)
        receipt = current_receipt
        assert_equal @event.ends_at, receipt.deadline_at
        travel_to @event.ends_at do
          assert_no_difference("Decidim::Bih::AccountNotification.count") { CityServiceFallbackJob.perform_now(receipt.id) }
        end
      end

      test "opt out after authorization suppresses the final fallback" do
        perform_job(@opts)
        Decidim::Bih::NotificationPreferences.set!(@recipient, topic: :city_service_alerts, channel: :viber, enabled: false)
        notification = Decidim::Bih::AccountNotification.last
        dispatch(notification)
        assert_empty @client.calls
        assert_equal "skipped", notification.reload.status
      end

      test "aggregate Viber preview fingerprints changes in recipient eligibility" do
        CityServiceAlertNotificationJob.stub(:recipient_ids_for, [@recipient.id]) do
          Decidim::Bih::Infobip::Client.stub(:new, @client) do
            Decidim::Bih::VerifiedPhone.stub(:delivery_phone_for, "+12025550101") do
              first = CityServiceFallbackAudience.preview(organization: @organization, area_slugs: [], expires_at: @event.ends_at)
              assert_equal 1, first[:eligible_viber]
              assert_equal 1, first[:total]
              assert_not first.has_key?(:user_ids)
              Decidim::Bih::NotificationPreferences.set!(@recipient, topic: :city_service_alerts, channel: :viber, enabled: false)
              second = CityServiceFallbackAudience.preview(organization: @organization, area_slugs: [])
              assert_equal 0, second[:eligible_viber]
              assert_equal({ "permission_required" => 1 }, second[:excluded])
              assert_not_equal first[:audience_fingerprint], second[:audience_fingerprint]
            end
          end
        end
      end

      test "target membership loss before final dispatch suppresses Viber" do
        perform_job(@opts)
        other_area = Decidim::Bih::LocalArea.create!(organization: @organization, kind: "komsiluk", slug: "komsiluk-other", name: { "sr" => "Other" })
        Decidim::Bih::CitizenProfile.for_user(@recipient, organization: @organization).assign_komsiluk!(other_area, source: "dropdown")
        notification = Decidim::Bih::AccountNotification.last
        dispatch(notification)
        assert_empty @client.calls
        assert_equal "recipient_area_changed", notification.reload.reason
      end

      test "routed Viber transport also honors a late platform acknowledgment" do
        Decidim::Bih::Setting.put(@organization, "messaging", "mode.city.service_alert_viber", "target")
        perform_job(@opts)
        current_receipt.acknowledge!("browser_display")
        notification = Decidim::Bih::AccountNotification.last
        dispatch(notification)
        assert_empty @client.calls
        assert_equal "platform_delivery_confirmed", notification.reload.reason
      end

      test "citywide publication captures board members before the worker without expanding to later joins" do
        area = Decidim::Bih::LocalArea.create!(organization: @organization, kind: "komsiluk", slug: "komsiluk-citywide", name: { "sr" => "Komšiluk" })
        Decidim::Bih::CitizenProfile.for_user(@recipient, organization: @organization).assign_komsiluk!(area, source: "dropdown")
        @event.update!(targeting_level: "citywide", affected_area_slugs: [])
        assert_includes CityServiceAlertNotificationJob.recipient_ids(@event), @recipient.id
        assert_difference -> { Decidim::Bih::PlatformDelivery.where(user: @recipient).count }, 1 do
          capture_city_publication!
        end
        newcomer = FactoryBot.create(:user, :confirmed, organization: @organization)
        Decidim::Bih::CitizenProfile.for_user(newcomer, organization: @organization).assign_komsiluk!(area, source: "dropdown")
        assert_no_difference "Decidim::Bih::PlatformDelivery.count" do
          CityServiceAlertNotificationJob.perform_now(@opts.except(:user_ids))
        end
        identity = CityServiceIncidentIdentity.delivery_identity(@event)
        assert Decidim::Bih::PlatformDelivery.exists?(user: @recipient, identity:)
        assert_not Decidim::Bih::PlatformDelivery.exists?(user: newcomer, identity:)
      end

      test "canonical incident membership change suppresses pending fallback and final transport" do
        CityServiceAlertNotificationJob.perform_now(@opts)
        receipt = current_receipt
        receipt.update!(deadline_at: 1.second.ago)
        first_identity = receipt.identity
        @event.update!(incident: CityServiceIncident.create!(organization: @organization, identity_key: "newly-merged", service: "electricity"))
        assert_not_equal first_identity, CityServiceIncidentIdentity.delivery_identity(@event)
        assert_no_difference("Decidim::Bih::AccountNotification.count") { CityServiceFallbackJob.perform_now(receipt.id) }

        @event.update!(summary: "Next meaningful revision")
        capture_city_publication!
        perform_job(@opts)
        notification = Decidim::Bih::AccountNotification.last
        replacement = CityServiceIncident.create!(organization: @organization, identity_key: "different-canonical", service: "electricity")
        @event.update!(incident: replacement)
        dispatch(notification)
        assert_empty @client.calls
        assert_equal "incident_identity_changed", notification.reload.reason
      end

      test "an explicitly empty city capture remains empty after a member joins" do
        empty_area = Decidim::Bih::LocalArea.create!(organization: @organization, kind: "komsiluk", slug: "komsiluk-empty-capture", name: { sr: "Empty" })
        @event.update!(affected_area_slugs: [empty_area.slug])
        capture_city_publication!
        identity = CityServiceIncidentIdentity.delivery_identity(@event)
        assert_equal identity, @event.extraction_metadata["board_audience_identity"]
        assert_empty Decidim::Bih::PlatformDelivery.where(organization: @organization, identity:)
        Decidim::Bih::CitizenProfile.for_user(@recipient, organization: @organization).assign_komsiluk!(empty_area, source: "dropdown")
        assert_no_difference ["Decidim::Bih::PlatformDelivery.count", "Decidim::Notification.count"] do
          CityServiceAlertNotificationJob.perform_now(@opts)
          CityServiceAlertNotificationJob.perform_now(@opts.except(:user_ids))
        end
      end

      test "uncaptured legacy work never creates or authorizes a historical audience" do
        @event.update!(incident: nil, extraction_metadata: @event.extraction_metadata.except("board_audience_identity"))
        assert_no_difference ["CityServiceIncident.count", "Decidim::Bih::PlatformDelivery.count", "Decidim::Bih::AccountNotification.count", "Decidim::Notification.count"] do
          CityServiceAlertNotificationJob.perform_now(@opts)
          CityServiceAlertNotificationJob.perform_now(@opts.except(:user_ids))
        end
        assert_empty Decidim::Bih::PlatformDelivery.where.not(fallback_requested_at: nil)
        assert_nil @event.reload.incident_id
      end

      private

      def current_receipt
        Decidim::Bih::PlatformDelivery.find_by!(user: @recipient, identity: CityServiceIncidentIdentity.delivery_identity(@event))
      end

      # These tests exercise the queued event's lifetime and final dispatch.
      # Provider readiness is covered by the router and broadcast tests.
      def perform_job(options = @opts)
        Decidim::Bih::Messaging::BroadcastChannels.stub(:for, ["viber"]) do
          CityServiceAlertNotificationJob.perform_now(options)
          Decidim::Bih::PlatformDelivery.where(account_notification_id: nil).where.not(fallback_requested_at: nil).find_each do |receipt|
            receipt.update!(deadline_at: 1.second.ago)
            CityServiceFallbackJob.perform_now(receipt.id)
          end
        end
      end

      def dispatch(notification)
        Decidim::Bih::Infobip::Client.stub(:new, @client) do
          Decidim::Bih::VerifiedPhone.stub(:delivery_phone_for, "+12025550101") do
            CityServicePhoneDelivery.stub(:channels, ["viber"]) do
              Decidim::Bih::AccountNotifications.dispatch!(notification)
            end
          end
        end
      end
    end
  end
end
