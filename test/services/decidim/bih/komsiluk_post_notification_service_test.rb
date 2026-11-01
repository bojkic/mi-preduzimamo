# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    class KomsilukPostNotificationServiceTest < ActiveSupport::TestCase
      include ActiveJob::TestHelper

      setup do
        @organization = create_organization
        @mz = LocalArea.create!(organization: @organization, kind: "mz", slug: "mz-notif", name: { sr: "Test MZ" })
        @komsiluk = LocalArea.create!(organization: @organization, kind: "komsiluk", slug: "komsiluk-notif", name: { sr: "Test Komšiluk" }, parent: @mz)
        @author = FactoryBot.create(:user, :confirmed, organization: @organization)
        @neighbor = FactoryBot.create(:user, :confirmed, organization: @organization)
        [@author, @neighbor].each do |user|
          CitizenProfile.for_user(user, organization: @organization).assign_komsiluk!(@komsiluk, source: "dropdown")
        end
      end

      KomsilukPost::CATEGORIES.each do |category|
        test "new #{category} publication captures the neighbor and enqueues only its durable receipt" do
          post = build_post(category:)
          assert_enqueued_with(job: KomsilukNoticeDeliveryJob) { publish(post) }
          receipt = PlatformDelivery.find_by!(komsiluk_post: post, user: @neighbor)
          assert_equal [@neighbor.id], PlatformDelivery.where(identity: receipt.identity).pluck(:decidim_user_id)
          assert_enqueued_with(job: KomsilukNoticeDeliveryJob, args: [receipt.id])
          assert_no_enqueued_jobs(only: KomsilukPostNotificationJob)
        end
      end

      test "legacy urgent category controls remain readable but do not suppress new board delivery" do
        policy = Komsiluk::UrgentNotificationPolicy.new(@organization)
        assert_equal %w(lost_pet safety), Komsiluk::UrgentNotificationPolicy.categories_for(@organization)
        [["safety"], []].each do |categories|
          policy.save_categories(categories)
          assert_equal categories, Komsiluk::UrgentNotificationPolicy.categories_for(@organization)
          %w(lost_pet safety).each do |category|
            post = build_post(category:)
            assert_enqueued_with(job: KomsilukNoticeDeliveryJob) { publish(post) }
            assert PlatformDelivery.exists?(komsiluk_post: post, user: @neighbor)
          end
        end
      end

      test "legacy urgent settings remain organization scoped" do
        other_organization = create_organization
        Komsiluk::UrgentNotificationPolicy.new(other_organization).save_categories([])
        assert_equal %w(lost_pet safety), Komsiluk::UrgentNotificationPolicy.categories_for(@organization)
        assert_equal [], Komsiluk::UrgentNotificationPolicy.categories_for(other_organization)
      end

      test "author is excluded from the captured audience" do
        post = build_post(category: "safety")
        publish(post)
        ids = PlatformDelivery.where(komsiluk_post: post).pluck(:decidim_user_id)
        assert_not_includes ids, @author.id
        assert_includes ids, @neighbor.id
      end

      test "legacy board and urgent-bell opt-outs cannot hide the inbox while the topic suppresses push" do
        @neighbor.update!(notification_settings: { "komsiluk_board" => false, "mi_komsiluk_urgent_bell" => false })
        TopicPreferences.set!(@neighbor, topic: :neighborhood_info, enabled: false)
        post = build_post(category: "safety")
        publish(post)
        receipt = PlatformDelivery.find_by!(komsiluk_post: post, user: @neighbor)
        assert_difference -> { @neighbor.notifications.count }, 1 do
          KomsilukNoticeDeliveryJob.perform_now(receipt.id)
        end
        assert receipt.reload.inbox_created_at
        assert_nil receipt.push_queued_at
      end

      test "the return value is the publication identity without a recipient list" do
        post = build_post(category: "general")
        result = publish(post)
        assert_equal post.reload.notification_capture_identity, result
        assert_kind_of String, result
      end

      test "uncaptured historical notices never resolve a new audience" do
        post = build_post(category: "safety", origin: "legacy")
        assert_no_difference "PlatformDelivery.count" do
          assert_no_enqueued_jobs(only: KomsilukNoticeDeliveryJob) { assert_nil publish(post) }
        end
        assert_nil post.reload.notification_capture_identity
      end

      test "repeat publication calls never add a later member or enqueue duplicate work" do
        post = build_post(category: "general")
        assert_enqueued_jobs 1, only: KomsilukNoticeDeliveryJob do
          publish(post)
          newcomer = FactoryBot.create(:user, :confirmed, organization: @organization)
          CitizenProfile.for_user(newcomer, organization: @organization).assign_komsiluk!(@komsiluk, source: "dropdown")
          publish(post.reload)
          assert_not PlatformDelivery.exists?(komsiluk_post: post, user: newcomer)
        end
      end

      test "an empty publication captures its identity and stays empty after a later join" do
        empty_board = LocalArea.create!(organization: @organization, kind: "komsiluk", slug: "komsiluk-empty", name: { sr: "Empty" })
        post = build_post(category: "general", komsiluk: empty_board)
        assert_no_enqueued_jobs(only: KomsilukNoticeDeliveryJob) do
          publish(post)
          CitizenProfile.for_user(@neighbor, organization: @organization).assign_komsiluk!(empty_board, source: "dropdown")
          publish(post.reload)
        end
        assert post.reload.notification_capture_identity
        assert_empty PlatformDelivery.where(komsiluk_post: post)
      end

      private

      def build_post(category:, origin: "citizen", komsiluk: @komsiluk)
        KomsilukPost.create!(organization: @organization, author: @author, komsiluk:, origin:,
                             publication_key: SecureRandom.uuid, published_at: Time.current, category:,
                             title: "Test #{category}", body: "Test body", expires_at: 1.day.from_now)
      end

      def publish(post)
        KomsilukPostNotificationService.call(post:, board_url: "https://example.test/biceriseno/komsiluk-board")
      end
    end
  end
end
