# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    class KomsilukDeliveryOperationsTest < ActiveSupport::TestCase
      setup do
        @organization = create_organization
        @member = FactoryBot.create(:user, :confirmed, organization: @organization)
        @actor = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
        @area = LocalArea.create!(organization: @organization, kind: "komsiluk", slug: "komsiluk-ops", name: { sr: "Tabla" })
        @post = notice
        @at = Time.current
        @receipt = receipt(@post)
      end

      test "work list and counts respect the supplied board scope and contain no recipient identifiers" do
        @receipt.update!(created_at: 20.minutes.ago)
        outside = notice(title: "Outside scope")
        receipt(outside).update!(created_at: 20.minutes.ago)
        result = operations(scope: KomsilukPost.where(id: @post.id))
        assert_equal 1, result.total
        assert_equal 1, result.counts.fetch("inbox_stalled")
        assert_equal [@post.id], (result.entries.map { |entry| entry.post.id })
        assert_equal({ "inbox_stalled" => 1 }, result.entries.sole.issues)
      end

      test "push device failure and uncertainty are distinct from queued receipts and acceptance" do
        intent = WebPush.fanout_intent(@member, "notifications", deduplication_key: @receipt.identity)
        @receipt.update!(push_intent_id: intent.id, inbox_created_at: 20.minutes.ago,
                         push_queued_at: 20.minutes.ago, notification_dispatched_at: 20.minutes.ago)
        %w(failed uncertain accepted).each do |status|
          intent.attempts.create!(channel: "push", channel_group: "push", status:, destination_version: "fixture-#{status}")
        end
        result = operations
        assert_equal 1, result.counts.fetch("push_failed")
        assert_equal 1, result.counts.fetch("push_uncertain")
        assert_equal 0, result.counts.fetch("push_stalled")
        assert_equal 0, result.counts.fetch("inbox_stalled")
        @receipt.update!(cancelled_at: Time.current)
        assert_equal 0, operations.total
      end

      test "queued push without a device claim is visible after the waiting threshold" do
        intent = WebPush.fanout_intent(@member, "notifications", deduplication_key: @receipt.identity)
        @receipt.update!(push_intent_id: intent.id, inbox_created_at: 20.minutes.ago,
                         push_queued_at: 20.minutes.ago, notification_dispatched_at: 20.minutes.ago)
        assert_equal 1, operations.counts.fetch("push_stalled")
      end

      test "expired board closure and phone outcomes remain separate" do
        @post.update!(expires_at: 1.minute.ago)
        request = phone(status: "unknown")
        counts = operations.counts
        assert_equal 1, counts.fetch("expiry_backlog")
        assert_equal 1, counts.fetch("phone_unknown")
        assert_equal 0, counts.fetch("phone_failed")
        request.update!(status: "pending", expires_at: 1.minute.ago)
        assert_equal 1, operations.counts.fetch("phone_expired")
        request.update!(status: "delivered")
        assert_equal 0, operations.counts.fetch("phone_expired")
      end

      private

      def operations(scope: KomsilukPost.all)
        Komsiluk::DeliveryOperations.new(organization: @organization, actor: @member, scope:, at: @at)
      end

      def notice(**attributes)
        KomsilukPost.create!({ organization: @organization, komsiluk: @area, origin: "staff", publication_key: SecureRandom.uuid,
                               title: "Operativna objava", body: "Sadržaj", category: "general", expires_at: 1.day.from_now }.merge(attributes))
      end

      def receipt(post)
        PlatformDelivery.for!(user: @member, identity: "fixture:#{post.publication_key}", expires_at: 1.day.from_now).tap do |item|
          item.update!(komsiluk_post: post, publication_revision: 1)
        end
      end

      def phone(status:)
        intent = KomsilukSendIntent.create!(organization: @organization, actor: @actor, publication_key: @post.publication_key,
                                            kind: "phone", state: "confirmed", preview_digest: "fixture", payload: {}, expires_at: 1.hour.from_now)
        KomsilukPhoneDelivery.create!(organization: @organization, user: @member, platform_delivery: @receipt, send_intent: intent,
                                      status:, destination_digest: "f" * 64, due_at: Time.current, expires_at: 1.hour.from_now)
      end
    end
  end
end
