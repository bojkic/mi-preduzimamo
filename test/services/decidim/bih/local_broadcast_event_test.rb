# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    # Tests for LocalBroadcastEvent — Wave B2 in-app bell notification.
    class LocalBroadcastEventTest < ActiveSupport::TestCase
      def build_event(message: "Sutra čišćenje parka!", area_name: "Centar", user: nil)
        organization = create_organization
        recipient = user || FactoryBot.create(:user, :confirmed, organization:)

        Decidim::Bih::LocalBroadcastEvent.new(
          resource: recipient,
          event_name: "decidim.events.bih.local_broadcast",
          user: recipient,
          extra: {
            "message" => message,
            "area_name" => area_name,
            "area_id" => 99,
            "organization_id" => organization.id
          }
        )
      end

      # ─── notification_title ──────────────────────────────────────────────────

      test "notification_title includes the message text" do
        event = build_event(message: "Hitna poruka za komšiluk")

        assert_includes event.notification_title, "Hitna poruka za komšiluk"
      end

      test "notification_title includes the area name" do
        event = build_event(area_name: "Komšiluk Centar")

        assert_includes event.notification_title, "Komšiluk Centar"
      end

      test "notification_title does NOT expose any other user identity" do
        organization = create_organization
        recipient = FactoryBot.create(:user, :confirmed, organization:, name: "Ana Kovač")
        other = FactoryBot.create(:user, :confirmed, organization:, name: "Marko Marković")

        event = Decidim::Bih::LocalBroadcastEvent.new(
          resource: recipient,
          event_name: "decidim.events.bih.local_broadcast",
          user: recipient,
          extra: {
            "message" => "Neka poruka",
            "area_name" => "Komšiluk A",
            "area_id" => 1,
            "organization_id" => organization.id
          }
        )

        title = event.notification_title
        assert_not_includes title, other.name
        assert_not_includes title, other.id.to_s
        assert_not_includes title, other.email
      end

      test "notification_title strips HTML tags from the operator message" do
        event = build_event(message: "<script>alert(1)</script>Čišćenje")

        title = event.notification_title
        assert_not_includes title, "<script>"
        assert_includes title, "Čišćenje"
      end

      # ─── No link ────────────────────────────────────────────────────────────

      test "resource_path returns nil (in-app bell only, no deep link)" do
        assert_nil build_event.resource_path
      end

      test "resource_url returns nil" do
        assert_nil build_event.resource_url
      end

      test "resource_title returns nil" do
        assert_nil build_event.resource_title
      end
    end
  end
end
