# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    # Tests for KomsilukBroadcast service — Wave B2 operator-initiated broadcast.
    class KomsilukBroadcastTest < ActiveSupport::TestCase
      include ActiveJob::TestHelper

      setup do
        @organization = create_organization
        @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)

        @mz = LocalArea.create!(
          organization: @organization,
          kind: "mz",
          slug: "mz-broadcast-test",
          name: { "sr" => "Centar MZ", "bs" => "Centar MZ", "hr" => "Centar MZ" }
        )
        # Decoupled model: komsiluci have primary_mz_slug instead of parent.
        @komsiluk1 = LocalArea.create!(
          organization: @organization,
          kind: "komsiluk",
          slug: "komsiluk-a",
          name: { "sr" => "Komšiluk A" },
          primary_mz_slug: "mz-broadcast-test"
        )
        @komsiluk2 = LocalArea.create!(
          organization: @organization,
          kind: "komsiluk",
          slug: "komsiluk-b",
          name: { "sr" => "Komšiluk B" },
          primary_mz_slug: "mz-broadcast-test"
        )

        @citizen1 = FactoryBot.create(:user, :confirmed, organization: @organization)
        @citizen2 = FactoryBot.create(:user, :confirmed, organization: @organization)
        @citizen3 = FactoryBot.create(:user, :confirmed, organization: @organization)

        # citizen1 → komsiluk1; citizen2 → komsiluk2; citizen3 → komsiluk1
        assign_komsiluk(@citizen1, @komsiluk1)
        assign_komsiluk(@citizen2, @komsiluk2)
        assign_komsiluk(@citizen3, @komsiluk1)
      end

      # ─── Recipient resolution: komsiluk-level ────────────────────────────────

      test "komsiluk broadcast resolves only citizens of that komsiluk" do
        result = perform_broadcast(area: @komsiluk1)

        assert_equal 2, result[:recipients_count]
        assert_equal 2, result[:broadcast].recipients_count
      end

      test "komsiluk broadcast does NOT include citizens of a sibling komsiluk" do
        result = perform_broadcast(area: @komsiluk1)

        # citizen2 is in komsiluk2 — verify she's excluded
        # The broadcast count must be 2 (citizen1 + citizen3 only).
        assert_equal 2, result[:recipients_count]
      end

      # ─── Recipient resolution: MZ-level ─────────────────────────────────────

      test "mz broadcast resolves all citizens across its komsiluci via mz_id" do
        result = perform_broadcast(area: @mz)

        assert_equal 3, result[:recipients_count]
      end

      # ─── MZ-level: overlapping komšiluk with nil mz_id (Komšiluk fix a) ──────

      test "mz broadcast includes a citizen with nil mz_id whose komsiluk overlaps the MZ" do
        # A komšiluk that geographically overlaps @mz (via overlapping_mz_slugs)
        # but whose primary_mz is unresolved, so assigned citizens get nil mz_id.
        overlapping_komsiluk = LocalArea.create!(
          organization: @organization,
          kind: "komsiluk",
          slug: "komsiluk-overlap",
          name: { "sr" => "Preklapajući komšiluk" },
          primary_mz_slug: nil,
          overlapping_mz_slugs: ["mz-broadcast-test"]
        )

        stranded = FactoryBot.create(:user, :confirmed, organization: @organization)
        assign_komsiluk(stranded, overlapping_komsiluk)

        # Sanity: this citizen has a nil mz_id (no primary_mz to resolve).
        profile = CitizenProfile.for_user(stranded, organization: @organization)
        assert_nil profile.mz_id, "precondition: stranded citizen must have nil mz_id"

        result = perform_broadcast(area: @mz)

        # citizen1, citizen2, citizen3 (mz_id set) + stranded (overlap) = 4.
        assert_equal 4, result[:recipients_count]
      end

      # ─── Exclusions ─────────────────────────────────────────────────────────

      test "blocked users are excluded from the broadcast" do
        @citizen1.update!(blocked: true)
        result = perform_broadcast(area: @komsiluk1)

        assert_equal 1, result[:recipients_count]
      end

      test "deleted users are excluded from the broadcast" do
        @citizen3.update!(deleted_at: Time.current, email: "deleted-#{Time.now.to_i}@example.invalid")
        result = perform_broadcast(area: @komsiluk1)

        assert_equal 1, result[:recipients_count]
      end

      test "unconfirmed users are excluded from the broadcast" do
        unconfirmed = FactoryBot.create(:user, organization: @organization, confirmed_at: nil)
        assign_komsiluk(unconfirmed, @komsiluk1)

        result = perform_broadcast(area: @komsiluk1)

        # Only confirmed citizen1 + citizen3; unconfirmed excluded.
        assert_equal 2, result[:recipients_count]
      end

      # ─── Opt-out is NOT honoured on the broadcast path (per-path difference) ──
      #
      # Characterization: an operator broadcast is a deliberate org-level message
      # and — unlike the urgent-post bell — does NOT respect the per-user
      # notification_settings["komsiluk_board"] opt-out. This pins the difference
      # that must survive sharing the MembershipResolver with the post service.
      test "broadcast ignores the komsiluk_board opt-out (opted-out users still receive it)" do
        @citizen1.update!(notification_settings: { "komsiluk_board" => false })

        result = perform_broadcast(area: @komsiluk1)

        # Both komsiluk1 citizens still counted despite citizen1 opting out.
        assert_equal 2, result[:recipients_count]
      end

      # ─── Author / sender is NOT excluded on the broadcast path ───────────────
      #
      # Characterization: the broadcast does not exclude its sender. If the
      # operator happens to be an assigned citizen of the area they still receive
      # the bell (the post path, by contrast, excludes the author).
      test "broadcast does not exclude the sender even if they belong to the area" do
        assign_komsiluk(@admin, @komsiluk1)

        result = perform_broadcast(area: @komsiluk1)

        # citizen1 + citizen3 + admin = 3.
        assert_equal 3, result[:recipients_count]
      end

      test "users from a different organization are never included" do
        other_org = create_organization
        other_citizen = FactoryBot.create(:user, :confirmed, organization: other_org)
        LocalArea.create!(
          organization: other_org,
          kind: "mz",
          slug: "mz-other",
          name: { "sr" => "Other MZ" }
        )
        other_komsiluk = LocalArea.create!(
          organization: other_org,
          kind: "komsiluk",
          slug: "komsiluk-other",
          name: { "sr" => "Other K" }
        )
        assign_komsiluk(other_citizen, other_komsiluk)

        result = perform_broadcast(area: @komsiluk1)

        assert_equal 2, result[:recipients_count]
      end

      # ─── Empty area ─────────────────────────────────────────────────────────

      test "empty area (no assigned citizens) sends nothing and reports 0" do
        empty_komsiluk = LocalArea.create!(
          organization: @organization,
          kind: "komsiluk",
          slug: "komsiluk-empty",
          name: { "sr" => "Prazni komšiluk" },
          primary_mz_slug: "mz-broadcast-test"
        )

        result = nil
        assert_enqueued_jobs 0, only: BroadcastNotificationJob do
          result = perform_broadcast(area: empty_komsiluk)
        end

        assert_equal 0, result[:recipients_count]
        assert_equal 0, result[:broadcast].recipients_count
      end

      # ─── Broadcast audit record ─────────────────────────────────────────────

      test "creates a Broadcast record with the correct attributes" do
        assert_difference("Broadcast.count", 1) do
          perform_broadcast(area: @komsiluk1, message: "Test poruka")
        end

        bc = Broadcast.last
        assert_equal @organization.id, bc.decidim_organization_id
        assert_equal @komsiluk1.id, bc.local_area_id
        assert_equal @admin.id, bc.sent_by_id
        assert_equal "Test poruka", bc.message
        assert_equal "bell", bc.channels
        assert_equal 2, bc.recipients_count
      end

      test "preview returns only aggregate count without audit record or jobs" do
        result = nil

        assert_no_difference("Broadcast.count") do
          assert_enqueued_jobs 0, only: BroadcastNotificationJob do
            result = KomsilukBroadcast.preview(
              organization: @organization,
              area: @komsiluk1,
              message: "Pregled poruke",
              channels: ["bell"],
              sent_by: @admin
            )
          end
        end

        assert_equal 2, result[:recipients_count]
        assert_nil result[:broadcast]
        assert_nil result[:user_ids]
        assert_nil result[:recipients]
      end

      test "broadcast with viber channel stores bell,viber" do
        perform_broadcast(area: @komsiluk1, channels: %w(bell viber))

        bc = Broadcast.last
        assert_includes bc.channels_list, "bell"
        assert_includes bc.channels_list, "viber"
      end

      # ─── Chunking ────────────────────────────────────────────────────────────

      test "fans out in chunks of 50 or fewer" do
        # Create 101 citizens each in komsiluk1.
        101.times do
          c = FactoryBot.create(:user, :confirmed, organization: @organization)
          assign_komsiluk(c, @komsiluk1)
        end
        # Plus citizen1 and citizen3 already there = 103 total.

        jobs_enqueued = []
        BroadcastNotificationJob.stub(:perform_later, ->(**kwargs) { jobs_enqueued << kwargs }) do
          perform_broadcast(area: @komsiluk1)
        end

        # 103 citizens / 50 = 3 chunks (50 + 50 + 3).
        assert_equal 3, jobs_enqueued.size
        chunk_sizes = jobs_enqueued.map { |j| j[:user_ids].size }
        assert(chunk_sizes.all? { |s| s <= 50 })
        assert_equal 103, chunk_sizes.sum
      end

      # ─── Privacy ─────────────────────────────────────────────────────────────

      test "call returns only the count, never the recipient id list" do
        result = perform_broadcast(area: @komsiluk1)

        assert result.has_key?(:broadcast)
        assert result.has_key?(:recipients_count)
        # The result hash must NOT contain a list of user ids.
        assert_nil result[:user_ids]
        assert_nil result[:recipients]
      end

      private

      def assign_komsiluk(user, komsiluk)
        CitizenProfile.for_user(user, organization: user.organization).assign_komsiluk!(komsiluk, source: "map")
      end

      def perform_broadcast(area:, message: "Obavještenje za komšiluk", channels: ["bell"])
        KomsilukBroadcast.call(
          organization: @organization,
          area:,
          message:,
          channels:,
          sent_by: @admin
        )
      end
    end
  end
end
