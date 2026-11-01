# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module Komsiluk
      # Inbox recipients stay available regardless of topic choices. Proactive
      # delivery filters the same membership through the canonical topic choice.
      class MembershipResolverTest < ActiveSupport::TestCase
        setup do
          @organization = create_organization

          @mz = LocalArea.create!(
            organization: @organization, kind: "mz", slug: "mz-res",
            name: { "sr" => "MZ" }
          )
          @komsiluk1 = LocalArea.create!(
            organization: @organization, kind: "komsiluk", slug: "k-res-1",
            name: { "sr" => "K1" }, primary_mz_slug: "mz-res"
          )
          @komsiluk2 = LocalArea.create!(
            organization: @organization, kind: "komsiluk", slug: "k-res-2",
            name: { "sr" => "K2" }, primary_mz_slug: "mz-res"
          )

          @c1 = FactoryBot.create(:user, :confirmed, organization: @organization)
          @c2 = FactoryBot.create(:user, :confirmed, organization: @organization)
          @c3 = FactoryBot.create(:user, :confirmed, organization: @organization)

          assign(@c1, @komsiluk1)
          assign(@c2, @komsiluk2)
          assign(@c3, @komsiluk1)
        end

        # ── komsiluk audience ────────────────────────────────────────────────

        test "for_komsiluk resolves only that komsiluk's active citizens" do
          ids = resolver_for_komsiluk(@komsiluk1).recipient_ids
          assert_equal [@c1.id, @c3.id].sort, ids.sort
        end

        test "for_komsiluk excludes the given user id when exclude_user_id is set" do
          ids = resolver_for_komsiluk(@komsiluk1).recipient_ids(exclude_user_id: @c1.id)
          assert_equal [@c3.id], ids
        end

        test "for_komsiluk with no exclude keeps everyone (default exclude_user_id: nil)" do
          ids = resolver_for_komsiluk(@komsiluk1).recipient_ids(exclude_user_id: nil)
          assert_equal [@c1.id, @c3.id].sort, ids.sort
        end

        # ── opt-out parameter ────────────────────────────────────────────────

        test "unfiltered membership includes users with the neighborhood topic disabled" do
          TopicPreferences.set!(@c1, topic: :neighborhood_info, enabled: false)

          ids = resolver_for_komsiluk(@komsiluk1).recipient_ids(honor_opt_out: false)

          assert_equal [@c1.id, @c3.id].sort, ids.sort
        end

        test "bell recipients include users with the neighborhood topic disabled" do
          TopicPreferences.set!(@c1, topic: :neighborhood_info, enabled: false)

          ids = resolver_for_komsiluk(@komsiluk1).recipient_ids(
            honor_opt_out: true, notification_channel: :bell
          )

          assert_equal [@c1.id, @c3.id].sort, ids.sort
        end

        test "proactive recipients exclude users with the neighborhood topic disabled" do
          TopicPreferences.set!(@c1, topic: :neighborhood_info, enabled: false)

          ids = resolver_for_komsiluk(@komsiluk1).recipient_ids(
            honor_opt_out: true, notification_topic: :neighborhood_info,
            notification_channel: :viber
          )

          assert_equal [@c3.id], ids
        end

        test "proactive recipients include an explicit choice and the missing default" do
          TopicPreferences.set!(@c1, topic: :neighborhood_info, enabled: true)

          ids = resolver_for_komsiluk(@komsiluk1).recipient_ids(
            honor_opt_out: true, notification_topic: :komsiluk_urgent,
            notification_channel: :viber
          )

          assert_equal [@c1.id, @c3.id].sort, ids.sort
        end

        # ── active-user filter ───────────────────────────────────────────────

        test "blocked, deleted and unconfirmed users are filtered out on every path" do
          @c1.update!(blocked: true)
          @c3.update!(deleted_at: Time.current, email: "del-#{Time.now.to_i}@example.invalid")
          unconfirmed = FactoryBot.create(:user, organization: @organization, confirmed_at: nil)
          assign(unconfirmed, @komsiluk1)

          ids = resolver_for_komsiluk(@komsiluk1).recipient_ids
          assert_empty ids
        end

        test "users from another organization are never resolved" do
          other_org = create_organization
          other_user = FactoryBot.create(:user, :confirmed, organization: other_org)
          other_k = LocalArea.create!(
            organization: other_org, kind: "komsiluk", slug: "k-other",
            name: { "sr" => "Other" }
          )
          assign(other_user, other_k, organization: other_org)

          ids = MembershipResolver
                .for_komsiluk(organization: @organization, komsiluk_id: other_k.id)
                .recipient_ids
          assert_empty ids
        end

        # ── MZ audience + overlap union ──────────────────────────────────────

        test "for_mz resolves all citizens across the MZ via mz_id" do
          ids = MembershipResolver.for_mz(organization: @organization, mz_area: @mz).recipient_ids
          assert_equal [@c1.id, @c2.id, @c3.id].sort, ids.sort
        end

        test "for_mz unions in nil-mz_id citizens whose komsiluk overlaps the MZ" do
          overlapping = LocalArea.create!(
            organization: @organization, kind: "komsiluk", slug: "k-overlap",
            name: { "sr" => "Overlap" },
            primary_mz_slug: nil, overlapping_mz_slugs: ["mz-res"]
          )
          stranded = FactoryBot.create(:user, :confirmed, organization: @organization)
          assign(stranded, overlapping)
          assert_nil CitizenProfile.for_user(stranded, organization: @organization).mz_id

          ids = MembershipResolver.for_mz(organization: @organization, mz_area: @mz).recipient_ids
          assert_equal [@c1.id, @c2.id, @c3.id, stranded.id].sort, ids.sort
        end

        # ── empty audience ───────────────────────────────────────────────────

        test "empty komsiluk resolves to an empty array" do
          empty_k = LocalArea.create!(
            organization: @organization, kind: "komsiluk", slug: "k-empty",
            name: { "sr" => "Empty" }, primary_mz_slug: "mz-res"
          )
          assert_empty resolver_for_komsiluk(empty_k).recipient_ids
        end

        private

        def assign(user, komsiluk, organization: @organization)
          CitizenProfile.for_user(user, organization:).assign_komsiluk!(komsiluk, source: "map")
        end

        def resolver_for_komsiluk(komsiluk)
          MembershipResolver.for_komsiluk(organization: @organization, komsiluk_id: komsiluk.id)
        end
      end
    end
  end
end
