# frozen_string_literal: true

# Standalone Minitest does not load Rails' assert_not aliases.
# rubocop:disable Rails/RefuteMethods

require "bundler/setup"
require "minitest/autorun"
require "i18n"

engine_root = Gem.loaded_specs.fetch("decidim-bih").full_gem_path
require File.join(engine_root, "app/services/decidim/bih/text")
require File.join(engine_root, "app/services/decidim/bih/concierge/dialogue/contracts")
require_relative "../../app/services/decidim_app/bijeljina/milica/foundation_read"

class MilicaFoundationReadTest < Minitest::Test
  Read = DecidimApp::Bijeljina::Milica::FoundationRead
  Contracts = Decidim::Bih::Concierge::Dialogue::Contracts
  Organization = Data.define(:id)

  def setup
    @old_backend = I18n.backend
    @old_locales = I18n.available_locales
    I18n.available_locales = Contracts::LOCALES
    I18n.backend = I18n::Backend::Simple.new
    I18n.backend.load_translations(File.expand_path("../../config/locales/milica_foundation_answers.yml", __dir__))
    @context = Contracts::TrustedContext.new(
      organization_id: 1, conversation_key: "a" * 64, capabilities: ["public_reads"], now: Time.utc(2040, 9, 10, 19)
    )
    @metadata = { "reviewed_on" => "2040-09-10", "reviewed_at" => "2040-09-10T18:30:00Z", "review_expires_on" => "2040-12-09",
      "sources" => { "about" => { "id" => "lfbn:about", "url" => "https://community.example.invalid/about" },
                     "idea_call" => { "id" => "lfbn:idea_call", "url" => "https://community.example.invalid/call", "current_open_status" => "unverified" } } }
    @read = Read.new(organization: Organization.new(id: 1), metadata: @metadata, status_override: nil)
  end

  def teardown
    I18n.backend = @old_backend
    I18n.available_locales = @old_locales
  end

  def test_general_and_named_funding_questions_use_reviewed_foundation_facts_in_both_scripts
    questions = [
      "Postoji li fondacija koja finansira projekte građana?",
      "Da li neka fondacija podržava ideje građana u Bijeljini?",
      "Da li Lokalna fondacija Bijeljina finansira projekte građana?",
      "Постоји ли фондација која финансира пројекте грађана?",
      "Is there a foundation that funds citizen projects in Bijeljina?"
    ]
    questions.each do |query|
      result = call(query)
      assert_equal "ok", result.fetch(:status), query
      assert_equal %w(lfbn:about lfbn:idea_call), (result.fetch(:facts).map { |fact| fact.fetch("source_id") })
      assert_empty result.fetch(:warnings)
      assert_equal "unverified", result.fetch(:validity).fetch("current_call_status")
      assert_nil result.fetch(:validity).fetch("funds_available")
      refute result.fetch(:coverage).fetch("complete_inventory")
      assert Contracts::ReadResult.new(**result)
    end
  end

  # Named questions exercise the reference adapter; answers contain no local factual copy.
  def test_identity_answers_are_short_localized_and_not_bank_or_current_grant_instructions
    Contracts::LOCALES.each do |locale|
      result = call("Šta je Lokalna fondacija Bijeljina?", locale:)
      assert_equal "ok", result.fetch(:status)
      assert_equal 1, result.fetch(:facts).length
      fact = result.fetch(:facts).first
      assert_equal I18n.t("decidim_app.milica.foundation_answers.identity", locale:), fact.fetch("text")
      assert_equal "https://community.example.invalid/about", fact.fetch("source_url")
      refute_match(/\b(?:racun|ziro|uplati|account|bank|24[.,]000|8[.,]000)\b/, Decidim::Bih::Text.fold(fact.fetch("text")))
      assert_operator fact.fetch("text").length, :<, 260
    end
    assert Read.handles?(topic: "community", entities: { "query" => "Локална фондација Бијељина" })
    assert Read.handles?(topic: "community", entities: { "query" => "What is Local Foundation Bijeljina?" })
  end

  def test_contextual_application_and_open_status_need_a_known_public_source_and_do_not_repeat_biography
    ["Gdje mogu prijaviti svoju ideju?", "Гдје могу пријавити своју идеју?", "Da li je konkurs još otvoren?", "Where can I apply?"].each do |query|
      assert_nil call(query)
      assert_nil call(query, source_identity: "unrelated:foundation")
      Read::SOURCE_IDS.each do |source_identity|
        result = call(query, source_identity:)
        assert_equal "ok", result.fetch(:status)
        assert_equal 1, result.fetch(:facts).length
        fact = result.fetch(:facts).first
        assert_equal "lfbn:idea_call", fact.fetch("source_id")
        assert_equal "https://community.example.invalid/call", fact.fetch("source_url")
        refute_includes fact.fetch("text"), "2025"
        assert_includes fact.fetch("text"), "Ne mogu potvrditi"
        refute_includes fact.fetch("text"), "prikuplja donacije"
      end
    end
  end

  def test_unrelated_foundations_specific_lists_and_private_or_report_actions_are_not_hijacked
    [
      "Šta je fondacija Mozaik?", "Da li fondacija Mozaik finansira projekte građana?",
      "Postoji li fondacija koja finansira projekte građana u Tuzli?",
      "Šta je Lokalna fondacija Tuzla?", "Koje projekte trenutno finansira Lokalna fondacija Bijeljina?",
      "Prikaži projekte Lokalna fondacija Bijeljina", "Da li Lokalna fondacija Bijeljina finansira projekat Školsko dvorište?",
      "Kako da prijavim problem?", "Prijavi rupu na putu", "Gdje mogu prijaviti svoju ideju fondaciji Mozaik?",
      "Zdravo", "Prikaži moje prijave", "Lozinka je privatna", "Kako da se zaposlim u Lokalnoj fondaciji Bijeljina?"
    ].each do |query|
      assert_nil call(query), query
      assert_nil call(query, source_identity: "lfbn:about"), query
    end
    assert_nil @read.call(topic: "report", entities: { "query" => "Lokalna fondacija Bijeljina" }, context: @context, locale: "sr")
    assert_nil @read.call(topic: "community", entities: { "query" => "a" * 1_001 }, context: @context, locale: "sr")
  end

  def test_tenant_and_public_read_permission_are_checked_before_answering
    [@context.with(organization_id: 2), @context.with(capabilities: []), Object.new].each do |context|
      result = @read.call(topic: "community", entities: { "query" => "Lokalna fondacija Bijeljina" }, context:, locale: "sr")
      assert_equal "not_authorized", result.fetch(:status)
      assert_empty result.fetch(:facts, [])
    end
  end

  def test_expired_or_future_review_cannot_be_reported_as_current_knowledge
    [Time.utc(2040, 9, 9), Time.utc(2040, 9, 10, 18), Time.utc(2040, 12, 10)].each do |now|
      result = @read.call(topic: "community", entities: { "query" => "Lokalna fondacija Bijeljina" }, context: @context.with(now:), locale: "sr")
      assert_equal "stale", result.fetch(:status)
      assert_empty result.fetch(:facts, [])
      assert_equal ["foundation_reference_review_due"], result.fetch(:warnings)
      assert_equal "unverified", result.fetch(:validity).fetch("current_call_status")
    end
  end

  def test_cyrillic_copy_is_generated_from_the_maintained_serbian_locale
    latin = I18n.t("decidim_app.milica.foundation_answers", locale: "sr")
    cyrillic = I18n.t("decidim_app.milica.foundation_answers", locale: "sr-Cyrl")
    assert_equal latin.transform_values { |value| Decidim::Bih::Transliterator.call(value) }, cyrillic
  end

  def test_generic_copy_contains_no_shipped_local_facts_and_preserves_contact_placeholders
    Contracts::LOCALES.each do |locale|
      copy = I18n.t("decidim_app.milica.foundation_answers", locale:)
      refute_match(/Bijeljin|Бијељин|2025/, copy.values.join(" "))
      values = { name: "SYNTHETIC ORGANIZATION", address: "SYNTHETIC ADDRESS", email: "office@community.example.invalid", website: "https://community.example.invalid" }
      contact = I18n.t("decidim_app.milica.foundation_answers.contact", locale:, **values)
      values.each_value { |value| assert_includes contact, value }
      refute_match(/ne objavljuje|не објављује|publishes no/, contact)
    end
  end

  private

  def call(query, locale: "sr", source_identity: nil)
    @read.call(topic: "community", entities: { "query" => query }, context: @context, locale:, source_identity:)
  end
end

# rubocop:enable Rails/RefuteMethods
