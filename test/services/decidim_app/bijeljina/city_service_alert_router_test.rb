# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/synthetic_event_source_registry"
require_relative "../../../support/city_service_captured_publication_fixture"

module DecidimApp
  module Bijeljina
    # Automatic transport candidates share the neighborhood topic gate while
    # reviewed publication, revision and deduplication controls still apply.
    class CityServiceAlertRouterTest < ActiveJob::TestCase
      include SyntheticEventSourceRegistry
      include CityServiceCapturedPublicationFixture

      MESSAGE_CLASS = DecidimApp::Bijeljina::CityServiceAlertNotificationJob::MESSAGE_CLASS

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
        @silent = FactoryBot.create(:user, :confirmed, organization: @organization)
        [@recipient, @silent].each { |user| Decidim::Bih::EmailConfirmation.mark_confirmed!(user) }
        @area = Decidim::Bih::LocalArea.create!(organization: @organization, kind: "komsiluk", slug: "komsiluk-router", name: { "sr" => "Komšiluk" })
        [@recipient, @silent].each do |user|
          Decidim::Bih::CitizenProfile.for_user(user, organization: @organization).assign_komsiluk!(@area, source: "dropdown")
        end
        @event = CityServiceEvent.create!(
          organization: @organization, source_key: "electricity_outages", source_url: "https://example.test/outages",
          source_fingerprint: "router-test", parser_version: "test", event_type: "planned_outage",
          severity: "service_outage", title: "Source notice", summary: "Source facts", targeting_level: "komsiluk",
          state: "published", lifecycle: "scheduled", starts_at: 1.hour.ago, ends_at: 1.hour.from_now,
          affected_area_slugs: [@area.slug], extraction_metadata: { publication_revision: "revision-1" }, viber_dedupe_key: "router-123"
        )
        @opts = { organization_id: @organization.id, user_ids: [@recipient.id], text: "Planirano iskljucenje",
                  dedupe_key: "router-123", event_id: @event.id, event_revision: "revision-1" }
        @previous_switch = ENV.fetch("MI_CITY_SERVICE_VIBER_ALERTS_ENABLED", nil)
        ENV["MI_CITY_SERVICE_VIBER_ALERTS_ENABLED"] = "1"
        @client = ClientDouble.new
        capture_city_publication!
      end

      teardown do
        @previous_switch.nil? ? ENV.delete("MI_CITY_SERVICE_VIBER_ALERTS_ENABLED") : ENV["MI_CITY_SERVICE_VIBER_ALERTS_ENABLED"] = @previous_switch
      end

      def enroll!(mode = "compatibility")
        Decidim::Bih::Setting.put(@organization, Decidim::Bih::Messaging::Modes::NAMESPACE,
                                  "mode.#{MESSAGE_CLASS}", mode)
      end

      # The recipient's number is not stored in this fixture, so the same stub
      # the sibling job test uses stands in for it — here it also has to be
      # visible to the ROUTED read, which asks the same reader.
      def perform_job(opts = @opts)
        Decidim::Bih::VerifiedPhone.stub(:delivery_phone_for, "+12025550101") do
          Decidim::Bih::Messaging::BroadcastChannels.stub(:for, %w(email viber)) do
            CityServiceAlertNotificationJob.perform_now(opts)
            Decidim::Bih::PlatformDelivery.where(account_notification_id: nil).where.not(fallback_requested_at: nil).find_each do |receipt|
              receipt.update!(deadline_at: 1.second.ago)
              CityServiceFallbackJob.perform_now(receipt.id)
            end
          end
        end
      end

      def payload_channels
        Decidim::Bih::AccountNotification.last.payload.fetch("channels")
      end

      test "enrollment never turns initial platform enqueue into immediate external delivery" do
        enroll!
        assert_difference "Decidim::Notification.count", 1 do
          assert_no_difference "Decidim::Bih::AccountNotification.count" do
            CityServiceAlertNotificationJob.perform_now(@opts)
          end
        end
        receipt = Decidim::Bih::PlatformDelivery.find_by!(user: @recipient, identity: CityServiceIncidentIdentity.delivery_identity(@event))
        assert receipt.inbox_created_at
        assert_nil receipt.acknowledged_at
        assert_operator receipt.deadline_at, :>, Time.current
      end

      test "enrollment keeps Viber-only fallback for distinct meaningful revisions" do
        assert_difference "Decidim::Bih::AccountNotification.count", 1 do
          perform_job
        end
        legacy_channels = payload_channels

        enroll!
        @event.update!(viber_dedupe_key: "router-456", summary: "Updated source facts")
        capture_city_publication!
        assert_difference "Decidim::Bih::AccountNotification.count", 1 do
          perform_job(@opts.merge(dedupe_key: "router-456"))
        end

        assert_equal ["viber"], legacy_channels
        assert_equal legacy_channels, payload_channels
      end

      test "the enrolled job defaults on for a citizen with no stored topic choice" do
        enroll!
        assert_difference "Decidim::Bih::AccountNotification.count", 1 do
          perform_job(@opts.merge(user_ids: [@silent.id]))
        end
        assert_equal ["viber"], payload_channels
      end

      test "an explicit opt-out is still refused before the router is consulted at all" do
        enroll!
        Decidim::Bih::NotificationPreferences.set!(@silent, topic: :city_service_alerts, channel: :viber, enabled: false)

        assert_no_difference "Decidim::Bih::AccountNotification.count" do
          perform_job(@opts.merge(user_ids: [@silent.id]))
        end
      end

      test "publication, revision and dedupe gates still refuse first under enrollment" do
        enroll!
        assert_no_difference "Decidim::Bih::AccountNotification.count" do
          perform_job(@opts.merge(event_revision: "old-revision"))
          perform_job(@opts.merge(dedupe_key: "not-the-event-key"))
          perform_job(@opts.except(:event_id))
        end
      end

      test "disabling the source switch still stops an enrolled job before any intent exists" do
        enroll!
        ENV["MI_CITY_SERVICE_VIBER_ALERTS_ENABLED"] = "0"

        assert_no_difference "Decidim::Bih::AccountNotification.count" do
          perform_job
        end
      end

      test "routing uses provider-ready candidates independently of unrelated community choices" do
        enroll!
        Decidim::Bih::NotificationPreferences.set!(@recipient, topic: :community_news, channel: :whatsapp, enabled: false)

        perform_job

        assert_equal ["viber"], payload_channels
      end

      test "dispatch_disabled retains platform delivery but refuses the external transport" do
        enroll!
        Decidim::Bih::Setting.put(@organization, Decidim::Bih::Messaging::Modes::NAMESPACE,
                                  "dispatch_disabled.#{MESSAGE_CLASS}", true)

        assert_difference "Decidim::Bih::AccountNotification.count", 1 do
          perform_job(@opts.merge(user_ids: [@silent.id]))
        end

        assert_equal ["viber"], payload_channels,
                     "authorization never adds email or another external channel"
        notification = Decidim::Bih::AccountNotification.last
        Decidim::Bih::Infobip::Client.stub(:new, @client) do
          Decidim::Bih::VerifiedPhone.stub(:delivery_phone_for, "+12025550101") do
            Decidim::Bih::AccountNotifications.dispatch!(notification)
          end
        end
        assert_empty @client.calls
        assert_equal "skipped", notification.reload.status
        assert_equal "dispatch_disabled", notification.reason
        assert Decidim::Bih::PlatformDelivery.find_by!(user: @silent, identity: CityServiceIncidentIdentity.delivery_identity(@event)).inbox_created_at
      end
    end
  end
end
