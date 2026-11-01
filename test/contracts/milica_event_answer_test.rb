# frozen_string_literal: true

# Standalone Minitest does not include ActiveSupport's assert_not aliases.
# rubocop:disable Rails/RefuteMethods

require "bundler/setup"
require "minitest/autorun"
require "i18n"
require_relative "../support/isolated_i18n_backend"
require "active_support"
require "active_support/time"
require "active_support/core_ext/object/blank"
require "active_support/core_ext/object/deep_dup"
require "active_support/core_ext/string/access"
require "active_support/core_ext/string/filters"
require "active_support/core_ext/enumerable"
require "action_controller"

engine_root = Gem.loaded_specs.fetch("decidim-bih").full_gem_path
require File.join(engine_root, "app/services/decidim/bih/text")
require File.join(engine_root, "lib/decidim/bih/transliterator")
require File.join(engine_root, "app/services/decidim/bih/concierge/dialogue/contracts")
require_relative "../../app/services/decidim_app/bijeljina/city_service_sources"
require_relative "../../app/services/decidim_app/bijeljina/city_service_time"
require_relative "../../app/services/decidim_app/bijeljina/electricity_outage_parser"
require_relative "../../app/services/decidim_app/bijeljina/city_service_place_context"
require_relative "../../app/services/decidim_app/bijeljina/milica/read_port"

