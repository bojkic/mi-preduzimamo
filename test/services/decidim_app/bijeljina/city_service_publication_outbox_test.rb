# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/synthetic_event_source_registry"

module DecidimApp
  module Bijeljina
    class CityServicePublicationOutboxTest < ActiveSupport::TestCase
      include SyntheticEventSourceRegistry
      include ActiveJob::TestHelper

      setup do
        @organization = create_organization
        @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
        @area = Decidim::Bih::LocalArea.create!(organization: @organization, kind: "komsiluk", slug: "komsiluk-outbox", name: { sr: "Outbox" })
        @event = CityServiceEvent.create!(organization: @organization, source_key: "electricity_outages", source_url: "https://example.test/outages",
                                          source_fingerprint: "outbox-1", source_occurrence_id: "outbox-occurrence", content_version: "source-v1", parser_version: "test",
                                          event_type: "planned_outage", severity: "service_outage", title: "Prekid struje", summary: "Prekid struje u komšiluku.",
                                          targeting_level: "komsiluk", affected_area_slugs: [@area.slug], starts_at: 1.hour.from_now, ends_at: 3.hours.from_now)
      end

      test "publication and its durable effects roll back together" do
        CityServiceEvent.transaction(requires_new: true) do
          CityServiceEventPublisher.new(@event, actor: @admin).publish_board!
          assert_equal 1, CityServiceEffect.count
          raise ActiveRecord::Rollback
        end
        assert_equal "pending_review", @event.reload.state
        assert_empty CityServiceEffect.all
        assert_empty CityServiceProjection.all
        assert_empty Decidim::Bih::KomsilukPost.all
      end

      test "repeated publication has one post projection and one durable board intent" do
        2.times { CityServiceEventPublisher.new(@event.reload, actor: @admin).publish_board! }
        assert_equal 1, CityServiceProjection.count
        assert_equal 1, Decidim::Bih::KomsilukPost.count
        effect = CityServiceEffect.sole
        assert_equal "board", effect.kind
        assert_not effect.payload.has_key?("user_ids")
        assert_equal CityServiceIncidentIdentity.delivery_identity(@event), effect.payload["delivery_identity"]
      end

      test "retry after inbox creation does not duplicate the platform notification" do
        user = FactoryBot.create(:user, :confirmed, organization: @organization)
        Decidim::Bih::CitizenProfile.for_user(user, organization: @organization).assign_komsiluk!(@area, source: "dropdown")
        CityServiceEventPublisher.new(@event, actor: @admin).publish_board!
        effect = CityServiceEffect.sole
        Decidim::Bih::WebPush.stub(:enqueue, false) do
          2.times { CityServiceEffectJob.perform_now(effect.id) }
        end
        assert_equal 1, user.notifications.count
        assert_equal 1, Decidim::Bih::PlatformDelivery.where(user:).count
        assert_not_nil effect.reload.completed_at
        assert_empty Decidim::Bih::AccountNotification.all
      end

      test "failed dispatch records its attempt and durable recovery succeeds" do
        CityServiceEventPublisher.new(@event, actor: @admin).publish_board!
        effect = CityServiceEffect.sole
        Decidim::Bih::Komsiluk::NoticePublishing.stub(:replay_captured!, ->(**) { raise IOError, "temporary transport failure" }) do
          assert_raises(IOError) { CityServiceEffectJob.perform_now(effect.id) }
        end
        assert_equal 1, effect.reload.attempts
        assert_equal "IOError", effect.error_code
        assert_nil effect.completed_at
        Decidim::Bih::Komsiluk::NoticePublishing.stub(:replay_captured!, 0) do
          CityServiceEffectJob.perform_now(effect.id)
        end
        assert_equal 2, effect.reload.attempts
        assert_not_nil effect.completed_at
        assert_nil effect.error_code
      end

      test "city board effects replay captured general notices without adding later members" do
        user = FactoryBot.create(:user, :confirmed, organization: @organization)
        Decidim::Bih::CitizenProfile.for_user(user, organization: @organization).assign_komsiluk!(@area, source: "dropdown")
        CityServiceEventPublisher.new(@event, actor: @admin).publish_board!
        post = Decidim::Bih::KomsilukPost.sole
        post.update!(category: "general")
        later = FactoryBot.create(:user, :confirmed, organization: @organization)
        Decidim::Bih::CitizenProfile.for_user(later, organization: @organization).assign_komsiluk!(@area, source: "dropdown")
        Decidim::Bih::WebPush.stub(:enqueue, false) { CityServiceEffectJob.perform_now(CityServiceEffect.sole.id) }
        assert_equal 1, user.notifications.count
        assert_empty later.notifications
        assert_not Decidim::Bih::PlatformDelivery.exists?(user: later)
        assert_includes user.notifications.sole.extra["board_url"], "#{Decidim::Bih.normalized_public_mount_path}/komsiluk-board/objava/"
      end

      test "empty captured city audience is complete and cannot gain later joiners" do
        CityServiceEventPublisher.new(@event, actor: @admin).publish_board!
        post = Decidim::Bih::KomsilukPost.sole
        assert post.notification_capture_identity.present?
        later = FactoryBot.create(:user, :confirmed, organization: @organization)
        Decidim::Bih::CitizenProfile.for_user(later, organization: @organization).assign_komsiluk!(@area, source: "dropdown")
        effect = CityServiceEffect.sole
        assert_no_difference ["Decidim::Bih::PlatformDelivery.count", "Decidim::Notification.count"] do
          2.times { CityServiceEffectJob.perform_now(effect.id) }
        end
        assert effect.reload.completed_at
        assert_nil effect.error_code
      end

      test "city effect cannot bypass cancelled publication receipts" do
        user = FactoryBot.create(:user, :confirmed, organization: @organization)
        Decidim::Bih::CitizenProfile.for_user(user, organization: @organization).assign_komsiluk!(@area, source: "dropdown")
        CityServiceEventPublisher.new(@event, actor: @admin).publish_board!
        # Fixture represents already-cancelled durable evidence without replaying callbacks.
        receipts = Decidim::Bih::PlatformDelivery.where(user:)
        receipts.update_all(cancelled_at: Time.current, cancellation_reason: "moderated") # rubocop:disable Rails/SkipsModelValidations
        assert_no_difference "Decidim::Notification.count" do
          CityServiceEffectJob.perform_now(CityServiceEffect.sole.id)
        end
      end

      test "uncaptured pre-release effect retires with evidence and never resolves current members" do
        CityServiceEventPublisher.new(@event, actor: @admin).publish_board!
        # Simulate a pre-release row whose audience was never captured.
        Decidim::Bih::KomsilukPost.sole.update_columns(notification_capture_identity: nil) # rubocop:disable Rails/SkipsModelValidations
        later = FactoryBot.create(:user, :confirmed, organization: @organization)
        Decidim::Bih::CitizenProfile.for_user(later, organization: @organization).assign_komsiluk!(@area, source: "dropdown")
        effect = CityServiceEffect.sole
        assert_no_difference ["Decidim::Bih::PlatformDelivery.count", "Decidim::Notification.count"] do
          CityServiceEffectJob.perform_now(effect.id)
        end
        assert effect.reload.completed_at
        assert_equal "legacy_publication_uncaptured", effect.error_code
      end

      test "source replacement before outbox execution suppresses the old notice" do
        CityServiceEventPublisher.new(@event, actor: @admin).publish_board!
        effect = CityServiceEffect.sole
        @event.update!(lifecycle: "cancelled")
        CityServiceEffectJob.perform_now(effect.id)
        assert_equal "event_changed_or_expired", effect.reload.error_code
        assert_not_nil effect.completed_at
        assert_empty Decidim::Bih::PlatformDelivery.all
      end

      test "withdrawal correction restores the same placement with a new publication revision" do
        CityServiceEventPublisher.new(@event, actor: @admin).publish_board!
        old_post = CityServiceProjection.sole.post
        old_revision = @event.publication_revision
        CityServicePublicationWithdrawal.call(event: @event, actor: @admin, review_token: @event.answer_review_token, note: "Ispravka", correct: true)
        assert_equal "expired", old_post.reload.status
        @event.update!(extraction_metadata: @event.extraction_metadata.except("publication_correction_pending"), summary: "Ispravljeno obavještenje.")
        CityServiceEventPublisher.new(@event, actor: @admin).publish_board!
        assert_equal "open", old_post.reload.status
        assert_equal "Ispravljeno obavještenje.", old_post.body
        assert_equal old_post.id, CityServiceProjection.sole.post_id
        assert_equal 1, Decidim::Bih::KomsilukPost.count
        assert_not_equal old_revision, @event.reload.publication_revision
        assert_equal 1, CityServiceProjection.count
      end
    end
  end
end
