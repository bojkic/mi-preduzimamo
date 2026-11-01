# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/synthetic_event_source_registry"

module DecidimApp
  module Bijeljina
    class CityServiceIncidentSafetyTest < ActiveSupport::TestCase
      include SyntheticEventSourceRegistry
      setup do
        @event_starts_at = 2.hours.from_now.change(usec: 0)
        @event_ends_at = @event_starts_at + 5.hours
        @organization = create_organization
        @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
        @area = Decidim::Bih::LocalArea.create!(organization: @organization, kind: "komsiluk", slug: "komsiluk-incident-test", name: { "sr" => "Test" })
      end

      test "same title and time with distinct feeders remain separate identities and are excluded as candidates" do
        a = event("a", feeder: "TS IZMIŠLJENI VOD A")
        b = event("b", feeder: "TS IZMIŠLJENI VOD B")
        CityServiceIncidentIdentity.attach!(a)
        CityServiceIncidentIdentity.attach!(b)
        assert_not_equal a.incident_id, b.incident_id
        assert_empty CityServiceIncidentReview.new(event: a).candidates
      end

      test "same feeder label in different operating units is not an automatic duplicate candidate" do
        left = event("left", unit: "Izmišljena jedinica A")
        event("right", unit: "Izmišljena jedinica B")
        assert_empty CityServiceIncidentReview.new(event: left).candidates
      end

      test "operator can separate merge and undo with stale and foreign selections rejected" do
        a = event("a")
        b = event("b")
        assert_equal :updated, resolve(a, b, "separate")
        assert_not_equal a.reload.incident_id, b.reload.incident_id
        old_token = a.answer_review_token
        assert_equal :updated, resolve(a, b, "same")
        assert_equal a.reload.incident_id, b.reload.incident_id
        assert_equal :stale_review,
                     CityServiceIncidentReview.new(event: a, actor: @admin).resolve!(other_event_id: b.id, decision: "undo", review_token: old_token,
                                                                                     other_review_token: b.answer_review_token)
        assert_equal :updated, resolve(a, b, "undo")
        assert_not_equal a.reload.incident_id, b.reload.incident_id
        assert_equal "pending_review", a.state
        foreign = event("foreign", organization: create_organization)
        assert_equal :invalid_selection, resolve(a, foreign, "same")
      end

      test "undo refuses to silently break a later group merge" do
        a, b, c = %w(a b c).map { |id| event(id) }
        assert_equal :updated, resolve(a, b, "same")
        assert_equal :updated, resolve(b.reload, c, "same")
        assert_equal :subsequent_merge_requires_review, resolve(a.reload, b.reload, "undo")
        assert_equal 1, [a.reload.incident_id, b.reload.incident_id, c.reload.incident_id].uniq.size
      end

      test "coverage registry revocation expiry and geometry change cannot revive legacy approved coverage" do
        original = event("old")
        original.update!(state: "board_published", reviewed_by_id: @admin.id, reviewed_at: Time.current, reviewed_content_version: original.content_version,
                         extraction_metadata: original.extraction_metadata.merge("operator_review" => { "reuse_coverage" => true,
                                                                                                        "coverage_valid_until" => 10.days.from_now.to_date.iso8601 }))
        assert CityServiceCoverageRegistry.remember!(original, actor: @admin)
        mapping = CityServiceCoverage.find_by!(event: original)
        candidate = event("new")
        candidate.update!(targeting_level: "unknown", affected_area_slugs: [])
        assert_equal mapping.id, CityServiceCoverageRegistry.resolve(candidate).id
        assert_equal :updated, CityServiceCoverageRegistry.revoke!(event: original, actor: @admin)
        assert_nil CityServiceCoverageRegistry.resolve(candidate)
        preparation = CityServiceAreaPreparation.new(organization: @organization)
        assert_not preparation.send(:apply_reviewed_mapping, candidate)
        mapping.update!(revoked_at: nil, valid_until: Date.yesterday)
        assert_not preparation.send(:apply_reviewed_mapping, candidate)
        mapping.update!(valid_until: 10.days.from_now.to_date, evidence: mapping.evidence.merge("boundary_revision" => "old-boundaries"))
        assert_not preparation.send(:apply_reviewed_mapping, candidate)
        assert_equal "unknown", candidate.reload.targeting_level
      end

      test "board published legacy mappings remain reusable only with matching unit and current reviewed facts" do
        original = event("old", unit: "Izmišljena jedinica A")
        original.update!(state: "board_published", reviewed_by_id: @admin.id, reviewed_at: Time.current, reviewed_content_version: original.content_version,
                         extraction_metadata: original.extraction_metadata.merge("operator_review" => { "reuse_coverage" => true,
                                                                                                        "coverage_valid_until" => 10.days.from_now.to_date.iso8601 }))
        candidate = event("new", unit: "Izmišljena jedinica A")
        candidate.update!(targeting_level: "unknown", affected_area_slugs: [])
        preparation = CityServiceAreaPreparation.new(organization: @organization)
        assert preparation.send(:apply_reviewed_mapping, candidate)
        mismatched = event("wrong-unit", unit: "Izmišljena jedinica B")
        mismatched.update!(targeting_level: "unknown", affected_area_slugs: [])
        assert_not preparation.send(:apply_reviewed_mapping, mismatched)
        original.update!(content_version: "changed-without-review")
        candidate.update!(targeting_level: "unknown", affected_area_slugs: [])
        assert_not preparation.send(:apply_reviewed_mapping, candidate)
      end

      test "confirmed mirrored observations share delivery identity despite source wording while changed time is a revision" do
        left = event("left")
        right = event("right")
        left.update!(source_key: "water_service", event_type: "planned_interruption")
        right.update!(source_key: "city_official_notices", event_type: "planned_interruption",
                      summary: "Drugi izvor potvrđuje prekid", affected_text: "Isto područje drugim riječima",
                      recommended_action: "Sačekajte obnovu usluge",
                      starts_at: left.starts_at, ends_at: left.ends_at)
        assert_equal :updated, resolve(left, right, "same")
        assert_equal CityServiceIncidentIdentity.delivery_identity(left.reload), CityServiceIncidentIdentity.delivery_identity(right.reload)
        right.update!(ends_at: right.ends_at + 1.hour)
        assert_not_equal CityServiceIncidentIdentity.delivery_identity(left), CityServiceIncidentIdentity.delivery_identity(right)
      end

      test "merge rebinds published members to one active projection and undo retires projections" do
        left = event("left")
        right = event("right")
        assert_equal :published, CityServiceEventPublisher.new(left, actor: @admin).publish_board!.status
        assert_equal :published, CityServiceEventPublisher.new(right, actor: @admin).publish_board!.status
        assert_equal 2, CityServiceProjection.count
        assert_equal :updated, resolve(left.reload, right.reload, "same")
        assert_equal 1, CityServiceProjection.count
        assert_equal left.reload.komsiluk_post_ids, right.reload.komsiluk_post_ids
        assert_equal :updated, resolve(left, right, "undo")
        assert_equal 0, CityServiceProjection.count
        assert_empty left.reload.komsiluk_post_ids
        assert_empty right.reload.komsiluk_post_ids
      end

      test "splitting published incidents retires both captured audiences without losing receipt evidence" do
        left, right, user = published_corroborations
        receipt_ids = Decidim::Bih::PlatformDelivery.where(user:).order(:id).pluck(:id)
        assert_equal 2, receipt_ids.size
        assert_equal :updated, resolve(left.reload, right.reload, "same")
        assert_equal :updated, resolve(left.reload, right.reload, "undo")
        receipts = Decidim::Bih::PlatformDelivery.where(id: receipt_ids)
        assert_equal receipt_ids, receipts.order(:id).pluck(:id)
        assert_equal 2, receipts.where.not(cancelled_at: nil).count
        assert_no_difference "user.notifications.count" do
          receipts.each { |receipt| Decidim::Bih::KomsilukNoticeDeliveryJob.perform_now(receipt.id) }
        end
      end

      test "withdrawing one source keeps a corroborated projection and removes unsupported citation and content" do
        left = event("left")
        right = event("right")
        right.update!(source_url: "https://example.test/corroborating", summary: "Još važeće obavještenje", starts_at: left.starts_at, ends_at: left.ends_at)
        [left, right].each { |member| assert_equal :published, CityServiceEventPublisher.new(member, actor: @admin).publish_board!.status }
        assert_equal :updated, resolve(left.reload, right.reload, "same")
        post = CityServiceProjection.sole.post
        effects_before = CityServiceEffect.count
        left.withdraw_source_version!(document_url: left.source_url, document_version: "new-empty", observed_at: Time.current, reason: "complete_source_snapshot_changed")
        assert_equal "open", post.reload.status
        assert_includes post.body, right.summary
        assert_includes post.details.dig("source", "urls"), right.source_url
        assert_not_includes post.details.dig("source", "urls"), left.source_url
        assert_not_includes post.details.dig("source", "event_ids"), left.id
        assert_equal "board_published", right.reload.state
        assert_equal effects_before, CityServiceEffect.count
        assert_equal :withdrawn, CityServicePublicationWithdrawal.call(event: right, actor: @admin, review_token: right.answer_review_token, note: "Povučeno")
        assert_equal "expired", post.reload.status
      end

      test "operator observation withdrawal preserves another published source without sending again" do
        left = event("left")
        travel 2.seconds
        right = event("right")
        assert_equal left.starts_at, right.starts_at
        assert_equal left.ends_at, right.ends_at
        [left, right].each { |member| CityServiceEventPublisher.new(member, actor: @admin).publish_board! }
        resolve(left.reload, right.reload, "same")
        post = CityServiceProjection.sole.post
        assert_no_difference "CityServiceEffect.count" do
          assert_equal :withdrawn, CityServicePublicationWithdrawal.call(event: left.reload, actor: @admin, review_token: left.answer_review_token, note: "Ispravka", correct: true)
        end
        assert_equal "pending_review", left.reload.state
        assert_equal "open", post.reload.status
        assert_equal "board_published", right.reload.state
      end

      test "canonical source withdrawal before dispatch preserves one pending platform intent" do
        left, right, user = published_corroborations
        assert_equal :updated, resolve(left.reload, right.reload, "same")
        identity = CityServiceIncidentIdentity.delivery_identity(left)
        left.withdraw_source_version!(document_url: left.source_url, document_version: "removed", observed_at: Time.current, reason: "complete_source_snapshot_changed")
        assert_equal identity, CityServiceIncidentIdentity.delivery_identity(right.reload)
        Decidim::Bih::WebPush.stub(:enqueue, false) do
          CityServiceEffect.order(:id).each { |effect| CityServiceEffectJob.perform_now(effect.id) }
        end
        assert_equal 1, user.notifications.count
        receipts = Decidim::Bih::PlatformDelivery.where(user:)
        assert_equal 2, receipts.count
        assert_equal 1, receipts.where.not(cancelled_at: nil).count
        active_receipt = receipts.where(cancelled_at: nil).sole
        assert_equal identity, active_receipt.identity
        assert_equal 0, CityServiceEffect.where(kind: "fallback").count
        assert_nil active_receipt.fallback_requested_at
      end

      test "confirmed platform receipt remains shared after canonical source withdrawal without another inbox or push" do
        left, right, user = published_corroborations
        Decidim::Bih::WebPush.stub(:enqueue, false) { CityServiceEffectJob.perform_now(CityServiceEffect.find_by!(event: left).id) }
        receipt = captured_receipt(left, user)
        receipt.acknowledge!("inbox_read")
        identity = receipt.identity
        assert_equal :updated, resolve(left.reload, right.reload, "same")
        left.withdraw_source_version!(document_url: left.source_url, document_version: "removed", observed_at: Time.current, reason: "complete_source_snapshot_changed")
        assert_equal identity, CityServiceIncidentIdentity.delivery_identity(right.reload)
        pushes = 0
        Decidim::Bih::WebPush.stub(:enqueue, ->(*) { pushes += 1 }) do
          CityServiceEffect.order(:id).each { |effect| CityServiceEffectJob.perform_now(effect.id) }
        end
        assert_equal 0, pushes
        assert_equal 1, user.notifications.count
        receipts = Decidim::Bih::PlatformDelivery.where(user:)
        assert_equal 2, receipts.count
        assert_equal 1, receipts.where.not(cancelled_at: nil).count
        assert_equal receipt.id, receipts.where(cancelled_at: nil).sole.id
        assert receipt.reload.acknowledged_at
        assert receipt.inbox_read_at
        assert_equal 0, CityServiceEffect.where(kind: "fallback").count
      end

      test "merge keeps the acknowledged right capture and does not invent a later audience" do
        left, right, user = published_corroborations
        left_receipt = captured_receipt(left, user)
        right_receipt = captured_receipt(right, user)
        right_post = right_receipt.komsiluk_post
        Decidim::Bih::WebPush.stub(:enqueue, false) { Decidim::Bih::KomsilukNoticeDeliveryJob.perform_now(right_receipt.id) }
        right_receipt.reload.acknowledge!("inbox_read")
        evidence = right_receipt.attributes.slice("identity", "komsiluk_post_id", "inbox_created_at", "inbox_read_at", "acknowledged_at", "notification_id")
        newcomer = board_member
        receipt_ids = Decidim::Bih::PlatformDelivery.where(organization: @organization).order(:id).pluck(:id)

        assert_equal :updated, resolve(left.reload, right.reload, "same")
        assert_equal right_post.id, CityServiceProjection.sole.post_id
        assert_equal [right_post.id], left.reload.komsiluk_post_ids
        assert_equal [right_post.id], right.reload.komsiluk_post_ids
        assert_equal right_receipt.identity, CityServiceIncidentIdentity.delivery_identity(left)
        assert_equal right_receipt.identity, right_post.reload.notification_capture_identity
        assert_equal evidence, right_receipt.reload.attributes.slice(*evidence.keys)
        assert_nil right_receipt.cancelled_at
        assert left_receipt.reload.cancelled_at
        assert_equal receipt_ids, Decidim::Bih::PlatformDelivery.where(organization: @organization).order(:id).pluck(:id)
        assert_not Decidim::Bih::PlatformDelivery.exists?(user: newcomer)
        assert_no_incident_redelivery
      end

      test "mixed user receipts suppress a pending duplicate without copying another receipt's proof" do
        second_user = board_member
        left, right, first_user = published_corroborations
        first_left = captured_receipt(left, first_user)
        second_left = captured_receipt(left, second_user)
        second_right = captured_receipt(right, second_user)
        Decidim::Bih::WebPush.stub(:enqueue, false) do
          Decidim::Bih::KomsilukNoticeDeliveryJob.perform_now(first_left.id)
          Decidim::Bih::KomsilukNoticeDeliveryJob.perform_now(second_right.id)
        end
        first_left.reload.acknowledge!("inbox_read")
        second_right.reload.acknowledge!("browser_display")
        proof = second_right.attributes.slice("identity", "komsiluk_post_id", "inbox_created_at", "browser_displayed_at", "acknowledged_at", "notification_id")
        pending_phone = captured_phone(second_left, status: "pending")
        accepted_phone = captured_phone(second_right, status: "accepted")
        provider_proof = accepted_phone.attributes.slice("status", "provider_message_ids", "attempted_at", "platform_delivery_id")

        assert_equal :updated, resolve(left.reload, right.reload, "same")
        assert_equal first_left.komsiluk_post_id, CityServiceProjection.sole.post_id
        assert_equal first_left.identity, CityServiceIncidentIdentity.delivery_identity(right.reload)
        assert_nil first_left.reload.cancelled_at
        assert_equal "duplicate_incident_already_dispatched", second_left.reload.cancellation_reason
        assert second_left.cancelled_at
        assert_nil second_left.inbox_created_at
        assert_nil second_left.notification_dispatched_at
        assert_nil second_left.acknowledged_at
        assert_equal proof, second_right.reload.attributes.slice(*proof.keys)
        assert second_right.cancelled_at
        assert_equal "skipped", pending_phone.reload.status
        assert_equal "duplicate_incident_already_dispatched", pending_phone.reason
        assert_equal provider_proof, accepted_phone.reload.attributes.slice(*provider_proof.keys)
        assert_no_incident_redelivery
      end

      test "queued push alone does not suppress the retained captured notice" do
        left, right, user = published_corroborations
        left_receipt = captured_receipt(left, user)
        right_receipt = captured_receipt(right, user)
        right_receipt.update!(push_queued_at: Time.current)

        assert_equal :updated, resolve(left.reload, right.reload, "same")
        assert_nil left_receipt.reload.cancelled_at
        assert right_receipt.reload.cancelled_at
        Decidim::Bih::WebPush.stub(:enqueue, false) do
          CityServiceEffect.order(:id).each { |effect| CityServiceEffectJob.perform_now(effect.id) }
        end
        assert_equal 1, user.notifications.count
        assert left_receipt.reload.inbox_created_at
        assert_nil right_receipt.inbox_created_at
      end

      %w(hidden source_hold).each do |hold|
        test "an acknowledged canonical post inherits the duplicate board's #{hold}" do
          left, right, user = published_corroborations
          left_post = captured_receipt(left, user).komsiluk_post
          right_receipt = captured_receipt(right, user)
          right_post = right_receipt.komsiluk_post
          Decidim::Bih::WebPush.stub(:enqueue, false) { Decidim::Bih::KomsilukNoticeDeliveryJob.perform_now(right_receipt.id) }
          right_receipt.reload.acknowledge!("inbox_read")
          moderation = { "source_hold" => true, "previous_status" => "open" }
          left_post.update!(details: left_post.details.merge("moderation" => moderation),
                            status: hold == "hidden" ? "hidden" : "open", hidden_at: hold == "hidden" ? Time.current : nil)
          Decidim::Bih::Komsiluk::NoticePublishing.cancel_pending_for!(post: left_post, reason: "projection_hidden")

          assert_equal :updated, resolve(left.reload, right.reload, "same")
          assert_equal right_post.id, CityServiceProjection.sole.post_id
          assert_equal true, right_post.reload.details.dig("moderation", "source_hold")
          assert_equal left_post.id, right_post.details.dig("moderation", "merged_hold_post_id")
          assert_equal "hidden", right_post.status if hold == "hidden"
          assert_not CityServiceBoardVisibility.current?(right_post)
          assert_equal "incident_merged_hold", right_receipt.reload.cancellation_reason
          assert right_receipt.acknowledged_at
          assert right_receipt.inbox_read_at
          assert_no_incident_redelivery
        end
      end

      private

      def captured_receipt(member, user)
        member.reload
        Decidim::Bih::PlatformDelivery.find_by!(user:, identity: CityServiceIncidentIdentity.delivery_identity(member),
                                                komsiluk_post_id: member.komsiluk_post_id_values.sole)
      end

      def board_member
        user = FactoryBot.create(:user, :confirmed, organization: @organization)
        Decidim::Bih::CitizenProfile.for_user(user, organization: @organization).assign_komsiluk!(@area, source: "dropdown")
        user
      end

      def captured_phone(receipt, status:)
        intent = Decidim::Bih::KomsilukSendIntent.create!(organization: @organization, actor: @admin, kind: "phone", state: "confirmed",
                                                          publication_key: receipt.komsiluk_post.publication_key, preview_digest: SecureRandom.hex(32),
                                                          payload: { post_id: receipt.komsiluk_post_id }, expires_at: receipt.expires_at)
        Decidim::Bih::KomsilukPhoneDelivery.create!(organization: @organization, user: receipt.user, send_intent: intent, platform_delivery: receipt,
                                                    status:, channels: ["viber"], destination_digest: "synthetic-#{receipt.id}",
                                                    due_at: receipt.deadline_at, expires_at: receipt.expires_at,
                                                    attempted_at: status == "accepted" ? Time.current : nil,
                                                    provider_message_ids: status == "accepted" ? ["synthetic-provider-#{receipt.id}"] : [])
      end

      def assert_no_incident_redelivery
        pushes = 0
        assert_no_difference ["Decidim::Notification.count", "Decidim::Bih::PlatformDelivery.count"] do
          Decidim::Bih::WebPush.stub(:enqueue, ->(*) { pushes += 1 }) do
            CityServiceEffect.order(:id).each { |effect| CityServiceEffectJob.perform_now(effect.id) }
            Decidim::Bih::PlatformDelivery.order(:id).each { |receipt| Decidim::Bih::KomsilukNoticeDeliveryJob.perform_now(receipt.id) }
          end
        end
        assert_equal 0, pushes
      end

      def published_corroborations
        left = event("left")
        right = event("right")
        right.update!(summary: "Isti prekid potvrđen drugim riječima", starts_at: left.starts_at, ends_at: left.ends_at)
        user = FactoryBot.create(:user, :confirmed, organization: @organization)
        Decidim::Bih::CitizenProfile.for_user(user, organization: @organization).assign_komsiluk!(@area, source: "dropdown")
        [left, right].each { |member| assert_equal :published, CityServiceEventPublisher.new(member, actor: @admin).publish_board!.status }
        [left, right, user]
      end

      def resolve(left, right, decision)
        CityServiceIncidentReview.new(event: left, actor: @admin).resolve!(other_event_id: right.id, decision:, review_token: left.answer_review_token,
                                                                           other_review_token: right.answer_review_token)
      end

      def event(fingerprint, feeder: "TS SHARED", unit: "Izmišljena jedinica A", organization: @organization)
        CityServiceEvent.create!(organization:, source_key: "electricity_outages", source_label: "Izmišljeni pružalac",
                                 source_fingerprint: fingerprint, source_url: CityServiceSources.fetch("electricity_outages").fetch(:source_url),
                                 event_type: "planned_outage", severity: "service_outage", targeting_level: "komsiluk", affected_area_slugs: [@area.slug],
                                 affected_text: "1 NN izlaz", title: "Planirano isključenje", summary: "Najavljeni prekid", starts_at: @event_starts_at, ends_at: @event_ends_at,
                                 fetched_at: Time.current, state: "pending_review", lifecycle: "scheduled", parser_version: "fixture", content_version: "revision-1",
                                 extraction_metadata: { "feeder" => feeder, "tj" => unit, "source_snapshot_complete" => true, "complete" => true })
      end
    end
  end
end
