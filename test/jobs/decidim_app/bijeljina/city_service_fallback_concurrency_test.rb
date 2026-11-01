# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/synthetic_event_source_registry"
require "timeout"

module DecidimApp
  module Bijeljina
    # Committed fixtures and independent PostgreSQL sessions are essential:
    # a transaction-wrapped test cannot demonstrate a competing worker claim.
    class CityServiceFallbackConcurrencyTest < ActiveJob::TestCase
      include SyntheticEventSourceRegistry
      self.use_transactional_tests = false

      class FakeProvider
        attr_reader :calls

        def initialize = @calls = []

        def configured? = false

        def viber_business_configured? = true

        def chat_channel_configured?(_channel) = false

        def send_phone_message(**args)
          @calls << args
          { "messages" => [{ "messageId" => "fake-concurrency-only" }] }
        end
      end

      setup do
        @threads = []
        @previous_switch = ENV.fetch("MI_CITY_SERVICE_VIBER_ALERTS_ENABLED", nil)
        ENV["MI_CITY_SERVICE_VIBER_ALERTS_ENABLED"] = "1"
        @organization = create_organization
        @user = create(:user, :confirmed, organization: @organization)
        @area = Decidim::Bih::LocalArea.create!(organization: @organization, kind: "komsiluk",
                                                slug: "komsiluk-concurrency", name: { "sr" => "Test" })
        Decidim::Bih::CitizenProfile.for_user(@user, organization: @organization).assign_komsiluk!(@area, source: "dropdown")
        Decidim::Bih::NotificationPreferences.set!(@user, topic: :city_service_alerts, channel: :viber, enabled: true)
        Decidim::Bih::Setting.put(@organization, "messaging", "mode.city.service_alert_viber", "target")
        @event = CityServiceEvent.create!(organization: @organization, source_key: "electricity_outages",
                                          source_url: CityServiceSources.fetch("electricity_outages").fetch(:source_url), source_fingerprint: SecureRandom.hex(8),
                                          parser_version: "test", event_type: "planned_outage", severity: "service_outage",
                                          title: "Concurrency fixture", summary: "Public fixture facts", targeting_level: "komsiluk",
                                          affected_area_slugs: [@area.slug], state: "published", lifecycle: "scheduled",
                                          starts_at: 1.hour.ago, ends_at: 1.hour.from_now,
                                          extraction_metadata: { publication_revision: "concurrency-revision" }, viber_dedupe_key: "concurrency-key")
        @incident = CityServiceIncidentIdentity.attach!(@event)
        @receipt = Decidim::Bih::PlatformDelivery.for!(user: @user,
                                                       identity: CityServiceIncidentIdentity.delivery_identity(@event), expires_at: @event.ends_at)
        @receipt.update!(deadline_at: 1.second.ago, fallback_requested_at: Time.current,
                         fallback_context: { event_id: @event.id, event_revision: @event.publication_revision, dedupe_key: @event.viber_dedupe_key })
      end

      teardown do
        @threads.each { |thread| thread.kill.join if thread.alive? }
        ENV["MI_CITY_SERVICE_VIBER_ALERTS_ENABLED"] = @previous_switch
        if @organization
          intents = Decidim::Bih::Messaging::Intent.where(organization: @organization)
          Decidim::Bih::Messaging::Attempt.where(intent: intents).delete_all
          intents.delete_all
          [Decidim::Bih::AccountNotification, Decidim::Bih::PlatformDelivery,
           Decidim::Bih::Messaging::PreferenceChange, Decidim::Bih::Messaging::Preference,
           Decidim::Bih::CitizenProfile, Decidim::Bih::Setting].each { |model| model.where(organization: @organization).delete_all }
          @event&.destroy!
          @incident&.destroy!
          @area&.destroy!
          @user&.destroy!
          Decidim::StaticPage.where(organization: @organization).delete_all
          @organization.destroy!
        end
      end

      test "two committed due workers create one intent and a competing ACK suppresses routed provider send" do
        ready = Queue.new
        gate = Queue.new
        2.times do
          @threads << Thread.new do
            ActiveRecord::Base.connection_pool.with_connection do |connection|
              ready << connection.select_value("SELECT pg_backend_pid()")
              gate.pop
              CityServiceFallbackJob.perform_now(@receipt.id)
            end
          end
        end
        backend_ids = Timeout.timeout(20) { 2.times.map { ready.pop } }
        assert_equal 2, backend_ids.uniq.length, "workers must use independent PostgreSQL sessions"
        2.times { gate << true }
        Timeout.timeout(20) { @threads.each(&:value) }
        notifications = Decidim::Bih::AccountNotification.where(organization: @organization, user: @user)
        assert_equal 1, notifications.count
        notification = notifications.sole
        assert_equal notification.id, @receipt.reload.account_notification_id
        assert_equal ["viber"], notification.payload["channels"]

        provider = FakeProvider.new
        at_guard = Queue.new
        original_guard = CityServiceDeliveryGuard.method(:call)
        guarded = lambda do |**args, &transport|
          at_guard << true
          original_guard.call(**args, &transport)
        end
        Decidim::Bih::Infobip::Client.stub(:new, provider) do
          Decidim::Bih::VerifiedPhone.stub(:delivery_phone_for, "+38765111001") do
            CityServiceDeliveryGuard.stub(:call, guarded) do
              @receipt.with_lock do
                @threads << Thread.new do
                  ActiveRecord::Base.connection_pool.with_connection do
                    Decidim::Bih::AccountNotifications.dispatch!(Decidim::Bih::AccountNotification.find(notification.id))
                  end
                end
                Timeout.timeout(20) { at_guard.pop }
                assert_equal "sending", notification.reload.status, "routed claim must be committed before the receipt guard"
                @receipt.acknowledge!("inbox_read")
              end
              Timeout.timeout(20) { @threads.last.value }
            end
          end
        end
        assert_empty provider.calls
        assert_equal "skipped", notification.reload.status
        assert_equal "platform_delivery_confirmed", notification.reason
        assert_equal 1, notifications.count
        puts "CONCURRENCY EVIDENCE: independent_sessions=#{backend_ids.uniq.length} workers=2 account_intents=#{notifications.count} " \
             "provider_calls=#{provider.calls.length} outcome=#{notification.reason}"
      end
    end
  end
end
