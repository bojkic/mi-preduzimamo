# frozen_string_literal: true

# Standalone Minitest has refute helpers without ActiveSupport assert_not aliases.
# rubocop:disable Rails/RefuteMethods

require "bundler/setup"
require "minitest/autorun"
require "i18n"
require_relative "../support/isolated_i18n_backend"
require "active_support"
require "active_support/time"
require "active_support/core_ext/object/blank"
require "active_support/core_ext/object/deep_dup"
require "active_support/core_ext/hash/keys"
require "active_support/core_ext/string/filters"
require "active_support/core_ext/string/exclude"
require "active_support/core_ext/enumerable"

engine_root = Gem.loaded_specs.fetch("decidim-bih").full_gem_path
require File.join(engine_root, "app/services/decidim/bih/concierge/dialogue/procedure_question")
require_relative "../../app/services/decidim_app/bijeljina/service_procedures"
require_relative "../../app/services/decidim_app/bijeljina/city_service_notice_collector"
require_relative "../../app/services/decidim_app/bijeljina/city_service_source_check_store"
require_relative "../../app/services/decidim_app/bijeljina/milica/read_port"
require_relative "../support/synthetic_procedures"

# Authored reviewed cards and real read adapter, with synthetic source-store
# status. No Rails boot, database, model calls, forms, or citizen data.
class MilicaProcedureFeeFollowupTest < Minitest::Test
  include SyntheticProcedures
  Dialogue = Decidim::Bih::Concierge::Dialogue
  Cards = DecidimApp::Bijeljina::ServiceProcedures
  NOW = Time.utc(2040, 9, 9, 21)

  def setup
    install_synthetic_procedures
    @prior_backend = I18n.backend
    @prior_locales = I18n.available_locales
    I18n.backend = MiTestSupport::IsolatedI18nBackend.new
    I18n.available_locales = %w(sr sr-Cyrl bs hr en)
    I18n.available_locales.each do |locale|
      # Shipping locale keys are owned and integrated by the lead.
      messages = { procedure_fee_check: "CHECK_OFFICIAL_SOURCE: %{title}.", procedure_fee_amount: "ADMIN_FEE: %{amount} KM.",
                   procedure_fee_unknown: "ADMIN_FEE_UNKNOWN.", procedure_postage_unknown: "POSTAGE_UNKNOWN.",
                   procedure_postage_amount: "POSTAGE: %{amount} KM." }
      I18n.backend.store_translations(locale, decidim: { bih: { dialogue: messages } })
    end
    @organization = Data.define(:id).new(71)
    @context = context
    @snapshots = []
    @payload = { "status" => "ok" }
    @card_override = nil
    receiver = self
    @store = Object.new
    @store.define_singleton_method(:snapshot) do |source_key:|
      receiver.instance_variable_get(:@snapshots) << source_key
      Data.define(:check_payload).new(receiver.instance_variable_get(:@payload))
    end
    directory = Object.new
    directory.define_singleton_method(:procedure_for) do |key|
      receiver.instance_variable_get(:@card_override) || Cards.find(key)
    end
    @port = DecidimApp::Bijeljina::Milica::ReadPort.allocate
    @port.instance_variable_set(:@organization, @organization)
    @port.instance_variable_set(:@directory, directory)
    @port.instance_variable_set(:@source_checker, @store)
  end

  def teardown
    I18n.backend = @prior_backend
    I18n.available_locales = @prior_locales
    restore_synthetic_procedures
  end

  def test_closed_fee_followups_accept_both_scripts_without_hijacking_named_new_questions
    ["A gdje provjeravam cijenu?", "Гдје провјеравам цијену?", "Gde mogu proveriti cenu?", "Koliko košta?", "A poštarina?",
     "Kolika je taksa?", "Where can I check the fee?", "How much does it cost?"].each do |text|
      assert Dialogue::ProcedureQuestion.fee_follow_up?(text), text
    end
    [nil, "Koliko košta karta do Izmišljenog vrta?", "Cijena parkinga", "Ne provjeravaj cijenu", "A gdje provjeravam cijenu i pošalji zahtjev?",
     "Koliko košta? Podnesi zahtjev za mene.", "Prijavi problem", "a" * 161].each do |text|
      refute Dialogue::ProcedureQuestion.fee_follow_up?(text), text.inspect
    end
  end

  def test_retained_id_requires_current_public_procedure_evidence_not_saved_entity_text
    value = state
    assert_equal "procedure:maticar", Dialogue::ProcedureQuestion.retained_id(state: value, context: @context)
    [value.merge("active_task" => "report_problem"), value.merge("topic" => "transport"), value.merge("draft" => {}),
     value.merge("prior_evidence" => nil), value.merge("expires_at" => NOW.to_f - 1)].each do |invalid|
      assert_nil Dialogue::ProcedureQuestion.retained_id(state: invalid, context: @context)
    end
    value["prior_evidence"]["facts"][0]["source_id"] = "procedure:e_registar"
    assert_nil Dialogue::ProcedureQuestion.retained_id(state: value, context: @context)
    value = state
    value["prior_evidence"]["facts"] << { "id" => "procedure:e_registar", "source_id" => "procedure:e_registar" }
    assert_nil Dialogue::ProcedureQuestion.retained_id(state: value, context: @context)
    assert_nil Dialogue::ProcedureQuestion.retained_id(state: state, context: context(capabilities: []))
  end

  def test_original_procedure_evidence_rereads_the_same_card_and_separates_zero_fee_from_unknown_postage
    initial = DecidimApp::Bijeljina::Milica::ProcedureRead.new(source_store: @store).call(card: Cards.find("maticar"), locale: "sr", now: NOW)
    typed = Dialogue::Contracts::ReadResult.new(**initial)
    prior = Dialogue::PriorEvidence.capture(result: typed, facts: typed.facts, action: "ask_information", topic: "city_service",
                                            now: NOW, expires_at: NOW.to_f + 600)
    retained = state.merge("prior_evidence" => prior)
    id = Dialogue::ProcedureQuestion.retained_id(state: retained, context: @context)
    result = read(id:)
    assert_equal "ok", result.status
    assert_equal ["reference:procedure:maticar", "reference:procedure:maticar"], @snapshots
    fact = result.facts.first
    assert_equal "procedure:maticar", fact["id"]
    assert_equal "service_procedure", fact["kind"]
    assert_equal typed.facts.first.except("text"), fact.except("text")
    assert_equal 0, fact.dig("fee", "administrative_fee_bam")
    assert_nil fact.dig("fee", "postage_amount_bam")
    assert_equal Cards.find("maticar")[:source_url], fact["source_url"]
    assert_equal "2040-09-09", fact["reviewed_on"]
    assert_includes fact["text"], "ADMIN_FEE: 0 KM"
    assert_includes fact["text"], "POSTAGE_UNKNOWN"
    assert_includes fact["text"], "CHECK_OFFICIAL_SOURCE"
    refute_includes fact["text"], "POSTAGE: 0"
  end

  def test_changed_or_expired_source_does_not_replay_the_previous_fee
    card = Cards.find("maticar")
    @payload = { "status" => "ok", "review_required_for_hash" => card[:reviewed_content_hash], "source_url" => card[:source_url] }
    changed = read
    assert_equal "unreviewed", changed.status
    assert_empty changed.facts
    assert_includes changed.warnings, "procedure_source_changed_review_required"

    @payload = { "status" => "ok" }
    expired = read(trusted: context(now: NOW + 366.days))
    assert_equal "stale", expired.status
    assert_empty expired.facts
    assert_includes expired.warnings, "procedure_review_expired"
  end

  def test_unknown_or_invalid_fee_is_not_replaced_with_zero
    unknown = read(id: "procedure:e_registar")
    assert_includes unknown.facts.first["text"], "ADMIN_FEE_UNKNOWN"
    refute_includes unknown.facts.first["text"], "0 KM"
    @card_override = Cards.find("maticar").deep_dup.merge(fee: { administrative_fee_bam: -1, delivery_cost: "postage", postage_amount_bam: nil })
    invalid = read
    assert_includes invalid.facts.first["text"], "ADMIN_FEE_UNKNOWN"
    assert_includes invalid.facts.first["text"], "POSTAGE_UNKNOWN"
  end

  def test_reviewed_amounts_remain_separate_and_latest_source_check_warning_is_retained
    @payload = { "status" => "unavailable" }
    @card_override = Cards.find("maticar").deep_dup.merge(fee: { administrative_fee_bam: 4, delivery_cost: "postage", postage_amount_bam: 2.5 })
    result = read
    assert_equal "ok", result.status
    assert_includes result.facts.first["text"], "ADMIN_FEE: 4 KM"
    assert_includes result.facts.first["text"], "POSTAGE: 2.5 KM"
    refute_includes result.facts.first["text"], "6.5 KM"
    assert_includes result.warnings, "latest_source_check_unavailable"
    assert_includes result.facts.first["warning_codes"], "latest_source_check_unavailable"
  end

  def test_public_tenant_and_identifier_guards_precede_source_reads
    denied = read(trusted: context(capabilities: []))
    assert_equal "not_authorized", denied.status
    assert_raises(Dialogue::Contracts::Invalid) { read(trusted: context(organization_id: 72)) }
    ["https://evil.invalid/", "procedure:../../secret", "procedure:missing"].each do |id|
      assert_empty read(id:).facts
    end
    assert_empty @snapshots
  end

  private

  def context(organization_id: 71, capabilities: ["public_reads"], now: NOW)
    Dialogue::Contracts::TrustedContext.new(organization_id:, conversation_key: "c" * 64, capabilities:, now:)
  end

  def state
    { "active_task" => "ask_information", "topic" => "city_service", "draft" => nil, "expires_at" => NOW.to_f + 600,
      "prior_evidence" => { "version" => 1, "kind" => "public_read", "action" => "ask_information", "topic" => "city_service", "status" => "ok",
                            "facts" => [{ "id" => "procedure:maticar", "source_id" => "procedure:maticar", "reviewed_on" => "2040-09-09" }],
                            "scope" => { "area_slugs" => [] }, "expires_at" => NOW.to_f + 600 } }
  end

  def read(id: "procedure:maticar", trusted: @context)
    @port.procedure_follow_up(procedure_id: id, focus: "fee", context: trusted, locale: "sr")
  end
end

# rubocop:enable Rails/RefuteMethods
