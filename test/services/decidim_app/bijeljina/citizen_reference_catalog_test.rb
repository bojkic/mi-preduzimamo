# frozen_string_literal: true

require "minitest/autorun"
require "active_support/all"
require "active_support/test_case"

# These reviewed-reference checks need neither Rails boot nor a database. Use
# the engine selected by Bundler, and the catalogue in this test's own checkout.
$LOAD_PATH.unshift(File.join(Gem.loaded_specs.fetch("decidim-bih").full_gem_path, "app/services"))
require "decidim/bih/text"
require_relative "../../../../app/services/decidim_app/bijeljina/citizen_reference_catalog"

require_relative "../../../support/synthetic_citizen_references"

class CitizenReferenceCatalogTest < ActiveSupport::TestCase
  Catalog = DecidimApp::Bijeljina::CitizenReferenceCatalog

  def setup
    @data = SyntheticCitizenReferences.data
    @catalog = Catalog.new(data: @data)
  end

  def test_all_six_domains_have_independently_identified_reviewed_atoms
    assert_equal %w(agriculture culture education employment health intercity_travel), @catalog.subjects.values.map { |row| row.fetch("domain") }.uniq.sort
    assert_equal 11, @data.fetch("facts").size
    @data.fetch("facts").each do |row|
      assert_equal "ready", @catalog.readiness(row, day: Date.new(2040, 9, 15)), row.fetch("id")
      assert_not_equal row.fetch("id"), row.fetch("subject_id")
      assert_not_nil @catalog.source_for(row).fetch("document_revision_sha256")
    end
  end

  def test_scripts_fold_to_the_same_subject_and_unrelated_services_do_not_match
    latin = @catalog.matching(topic: "transport", entities: { "query" => "Telefon Izmišljeni prevoz" })
    cyrillic = @catalog.matching(topic: "transport", entities: { "query" => "Телефон Измишљени превоз" })
    assert_equal latin, cyrillic
    assert_equal(["synthetic:intercity"], latin.map { |row| row.fetch("id") })
    assert_empty @catalog.matching(topic: "transport", entities: { "query" => "Kada vozi autobus 1?" })
    assert_empty @catalog.matching(topic: "health", entities: { "query" => "Telefon Doma zdravlja" })
    assert_empty @catalog.matching(topic: "health", entities: { "query" => "Radno vrijeme privatnog stomatologa" })
    assert_empty @catalog.matching(topic: "community", entities: { "query" => "Telefon Centar za kulturu" })
    assert_empty @catalog.matching(topic: "education", entities: { "query" => "Telefon osnovne skole" })
  end

  def test_revision_change_in_any_evidence_layer_revokes_answerability
    %w(facts documents sources subjects).each do |layer|
      data = Marshal.load(Marshal.dump(@data))
      data.fetch(layer).first["unreviewed_change"] = "changed"
      catalog = Catalog.new(data:)
      assert_equal "unreviewed", catalog.readiness(data.fetch("facts").first, day: Date.new(2040, 9, 15)), layer
    end
  end

  def test_revocation_and_both_expiry_clocks_are_enforced
    fuel = @data.fetch("facts").find { |row| row.fetch("id") == "agriculture:fuel-forms-window" }
    assert_equal "ready", @catalog.readiness(fuel, day: Date.new(2040, 11, 15))
    assert_equal "expired", @catalog.readiness(fuel, day: Date.new(2040, 11, 16))
    health = @data.fetch("facts").find { |row| row.fetch("id") == "health:dentistry-hours" }
    assert_equal "review_expired", @catalog.readiness(health, day: Date.new(2040, 10, 15))
    health["review_status"] = "revoked"
    assert_equal "revoked", @catalog.readiness(health, day: Date.new(2040, 9, 15))
  end

  def test_undated_publication_is_not_replaced_with_review_or_download_date
    doc = @data.fetch("documents").find { |row| row.fetch("id") == "health" }
    assert_nil doc.fetch("published_on")
    assert_equal "2040-09-15", doc.fetch("reviewed_on")
    primary = @data.fetch("documents").find { |row| row.fetch("id") == "primary" }
    assert_equal "2040-05-12", primary.fetch("published_on")
    assert_equal "response_bytes", primary.fetch("revision_basis")
  end

  def test_duplicate_identity_and_nonpublic_citation_fail_closed
    @data.fetch("facts") << @data.fetch("facts").first.dup
    assert_raises(Catalog::ReviewError) { Catalog.new(data: @data) }
    @data.fetch("facts").pop
    @data.fetch("documents").first["url"] = "http://example.com"
    assert_raises(Catalog::ReviewError) { Catalog.new(data: @data) }
  end
end
