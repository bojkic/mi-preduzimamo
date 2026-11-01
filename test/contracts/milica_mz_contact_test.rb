# frozen_string_literal: true

require_relative "milica_neighborhood_read_test"
require "action_controller"
require File.join(Gem.loaded_specs.fetch("decidim-bih").full_gem_path, "lib/decidim/bih/transliterator")

unless Decidim::Bih.respond_to?(:public_path)
  Decidim::Bih.define_singleton_method(:public_path) { |path| "/biceriseno/#{path}" }
  Minitest.after_run { Decidim::Bih.singleton_class.remove_method(:public_path) }
end

# Reuse the existing actual ReadPort authorization fixture; run the mz_contact
# cases only. No production users, profiles, contact data or writes are involved.
class MilicaNeighborhoodReadTest
  ContactArea = Data.define(:id, :kind, :slug, :decidim_organization_id, :name, :predsjednik, :telefon)

  def mz_contact_setup
    I18n.load_path += Dir[File.join(Gem.loaded_specs.fetch("decidim-bih").full_gem_path, "config/locales/decidim_bih_dialogue*.yml")]
    I18n.backend.reload!
    ContactArea.new(81, "mz", "mz-synthetic", 71, { "sr" => "Synthetic MZ" }, "Synthetic Official", "000 / public fixture")
  end

  def test_mz_contact_uses_independent_trusted_profile_mz_not_komsiluk
    area = mz_contact_setup
    profile = Data.define(:mz, :komsiluk).new(area, @profile.komsiluk)
    @profile = profile
    result = read(entities: { "query" => "ko je predsjednik moje MZ" })
    assert_equal "ok", result.status
    assert_equal ["mz-synthetic"], result.coverage.fetch("area_slugs")
    assert_includes result.facts.first.fetch("text"), "Synthetic Official"
    refute_includes result.facts.first.fetch("text"), "000 /"
    assert_empty @board_calls
    assert_equal [{ decidim_organization_id: 71, decidim_user_id: 17 }], @profile_calls
  end

  def test_mz_contact_explicit_public_area_needs_no_user_or_profile
    area = mz_contact_setup
    @resolution = Resolution.new(:ok, [area], :explicit_name, nil)
    result = read(entities: { "query" => "ko je predsjednik MZ Synthetic", "area_query" => "Synthetic" }, actor_id: nil, capabilities: ["public_reads"])
    assert_equal "ok", result.status
    assert_includes result.facts.first.fetch("destination"), "/mjesne-zajednice/mz-synthetic"
    assert_empty @profile_calls
    assert_empty @board_calls
  end

  def test_mz_contact_unknown_or_foreign_profile_never_leaks_contacts
    area = mz_contact_setup
    @profile = Data.define(:mz).new(area.with(decidim_organization_id: 72))
    result = read(entities: { "query" => "ko je predsjednik moje MZ" })
    assert_equal "ambiguous", result.status
    assert_empty result.facts
    @profile_calls.clear
    result = read(entities: { "query" => "ko je predsjednik moje MZ" }, actor_id: nil, capabilities: ["public_reads"])
    assert_equal "ambiguous", result.status
    assert_empty result.facts
    assert_empty @profile_calls
  end
end
