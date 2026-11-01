# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    class KomsilukPostTest < ActiveSupport::TestCase
      setup do
        @organization = create_organization
        @user = FactoryBot.create(:user, :confirmed, organization: @organization)
        @mz = LocalArea.create!(
          organization: @organization, kind: "mz", slug: "mz-kp",
          name: { "sr" => "Test MZ" }
        )
        @komsiluk = LocalArea.create!(
          organization: @organization, kind: "komsiluk", slug: "komsiluk-kp",
          name: { "sr" => "Test Komšiluk" }, parent: @mz
        )
      end

      def build_post(attrs = {})
        KomsilukPost.new({
          organization: @organization,
          author: @user,
          komsiluk: @komsiluk,
          category: "general",
          title: "Test title",
          body: "Test body"
        }.merge(attrs))
      end

      # ── Enums / predicates ────────────────────────────────────────────────

      test "category predicates match string values" do
        %w(lost_pet safety activity general).each do |cat|
          post = build_post(category: cat)
          assert post.public_send(:"#{cat}?"), "expected #{cat}? to be true"
          other_cats = %w(lost_pet safety activity general) - [cat]
          other_cats.each { |o| assert_not post.public_send(:"#{o}?") }
        end
      end

      test "status predicates match string values" do
        %w(open closed expired hidden).each do |status|
          post = build_post(status: status)
          assert post.public_send(:"#{status}?"), "expected #{status}? to be true"
        end
      end

      # ── expires_at defaults ───────────────────────────────────────────────

      test "lost_pet gets 30-day expiry on create" do
        post = build_post(category: "lost_pet")
        post.valid?
        assert_in_delta 30.days.from_now, post.expires_at, 5.seconds
      end

      test "safety gets 30-day expiry on create" do
        post = build_post(category: "safety")
        post.valid?
        assert_in_delta 30.days.from_now, post.expires_at, 5.seconds
      end

      test "activity has nil expires_at by default" do
        post = build_post(category: "activity")
        post.valid?
        assert_nil post.expires_at
      end

      test "general has nil expires_at by default" do
        post = build_post(category: "general")
        post.valid?
        assert_nil post.expires_at
      end

      test "explicit expires_at is not overwritten on create" do
        future = 45.days.from_now
        post = build_post(category: "activity", expires_at: future)
        post.valid?
        assert_in_delta future, post.expires_at, 5.seconds
      end

      # ── urgent? ───────────────────────────────────────────────────────────

      test "urgent? is true for lost_pet and safety" do
        assert build_post(category: "lost_pet").urgent?
        assert build_post(category: "safety").urgent?
      end

      test "urgent? is false for activity and general" do
        assert_not build_post(category: "activity").urgent?
        assert_not build_post(category: "general").urgent?
      end

      # ── Validations ───────────────────────────────────────────────────────

      test "title length is bounded to TITLE_MAX" do
        post = build_post(title: "x" * (KomsilukPost::TITLE_MAX + 1))
        assert_not post.valid?
        assert_includes post.errors[:title], post.errors.generate_message(:title, :too_long, count: KomsilukPost::TITLE_MAX)
      end

      test "body length is bounded to BODY_MAX" do
        post = build_post(body: "x" * (KomsilukPost::BODY_MAX + 1))
        assert_not post.valid?
      end

      test "category must be in CATEGORIES" do
        post = build_post(category: "bogus")
        assert_not post.valid?
        assert post.errors[:category].any?
      end

      # ── flag! ─────────────────────────────────────────────────────────────

      test "flag! creates a flag row and increments flagged_count" do
        post = build_post.tap(&:save!)
        assert_difference("KomsilukPostFlag.count", 1) do
          result = post.flag!(@user)
          assert_equal :flagged, result
        end
        assert_equal 1, post.reload.flagged_count
      end

      test "flag! is idempotent per user" do
        post = build_post.tap(&:save!)
        post.flag!(@user)
        assert_no_difference("KomsilukPostFlag.count") do
          result = post.flag!(@user)
          assert_equal :already_flagged, result
        end
        assert_equal 1, post.reload.flagged_count
      end

      test "flag! auto-hides at FLAG_HIDE_THRESHOLD distinct users" do
        post = build_post.tap(&:save!)
        users = (1..KomsilukPost::FLAG_HIDE_THRESHOLD).map do |_i|
          FactoryBot.create(:user, :confirmed, organization: @organization)
        end

        # First FLAG_HIDE_THRESHOLD - 1 flags should NOT hide
        (users[0..-2]).each { |u| post.flag!(u) }
        assert_equal "open", post.reload.status

        # Final flag at threshold should auto-hide
        result = post.flag!(users.last)
        assert_equal :auto_hidden, result
        post.reload
        assert_equal "hidden", post.status
        assert_not_nil post.hidden_at
      end

      # ── close! ────────────────────────────────────────────────────────────

      test "close! changes status to closed for the author" do
        post = build_post.tap(&:save!)
        assert post.close!(by: @user)
        post.reload
        assert_equal "closed", post.status
        assert_not_nil post.closed_at
      end

      test "close! returns false for non-author" do
        other_user = FactoryBot.create(:user, :confirmed, organization: @organization)
        post = build_post.tap(&:save!)
        assert_not post.close!(by: other_user)
        assert_equal "open", post.reload.status
      end

      test "close! is a no-op on an already-closed post" do
        post = build_post.tap(&:save!)
        post.close!(by: @user)
        assert_not post.close!(by: @user)
      end

      # ── scopes ────────────────────────────────────────────────────────────

      test "visible scope only returns open posts" do
        open_post = build_post(status: "open").tap(&:save!)
        closed_post = build_post(status: "closed").tap(&:save!)
        hidden_post = build_post(status: "hidden").tap(&:save!)

        visible_ids = KomsilukPost.visible.pluck(:id)
        assert_includes visible_ids, open_post.id
        assert_not_includes visible_ids, closed_post.id
        assert_not_includes visible_ids, hidden_post.id
      end

      test "visible scope excludes expired posts and includes non-expired and null-expiry" do
        # A lapsed post (expires_at in the past) may still carry status "open"
        # if the retention sweep cron lags — it must NOT be visible.
        expired = build_post(status: "open", expires_at: 1.day.ago).tap(&:save!)
        not_expired = build_post(status: "open", expires_at: 1.day.from_now).tap(&:save!)
        null_expiry = build_post(status: "open", expires_at: nil).tap(&:save!)

        visible_ids = KomsilukPost.visible.pluck(:id)
        assert_not_includes visible_ids, expired.id
        assert_includes visible_ids, not_expired.id
        assert_includes visible_ids, null_expiry.id
      end

      test "for_komsiluk scope filters by komsiluk_id" do
        other_mz = LocalArea.create!(organization: @organization, kind: "mz", slug: "mz-other", name: { "sr" => "Other MZ" })
        other_komsiluk = LocalArea.create!(organization: @organization, kind: "komsiluk", slug: "komsiluk-other", name: { "sr" => "Other" }, parent: other_mz)
        my_post = build_post(komsiluk: @komsiluk).tap(&:save!)
        other_post = build_post(komsiluk: other_komsiluk).tap(&:save!)

        mine = KomsilukPost.for_komsiluk(@komsiluk.id).pluck(:id)
        assert_includes mine, my_post.id
        assert_not_includes mine, other_post.id
      end

      # ── sanitized_body ────────────────────────────────────────────────────

      test "sanitized_body strips HTML tags" do
        post = build_post(body: "<b>Bold</b> <script>alert(1)</script> text")
        assert_equal "Bold  text", post.sanitized_body
      end
    end
  end
end
