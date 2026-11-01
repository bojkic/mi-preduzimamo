# frozen_string_literal: true

gem "minitest", "~> 5.0"
require "json"
require "digest"
require "minitest/autorun"

# Dependency audit 2026-10-21, Stage A item 3. Guards the lockfile against
# sliding back below the releases that fix the browser-side advisories, and
# against a blind `npm audit fix` moving the Decidim frontend off the gem's
# release (frontend and Ruby packages must move together).
# Reads package-lock.json only; never needs node_modules.
class FrontendDependencyFloorTest < Minitest::Test
  LOCK = File.expand_path("../../package-lock.json", __dir__)

  FLOORS = {
    "prosemirror-view" => "1.42.3", # GHSA-c8x8-7fp4-3x9w paste XSS in the rich-text editor
    # Four quadratic-time DoS advisories. Reaches browser packs by two paths: GraphiQL docs
    # (graphiql) and the rich-text editor (@tiptap/pm -> prosemirror-markdown).
    "markdown-it" => "14.3.3",
    "source-map-js" => "1.2.2" # GHSA-68fv-2mgg-jv7q (build time)
  }.freeze

  def setup
    @packages = JSON.parse(File.read(LOCK)).fetch("packages")
  end

  def test_advisory_fixes_stay_in_the_lock
    FLOORS.each do |name, floor|
      version = @packages.fetch("node_modules/#{name}").fetch("version")
      assert Gem::Version.new(version) >= Gem::Version.new(floor), "#{name} #{version} is below #{floor}"
    end
  end

  def test_decidim_frontend_stays_on_the_gem_release
    gemfile = File.read(File.expand_path("../../Gemfile", __dir__))
    decidim = gemfile[/^gem "decidim", "([^"]+)"/, 1]
    assert_equal decidim, @packages.fetch("node_modules/@decidim/core").fetch("version")

    tiptap = @packages.select { |path, _| path.start_with?("node_modules/@tiptap/") }
    assert_operator tiptap.size, :>, 0
    assert_equal ["3.32.2"], tiptap.values.map { |entry| entry.fetch("version") }.uniq,
                 "tiptap moves only with @decidim/core"
  end

  def test_browser_notices_match_the_locked_dependency_set
    root = File.expand_path("../..", __dir__)
    manifest = JSON.parse(File.read(File.join(root, "public/mi/licenses/browser-packages.json")))
    assert_equal Digest::SHA256.file(LOCK).hexdigest, manifest.fetch("npm_lock_sha256"),
                 "review browser licence notices after changing npm dependencies"
    notices = File.read(File.join(root, "public/mi/licenses/BROWSER_THIRD_PARTY_NOTICES.txt"))
    assert_operator manifest.fetch("packages").size, :>, 0
    manifest.fetch("packages").each do |package|
      locked = @packages.fetch(package.fetch("package_path"))
      assert_equal locked.fetch("version").delete_prefix("v"), package.fetch("version").delete_prefix("v"),
                   "notice version differs from package-lock for #{package.fetch("name")}"
      assert_includes notices, "#{package.fetch("name")} #{package.fetch("version")}"
    end
  end
end
