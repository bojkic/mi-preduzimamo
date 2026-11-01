# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    class LocalAreaTest < ActiveSupport::TestCase
      setup do
        @organization = create_organization
      end

      # ─── Kind validation ────────────────────────────────────────────────────

      test "valid MZ area" do
        mz = LocalArea.new(
          organization: @organization,
          kind: "mz",
          slug: "mz-test",
          name: { "sr" => "Test MZ" }
        )
        assert mz.valid?, mz.errors.full_messages.inspect
      end

      test "valid komsiluk area without parent (decoupled model)" do
        komsiluk = LocalArea.new(
          organization: @organization,
          kind: "komsiluk",
          slug: "komsiluk-standalone",
          name: { "sr" => "Standalone Komšiluk" }
        )
        assert komsiluk.valid?, komsiluk.errors.full_messages.inspect
      end

      test "rejects unknown kind" do
        area = LocalArea.new(
          organization: @organization,
          kind: "district",
          slug: "test",
          name: { "sr" => "X" }
        )
        assert_not area.valid?
        assert_includes area.errors[:kind], I18n.t("errors.messages.inclusion")
      end

      test "komsiluk does not require a parent MZ (decoupled)" do
        area = LocalArea.new(
          organization: @organization,
          kind: "komsiluk",
          slug: "orphan",
          name: { "sr" => "Orphan" }
        )
        assert area.valid?, "komsiluk should be valid without a parent in the decoupled model"
      end

      test "MZ can optionally have a parent (no validation prevents it)" do
        mz1 = LocalArea.create!(organization: @organization, kind: "mz", slug: "mz-1", name: { "sr" => "MZ 1" })
        mz2 = LocalArea.new(
          organization: @organization,
          kind: "mz",
          slug: "mz-2",
          name: { "sr" => "MZ 2" },
          parent: mz1
        )
        # The mz_must_not_have_parent validation has been removed; parent is optional.
        assert mz2.valid?, "MZ should be saveable with a parent (column exists, no longer forbidden)"
      end

      # ─── Scopes ─────────────────────────────────────────────────────────────

      test ".mz scope returns only mz records" do
        mz = LocalArea.create!(organization: @organization, kind: "mz", slug: "mz-scope", name: { "sr" => "MZ" })
        k = LocalArea.create!(organization: @organization, kind: "komsiluk", slug: "k-scope", name: { "sr" => "K" })

        assert_includes LocalArea.mz, mz
        assert_not_includes LocalArea.mz, k
      end

      test ".komsiluci scope returns only komsiluk records" do
        mz = LocalArea.create!(organization: @organization, kind: "mz", slug: "mz-scope2", name: { "sr" => "MZ" })
        k = LocalArea.create!(organization: @organization, kind: "komsiluk", slug: "k-scope2", name: { "sr" => "K" })

        assert_includes LocalArea.komsiluci, k
        assert_not_includes LocalArea.komsiluci, mz
      end

      # ─── Unique slug constraint ──────────────────────────────────────────────

      test "slug unique per organization" do
        LocalArea.create!(organization: @organization, kind: "mz", slug: "slug-dup", name: { "sr" => "First" })
        dupe = LocalArea.new(organization: @organization, kind: "mz", slug: "slug-dup", name: { "sr" => "Second" })

        assert_raises(ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique) { dupe.save! }
      end

      # ─── MZ-facing fields ────────────────────────────────────────────────────

      test "MZ stores predsjednik and telefon" do
        mz = LocalArea.create!(
          organization: @organization,
          kind: "mz",
          slug: "mz-predsjednik",
          name: { "sr" => "Test MZ" },
          predsjednik: "Petar Petrović",
          telefon: "+387 55 123 456"
        )
        mz.reload
        assert_equal "Petar Petrović", mz.predsjednik
        assert_equal "+387 55 123 456", mz.telefon
      end

      test "MZ stores metadata as a jsonb hash" do
        mz = LocalArea.create!(
          organization: @organization,
          kind: "mz",
          slug: "mz-metadata",
          name: { "sr" => "MZ Meta" },
          metadata: { "povrsina_m2" => 12_000, "izvor" => "Sl.glasnik 22/18" }
        )
        mz.reload
        assert_equal 12_000, mz.metadata["povrsina_m2"]
        assert_equal "Sl.glasnik 22/18", mz.metadata["izvor"]
      end

      test "metadata defaults to empty hash" do
        mz = LocalArea.create!(
          organization: @organization,
          kind: "mz",
          slug: "mz-no-meta",
          name: { "sr" => "MZ No Meta" }
        )
        assert_equal({}, mz.reload.metadata)
      end

      # ─── Komšiluk-facing relation fields ────────────────────────────────────

      test "primary_mz_slug and overlapping_mz_slugs default to nil/[]" do
        k = LocalArea.create!(
          organization: @organization,
          kind: "komsiluk",
          slug: "k-defaults",
          name: { "sr" => "K" }
        )
        k.reload
        assert_nil k.primary_mz_slug
        assert_equal [], k.overlapping_mz_slugs
      end

      test "primary_mz returns the LocalArea for primary_mz_slug" do
        mz = LocalArea.create!(
          organization: @organization,
          kind: "mz",
          slug: "mz-primary",
          name: { "sr" => "Primary MZ" }
        )
        k = LocalArea.create!(
          organization: @organization,
          kind: "komsiluk",
          slug: "k-primary",
          name: { "sr" => "K" },
          primary_mz_slug: "mz-primary"
        )
        assert_equal mz, k.primary_mz
      end

      test "primary_mz returns nil when slug is blank" do
        k = LocalArea.create!(
          organization: @organization,
          kind: "komsiluk",
          slug: "k-no-primary",
          name: { "sr" => "K" }
        )
        assert_nil k.primary_mz
      end

      test "overlapping_mz returns LocalArea records for all slugs" do
        mz1 = LocalArea.create!(organization: @organization, kind: "mz", slug: "mz-ov1", name: { "sr" => "MZ 1" })
        mz2 = LocalArea.create!(organization: @organization, kind: "mz", slug: "mz-ov2", name: { "sr" => "MZ 2" })
        k = LocalArea.create!(
          organization: @organization,
          kind: "komsiluk",
          slug: "k-overlapping",
          name: { "sr" => "K" },
          overlapping_mz_slugs: %w(mz-ov1 mz-ov2)
        )
        result = k.overlapping_mz.to_a
        assert_includes result, mz1
        assert_includes result, mz2
      end

      test "overlapping_mz returns empty when no slugs set" do
        k = LocalArea.create!(
          organization: @organization,
          kind: "komsiluk",
          slug: "k-empty-overlap",
          name: { "sr" => "K" }
        )
        assert_equal [], k.overlapping_mz.to_a
      end

      # ─── translated_name ────────────────────────────────────────────────────

      test "translated_name returns current locale value" do
        area = LocalArea.create!(
          organization: @organization,
          kind: "mz",
          slug: "mz-translated",
          name: { "sr" => "Centar", "en" => "Centre" }
        )
        I18n.with_locale(:sr) { assert_equal "Centar", area.translated_name }
        I18n.with_locale(:en) { assert_equal "Centre", area.translated_name }
      end

      test "translated_name falls back to first available translation" do
        area = LocalArea.create!(
          organization: @organization,
          kind: "mz",
          slug: "mz-fallback",
          name: { "sr" => "Samo srpski" }
        )
        I18n.with_locale(:en) { assert_equal "Samo srpski", area.translated_name }
      end
    end
  end
end
