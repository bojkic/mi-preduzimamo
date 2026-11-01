# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/synthetic_event_source_registry"
require "securerandom"

module DecidimApp
  module Bijeljina
    class CityServiceNoticePublisherTest < ActiveSupport::TestCase
      include SyntheticEventSourceRegistry
      setup do
        @organization = create_organization
        @starts_at = 2.hours.from_now.change(usec: 0)
        @ends_at = 4.hours.from_now.change(usec: 0)
        @mz = Decidim::Bih::LocalArea.create!(
          organization: @organization,
          kind: "mz",
          slug: "mz-synthetic-field",
          name: { "sr" => "Izmišljeno polje" }
        )
        @komsiluk = Decidim::Bih::LocalArea.create!(
          organization: @organization,
          kind: "komsiluk",
          slug: "komsiluk-synthetic-field",
          name: { "sr" => "Izmišljeno polje 1" },
          parent: @mz,
          primary_mz_slug: "mz-synthetic-field",
          overlapping_mz_slugs: ["mz-synthetic-field"]
        )
        @other_komsiluk = Decidim::Bih::LocalArea.create!(
          organization: @organization,
          kind: "komsiluk",
          slug: "komsiluk-synthetic-garden",
          name: { "sr" => "Centar" },
          primary_mz_slug: "mz-synthetic-garden",
          overlapping_mz_slugs: ["mz-synthetic-garden"]
        )

        @recipient = FactoryBot.create(:user, :confirmed, organization: @organization)
        @opted_out = FactoryBot.create(:user, :confirmed, organization: @organization)
        @outside = FactoryBot.create(:user, :confirmed, organization: @organization)

        Decidim::Bih::CitizenProfile.for_user(@recipient, organization: @organization).assign_komsiluk!(
          @komsiluk,
          source: "dropdown",
          resolved_mz: @mz
        )
        Decidim::Bih::CitizenProfile.for_user(@opted_out, organization: @organization).assign_komsiluk!(
          @komsiluk,
          source: "dropdown",
          resolved_mz: @mz
        )
        Decidim::Bih::CitizenProfile.for_user(@outside, organization: @organization).assign_komsiluk!(
          @other_komsiluk,
          source: "dropdown"
        )

        Decidim::Bih::TopicPreferences.set!(@opted_out, topic: "neighborhood_info", enabled: false)
        create_linkage(@recipient, "viber-recipient")
        create_linkage(@opted_out, "viber-opted-out")
        create_linkage(@outside, "viber-outside")
      end

      test "posts a targeted planned outage and queues proactive delivery for topic-enabled MZ members" do
        publisher = CityServiceNoticePublisher.new(
          organization: @organization,
          classifier: FakeClassifier.new(planned_outage_result(targeting_level: "mz", target_area_slugs: ["mz-synthetic-field"])),
          board_url: "https://example.test/biceriseno/komsiluk-board",
          delivery_options: { event_id: 123, event_revision: "publication-v1" },
          operator_approved: true
        )
        payloads = []

        with_env("MI_CITY_SERVICE_VIBER_ALERTS_ENABLED" => "1") do
          CityServiceAlertNotificationJob.stub(:perform_later, ->(opts = {}) { payloads << opts }) do
            assert_difference("Decidim::Bih::KomsilukPost.count", 1) do
              @result = publisher.call(notice: notice)
            end
          end
        end

        post = Decidim::Bih::KomsilukPost.order(:created_at).last
        assert_nil post.author
        assert_equal @komsiluk, post.komsiluk
        assert_equal "safety", post.category
        assert_includes post.title, "Planirano iskljucenje"
        assert_equal @starts_at.iso8601, post.details.dig("source", "starts_at")
        assert_equal @ends_at.iso8601, post.details.dig("source", "ends_at")

        assert_equal :published, @result.status
        assert_equal ["mz-synthetic-field"], @result.target_area_slugs
        assert_equal ["komsiluk-synthetic-field"], @result.target_komsiluk_slugs
        assert_equal "viber_alert", @result.policy_decision.fetch(:delivery)
        assert_equal 1, @result.viber_recipients_count
        assert_equal 1, @result.viber_jobs_count

        user_ids = payloads.flat_map { |payload| Array(payload[:user_ids]) }
        assert_equal [@recipient.id], user_ids
        assert_equal "mi_city_service_alerts_viber", @result.policy_decision.fetch(:opt_out_key)
        assert_equal "komsiluk_board", @result.policy_decision.fetch(:legacy_opt_out_key)
      end

      test "canonical neighborhood opt-out remains authoritative despite stale legacy keys" do
        @opted_out.update!(notification_settings: { "komsiluk_board" => false })
        publisher = CityServiceNoticePublisher.new(
          organization: @organization,
          classifier: FakeClassifier.new(planned_outage_result(targeting_level: "mz", target_area_slugs: ["mz-synthetic-field"])),
          board_url: "https://example.test/biceriseno/komsiluk-board",
          delivery_options: { event_id: 123, event_revision: "publication-v1" },
          operator_approved: true
        )
        payloads = []

        with_env("MI_CITY_SERVICE_VIBER_ALERTS_ENABLED" => "1") do
          CityServiceAlertNotificationJob.stub(:perform_later, ->(opts = {}) { payloads << opts }) do
            @result = publisher.call(notice: notice)
          end
        end

        user_ids = payloads.flat_map { |payload| Array(payload[:user_ids]) }
        assert_equal [@recipient.id], user_ids
      end

      test "default publisher does not enqueue Viber without operator approval even when switch is enabled" do
        publisher = CityServiceNoticePublisher.new(
          organization: @organization,
          classifier: FakeClassifier.new(planned_outage_result(targeting_level: "mz", target_area_slugs: ["mz-synthetic-field"])),
          board_url: "https://example.test/biceriseno/komsiluk-board"
        )
        payloads = []

        with_env("MI_CITY_SERVICE_VIBER_ALERTS_ENABLED" => "1") do
          CityServiceAlertNotificationJob.stub(:perform_later, ->(opts = {}) { payloads << opts }) do
            @result = publisher.call(notice: notice)
          end
        end

        assert_equal :published, @result.status
        assert_equal "operator_review", @result.policy_decision.fetch(:delivery)
        assert_equal "operator_review_required", @result.policy_decision.fetch(:reason)
        assert_equal 0, @result.viber_recipients_count
        assert_equal [], payloads
      end

      test "posts board notice but does not enqueue Viber while alert switch is disabled" do
        publisher = CityServiceNoticePublisher.new(
          organization: @organization,
          classifier: FakeClassifier.new(planned_outage_result(targeting_level: "komsiluk", target_area_slugs: ["komsiluk-synthetic-field"])),
          board_url: "https://example.test/biceriseno/komsiluk-board",
          operator_approved: true
        )
        payloads = []

        with_env("MI_CITY_SERVICE_VIBER_ALERTS_ENABLED" => nil) do
          CityServiceAlertNotificationJob.stub(:perform_later, ->(opts = {}) { payloads << opts }) do
            assert_difference("Decidim::Bih::KomsilukPost.count", 1) do
              @result = publisher.call(notice: notice)
            end
          end
        end

        assert_equal :published, @result.status
        assert_equal "dry_run", @result.policy_decision.fetch(:delivery)
        assert_equal 0, @result.viber_recipients_count
        assert_equal [], payloads
      end

      test "suppresses Viber when the alert dedupe key was already delivered" do
        decision = CityServiceAlertPolicy.evaluate(
          source_key: "electricity_outages",
          event_type: "planned_outage",
          severity: "service_outage",
          target_area_slugs: ["mz-synthetic-field"],
          fingerprint: "synthetic-outage-v1",
          operator_approved: true
        )
        create_delivered_event(viber_dedupe_key: decision.fetch(:dedupe_key))
        publisher = CityServiceNoticePublisher.new(
          organization: @organization,
          classifier: FakeClassifier.new(planned_outage_result(targeting_level: "mz", target_area_slugs: ["mz-synthetic-field"])),
          board_url: "https://example.test/biceriseno/komsiluk-board",
          operator_approved: true
        )
        payloads = []

        with_env("MI_CITY_SERVICE_VIBER_ALERTS_ENABLED" => "1") do
          CityServiceAlertNotificationJob.stub(:perform_later, ->(opts = {}) { payloads << opts }) do
            @result = publisher.call(notice: notice)
          end
        end

        assert_equal :published, @result.status
        assert_equal "suppressed", @result.policy_decision.fetch(:delivery)
        assert_equal "duplicate_suppressed", @result.policy_decision.fetch(:reason)
        assert_equal 0, @result.viber_jobs_count
        assert_equal [], payloads
      end

      test "does not post when classifier cannot map a target" do
        publisher = CityServiceNoticePublisher.new(
          organization: @organization,
          classifier: FakeClassifier.new(planned_outage_result(targeting_level: "unknown", target_area_slugs: []))
        )

        assert_no_difference("Decidim::Bih::KomsilukPost.count") do
          result = publisher.call(notice: notice)
          assert_equal :no_target, result.status
        end
      end

      private

      def notice
        {
          source_key: "electricity_outages",
          title: "Planirana iskljucenja",
          body: "Izmišljeno polje 09-12",
          url: "https://example.test/outages",
          fingerprint: "synthetic-outage-v1"
        }
      end

      def planned_outage_result(targeting_level:, target_area_slugs:)
        CityServiceNoticeClassifier::Result.new(
          source_key: "electricity_outages",
          publish: true,
          event_type: "planned_outage",
          severity: "service_outage",
          targeting_level:,
          target_area_slugs:,
          title: "Planirano iskljucenje struje",
          body: "Izmišljeno polje ce biti bez struje od 09:00 do 12:00.",
          viber_text: "Izmišljeno polje: planirano iskljucenje struje od 09:00 do 12:00.",
          delivery_recommendation: "viber_alert",
          confidence: 0.95,
          starts_at: @starts_at.iso8601,
          ends_at: @ends_at.iso8601,
          fingerprint: "synthetic-outage-v1",
          needs_review: false,
          reasons: ["planned outage"]
        )
      end

      def create_linkage(user, sender)
        Decidim::Bih::Viber::Linkage.create!(
          organization: @organization,
          user:,
          viber_sender: sender,
          verified_at: Time.current
        )
      end

      def create_delivered_event(viber_dedupe_key:)
        CityServiceEvent.create!(
          organization: @organization,
          source_key: "electricity_outages",
          source_label: "Izmišljeni pružalac planned outages",
          provider: "Izmišljeni pružalac",
          source_url: "https://example.test/outages",
          source_fingerprint: "delivered-#{SecureRandom.hex(4)}",
          parser_version: "test",
          event_type: "planned_outage",
          severity: "service_outage",
          targeting_level: "mz",
          affected_area_slugs: ["mz-synthetic-field"],
          title: "Ranije isključenje",
          summary: "Ranije poslano obavještenje.",
          state: "published",
          published_at: 10.minutes.ago,
          viber_delivery: "viber_alert",
          viber_dedupe_key:
        )
      end

      def with_env(values)
        previous = values.keys.index_with { |key| ENV.fetch(key, nil) }
        values.each do |key, value|
          value.nil? ? ENV.delete(key) : ENV[key] = value
        end
        yield
      ensure
        previous.each do |key, value|
          value.nil? ? ENV.delete(key) : ENV[key] = value
        end
      end

      class FakeClassifier
        def initialize(result)
          @result = result
        end

        def call(source_key:, title:, body:, url:, known_areas:)
          raise "wrong source" unless source_key == "electricity_outages"
          raise "missing title" if title.blank?
          raise "missing body" if body.blank?
          raise "missing url" if url.blank?
          raise "missing known areas" unless known_areas.any? { |row| row[:slug] == "komsiluk-synthetic-field" }

          @result
        end
      end
    end
  end
end