# Real parser fixture -> actual ReadPort event envelope -> bounded presentation.
# No Rails boot, database, citizen data, source HTTP, model, or Redis.
class MilicaEventAnswerTest < Minitest::Test
  Parser = DecidimApp::Bijeljina::ElectricityOutageParser
  Answer = DecidimApp::Bijeljina::Milica::EventAnswer
  NOW = Time.utc(2040, 9, 9, 8)
  AREA = Data.define(:slugs, :targeting_level, :coverage) do
    def unknown? = true
  end
  Event = Struct.new(*Parser::Event.members, :id, :confirmed, keyword_init: true) do
    def facts_confirmed? = confirmed == true

    def area_slugs = affected_area_slugs

    def source_label_text = source_label
  end

  def setup
    sources = DecidimApp::Bijeljina::CityServiceSources
    @previous_city_sources = sources::SOURCES
    row = sources::REFERENCE_SOURCES.find { |item| item.fetch(:key) == "electricity_outages" }.deep_dup.merge(
      enabled: true, label: "Izmišljeni testni izvor struje", provider: "Izmišljeni pružalac",
      source_url: "https://electricity.example.invalid/source")
    sources.send(:remove_const, :SOURCES)
    sources.const_set(:SOURCES, [row.freeze].freeze)
    @previous_backend = I18n.backend
    @previous_locales = I18n.available_locales
    I18n.backend = MiTestSupport::IsolatedI18nBackend.new
    I18n.available_locales = %w(sr sr-Cyrl bs hr en)
    I18n.backend.load_translations(*Dir[File.expand_path("../../config/locales/decidim_app*{unconfirmed_evidence,city_service_evidence,city_service_place_context}.yml", __dir__)])
    I18n.available_locales.each do |locale|
      # The lead owns the shipping translations; synthetic labels make this
      # helper contract independent of that parallel integration edit.
      messages = {
        notice_planned_electricity: "OUTAGE: %{affected}.", notice_asset: "ASSET: %{asset}.",
        notice_service_unit: "UNIT: %{unit}.", notice_reason: "REASON: %{reason}."
      }
      I18n.backend.store_translations(locale, decidim: { bih: { dialogue: messages } })
    end
    area = AREA.new([], "unknown", { "status" => "unknown", "affected_places" => [] })
    matcher = Object.new
    matcher.define_singleton_method(:match) { |*| area }
    html = File.read(File.expand_path("../fixtures/files/synthetic/electricity_event.html", __dir__))
    parsed = Parser.new(organization: Object.new, area_matcher: matcher).call(html:, fetched_at: NOW - 60).first
    @event = Event.new(**parsed.to_h, id: 64, confirmed: false)
    @port = DecidimApp::Bijeljina::Milica::ReadPort.allocate
  end

  def teardown
    sources = DecidimApp::Bijeljina::CityServiceSources
    sources.send(:remove_const, :SOURCES)
    sources.const_set(:SOURCES, @previous_city_sources)
    I18n.backend = @previous_backend
    I18n.available_locales = @previous_locales
  end

  def test_known_complete_parser_row_is_shortened_without_losing_any_source_fields
    original = @event.to_h.deep_dup
    fact = event_fact
    assert_equal "service_event_v1", fact["answer_shape"]
    assert_equal "OUTAGE: 1 TESTNI izlaz. ASSET: TESTNI OBJEKAT A. UNIT: TESTNA JEDINICA. REASON: Izmišljena sanacija.", fact["notice_body"]
    refute_includes fact["notice_body"], "09:00"
    assert_equal @event.title, fact.dig("source_text", "title")
    assert_equal @event.summary, fact.dig("source_text", "summary")
    assert_equal "service_event:64", fact["id"]
    assert_equal "city_service_event", fact["kind"]
    assert_equal @event.source_url, fact["source_url"]
    assert_equal @event.source_key, fact["source_id"]
    assert_equal @event.content_version, fact["content_version"]
    assert_equal @event.lifecycle, fact["lifecycle"]
    assert_equal @event.starts_at, Time.iso8601(fact["starts_at"])
    assert_equal @event.ends_at, Time.iso8601(fact["ends_at"])
    assert_equal @event.fetched_at, Time.iso8601(fact["checked_at"])
    assert_equal "unknown", fact.dig("coverage", "requested_relation")
    assert_includes fact["warning_codes"], "source_facts_unconfirmed"
    assert_includes fact["warning_codes"], "geographic_scope_unconfirmed"
    assert_includes fact["warning_codes"], "partial_geographic_coverage"
    assert_equal original, @event.to_h
    assert_equal fact, Decidim::Bih::Concierge::Dialogue::Contracts.snapshot(fact)
  end

  def test_context_only_places_are_kept_as_qualified_context_not_outage_coverage
    @event.extraction_metadata["place_context"] = {
      "source_content_version" => @event.content_version,
      "places" => [{ "slug" => "mz-synthetic-garden", "name" => "MZ Izmišljeni vrt", "relation" => "context_only" }]
    }
    fact = event_fact(slugs: ["mz-synthetic-garden"])
    assert_equal "context_only", fact.dig("coverage", "requested_relation")
    assert_empty fact.dig("coverage", "area_slugs")
    context = fact.dig("notice_qualifiers", "place_name_context_not_service_coverage")
    assert_includes context, "MZ Izmišljeni vrt"
    assert_includes context, "nije potvrđen"
    assert_includes fact["text"], context
    assert_includes fact["warning_codes"], "place_name_context_not_service_coverage"

    @event.extraction_metadata["place_context"]["source_content_version"] = "old"
    assert_nil event_fact.dig("notice_qualifiers", "place_name_context_not_service_coverage")
  end

  def test_operator_correction_or_edited_prose_never_uses_the_structured_shortcut
    @event.extraction_metadata["operator_review"] = { "source_content_version" => @event.content_version }
    corrected = event_fact
    assert_includes corrected["notice_body"], @event.summary
    assert_includes corrected["warning_codes"], "operator_reviewed_correction"
    refute_includes corrected["notice_body"], "OUTAGE:"

    @event.extraction_metadata.delete("operator_review")
    @event.summary += " Ne odnosi se na kućne brojeve 2 i 4."
    edited = event_fact
    assert_includes edited["notice_body"], "Ne odnosi se na kućne brojeve 2 i 4."
    refute_includes edited["notice_body"], "OUTAGE:"
    assert_equal @event.summary, edited.dig("source_text", "summary")
  end

  def test_version_mismatch_does_not_promote_stale_metadata_over_current_source_text
    @event.extraction_metadata["reason"] = "Different metadata not in this source version"
    fact = event_fact
    assert_includes fact["notice_body"], @event.summary
    refute_includes fact["notice_body"], "Different metadata"
    refute_includes fact["notice_body"], "OUTAGE:"
  end

  def test_unknown_and_date_only_windows_do_not_get_invented_minute_precision
    @event.starts_at = nil
    @event.ends_at = nil
    unknown = event_fact
    assert_nil unknown["starts_at"]
    assert_nil unknown["ends_at"]
    assert_equal "unknown", unknown.dig("validity", "precision")
    assert_includes unknown["notice_qualifiers"].keys, "event_time_unconfirmed"
    refute_includes unknown["notice_body"], "OUTAGE:"

    @event.starts_at = Time.utc(2040, 9, 9)
    @event.ends_at = Time.utc(2040, 9, 10)
    @event.extraction_metadata["temporal_precision"] = "day"
    dated = event_fact
    assert_nil dated["starts_at"]
    assert_nil dated["ends_at"]
    assert_equal "day", dated.dig("validity", "precision")
    assert_equal "2040-09-09", dated.dig("validity", "date")
    assert_includes dated["warning_codes"], "source_time_is_date_only"
  end

  def test_end_of_planned_window_does_not_become_a_restoration_claim
    fact = event_fact(now: @event.ends_at + 60)
    assert_equal "scheduled", fact["lifecycle"]
    assert_includes fact["warning_codes"], "planned_end_not_confirmed_restoration"
    refute_includes fact["notice_body"], "restored"
  end

  def test_arbitrary_notice_only_loses_exact_duplicate_title_not_negation_or_numbers
    @event.source_key = "water_service"
    @event.title = "Voda nije isključena za kućne brojeve 2 i 4."
    @event.summary = @event.title
    fact = event_fact
    assert_equal @event.summary, fact["notice_body"]
    assert_equal @event.summary, fact.dig("source_text", "summary")
    @event.title = "Radovi"
    @event.summary = "Voda nije isključena. Radovi traju do 14:00."
    assert_equal "Radovi: #{@event.summary}", event_fact["notice_body"]
  end

  def test_oversized_prose_uses_existing_fallback_instead_of_truncating_a_new_shape
    @event.summary = "Dodatna provjerljiva izvorna rečenica. " * 70
    fact = event_fact
    assert_nil fact["answer_shape"]
    assert_nil fact["source_text"]
    assert_operator fact["text"].length, :<=, 1000
  end

  def test_all_locales_keep_qualifiers_and_original_source_dates_separate
    @event.source_published_at = NOW - 180
    @event.source_updated_at = NOW - 120
    %w(sr sr-Cyrl bs hr en).each do |locale|
      fact = event_fact(locale:)
      assert_equal "service_event_v1", fact["answer_shape"]
      refute_includes fact["text"], "Translation missing"
      assert_equal @event.title, fact.dig("source_text", "title")
      assert_equal @event.summary, fact.dig("source_text", "summary")
      assert_equal NOW - 180, Time.iso8601(fact["source_published_at"])
      assert_equal NOW - 120, Time.iso8601(fact["source_updated_at"])
      assert_equal NOW - 60, Time.iso8601(fact["checked_at"])
      assert_equal %w(geographic_scope_unconfirmed partial_geographic_coverage source_facts_unconfirmed), fact["notice_qualifiers"].keys.sort
    end
  end

  def test_source_markup_is_not_included_in_the_shaped_contract
    @event.source_key = "water_service"
    @event.title = "<b>Obavještenje</b>"
    @event.summary = "Voda <strong>nije</strong> isključena za broj 4."
    fact = event_fact
    assert_equal "Obavještenje", fact.dig("source_text", "title")
    assert_equal "Voda nije isključena za broj 4.", fact.dig("source_text", "summary")
    refute_includes fact["text"], "<"
    assert_includes fact["notice_body"], "nije isključena za broj 4"
  end

  def test_missing_shape_translation_keeps_the_legacy_fact_as_fallback
    I18n.backend = MiTestSupport::IsolatedI18nBackend.new
    assert_nil Answer.call(event: @event, locale: "sr", warning_codes: [])
  end

  private

  def event_fact(slugs: ["mz-synthetic-field"], now: NOW, locale: "sr")
    @port.send(:event_fact, @event, locale:, now:, requested_area_slugs: slugs)
  end
end

# rubocop:enable Rails/RefuteMethods
