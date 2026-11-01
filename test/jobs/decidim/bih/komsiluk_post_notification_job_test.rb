# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    class KomsilukPostNotificationJobTest < ActiveJob::TestCase
      setup do
        @organization = create_organization
        @recipient = FactoryBot.create(:user, :confirmed, organization: @organization)
        @opted_out = FactoryBot.create(:user, :confirmed, organization: @organization)
        @board = LocalArea.create!(organization: @organization, kind: "komsiluk", slug: "komsiluk-compatibility", name: { sr: "Tabla" })
        @other = LocalArea.create!(organization: @organization, kind: "komsiluk", slug: "komsiluk-elsewhere", name: { sr: "Druga tabla" })
        [@recipient, @opted_out].each { |user| assign(user, @board) }
        TopicPreferences.set!(@opted_out, topic: :neighborhood_info, enabled: false)
      end

      test "captured posts of every category replay one inbox per original member without recapture" do
        KomsilukPost::CATEGORIES.each do |category|
          post = capture(category:)
          assert_no_difference "PlatformDelivery.count" do
            assert_difference "Decidim::Notification.count", 2 do
              WebPush.stub(:enqueue, false) do
                2.times { KomsilukPostNotificationJob.perform_now(post_id: post.id) }
              end
            end
          end
          assert_equal 2, PlatformDelivery.where(komsiluk_post: post).where.not(inbox_created_at: nil).count
        end
      end

      test "completed receipt replay does not enqueue another device fanout" do
        post = capture
        push_calls = []
        WebPush.stub(:enqueue, lambda { |user, **|
          push_calls << user.id
          false
        }) do
          2.times { KomsilukPostNotificationJob.perform_now(post_id: post.id) }
        end
        assert_equal [@recipient.id, @opted_out.id].sort, push_calls.sort
      end

      test "post retries ignore late joiners and stale queue URLs" do
        post = capture
        later = FactoryBot.create(:user, :confirmed, organization: @organization)
        assign(later, @board)
        WebPush.stub(:enqueue, false) do
          KomsilukPostNotificationJob.perform_now(post_id: post.id, board_url: "https://untrusted.example/old")
        end
        assert_empty later.notifications
        assert_not PlatformDelivery.exists?(komsiluk_post: post, user: later)
        expected = "https://#{@organization.host}#{Decidim::Bih.normalized_public_mount_path}/komsiluk-board/objava/#{post.publication_key}"
        assert_equal expected, Komsiluk::NoticePublishing.board_url(post)
        assert_equal expected, @recipient.notifications.sole.extra["board_url"]
      end

      test "a captured empty audience remains empty when old metadata jobs retry" do
        [@recipient, @opted_out].each { |user| assign(user, @other) }
        post = capture
        assert post.notification_capture_identity.present?
        assign(@recipient, @board)
        assert_no_difference ["PlatformDelivery.count", "Decidim::Notification.count"] do
          KomsilukPostNotificationJob.perform_now(post_id: post.id)
        end
      end

      test "cancelled moved hidden expired and mismatched identities cannot bypass the current dispatcher" do
        post = capture
        PlatformDelivery.find_by!(komsiluk_post: post, user: @opted_out).update!(cancelled_at: Time.current)
        assign(@recipient, @other)
        assert_no_difference "Decidim::Notification.count" do
          KomsilukPostNotificationJob.perform_now(post_id: post.id)
        end
        assign(@recipient, @board)
        hidden = capture
        hidden.update!(status: "hidden")
        expired = capture
        expired.update!(expires_at: 1.minute.ago)
        current = capture
        assert_no_difference "Decidim::Notification.count" do
          KomsilukPostNotificationJob.perform_now(post_id: hidden.id)
          KomsilukPostNotificationJob.perform_now(post_id: expired.id)
          KomsilukPostNotificationJob.perform_now(post_id: current.id, delivery_identity: "old-other-identity")
        end
      end

      test "legacy chunk IDs restrict existing post-bound receipts and never create an audience" do
        post = capture
        later = FactoryBot.create(:user, :confirmed, organization: @organization)
        assign(later, @board)
        opts = { organization_id: @organization.id, user_ids: [@recipient.id, later.id], category: "safety",
                 delivery_identity: post.notification_capture_identity, board_url: "/old-unmounted-board" }
        assert_no_difference "PlatformDelivery.count" do
          assert_difference "Decidim::Notification.count", 1 do
            WebPush.stub(:enqueue, false) { 2.times { KomsilukPostNotificationJob.perform_now(opts) } }
          end
        end
        assert_empty @opted_out.notifications
        assert_empty later.notifications
      end

      test "metadata-less legacy work is retired while existing provider receipts remain" do
        old_receipt = PlatformDelivery.for!(user: @recipient, identity: "old-unbound", expires_at: 1.hour.from_now)
        old_post = KomsilukPost.create!(organization: @organization, komsiluk: @board, title: "Stara objava", body: "Tekst", category: "safety")
        assert_no_difference ["PlatformDelivery.count", "Decidim::Notification.count"] do
          KomsilukPostNotificationJob.perform_now(organization_id: @organization.id, user_ids: [@recipient.id], category: "safety")
          KomsilukPostNotificationJob.perform_now(organization_id: @organization.id, user_ids: [@recipient.id], delivery_identity: "old-unbound")
          KomsilukPostNotificationJob.perform_now(post_id: old_post.id)
        end
        assert PlatformDelivery.exists?(old_receipt.id)
      end

      private

      def assign(user, area)
        CitizenProfile.for_user(user, organization: @organization).assign_komsiluk!(area, source: "map")
      end

      def capture(category: "general")
        KomsilukPost.create!(organization: @organization, komsiluk: @board, origin: "staff", publication_key: SecureRandom.uuid,
                             published_at: Time.current, content_revision: 1, title: "Nova objava", body: "Tekst", category:, expires_at: 1.day.from_now).tap do |post|
          Komsiluk::NoticePublishing.publish!(post:)
        end
      end
    end
  end
end
