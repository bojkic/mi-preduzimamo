# frozen_string_literal: true

require "bundler/setup"
require "minitest/autorun"
require "digest"

engine_root = Gem.loaded_specs.fetch("decidim-bih").full_gem_path
require File.join(engine_root, "app/services/decidim/bih/text")
require File.join(engine_root, "app/services/decidim/bih/city/matching")
require File.join(engine_root, "app/services/decidim/bih/city/service_directory")
require_relative "../../app/services/decidim_app/bijeljina/city_services_data"
require_relative "../../app/services/decidim_app/bijeljina/city_directory"
require_relative "../../app/services/decidim_app/bijeljina/milica/transport_fare_answer"

# Authored fare facts, not a local operator price. No Rails boot, DB or network.
class MilicaTransportFareAnswerTest < Minitest::Test
  Data = DecidimApp::Bijeljina::CityServicesData
  Selector = DecidimApp::Bijeljina::Milica::TransportFareAnswer

  def test_authored_timetable_and_fares_keep_distinct_reviewed_sources
    assert_includes entry.dig(:answer_sections, :timetable), "1. septembra 2040"
    assert_empty Data::TRANSPORT_ANSWER_SECTIONS, "no inherited community fares or schedule"
    assert_empty Data::TRANSPORT_ANSWER_SOURCES, "no inherited provider source"
    assert_equal "2040-08-15", entry.fetch(:verified_on).iso8601
    assert_includes entry.fetch(:source_url), "/synthetic/timetable"
    assert_equal entry.fetch(:answer), entry.fetch(:answer_sections).values.join(" ")
    assert entry.fetch(:answer_sections).frozen?
  end

  def test_generic_fare_questions_select_only_reviewed_facts_and_the_fare_source
    ["Koliko košta autobuska karta?", "Kolika je cijena autobuske karte?", "Koja je cijena karte za gradski prevoz?",
     "Колико кошта аутобуска карта?", "Koliko je karta za bus?", "How much is a bus ticket?"].each do |query|
      selected = Selector.call(entry:, query:)

      assert_equal entry.dig(:answer_sections, :fares), "#{selected.fetch(:text).delete_suffix(".")}: #{selected.fetch(:source_url)}."
      assert_equal entry.dig(:answer_sources, :fares), selected.fetch(:source_url)
      assert_includes selected.fetch(:source_url), "/synthetic/fares"
      refute_match(%r{https?://}, selected.fetch(:text)) # rubocop:disable Rails/RefuteMethods -- Plain Minitest has no assert_no_match.
    end
  end

  def test_mixed_journey_timetable_status_map_day_and_negated_requests_are_not_selected
    ["Cijena karte i red vožnje",
     "Cijena karte i mapa zona", "Koliko košta karta danas?", "Bus fare and current status",
     "Cijena karte nedjeljom", "Ne cijena autobuske karte", "Gdje kupiti autobusku kartu?",
     "Koliko je autobusa?", "Cijena karte za tri zone", "Koliko košta autobuska karta? #{"a" * 160}"].each do |query|
      assert_nil Selector.call(entry:, query:), query
    end
  end

  def test_scoped_fare_uses_reviewed_prices_without_guessing_journey_zone
    ["Treba mi samo cijena autobuske karte do Primjervrta.", "Колико кошта карта до Примјерврта?", "Cijena karte za Primjerpolje"].each do |query|
      selected = Selector.call(entry:, query:)
      assert_includes selected.fetch(:text), "2,70 KM"
      assert_includes selected.fetch(:text), "nije dovoljno da potvrdim broj tarifnih zona"
      assert_equal entry.dig(:answer_sources, :fares), selected.fetch(:source_url)
    end
    correction = Selector.call(entry:, query: "Nemoj mi umjesto cijene poslati cijeli raspored.")
    assert_includes correction.fetch(:text), "2,70 KM"
    refute_includes correction.fetch(:text), "raspored"
  end

  def test_invalid_input_and_other_entries_keep_the_existing_read_path
    [nil, {}, 42, "", "\xFF".dup.force_encoding(Encoding::UTF_8)].each do |query|
      assert_nil Selector.call(entry:, query:)
    end
    assert_nil Selector.call(entry: entry.merge(key: :parking), query: "Koliko košta karta?")
    assert_nil Selector.call(entry: entry.except(:answer_sources), query: "Koliko košta karta?")
  end

  private

  def entry
    @entry ||= begin
      fare_url = "https://community.example.invalid/synthetic/fares"
      sections = { timetable: "IZMIŠLJENI TEST: raspored od 1. septembra 2040.",
                   fares: "IZMIŠLJENI TEST: karta 2,70 KM: #{fare_url}." }.freeze
      { key: :javni_prevoz, verified_on: Date.new(2040, 8, 15),
        source_url: "https://community.example.invalid/synthetic/timetable",
        answer_sections: sections, answer_sources: { fares: fare_url }.freeze,
        answer: sections.values.join(" ") }.freeze
    end
  end
end
