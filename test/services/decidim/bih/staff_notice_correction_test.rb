# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/komsiluk_notice_source_fixtures"

module Decidim
  module Bih
    class StaffNoticeCorrectionTest < ActiveSupport::TestCase
      include KomsilukNoticeSourceFixtures

      setup do
        setup_notice_sources
        @other_area = LocalArea.create!(organization: @organization, kind: "komsiluk", slug: "correction-other", name: { sr: "Druga tabla" })
        @member = create(:user, :confirmed, organization: @organization)
        @other_member = create(:user, :confirmed, organization: @organization)
        assign(@member, @area)
        assign(@other_member, @other_area)
        @composer = Komsiluk::NoticeComposer.new(organization: @organization, actor: @admin)
        @original_source_provider = Komsiluk::NoticeComposer.source_provider
        Komsiluk::NoticeComposer.source_provider = DecidimApp::Bijeljina::KomsilukNoticeSources
        @expiry = 3.days.from_now.change(usec: 0)
      end

      teardown do
        Komsiluk::NoticeComposer.source_provider = @original_source_provider
      end

      test "one accepted correction preserves linked placement IDs and hidden or closed decisions" do
        posts = create_group
        hidden = posts.last
        hidden.update!(status: "hidden", hidden_at: Time.current, details: { "moderation" => { "source_hold" => true } })
        archived_area = LocalArea.create!(organization: @organization, kind: "komsiluk", slug: "correction-archived", name: { sr: "Ranija tabla" })
        archived = create_placement(archived_area, key: posts.first.publication_key, status: "closed", closed_at: 1.hour.ago)
        posts << archived
        posts.each(&:reload)
        before = posts.to_h { |post| [post.id, [post.publication_key, post.status, post.published_at]] }
        preview = @composer.preview_correction(post: posts.first, attributes: correction_attributes)
        assert_equal 1, preview[:summary][:hidden_count]
        assert_equal 1, preview[:summary][:archived_count]
        assert_not preview[:summary].has_key?(:rows)

        assert_no_difference -> { KomsilukPost.count } do
          assert_difference -> { KomsilukPostRevision.count }, 3 do
            2.times { @composer.confirm!(preview[:intent].confirmation_token) }
          end
        end
        posts.each do |post|
          post.reload
          assert_equal before.fetch(post.id), [post.publication_key, post.status, post.published_at]
          assert_equal 2, post.content_revision
          assert_equal correction_attributes[:body], post.body
          assert_equal @admin, post.revisions.sole.actor
          assert_equal "Original approved body", post.revisions.sole.snapshot["body"]
          assert_equal preview[:intent].id, post.details.dig("staff", "last_correction_intent_id")
        end
        assert hidden.reload.details.dig("moderation", "source_hold")
        assert_equal "confirmed", preview[:intent].reload.state
      end

      test "minor correction retains captured people and receipt evidence without adding later members" do
        posts = create_group
        capture(posts)
        receipts = PlatformDelivery.where(komsiluk_post_id: posts.map(&:id)).order(:id).to_a
        receipts.first.update!(inbox_created_at: 2.minutes.ago, notification_dispatched_at: 2.minutes.ago, browser_displayed_at: 1.minute.ago)
        receipts.last.update!(cancelled_at: Time.current, cancellation_reason: "prior_decision")
        evidence = receipts.to_h { |receipt| [receipt.id, receipt_evidence(receipt.reload)] }
        identities = posts.map { |post| post.reload.notification_capture_identity }
        newcomer = create(:user, :confirmed, organization: @organization)
        assign(newcomer, @area)
        preview = @composer.preview_correction(post: posts.first, attributes: correction_attributes)
        assert_equal 0, preview[:summary][:total]

        assert_no_difference -> { PlatformDelivery.count } do
          @composer.confirm!(preview[:intent].confirmation_token)
        end
        assert_equal(identities, posts.map { |post| post.reload.notification_capture_identity })
        receipts.each do |receipt|
          assert_equal 2, receipt.reload.publication_revision
          assert_equal evidence.fetch(receipt.id), receipt_evidence(receipt)
        end
        assert_not PlatformDelivery.exists?(komsiluk_post_id: posts.map(&:id), user: newcomer)
      end

      test "material correction captures the reviewed current audience once under the same publication key" do
        posts = create_group
        capture(posts)
        newcomer = create(:user, :confirmed, organization: @organization)
        assign(newcomer, @area)
        original_key = posts.first.publication_key
        preview = @composer.preview_correction(post: posts.first, attributes: correction_attributes(notify: "1"))
        assert_equal 3, preview[:summary][:total]
        assert_no_difference -> { KomsilukPost.count } do
          assert_difference -> { PlatformDelivery.count }, 3 do
            2.times { @composer.confirm!(preview[:intent].confirmation_token) }
          end
        end
        updated = PlatformDelivery.where(komsiluk_post_id: posts.map(&:id), publication_revision: 2)
        assert_equal [@member.id, @other_member.id, newcomer.id].sort, updated.pluck(:decidim_user_id).sort
        assert_equal [original_key], posts.map { |post| post.reload.publication_key }.uniq
        assert(posts.all? { |post| post.revisions.sole.notified? })
        later_member = create(:user, :confirmed, organization: @organization)
        assign(later_member, @area)
        Komsiluk::NoticePublishing.recover_pending!
        assert_not PlatformDelivery.exists?(komsiluk_post_id: posts.map(&:id), user: later_member)
      end

      test "a changed placement invalidates the whole correction before any revision is saved" do
        posts = create_group
        preview = @composer.preview_correction(post: posts.first, attributes: correction_attributes)
        posts.last.update!(review_state: "reviewed")
        assert_no_difference -> { KomsilukPostRevision.count } do
          assert_refused("preview_changed") { @composer.confirm!(preview[:intent].confirmation_token) }
        end
        assert_equal [1], posts.map { |post| post.reload.content_revision }.uniq
        assert_equal ["Original approved body"], posts.map(&:body).uniq
        assert_equal "preview", preview[:intent].reload.state
      end

      test "same size audience replacement requires a fresh material correction preview" do
        posts = create_group
        preview = @composer.preview_correction(post: posts.first, attributes: correction_attributes(notify: "1"))
        replacement = create(:user, :confirmed, organization: @organization)
        CitizenProfile.find_by!(organization: @organization, user: @member).update!(komsiluk: nil)
        assign(replacement, @area)
        assert_no_difference -> { PlatformDelivery.count } do
          assert_refused("preview_changed") { @composer.confirm!(preview[:intent].confirmation_token) }
        end
        assert_equal [1], posts.map { |post| post.reload.content_revision }.uniq
      end

      test "changed source rejects old preview while fresh approval clears stale markers and preserves a hidden hold" do
        activity = public_activity
        posts = publish_source_group(activity)
        hidden = posts.last
        hidden.update!(status: "hidden", hidden_at: Time.current,
                       details: hidden.details.merge("moderation" => { "source_hold" => true }))
        previous = @composer.preview_correction(post: posts.first, attributes: correction_attributes)
        activity.update!(title: "Updated reviewed public activity")
        assert_no_difference -> { KomsilukPostRevision.count } do
          assert_refused("source_changed") { @composer.confirm!(previous[:intent].confirmation_token) }
        end
        DecidimApp::Bijeljina::KomsilukSourceProjectionRefresh.refresh!(organization_id: @organization.id, kind: "activity", id: activity.id)
        posts.each do |post|
          post.reload
          reference = post.details.fetch("source_record").merge("unavailable_at" => 1.hour.ago.iso8601)
          post.update!(details: post.details.merge("source_record" => reference))
        end
        current_reference = source("activity", activity).fetch(:details).fetch("source_record")
        assert posts.first.details.dig("source_record", "changed_at")
        fresh = @composer.preview_correction(post: posts.first, attributes: correction_attributes)
        assert_no_difference -> { PlatformDelivery.count } do
          @composer.confirm!(fresh[:intent].confirmation_token)
        end
        posts.each do |post|
          post.reload
          assert_equal current_reference, post.details.fetch("source_record")
          assert_equal 2, post.content_revision
        end
        assert_equal "hidden", hidden.reload.status
        assert hidden.details.dig("moderation", "source_hold")
        assert_equal true, DecidimApp::Bijeljina::KomsilukNoticeSources.with_source_lock(post: posts.first) { true }
      end

      test "unavailable source and all hidden material corrections require a new review decision" do
        activity = public_activity
        posts = publish_source_group(activity)
        activity.update!(active: false)
        assert_no_difference -> { KomsilukSendIntent.count } do
          assert_refused("source_review_required") do
            @composer.preview_correction(post: posts.first.reload, attributes: correction_attributes)
          end
        end
        plain = create_group
        plain.each { |post| post.update!(status: "hidden", hidden_at: Time.current) }
        assert_no_difference -> { KomsilukSendIntent.count } do
          assert_refused("correction_no_visible") do
            @composer.preview_correction(post: plain.first, attributes: correction_attributes(notify: "1"))
          end
        end
      end

      test "ordinary members foreign administrators and revoked publishers cannot correct staff notices" do
        posts = create_group
        foreign = create_organization
        foreign_admin = create(:user, :admin, :confirmed, organization: foreign)
        [@member, foreign_admin].each do |actor|
          composer = Komsiluk::NoticeComposer.new(organization: @organization, actor:)
          assert_no_difference -> { KomsilukSendIntent.count } do
            assert_refused("permission_required") { composer.preview_correction(post: posts.first, attributes: correction_attributes) }
          end
        end
        assert_raises(KomsilukPost::NotEditable) do
          posts.first.correct!(by: @member, expected_revision: 1, attributes: { body: "Unauthorized correction" })
        end
        publisher = create(:user, :confirmed, organization: @organization)
        role = OperatorRole.create!(organization: @organization, user: publisher, created_by: @admin,
                                    role: "broadcast_operator", expires_at: 1.day.from_now)
        composer = Komsiluk::NoticeComposer.new(organization: @organization, actor: publisher)
        preview = composer.preview_correction(post: posts.first, attributes: correction_attributes)
        role.update!(revoked_at: Time.current)
        assert_no_difference -> { KomsilukPostRevision.count } do
          assert_refused("permission_required") { composer.confirm!(preview[:intent].confirmation_token) }
        end
        assert_equal [1], posts.map { |post| post.reload.content_revision }.uniq
      end

      private

      def assign(user, area)
        CitizenProfile.for_user(user, organization: @organization).assign_komsiluk!(area, source: "dropdown")
      end

      def create_group
        key = SecureRandom.uuid
        [@area, @other_area].map { |area| create_placement(area, key:) }
      end

      def create_placement(area, key:, **attributes)
        KomsilukPost.create!(organization: @organization, author: nil, komsiluk: area, origin: "staff",
                             publication_key: key, category: "general", title: "Original approved title", body: "Original approved body",
                             expires_at: @expiry, published_at: 1.hour.ago, **attributes)
      end

      def capture(posts)
        posts.each { |post| Komsiluk::NoticePublishing.publish!(post:) }
      end

      def correction_attributes(notify: "0")
        { title: "Corrected title", body: "Corrected approved body", category: "general", expires_at: @expiry.iso8601, notify: }
      end

      def receipt_evidence(receipt)
        receipt.attributes.slice("identity", "decidim_user_id", "inbox_created_at", "notification_dispatched_at", "browser_displayed_at",
                                 "cancelled_at", "cancellation_reason", "deadline_at", "expires_at")
      end

      def publish_source_group(activity)
        data = source("activity", activity)
        preview = @composer.preview_publication(
          title: data.fetch(:title), body: data.fetch(:body), category: "general", expires_at: @expiry.iso8601,
          area_ids: [@area.id, @other_area.id], source_kind: "activity", source_id: activity.id
        )
        @composer.confirm!(preview[:intent].confirmation_token)
        KomsilukPost.where(organization: @organization, publication_key: preview[:intent].publication_key).order(:id).to_a
      end

      def assert_refused(code)
        error = assert_raises(Komsiluk::NoticeComposer::Refused) { yield }
        assert_equal code, error.message
      end
    end
  end
end
