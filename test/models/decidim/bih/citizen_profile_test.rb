# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    class CitizenProfileTest < ActiveSupport::TestCase
      setup do
        @organization = create_organization
        @user = FactoryBot.create(:user, :confirmed, organization: @organization)
        @mz = LocalArea.create!(
          organization: @organization,
          kind: "mz",
          slug: "mz-test-cp",
          name: { "sr" => "Test MZ" }
        )
        # Decoupled model: komšiluk has no parent
        @komsiluk = LocalArea.create!(
          organization: @organization,
          kind: "komsiluk",
          slug: "komsiluk-test-cp",
          name: { "sr" => "Test Komšiluk" },
          primary_mz_slug: "mz-test-cp"
        )
      end

      # ─── for_user (lazy find-or-create) ─────────────────────────────────────

      test "for_user creates a new profile if absent" do
        assert_difference("CitizenProfile.count", 1) do
          CitizenProfile.for_user(@user, organization: @organization)
        end
      end

      test "for_user returns existing profile on second call" do
        profile = CitizenProfile.for_user(@user, organization: @organization)
        assert_no_difference("CitizenProfile.count") do
          assert_equal profile, CitizenProfile.for_user(@user, organization: @organization)
        end
      end

      # ─── uniqueness ─────────────────────────────────────────────────────────

      test "unique per user per organization" do
        CitizenProfile.create!(
          organization: @organization,
          user: @user
        )
        dupe = CitizenProfile.new(organization: @organization, user: @user)
        assert_raises(ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique) { dupe.save! }
      end

      # ─── assign_komsiluk! with explicit mz (point-resolved) ─────────────────

      test "assign_komsiluk! with explicit mz stores both komsiluk_id and mz_id" do
        profile = CitizenProfile.for_user(@user, organization: @organization)
        profile.assign_komsiluk!(@komsiluk, source: "map", resolved_mz: @mz)

        profile.reload
        assert_equal @komsiluk.id, profile.komsiluk_id
        assert_equal @mz.id, profile.mz_id
        assert_equal "map", profile.source
        assert_not_nil profile.assigned_at
      end

      test "assign_komsiluk! with explicit mz from point is NOT komsiluk.primary_mz" do
        # Point-resolved MZ may differ from primary_mz_slug; explicit wins.
        other_mz = LocalArea.create!(
          organization: @organization,
          kind: "mz",
          slug: "mz-point-resolved",
          name: { "sr" => "Point MZ" }
        )
        profile = CitizenProfile.for_user(@user, organization: @organization)
        profile.assign_komsiluk!(@komsiluk, source: "address", resolved_mz: other_mz)

        profile.reload
        assert_equal other_mz.id, profile.mz_id
      end

      # ─── assign_komsiluk! without point (dropdown) → falls back to primary_mz ─

      test "assign_komsiluk! without mz falls back to primary_mz (dropdown)" do
        profile = CitizenProfile.for_user(@user, organization: @organization)
        profile.assign_komsiluk!(@komsiluk, source: "dropdown")

        profile.reload
        assert_equal @komsiluk.id, profile.komsiluk_id
        assert_equal @mz.id, profile.mz_id # derived from primary_mz_slug
        assert_equal "dropdown", profile.source
      end

      test "assign_komsiluk! without mz and no primary_mz stores mz_id as nil" do
        komsiluk_no_mz = LocalArea.create!(
          organization: @organization,
          kind: "komsiluk",
          slug: "komsiluk-no-mz",
          name: { "sr" => "No Primary MZ" }
          # primary_mz_slug is nil
        )
        profile = CitizenProfile.for_user(@user, organization: @organization)
        profile.assign_komsiluk!(komsiluk_no_mz, source: "dropdown")

        profile.reload
        assert_equal komsiluk_no_mz.id, profile.komsiluk_id
        assert_nil profile.mz_id
      end

      test "assign_komsiluk! is idempotent (re-assignable)" do
        profile = CitizenProfile.for_user(@user, organization: @organization)
        profile.assign_komsiluk!(@komsiluk, source: "map", resolved_mz: @mz)
        profile.assign_komsiluk!(@komsiluk, source: "dropdown")

        profile.reload
        assert_equal "dropdown", profile.source
        assert_equal @komsiluk.id, profile.komsiluk_id
      end

      test "assign_komsiluk! rejects an MZ as the area" do
        profile = CitizenProfile.for_user(@user, organization: @organization)
        assert_raises(ArgumentError) { profile.assign_komsiluk!(@mz, source: "map") }
      end

      # ─── mz_id is point-resolved, never from komsiluk.parent ────────────────

      test "mz_id is point-resolved (explicit), not derived from parent_id" do
        profile = CitizenProfile.for_user(@user, organization: @organization)
        profile.assign_komsiluk!(@komsiluk, source: "map", resolved_mz: @mz)
        # The komsiluk has no parent — mz_id comes from the explicit argument.
        assert_nil @komsiluk.parent_id
        assert_equal @mz.id, profile.reload.mz_id
      end

      # ─── assigned? ──────────────────────────────────────────────────────────

      test "assigned? returns false when no komsiluk set" do
        profile = CitizenProfile.for_user(@user, organization: @organization)
        assert_not profile.assigned?
      end

      test "assigned? returns true after assignment" do
        profile = CitizenProfile.for_user(@user, organization: @organization)
        profile.assign_komsiluk!(@komsiluk, source: "map", resolved_mz: @mz)
        assert profile.reload.assigned?
      end

      # ─── on_delete :nullify for user FK ─────────────────────────────────────

      test "deleting a user nullifies decidim_user_id but keeps the profile row" do
        profile = CitizenProfile.for_user(@user, organization: @organization)
        profile.assign_komsiluk!(@komsiluk, source: "map", resolved_mz: @mz)
        profile_id = profile.id

        @user.destroy!

        profile = CitizenProfile.find(profile_id)
        assert_nil profile.decidim_user_id
        assert_equal @komsiluk.id, profile.komsiluk_id # area data retained
      end

      # ─── Privacy: NEVER in public profile or extended_data ──────────────────

      test "CitizenProfile data does not appear in the user's extended_data" do
        profile = CitizenProfile.for_user(@user, organization: @organization)
        profile.assign_komsiluk!(@komsiluk, source: "map", resolved_mz: @mz)

        @user.reload
        extended = @user.extended_data || {}
        assert_nil extended["komsiluk_id"]
        assert_nil extended["mz_id"]
        assert_nil extended["komsiluk"]
        # Ensure no komsiluk keys leaked anywhere in extended_data
        flat_keys = extended.keys.map(&:to_s)
        assert_empty(flat_keys.select { |k| k.include?("komsiluk") || k.include?("mz_id") })
      end

      test "source validation only accepts known values" do
        profile = CitizenProfile.for_user(@user, organization: @organization)
        profile.source = "hacked"
        assert_not profile.valid?
        assert profile.errors[:source].present?
      end

      test "source nil is allowed (profile created before assignment)" do
        profile = CitizenProfile.for_user(@user, organization: @organization)
        profile.source = nil
        assert profile.valid?
      end

      # ─── Citizen address is NEVER stored ────────────────────────────────────

      test "citizen_profiles table has no address column" do
        assert_not CitizenProfile.column_names.include?("address"),
                   "CitizenProfile must never store a citizen address"
      end
    end
  end
end
