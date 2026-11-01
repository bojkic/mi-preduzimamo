# frozen_string_literal: true

# ReadPort uses host autoloaded readers. Boot explicitly instead of relying
# on another test file to initialize their dependencies.
require_relative "../test_helper"

require "bundler/setup"
require "minitest/autorun"
require "i18n"
require "active_support"
require "active_support/core_ext/object/blank"
require "active_support/core_ext/object/deep_dup"
require "active_support/core_ext/string/access"
require "active_support/core_ext/string/filters"
require "active_support/core_ext/enumerable"

engine_root = Gem.loaded_specs.fetch("decidim-bih").full_gem_path
require File.join(engine_root, "app/services/decidim/bih/text")
require File.join(engine_root, "app/services/decidim/bih/city/matching")
require File.join(engine_root, "app/services/decidim/bih/city/service_directory")
require File.join(engine_root, "app/services/decidim/bih/concierge/dialogue/contracts")
require File.join(engine_root, "app/services/decidim/bih/concierge/dialogue/service_question")
require_relative "../../app/services/decidim_app/bijeljina/city_services_data"
require_relative "../../app/services/decidim_app/bijeljina/city_directory"
require_relative "../../app/services/decidim_app/bijeljina/city_service_notice_collector"
require_relative "../../app/services/decidim_app/bijeljina/milica/directory_answer"
require_relative "../../app/services/decidim_app/bijeljina/milica/parking_question"
require_relative "../../app/services/decidim_app/bijeljina/milica/read_port"

require_relative "../../app/services/decidim_app/bijeljina/city_service_sources"
require_relative "../../app/services/decidim_app/bijeljina/parking_zones"
require_relative "../support/synthetic_service_directory"
require_relative "../support/synthetic_civic_configuration"

# Real read boundary with authored facts and fail-fast unused adapters.
# No provider/geocoder calls, inferred coordinate zones or channel changes.
class MilicaParkingLocationTest < Minitest::Test
  include SyntheticServiceDirectory
  include SyntheticCivicConfiguration
  Contracts = Decidim::Bih::Concierge::Dialogue::Contracts
  Directory = DecidimApp::Bijeljina::CityDirectory
  ReadPort = DecidimApp::Bijeljina::Milica::ReadPort
  LOCATION = { "latitude" => 0.5, "longitude" => 0.75, "accuracy" => 15,
               "purpose" => "current_location", "consent" => true, "provenance" => "current_turn_browser" }.freeze

  def setup
    install_synthetic_service_directory
    install_synthetic_civic_configuration(day: Date.new(2040, 9, 15))
    @previous_locales = I18n.available_locales
    @previous_backend = I18n.backend
    I18n.available_locales = %w(sr sr-Cyrl bs hr en)
    I18n.backend = I18n::Backend::Simple.new
    I18n.backend.load_translations(File.expand_path("../../config/locales/milica_directory_answers.yml", __dir__))
    @entry = Directory.find(:parking)
    @context = Contracts::TrustedContext.new(organization_id: 71, conversation_key: "d" * 64, capabilities: ["public_reads"], now: Time.utc(2040, 9, 15, 12))
    unused = Object.new.freeze
    @port = ReadPort.new(organization: Data.define(:id).new(71), event_feed: unused, source_checker: unused, timetable: unused,
                         area_matcher: unused, directory: Directory, duplicate_finder: unused, waste_schedule: unused)
    @port.define_singleton_method(:log_failure) { |error, _action| raise error }
  end

  def teardown
    restore_synthetic_civic_configuration
    restore_synthetic_service_directory
    I18n.available_locales = @previous_locales
    I18n.backend = @previous_backend
  end

  def test_current_location_questions_need_a_visible_zone_without_tariffs
    ["Kako da platim parking ovdje", "Kako da platim na mojoj lokaciji", "Kako da platim parking za ovu lokaciju?",
     "U kojoj sam parking zoni?", "Како да платим паркинг овдје?", "How do I pay for parking at my location?"].each do |query|
      result = read(query)
      assert_equal "ambiguous", result.status, query
      assert_equal ["parking_zone_required"], result.warnings
      assert_empty result.facts
    end
  end

  def test_coordinates_alone_do_not_establish_a_zone_or_override_a_general_question
    assert_equal "ambiguous", read("", location: LOCATION).status
    assert_equal "ambiguous", read("Kako da platim parking ovdje", location: LOCATION).status
    assert_equal @entry.fetch(:answer_sections).fetch(:payment), read("Kako da platim parking?", location: LOCATION).facts.fetch(0).fetch("text")
  end

  def test_explicit_zone_with_here_keeps_only_its_reviewed_payment_details
    {
      "Na koji SMS broj se plaća crvena parking zona ovdje?" => "crvena / I zona TEST-R (1,85 KM/h)",
      "Који је СМС број за плаву зону овдје?" => "plava / II zona TEST-B (0,95 KM/h)",
      "SMS number for the white parking zone here?" => "bijela / zona centar TEST-W (2,35 KM/h)"
    }.each do |query, clause|
      result = read(query)
      assert_equal "ok", result.status
      assert_equal "Plaćanje SMS-om: #{clause}.", result.facts.fetch(0).fetch("text"), query
      assert_equal @entry.fetch(:source_url), result.source.fetch("url")
      assert_equal({ "reviewed_on" => "2040-09-14", "live_status" => false }, result.validity)
      assert_equal ["snapshot_not_live_status"], result.warnings
    end
  end

  def test_bare_color_in_the_known_parking_topic_answers_the_followup
    { "crvena" => "TEST-R", "плава" => "TEST-B", "U plavoj zoni." => "TEST-B", "white" => "TEST-W" }.each do |query, number|
      result = read(query)
      assert_equal "ok", result.status
      assert_equal [number], result.facts.fetch(0).fetch("text").scan(/TEST-[RWB]/)
    end
    result = read("Kako da platim parking ovdje", entities: { "area_query" => "crvena" })
    assert_equal "ambiguous", result.status, "A previously saved color is not a current location answer"
  end

  def test_negated_mixed_and_period_questions_keep_their_qualifiers
    ["Ne pitam za crvenu zonu ovdje", "SMS za crvenu i plavu zonu ovdje?"].each do |query|
      assert_equal @entry.fetch(:answer), read(query).facts.fetch(0).fetch("text")
    end
    assert_equal @entry.fetch(:answer_sections).fetch(:payment), read("SMS za dnevnu kartu u plavoj zoni ovdje?").facts.fetch(0).fetch("text")
    assert_equal @entry.fetch(:answer), read("Kako da platim mjesečnu kartu u crvenoj zoni ovdje?").facts.fetch(0).fetch("text")
    result = read("Radno vrijeme crvene zone ovdje?")
    assert_includes result.facts.fetch(0).fetch("text"), I18n.t("decidim_app.milica.directory_answers.parking_hours_unavailable", locale: :sr)
  end

  def test_an_unclassified_payment_question_is_not_forced_into_parking
    result = read("Kako da platim na mojoj lokaciji", topic: "city_service")
    assert_empty result.facts
    assert_equal "empty", result.status
  end

  def test_location_selector_does_not_bypass_public_read_authority
    @context = Contracts::TrustedContext.new(organization_id: 71, conversation_key: "d" * 64, capabilities: [], now: Time.utc(2040, 9, 15, 12))
    result = read("Kako da platim parking ovdje")
    assert_equal "not_authorized", result.status
    assert_empty result.facts
  end

  private

  def read(query, topic: "parking", location: nil, entities: {})
    @port.call(action: "ask_information", topic:, entities: entities.merge("query" => query), context: @context, location:)
  end
end
