# frozen_string_literal: true

require "test_helper"
require "rake"
require "tempfile"

# Tests the rake task decidim_bih:komsiluk:import_flat — the NON-POLYGON
# fallback that lets operators stand up komšiluci from a simple flat list
# (one komšiluk per line, or a JSON array) with NO boundary geometry, so
# citizens can join a komšiluk via the dropdown picker before the real
# GeoJSON polygons arrive.
#
# Mirrors the style of test/tasks/komsiluk_import_test.rb: loads rake tasks
# once globally (guarded on a task name), captures rake stdout, and verifies
# idempotent upsert-by-slug behaviour and tenant scoping.
module Tasks
  class KomsilukImportFlatTest < ActiveSupport::TestCase
    # Load rake tasks once GLOBALLY. Guarding on a per-class ivar is not enough:
    # another test file may have already called Rails.application.load_tasks, and
    # loading a second time re-registers every task's action block. Guard on a
    # task name.
    def self.load_tasks
      return if Rake::Task.task_defined?("decidim_bih:komsiluk:import_flat")

      Rails.application.load_tasks
    end

    setup do
      self.class.load_tasks
      @organization = create_organization
    end

    teardown do
      Rake::Task["decidim_bih:komsiluk:import_flat"].reenable
    end

    # ── Helpers ───────────────────────────────────────────────────────────────

    # Write `content` to a tempfile with the given extension and yield its path.
    def with_file(content, ext: ".txt")
      file = Tempfile.new(["komsiluci_flat", ext])
      file.write(content)
      file.flush
      yield file.path
    ensure
      file&.close!
    end

    def invoke(path)
      capture_io { Rake::Task["decidim_bih:komsiluk:import_flat"].invoke(path, @organization.host) }
    end

    def reinvoke(path)
      Rake::Task["decidim_bih:komsiluk:import_flat"].reenable
      invoke(path)
    end

    # ── Plain-text list import ──────────────────────────────────────────────────

    test "imports komsiluci from a one-per-line text file with NO boundary" do
      content = <<~TXT
        Centar Sjever
        Galac
        Ledinci
      TXT

      with_file(content) do |path|
        assert_difference("Decidim::Bih::LocalArea.count", 3) do
          invoke(path)
        end
      end

      areas = Decidim::Bih::LocalArea.where(decidim_organization_id: @organization.id, kind: "komsiluk")
      assert_equal 3, areas.count
      areas.each do |k|
        assert_equal "komsiluk", k.kind
        assert_nil k.boundary, "#{k.slug} must have NO boundary (flat import)"
      end
    end

    test "text import slugifies the name and sets all locale names" do
      with_file("Centar Sjever\n") do |path|
        invoke(path)
      end

      k = Decidim::Bih::LocalArea.find_by(decidim_organization_id: @organization.id, slug: "centar-sjever")
      assert_not_nil k
      assert_equal "komsiluk", k.kind
      assert_equal "Centar Sjever", k.name["sr"]
      assert_equal "Centar Sjever", k.name["bs"]
      assert_equal "Centar Sjever", k.name["hr"]
      assert_equal "Centar Sjever", k.name["en"]
    end

    test "text import transliterates South-Slavic diacritics in the slug" do
      with_file("Čaršija\n") do |path|
        invoke(path)
      end

      k = Decidim::Bih::LocalArea.find_by(decidim_organization_id: @organization.id, slug: "carsija")
      assert_not_nil k, "expected diacritics to be transliterated in slug"
      assert_equal "Čaršija", k.name["sr"], "display name keeps diacritics"
    end

    test "text import ignores blank lines and comment lines" do
      content = <<~TXT
        # This is a comment
        Centar Sjever

        Galac
      TXT

      with_file(content) do |path|
        assert_difference("Decidim::Bih::LocalArea.count", 2) do
          invoke(path)
        end
      end
    end

    # ── Optional primary MZ slug (pipe-delimited) ───────────────────────────────

    test "text import accepts an optional primary MZ slug after a pipe" do
      # Seed an MZ the komšiluk can soft-point to.
      Decidim::Bih::LocalArea.create!(
        organization: @organization, kind: "mz", slug: "mz-centar",
        name: { "sr" => "Centar" }
      )

      with_file("Centar Sjever | mz-centar\n") do |path|
        invoke(path)
      end

      k = Decidim::Bih::LocalArea.find_by(decidim_organization_id: @organization.id, slug: "centar-sjever")
      assert_not_nil k
      assert_equal "mz-centar", k.primary_mz_slug
      assert_equal "mz-centar", k.primary_mz&.slug, "primary_mz resolves the soft pointer"
    end

    # ── JSON array import ───────────────────────────────────────────────────────

    test "imports komsiluci from a JSON array of objects" do
      json = [
        { "name" => "Centar Sjever", "primary_mz_slug" => "mz-centar" },
        { "name" => "Galac" }
      ].to_json

      with_file(json, ext: ".json") do |path|
        assert_difference("Decidim::Bih::LocalArea.count", 2) do
          invoke(path)
        end
      end

      cs = Decidim::Bih::LocalArea.find_by(decidim_organization_id: @organization.id, slug: "centar-sjever")
      assert_equal "mz-centar", cs.primary_mz_slug
      assert_nil cs.boundary

      galac = Decidim::Bih::LocalArea.find_by(decidim_organization_id: @organization.id, slug: "galac")
      assert_nil galac.primary_mz_slug
    end

    test "imports komsiluci from a JSON array of plain strings" do
      json = ["Centar Sjever", "Galac"].to_json

      with_file(json, ext: ".json") do |path|
        assert_difference("Decidim::Bih::LocalArea.count", 2) do
          invoke(path)
        end
      end
    end

    test "JSON import accepts an explicit slug override" do
      json = [{ "name" => "Centar Sjever", "slug" => "cs-custom" }].to_json

      with_file(json, ext: ".json") do |path|
        invoke(path)
      end

      k = Decidim::Bih::LocalArea.find_by(decidim_organization_id: @organization.id, slug: "cs-custom")
      assert_not_nil k
      assert_equal "Centar Sjever", k.name["sr"]
    end

    # ── Idempotency ─────────────────────────────────────────────────────────────

    test "re-running the flat import is idempotent (upsert by slug)" do
      with_file("Centar Sjever\nGalac\n") do |path|
        invoke(path)

        assert_no_difference("Decidim::Bih::LocalArea.count") do
          reinvoke(path)
        end
      end
    end

    test "re-import updates the display name in place without duplicating" do
      Decidim::Bih::LocalArea.create!(
        organization: @organization, kind: "komsiluk", slug: "centar-sjever",
        name: { "sr" => "Old Name" }
      )

      # A name that slugifies to the same slug but carries a new display string.
      with_file("Centar  Sjever\n") do |path|
        assert_no_difference("Decidim::Bih::LocalArea.count") do
          invoke(path)
        end
      end

      k = Decidim::Bih::LocalArea.find_by(decidim_organization_id: @organization.id, slug: "centar-sjever")
      assert_equal "Centar Sjever", k.name["sr"]
    end

    test "re-import does NOT clobber a boundary set later by a real GeoJSON import" do
      # Operator first stands up a flat (boundary-less) komšiluk, later the real
      # polygon arrives via the geo importer. A subsequent flat re-run must not
      # wipe the boundary back to nil.
      with_file("Centar Sjever\n") do |path|
        invoke(path)
      end

      k = Decidim::Bih::LocalArea.find_by(decidim_organization_id: @organization.id, slug: "centar-sjever")
      boundary = { "type" => "Polygon", "coordinates" => [[[19.21, 44.75], [19.22, 44.75], [19.22, 44.76], [19.21, 44.75]]] }
      k.update!(boundary: boundary)

      with_file("Centar Sjever\n") do |path|
        reinvoke(path)
      end

      assert_equal boundary, k.reload.boundary, "flat re-import must preserve an existing boundary"
    end

    # ── Tenant scoping ──────────────────────────────────────────────────────────

    test "import is scoped to the supplied organization" do
      other_org = create_organization

      with_file("Centar Sjever\n") do |path|
        invoke(path)
      end

      assert_equal 0, Decidim::Bih::LocalArea.where(decidim_organization_id: other_org.id).count
      assert_equal 1, Decidim::Bih::LocalArea.where(decidim_organization_id: @organization.id).count
    end
  end
end
