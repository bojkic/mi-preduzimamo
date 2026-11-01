# frozen_string_literal: true
require "test_helper"

class PublicCatalogDefaultsTest < ActiveSupport::TestCase
  Catalog = DecidimApp::Bijeljina::CitizenReferenceCatalog
  Places = DecidimApp::Bijeljina::PlaceAliasRegistry
  Coverage = DecidimApp::Bijeljina::CityServiceSettlementCoverage

  def with_constant(owner, name, value)
    original = owner.const_get(name)
    owner.send(:remove_const, name)
    owner.const_set(name, value)
    yield
  ensure
    owner.send(:remove_const, name)
    owner.const_set(name, original)
  end

  def test_unconfigured_catalog_and_registry_do_not_invent_local_facts
    catalog = Catalog.new
    assert_empty catalog.subjects
    assert_empty catalog.matching(topic: :health, entities: { "query" => "klinika" })
    registry = Places.new(areas: [])
    assert_equal "unconfigured", registry.revision
    assert_equal :unknown, registry.resolve(query: "Izmišljeno mjesto").status
    assert_empty registry.send(:transport_entries)
    assert_empty Coverage.new(organization: nil, areas: []).match(clause: "Izmišljeno mjesto")
  end

  def test_registry_uses_only_the_community_area_supplied_by_the_caller
    area = Struct.new(:slug, :kind, :translated_name, :name).new("mz-test", "mz", "MZ Izmišljeni vrt", { "sr" => "MZ Izmišljeni vrt" })
    resolution = Places.new(areas: [area]).resolve(query: "Izmišljeni vrt")
    assert_equal :ok, resolution.status
    assert_equal ["mz-test"], resolution.places.map(&:id)
    assert_equal "local_area_registry", resolution.places.first.source
  end

  def test_explicit_missing_paths_fail_instead_of_becoming_silently_empty
    Dir.mktmpdir("public-catalog-") do |directory|
      missing = File.join(directory, "missing.yml")
      with_constant(Catalog, :PATH, missing) { assert_raises(Errno::ENOENT) { Catalog.new } }
      with_constant(Places, :CONFIG_PATH, missing) { assert_raises(Errno::ENOENT) { Places.new(areas: []) } }
      with_constant(Coverage, :DATA_PATH, missing) { assert_raises(Errno::ENOENT) { Coverage.new(organization: nil, areas: []) } }
      with_constant(Coverage, :ALIASES_PATH, missing) { assert_raises(Errno::ENOENT) { Coverage.new(organization: nil, areas: []) } }
    end
  end

  def test_invalid_catalog_version_is_rejected
    assert_raises(Catalog::ReviewError) { Catalog.new(data: { "version" => 99 }) }
  end
end
