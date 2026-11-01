# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    class KomsilukNoticeDeliveryTest < ActiveJob::TestCase
      class ReviewedSourceFixture
        attr_accessor :source

        def initialize(source)
          @source = source
        end

        def call(**)
          source
        end

        def with_reviewed_source_lock(organization:, actor:, kind:, id:, revision:)
          return unless actor&.organization == organization

          reference = source&.dig(:details, :source_record)
          return unless reference && reference[:kind].to_s == kind.to_s && reference[:id].to_s == id.to_s && reference[:revision] == revision

          yield
        end
      end

      class ProviderFixture
        attr_accessor :error, :reports
        attr_reader :requests

        def initialize
          @requests = []
          @reports = []
        end

        def send_phone_message(**attributes)
          @requests << attributes
          raise error if error

          { "messages" => [{ "messageId" => "fixture-notice-1" }] }
        end

        def message_delivery_reports(**)
          { "results" => reports }
        end
      end

      setup do
        @organization = create_organization
        @actor = create(:user, :admin, :confirmed, organization: @organization)
        @author = create(:user, :confirmed, organization: @organization)
        @member = create(:user, :confirmed, organization: @organization)
        @board = LocalArea.create!(organization: @organization, kind: "komsiluk", slug: "komsiluk-delivery", name: { sr: "Tabla" })
        @other_board = LocalArea.create!(organization: @organization, kind: "komsiluk", slug: "komsiluk-other", name: { sr: "Druga tabla" })
        [@author, @member].each { |user| assign(user, @board) }
        @composer = Komsiluk::NoticeComposer.new(organization: @organization, actor: @actor)
        @provider = ProviderFixture.new
        @source_provider = Komsiluk::NoticeComposer.source_provider
        @source_guard = Komsiluk::NoticePhonePolicy.source_dispatch_guard
        @source_blocker = Komsiluk::NoticePhonePolicy.source_blocker
      end

      teardown do
        Komsiluk::NoticeComposer.source_provider = @source_provider
        Komsiluk::NoticePhonePolicy.source_dispatch_guard = @source_guard
        Komsiluk::NoticePhonePolicy.source_blocker = @source_blocker
      end

      test "each new category captures once and creates an inbox item despite topic opt out" do
        TopicPreferences.set!(@member, topic: :neighborhood_info, enabled: false)
        KomsilukPost::CATEGORIES.each do |category|
          post = publish(category:)
          receipt = receipt_for(post)
          assert_equal [@member.id], PlatformDelivery.where(identity: receipt.identity).pluck(:decidim_user_id)
          Komsiluk::NoticePublishing.publish!(post: post.reload)
          assert_equal 1, PlatformDelivery.where(identity: receipt.identity).count
          assert_difference -> { Decidim::Notification.where(user: @member).count }, 1 do
            2.times { KomsilukNoticeDeliveryJob.perform_now(receipt.id) }
          end
          assert receipt.reload.inbox_created_at
          assert_nil receipt.push_queued_at
          assert_equal receipt.id, Decidim::Notification.find(receipt.notification_id).extra["platform_delivery_id"]
          assert_includes Decidim::Notification.find(receipt.notification_id).extra["board_url"], post.publication_key
        end
      end

      test "later joins never replay a captured publication including empty audiences" do
        assign(@member, @other_board)
        post = publish
        assert post.reload.notification_capture_identity
        assert_empty PlatformDelivery.where(komsiluk_post: post)
        assign(@member, @board)
        Komsiluk::NoticePublishing.publish!(post:)
        Komsiluk::NoticePublishing.recover_pending!
        assert_empty PlatformDelivery.where(komsiluk_post: post)
      end

      test "current membership visibility and expiry stop undispatched inbox work" do
        post = publish
        receipt = receipt_for(post)
        assign(@member, @other_board)
        assert_no_difference -> { Decidim::Notification.where(user: @member).count } do
          KomsilukNoticeDeliveryJob.perform_now(receipt.id)
        end
        assert receipt.reload.cancelled_at
        assign(@member, @board)
        post2 = publish
        post2.update!(status: "hidden")
        KomsilukNoticeDeliveryJob.perform_now(receipt_for(post2).id)
        assert receipt_for(post2).reload.cancelled_at
        post3 = publish
        post3.update!(expires_at: 1.minute.ago)
        assert_not Komsiluk::NoticePublishing.current_receipt?(receipt_for(post3))
      end

      test "publication reloads visibility under lock before capturing an audience" do
        post = create_notice
        KomsilukPost.find(post.id).update!(status: "hidden")
        assert_equal "open", post.status

        assert_no_difference "PlatformDelivery.count" do
          assert_nil Komsiluk::NoticePublishing.publish!(post:)
        end
        assert_nil post.reload.notification_capture_identity
        post.update!(status: "open")
        Komsiluk::NoticePublishing.recover_pending!
        assert_empty PlatformDelivery.where(komsiluk_post: post)
      end

      test "a held source placement cannot dispatch even while its status remains open" do
        post = publish
        receipt = receipt_for(post)
        post.update!(details: { moderation: { source_hold: true } })

        assert_not Komsiluk::NoticePublishing.current_post?(post)
        assert_not Komsiluk::NoticePublishing.current_receipt?(receipt.reload)
        assert_no_difference -> { Decidim::Notification.where(user: @member).count } do
          KomsilukNoticeDeliveryJob.perform_now(receipt.id)
        end
        assert receipt.reload.cancelled_at
        assert_nil receipt.push_queued_at
      end

      test "material correction creates one generic update notification without exposing notice copy" do
        post = publish
        KomsilukNoticeDeliveryJob.perform_now(receipt_for(post).id)
        post.update!(title: "Privatni naslov ispravke", body: "Privatni tekst ispravke", content_revision: 2)
        Komsiluk::NoticePublishing.publish!(post:, context: { notice_update: true })
        receipt = PlatformDelivery.find_by!(user: @member, identity: post.reload.notification_capture_identity)

        assert_difference -> { Decidim::Notification.where(user: @member).count }, 1 do
          2.times { KomsilukNoticeDeliveryJob.perform_now(receipt.id) }
        end
        extra = Decidim::Notification.find(receipt.reload.notification_id).extra
        assert_equal true, extra["notice_update"]
        assert_equal 2, extra["publication_revision"]
        assert_not_includes extra.to_json, post.title
        assert_not_includes extra.to_json, post.body
        event = KomsilukPostEvent.new(resource: @member, event_name: "decidim.events.bih.komsiluk_post", user: @member, extra:)
        [:sr, :bs, :hr, :en, :"sr-Cyrl"].each do |locale|
          I18n.with_locale(locale) do
            category = I18n.t("decidim.bih.komsiluk_board.categories.#{post.category}")
            assert I18n.exists?("decidim.bih.komsiluk_post.events.updated_notification_title", locale)
            assert_equal I18n.t("decidim.bih.komsiluk_post.events.updated_notification_title", category:), event.notification_title
            assert_not_equal I18n.t("decidim.bih.komsiluk_post.events.notification_title", category:), event.notification_title
            assert_not_includes event.notification_title, post.title
            assert_not_includes event.notification_title, post.body
          end
        end
      end

      test "minor correction rebinds existing receipts without audience capture or replay" do
        post = publish
        receipt = receipt_for(post)
        joined = create(:user, :confirmed, organization: @organization)
        assign(joined, @board)
        post.update!(body: "Ispravljeno", content_revision: 2)
        assert_no_difference "PlatformDelivery.count" do
          Komsiluk::NoticePublishing.refresh_existing_revision!(post:, previous_revision: 1)
        end
        assert_equal 2, receipt.reload.publication_revision
        assert_equal "komsiluk:#{post.publication_key}:1", receipt.identity
        assert Komsiluk::NoticePublishing.current_receipt?(receipt)
        KomsilukNoticeDeliveryJob.perform_now(receipt.id)
        assert_nil PlatformDelivery.find_by(komsiluk_post: post, user: joined)
        extra = Decidim::Notification.find(receipt.reload.notification_id).extra
        assert_equal false, extra["notice_update"]
        assert_equal 2, extra["publication_revision"]
        # Rebound minor edits and historical payloads without the marker retain
        # their original new-notice wording despite a newer content revision.
        [extra, extra.except("notice_update")].each do |payload|
          event = KomsilukPostEvent.new(resource: @member, event_name: "decidim.events.bih.komsiluk_post", user: @member, extra: payload)
          category = I18n.t("decidim.bih.komsiluk_board.categories.#{post.category}")
          assert_equal I18n.t("decidim.bih.komsiluk_post.events.notification_title", category:), event.notification_title
        end
      end

      test "display and platform reading retain independent evidence" do
        receipt = receipt_for(publish)
        receipt.acknowledge!("browser_display")
        first = receipt.reload.browser_displayed_at
        travel 1.minute do
          receipt.acknowledge!("inbox_read")
          receipt.acknowledge!("browser_display")
        end
        assert_equal first, receipt.reload.browser_displayed_at
        assert receipt.inbox_read_at > first
        assert_equal "browser_display", receipt.acknowledgment_kind
      end

      test "same size audience replacement invalidates an operator publication preview" do
        preview = @composer.preview_publication(publication_attributes)
        replacement = create(:user, :confirmed, organization: @organization)
        assign(@member, @other_board)
        assign(replacement, @board)
        assert_no_difference "KomsilukPost.count" do
          error = assert_raises(Komsiluk::NoticeComposer::Refused) { @composer.confirm!(preview[:intent].confirmation_token) }
          assert_equal "preview_changed", error.message
        end
      end

      test "overlapping selections create linked posts and confirmation executes once" do
        mz = LocalArea.create!(organization: @organization, kind: "mz", slug: "mz-delivery", name: { sr: "MZ" })
        @board.update!(primary_mz_slug: mz.slug)
        @other_board.update!(overlapping_mz_slugs: [mz.slug])
        assign(@author, @other_board)
        preview = @composer.preview_publication(publication_attributes.merge(area_ids: [mz.id, @board.id]))
        assert_equal 2, preview[:summary][:total]
        assert_difference "KomsilukPost.count", 2 do
          2.times { @composer.confirm!(preview[:intent].confirmation_token) }
        end
        posts = KomsilukPost.where(publication_key: preview[:intent].publication_key)
        assert_equal [@board.id, @other_board.id].sort, posts.pluck(:komsiluk_id).sort
        assert_equal 2, PlatformDelivery.where(komsiluk_post_id: posts.select(:id)).count
        assert_empty KomsilukPhoneDelivery.all
      end

      test "one combined preview publishes its exact optional phone plan once" do
        with_phone do
          preview = @composer.preview_publication(publication_attributes.merge(phone_attributes))
          assert_equal 2, preview[:summary][:phone][:eligible]
          assert_equal({ "sms" => 2 }, preview[:summary][:phone][:channel_counts])
          assert_nil preview[:summary][:phone][:rows]
          assert_difference "KomsilukPost.count", 1 do
            assert_difference "KomsilukPhoneDelivery.count", 2 do
              2.times { @composer.confirm!(preview[:intent].confirmation_token) }
            end
          end
          deliveries = KomsilukPhoneDelivery.where(send_intent: preview[:intent])
          assert_equal ["sms"], deliveries.first.channels
          assert_empty KomsilukSmsBudget.where(organization: @organization)
          deliveries.each { |delivery| KomsilukPhoneDeliveryJob.perform_now(delivery.id) }
          assert_equal 2, @provider.requests.size
          assert(@provider.requests.all? { |request| request[:channels] == [:sms] })
        end
      end

      test "blocked optional phone plan cannot partially publish its board notice" do
        with_phone do
          preview = @composer.preview_publication(publication_attributes.merge(phone_attributes).merge(mode: "fallback"))
          assert_no_difference "KomsilukPost.count" do
            assert_no_difference "KomsilukPhoneDelivery.count" do
              assert_raises(Komsiluk::NoticeComposer::Refused) { @composer.confirm!(preview[:intent].confirmation_token) }
            end
          end
        end
      end

      test "source metadata is resolved server side and revoked source blocks publication" do
        source = { title: "Odobreno", body: "Javno", area_ids: [@board.id], details: { source_record: { kind: "report", id: 4, revision: "r1" } } }
        source_provider = ReviewedSourceFixture.new(source)
        Komsiluk::NoticeComposer.source_provider = source_provider
        preview = @composer.preview_publication(publication_attributes.merge(source_kind: "report", source_id: 4, details: { private: "injected" }))
        assert_equal source[:details], preview[:payload][:details]
        source_provider.source = nil
        assert_raises(Komsiluk::NoticeComposer::Refused) { @composer.confirm!(preview[:intent].confirmation_token) }
      end

      test "source revision revocation blocks pending linked delivery before projection refresh" do
        source = { title: "Odobreno", body: "Javno", area_ids: [@board.id], details: { source_record: { kind: "report", id: 4, revision: "r1" } } }
        source_provider = ReviewedSourceFixture.new(source)
        Komsiluk::NoticeComposer.source_provider = source_provider
        preview = @composer.preview_publication(publication_attributes.merge(source_kind: "report", source_id: 4))
        @composer.confirm!(preview[:intent].confirmation_token)
        post = KomsilukPost.find_by!(publication_key: preview[:intent].publication_key)
        receipt = PlatformDelivery.find_by!(komsiluk_post: post, user: @member)
        assert Komsiluk::NoticePublishing.current_receipt?(receipt)
        source[:details][:source_record][:revision] = "r2"
        assert_not Komsiluk::NoticePublishing.current_receipt?(receipt)
      end

      test "SMS cannot be authorized by an ordinary category or fallback mode" do
        post = publish(category: "safety")
        assert_empty KomsilukPhoneDelivery.all
        with_phone do
          preview = @composer.preview_phone(post:, attributes: phone_attributes.merge(mode: "fallback"))
          assert_includes preview[:summary][:blockers], "sms_requires_urgency"
          assert_raises(Komsiluk::NoticeComposer::Refused) { @composer.confirm!(preview[:intent].confirmation_token) }
        end
        assert_empty @provider.requests
      end

      test "exact SMS preview includes canonical link script segments and one committed request" do
        post = publish
        with_phone do
          preview = @composer.preview_phone(post:, attributes: phone_attributes)
          assert_equal ["sms"], preview[:payload][:channels]
          assert_includes preview[:payload][:sms_text], Komsiluk::NoticePublishing.board_url(post)
          assert_equal "Unicode", preview[:payload][:segment_estimate][:encoding]
          assert_equal 1, preview[:summary][:eligible]
          assert_not_includes preview[:intent].payload_ciphertext, "Hitno"
          2.times { @composer.confirm!(preview[:intent].confirmation_token) }
          delivery = KomsilukPhoneDelivery.find_by!(platform_delivery: receipt_for(post))
          assert_equal 0, delivery.reserved_minor
          assert_empty KomsilukSmsBudget.where(organization: @organization)
          2.times { KomsilukPhoneDeliveryJob.perform_now(delivery.id) }
          assert_equal 1, @provider.requests.size
          assert_equal [:sms], @provider.requests.first[:channels]
          assert_equal preview[:payload][:sms_text], @provider.requests.first[:text]
          assert_equal "accepted", delivery.reload.status
        end
      end

      test "unknown phone outcome never starts a second SMS request" do
        with_phone do
          delivery = confirm_phone(publish)
          @provider.error = Infobip::Error.new("fixture timeout")
          2.times { KomsilukPhoneDeliveryJob.perform_now(delivery.id) }
          assert_equal 1, @provider.requests.size
          assert_equal "unknown", delivery.reload.status
          assert_equal 0, delivery.reserved_minor
          assert_empty KomsilukSmsBudget.where(organization: @organization)
        end
      end

      test "changed phone topic expiry and minor content correction block pending requests" do
        with_phone do
          post = publish
          delivery = confirm_phone(post)
          post.update!(content_revision: 2, body: "Ispravka")
          Komsiluk::NoticePublishing.refresh_existing_revision!(post:, previous_revision: 1)
          KomsilukPhoneDeliveryJob.perform_now(delivery.id)
          assert_equal "publication_changed", delivery.reload.reason
          delivery2 = confirm_phone(publish)
          TopicPreferences.set!(@member, topic: :neighborhood_info, enabled: false)
          KomsilukPhoneDeliveryJob.perform_now(delivery2.id)
          assert_equal "skipped", delivery2.reload.status
        end
        assert_empty @provider.requests
      end

      test "acknowledgment cancels routine phone follow up and immediate SMS retains explicit policy" do
        with_phone do
          post = publish
          preview = @composer.preview_phone(post:, attributes: phone_attributes.merge(mode: "urgent_fallback"))
          @composer.confirm!(preview[:intent].confirmation_token)
          receipt = receipt_for(post)
          delivery = KomsilukPhoneDelivery.find_by!(platform_delivery: receipt)
          receipt.acknowledge!("inbox_read")
          travel_to delivery.due_at + 1.second do
            KomsilukPhoneDeliveryJob.perform_now(delivery.id)
          end
          assert_equal "platform_acknowledged", delivery.reload.reason
          assert_empty @provider.requests
        end
      end

      test "turning SMS off after confirmation blocks provider handoff" do
        with_phone do
          delivery = confirm_phone(publish)
          Setting.put(@organization, Komsiluk::NoticePhonePolicy::NAMESPACE, :sms_enabled, false)
          KomsilukPhoneDeliveryJob.perform_now(delivery.id)
          assert_equal "skipped", delivery.reload.status
          assert_equal "sms_policy_required", delivery.reason
          assert_empty @provider.requests
        end
      end

      test "template change invalidates preview and no unselected transport is added" do
        with_phone do
          post = publish
          template = { name: "fixture_approved", language: "sr", body: { "1" => "tekst" }, display_text: "Odobrena poruka" }
          Komsiluk::NoticePhonePolicy.stub(:template, template) do
            preview = @composer.preview_phone(post:, attributes: phone_attributes.merge(channels: ["whatsapp"], mode: "fallback"))
            assert_equal({ "whatsapp" => 1 }, preview[:summary][:channel_counts])
            template[:name] = "changed"
            assert_raises(Komsiluk::NoticeComposer::Refused) { @composer.confirm!(preview[:intent].confirmation_token) }
          end
        end
        assert_empty @provider.requests
      end

      test "definitively rejected request can be deliberately previewed again but unknown cannot" do
        with_phone do
          post = publish
          delivery = confirm_phone(post)
          @provider.error = Infobip::Error.new("fixture refused", http_status: 403)
          KomsilukPhoneDeliveryJob.perform_now(delivery.id)
          assert_equal "rejected", delivery.reload.status
          preview = @composer.preview_phone(post:, attributes: phone_attributes.merge(retry_failed: true))
          @composer.confirm!(preview[:intent].confirmation_token)
          assert_equal "rejected", delivery.reload.previous_attempts.first["status"]
          @provider.error = Infobip::Error.new("fixture ambiguous")
          KomsilukPhoneDeliveryJob.perform_now(delivery.id)
          retry_preview = @composer.preview_phone(post:, attributes: phone_attributes.merge(retry_failed: true))
          assert_equal 0, retry_preview[:summary][:eligible]
        end
      end

      test "matching provider receipts are required and a late report cannot downgrade delivery" do
        with_phone do
          delivery = confirm_phone(publish)
          KomsilukPhoneDeliveryJob.perform_now(delivery.id)
          @provider.reports = [{ "messageId" => "unrelated", "status" => { "name" => "DELIVERED_TO_HANDSET" } }]
          KomsilukPhoneReconciliationJob.perform_now(delivery.id)
          assert_equal "accepted", delivery.reload.status
          @provider.reports = [{ "messageId" => "fixture-notice-1", "status" => { "name" => "DELIVERED_TO_HANDSET" } }]
          KomsilukPhoneReconciliationJob.perform_now(delivery.id)
          assert_equal "delivered", delivery.reload.status
          @provider.reports = [{ "messageId" => "fixture-notice-1", "status" => { "groupName" => "REJECTED" } }]
          KomsilukPhoneReconciliationJob.perform_now(delivery.id)
          assert_equal "delivered", delivery.reload.status
        end
      end

      test "an expired phone claim commits its terminal skip once" do
        with_phone do
          delivery = confirm_phone(publish)
          travel_to(delivery.expires_at + 1.second) do
            2.times { KomsilukPhoneDeliveryJob.perform_now(delivery.id) }
          end
          assert_equal "skipped", delivery.reload.status
          assert_equal "expired", delivery.reason
          assert_empty KomsilukSmsBudget.where(organization: @organization)
          assert_empty @provider.requests
        end
      end

      test "withdrawal cancels queued phone work before provider handoff" do
        with_phone do
          post = publish
          delivery = confirm_phone(post)
          post.with_lock { Komsiluk::NoticePublishing.cancel_pending_for!(post:, reason: "source_changed") }
          KomsilukPhoneDeliveryJob.perform_now(delivery.id)
          assert_equal "skipped", delivery.reload.status
          assert_empty KomsilukSmsBudget.where(organization: @organization)
          assert receipt_for(post).cancelled_at
        end
        assert_empty @provider.requests
      end

      test "retention scrubs old private copy but preserves unresolved provider evidence" do
        with_phone do
          post = publish
          delivery = confirm_phone(post)
          KomsilukPhoneDeliveryJob.perform_now(delivery.id)
          travel 200.days do
            Komsiluk::NoticePublishing.purge_expired_private_data!(organization: @organization, before: 90.days.ago)
            assert delivery.reload.provider_message_ids.present?
            assert delivery.send_intent.reload.payload_scrubbed_at
            assert_nil delivery.send_intent.payload_ciphertext
            assert PlatformDelivery.exists?(delivery.platform_delivery_id)
          end
        end
      end

      test "retention dry run predicts the same union of rows removed or scrubbed" do
        with_phone do
          delivery = confirm_phone(publish)
          delivery.update!(status: "skipped")
          travel 200.days do
            cutoff = 90.days.ago
            predicted = Komsiluk::NoticePublishing.purge_expired_private_data!(organization: @organization, before: cutoff, dry_run: true)
            assert KomsilukPhoneDelivery.exists?(delivery.id)
            applied = Komsiluk::NoticePublishing.purge_expired_private_data!(organization: @organization, before: cutoff)
            assert_equal predicted, applied
            assert_equal 0, Komsiluk::NoticePublishing.purge_expired_private_data!(organization: @organization, before: cutoff, dry_run: true)
          end
        end
      end

      test "phone area hold excludes paid audience without suppressing inbox or push" do
        with_phone do
          post = publish
          Komsiluk::PhoneAreaHolds.save!(organization: @organization, actor: @actor, komsiluk_ids: [@board.id])
          preview = @composer.preview_phone(post:, attributes: phone_attributes)
          assert_equal 0, preview[:summary][:eligible]
          assert_equal 1, preview[:summary][:excluded]["phone_area_held"]
          pushes = []
          WebPush.stub(:enqueue, ->(user, **) { pushes << user.id }) do
            assert_difference -> { Decidim::Notification.where(user: @member).count }, 1 do
              KomsilukNoticeDeliveryJob.perform_now(receipt_for(post).id)
            end
          end
          assert_equal [@member.id], pushes
          assert_empty @provider.requests
        end
      end

      test "changed phone hold version refuses an equal-count preview even after the hold is removed" do
        with_phone do
          post = publish
          preview = @composer.preview_phone(post:, attributes: phone_attributes)
          Komsiluk::PhoneAreaHolds.save!(organization: @organization, actor: @actor, komsiluk_ids: [@other_board.id])
          Komsiluk::PhoneAreaHolds.save!(organization: @organization, actor: @actor, komsiluk_ids: [])
          assert_equal preview[:summary][:eligible], @composer.view(preview[:intent])[:summary][:eligible]
          error = assert_raises(Komsiluk::NoticeComposer::Refused) { @composer.confirm!(preview[:intent].confirmation_token) }
          assert_equal "phone_area_policy_changed", error.message
          assert_equal "preview", preview[:intent].reload.state
          assert_empty KomsilukPhoneDelivery.where(organization: @organization)
          assert_empty KomsilukSmsBudget.where(organization: @organization)
        end
      end

      test "new area hold cancels confirmed phone request before provider handoff" do
        with_phone do
          delivery = confirm_phone(publish)
          Komsiluk::PhoneAreaHolds.save!(organization: @organization, actor: @actor, komsiluk_ids: [@board.id])
          KomsilukPhoneDeliveryJob.perform_now(delivery.id)
          assert_equal "skipped", delivery.reload.status
          assert_equal "phone_area_held", delivery.reason
          assert_empty KomsilukSmsBudget.where(organization: @organization)
          assert_empty @provider.requests
        end
      end

      test "area hold policy change also invalidates a combined publication and phone confirmation" do
        with_phone do
          preview = @composer.preview_publication(publication_attributes.merge(phone_attributes))
          Komsiluk::PhoneAreaHolds.save!(organization: @organization, actor: @actor, komsiluk_ids: [@other_board.id])
          assert_no_difference ["KomsilukPost.count", "PlatformDelivery.count", "KomsilukPhoneDelivery.count"] do
            error = assert_raises(Komsiluk::NoticeComposer::Refused) { @composer.confirm!(preview[:intent].confirmation_token) }
            assert_equal "phone_area_policy_changed", error.message
          end
        end
      end

      private

      def assign(user, board)
        CitizenProfile.for_user(user, organization: @organization).assign_komsiluk!(board, source: "map")
      end

      def publish(category: "general")
        post = create_notice(category:)
        Komsiluk::NoticePublishing.publish!(post:)
        post
      end

      def create_notice(category: "general")
        KomsilukPost.create!(organization: @organization, author: @author, komsiluk: @board, origin: "citizen",
                             publication_key: SecureRandom.uuid, content_revision: 1, published_at: Time.current,
                             category:, title: "Obavještenje", body: "Javni tekst članovima", expires_at: 1.day.from_now)
      end

      def receipt_for(post)
        PlatformDelivery.find_by!(komsiluk_post: post, user: @member)
      end

      def publication_attributes
        { title: "Obavještenje fondacije", body: "Detalji", category: "general", expires_at: 1.day.from_now.iso8601, area_ids: [@board.id] }
      end

      def phone_attributes
        { text: "Hitno obavještenje", sms_text: "Hitno obavještenje", channels: ["sms"], mode: "urgent_sms_now",
          urgency_reason: "Neposredna opasnost", expires_at: 1.hour.from_now.iso8601 }
      end

      def confirm_phone(post)
        preview = @composer.preview_phone(post:, attributes: phone_attributes)
        @composer.confirm!(preview[:intent].confirmation_token)
        KomsilukPhoneDelivery.find_by!(platform_delivery: receipt_for(post))
      end

      def with_phone(&block)
        Setting.put(@organization, Komsiluk::NoticePhonePolicy::NAMESPACE, :sms_enabled, true)
        config = { base_url: "https://provider.example.invalid", api_key: "fixture", sms_sender: "Fixture", viber_bm_sender: "Fixture",
                   messages_api_enabled: true, whatsapp_sender: "Fixture" }
        Config.stub(:infobip, config) do
          IntegrationHealth.instance.stub(:send_blocked?, false) do
            GovernanceApproval.stub(:current_for, Object.new) do
              VerifiedPhone.stub(:delivery_phone_for, "+38765000000") do
                Infobip::Client.stub(:new, @provider, &block)
              end
            end
          end
        end
      end
    end
  end
end
