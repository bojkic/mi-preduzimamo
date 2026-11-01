# frozen_string_literal: true

require "bundler/setup"
require "minitest/autorun"
require "active_support"
require "active_support/core_ext/object/blank"
require "active_support/core_ext/enumerable"
require File.join(Gem.loaded_specs.fetch("decidim-bih").full_gem_path, "app/services/decidim/bih/text")
require_relative "../../app/services/decidim_app/bijeljina/city_service_area_crosswalk"

class MilicaServicePlaceCrosswalkTest < Minitest::Test
  Event = Struct.new(:source_key, :source_url, :extraction_metadata, :affected_text, :content_version, keyword_init: true)

  def setup
    @event = Event.new(source_key: "electricity_outages", source_url: "https://elektrobijeljina.com/lt/podrska/iskljucenja/index.php?rj=41",
                       extraction_metadata: { "tj" => "Bijeljina", "source_snapshot_complete" => true }, content_version: "public-v1")
    matcher = Object.new
    matcher.define_singleton_method(:resolve) do |area_slug:, place_kind:|
      raise unless place_kind == "mz" && area_slug.start_with?("mz-")

      Struct.new(:status).new(:ok)
    end
    citation = ->(source, item) { { "source" => source, "item" => item } }
    @authored_config = {
      "sources" => { "authored_street_decision" => "https://community.example.invalid/authored-streets",
        "authored_mz_decision" => "https://community.example.invalid/authored-areas" },
      "places" => [
        { "aliases" => ["vrt"], "mz_slug" => "mz-vrt", "kind" => "settlement", "citations" => [citation.call("authored_mz_decision", "8")] },
        { "aliases" => ["jasen", "donji lugovi", "gornji lugovi"], "mz_slug" => "mz-lugovi", "kind" => "settlement",
          "citations" => [citation.call("authored_street_decision", "21"), citation.call("authored_mz_decision", "8")] },
        { "aliases" => ["ravni gaj"], "mz_slug" => "mz-ravni-gaj", "kind" => "settlement", "citations" => [citation.call("authored_mz_decision", "9")] },
        { "aliases" => ["mali park"], "mz_slug" => "mz-mali-park", "kind" => "settlement", "citations" => [citation.call("authored_mz_decision", "10")] },
        { "aliases" => ["donji gaj izvor"], "mz_slug" => "mz-gaj-donji", "kind" => "settlement", "citations" => [citation.call("authored_mz_decision", "11")] },
        { "aliases" => ["gornjeg gaja"], "mz_slug" => "mz-gaj-gornji", "kind" => "settlement", "citations" => [citation.call("authored_mz_decision", "12")] }
      ]
    }
    @crosswalk = DecidimApp::Bijeljina::CityServiceAreaCrosswalk.new(organization: nil, matcher:, config: @authored_config)
  end

  def test_typed_settlement_containment_is_complete_at_mz_level_only
    @event.affected_text = "Naseljeno mjesto: Vrt"
    result = @crosswalk.match(@event)
    assert result.fetch("complete")
    assert_equal "resolved", result.fetch("status")
    assert_equal(["mz-vrt"], result.fetch("affected_places").map { |row| row.fetch("slug") })
    assert_equal "part", result.fetch("affected_places").first.fetch("relation")
    assert_equal "not_inferred", result.fetch("komsiluk_status")
    assert_equal "8", result.fetch("affected_places").first.fetch("citations").first.fetch("item")
    assert_equal "public-v1", result.fetch("source_content_version")
  end

  def test_official_street_and_settlement_chain_retains_remaining_unknown_localities
    @event.affected_text = "Naseljena mjesta: Izmišljeni prilaz, Jasen, Neznani rub, Nepoznata"
    result = @crosswalk.match(@event)
    assert_equal false, result.fetch("complete")
    assert_equal "partial", result.fetch("status")
    assert_equal(["mz-lugovi"], result.fetch("affected_places").map { |row| row.fetch("slug") })
    assert_equal(%w(authored_street_decision authored_mz_decision), result.fetch("affected_places").first.fetch("citations").map { |row| row.fetch("source") })
    assert_equal(["izmisljeni prilaz", "neznani rub", "nepoznata"], result.fetch("unresolved_places").map { |row| row.fetch("evidence") })
  end

  def test_all_mentioned_locations_must_be_supported_before_complete_assignment
    @event.affected_text = "Naseljena mjesta: Donji i Gornji Lugovi, Ravni Gaj, Mali Park i Nepoznata"
    result = @crosswalk.match(@event)
    assert_equal false, result.fetch("complete")
    assert_equal %w(mz-lugovi mz-mali-park mz-ravni-gaj), result.fetch("affected_places").map { |row| row.fetch("slug") }.uniq.sort
    assert_equal(["nepoznata"], result.fetch("unresolved_places").map { |row| row.fetch("evidence") })
  end

  def test_feeder_or_street_homonyms_and_unsupported_source_context_are_not_coverage
    ["TS VRT", "1 NN izlaz", "Ulica Vrt", "Vrt"].each do |text|
      @event.affected_text = text
      assert_nil @crosswalk.match(@event)
    end
    @event.affected_text = "Naseljeno mjesto: Vrt"
    @event.source_url = "https://unrelated.example/lt/podrska/iskljucenja/index.php?rj=41"
    assert_nil @crosswalk.match(@event)
    @event.source_url = "https://elektrobijeljina.com/lt/podrska/iskljucenja/index.php?rj=42"
    assert_nil @crosswalk.match(@event)
  end

  def test_only_versioned_complete_https_source_observations_can_establish_containment
    @event.affected_text = "Naseljeno mjesto: Vrt"
    valid_url = @event.source_url
    [valid_url.sub("https", "http"), valid_url.sub(".com/", ".com:444/"), valid_url.sub("https://", "https://user@example.com@")].each do |url|
      @event.source_url = url
      assert_nil @crosswalk.match(@event)
    end
    @event.source_url = valid_url
    @event.content_version = nil
    assert_nil @crosswalk.match(@event)
    @event.content_version = "public-v1"
    @event.extraction_metadata["source_snapshot_complete"] = false
    assert_nil @crosswalk.match(@event)
  end

  def test_missing_mz_is_not_replaced_by_a_homonymous_komsiluk
    @event.affected_text = "Naseljeno mjesto: Vrt"
    matcher = Object.new
    matcher.define_singleton_method(:resolve) { |**| Struct.new(:status).new(:unknown) }
    crosswalk = DecidimApp::Bijeljina::CityServiceAreaCrosswalk.new(organization: nil, matcher:, config: @authored_config)
    assert_nil crosswalk.match(@event)
  end

  def test_identical_source_version_and_crosswalk_are_deterministic
    @event.affected_text = "Naseljeno mjesto: Vrt"
    assert_equal @crosswalk.match(@event), @crosswalk.match(@event)
  end

  def test_authored_split_and_unverified_hamlet_spelling_are_not_silently_collapsed
    @event.affected_text = "Naselja: Lugovi, Novi Lugovi"
    assert_nil @crosswalk.match(@event)
    @event.affected_text = "Naseljena mjesta: Donji Gaj – Izvor, Nepoznati greben i dio Gornjeg Gaja"
    result = @crosswalk.match(@event)
    assert_equal false, result.fetch("complete")
    assert_equal %w(mz-gaj-donji mz-gaj-gornji), result.fetch("affected_places").map { |row| row.fetch("slug") }.sort
    assert_equal(["nepoznati greben"], result.fetch("unresolved_places").map { |row| row.fetch("evidence") })
  end
end
