# frozen_string_literal: true

require "test_helper"
require "yaml"

# Round 25 / Wave — locks in en.yml as the CANONICAL source for the
# `decidim.bih.*` i18n tree. A locale audit found en.yml was missing ~111 of
# the `decidim.bih.*` keys that the other locales already carried (the whole
# reports new/show/severities/errors subtrees, the concierge budget/gazette/
# komsiluk/service/waste/link subtrees, the MI-hub homepage tiles, and the
# komsiluk_post earning label). When en lacks a key, the English UI renders
# "translation missing" AND en can no longer serve as the validation baseline
# the other locales are checked against.
#
# This guard asserts that en's set of `decidim.bih.*` leaf key-paths is a
# SUPERSET of every other maintained locale (sr, sr-Cyrl, bs, hr): no locale
# may carry a `decidim.bih.*` leaf that en does not also define.
#
# Plural-category nuance: English has only the CLDR `one` / `other` plural
# categories, whereas Serbian/Bosnian/Croatian also use `few` (and sometimes
# `many`). So a locale legitimately owns `...count.few` / `...count.many`
# leaves that en cannot and should not have, PROVIDED en defines the matching
# `...count.other` leaf. Those are the only allowed exceptions; everything else
# missing from en is a real gap and fails the test.
#
# Files are read straight from the decidim-bih engine's working tree rather than
# from the runtime I18n backend, because Decidim prunes the runtime `:en`
# namespace to the configured app locales — so genuinely-present en keys can be
# absent from `I18n.backend` at runtime. The YAML on disk is the source of truth.
class DecidimBihLocaleParityTest < ActiveSupport::TestCase
  CANONICAL = "en"
  OTHER_LOCALES = %w(sr sr-Cyrl bs hr).freeze

  # CLDR plural categories English does not have. A `<base>.<cat>` leaf in
  # another locale is allowed to be absent from en when en defines `<base>.other`.
  PLURAL_ONLY_CATEGORIES = %w(few many zero two).freeze

  LOCALES_DIR = begin
    engine_dir = Gem.loaded_specs["decidim-bih"].gem_dir
    File.join(engine_dir, "config", "locales")
  end

  # Flatten a nested hash into dotted leaf key-paths.
  def self.leaf_paths(node, prefix = "")
    node.each_with_object([]) do |(key, value), acc|
      path = prefix.empty? ? key.to_s : "#{prefix}.#{key}"
      if value.is_a?(Hash)
        acc.concat(leaf_paths(value, path))
      else
        acc << path
      end
    end
  end

  # The `decidim.bih.*` leaf set for a locale, as a Set of dotted paths rooted
  # at "decidim.bih".
  def self.bih_leaves(locale)
    file = File.join(LOCALES_DIR, "#{locale}.yml")
    raise "Locale file not found: #{file}" unless File.exist?(file)

    root = YAML.load_file(file).fetch(locale)
    bih = root.dig("decidim", "bih")
    raise "#{locale}.yml has no decidim.bih subtree" if bih.nil?

    leaf_paths(bih, "decidim.bih").to_set
  end

  EN_LEAVES = bih_leaves(CANONICAL)

  test "en.yml defines a non-empty decidim.bih tree" do
    assert EN_LEAVES.size.positive?, "en.yml has no decidim.bih leaves — canonical baseline is empty"
  end

  OTHER_LOCALES.each do |locale|
    test "en.yml is a superset of #{locale}.yml for the decidim.bih tree" do
      locale_leaves = self.class.bih_leaves(locale)

      missing = locale_leaves.reject do |path|
        next true if EN_LEAVES.include?(path)

        # Allow plural-category leaves en cannot have, as long as en defines the
        # sibling `.other` for the same base.
        segments = path.split(".")
        category = segments.last
        next false unless PLURAL_ONLY_CATEGORIES.include?(category)

        sibling_other = (segments[0..-2] + ["other"]).join(".")
        EN_LEAVES.include?(sibling_other)
      end

      assert missing.empty?, <<~MSG
        #{locale}.yml has #{missing.size} decidim.bih leaf key-path(s) that en.yml (the canonical source) lacks.
        Backfill these into decidim-bih/config/locales/en.yml with proper ENGLISH translations:
        #{missing.sort.map { |k| "  - #{k}" }.join("\n")}
      MSG
    end
  end
end
