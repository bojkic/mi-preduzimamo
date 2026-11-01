# frozen_string_literal: true

# rubocop:disable Rails/RefuteMethods, Rails/I18nLocaleAssignment -- isolated standalone Minitest backend
require_relative "../test_helper"
require_relative "../support/synthetic_foundation_reference"

require "bundler/setup"
require "minitest/autorun"
require "active_support"
require "active_support/time"
require "active_support/core_ext/object/blank"
require "active_support/core_ext/enumerable"
require "active_support/core_ext/string/exclude"
require "i18n"
require "digest"

engine = Gem.loaded_specs.fetch("decidim-bih").full_gem_path
require File.join(engine, "app/services/decidim/bih/concierge/dialogue/coordinator")
require File.join(engine, "app/services/decidim/bih/city/matching")
require File.join(engine, "app/services/decidim/bih/city/service_directory")
require_relative "../../app/services/decidim_app/bijeljina/city_service_notice_collector"
require_relative "../../app/services/decidim_app/bijeljina/milica/read_port"

class MilicaPublicReferenceContinuityTest < Minitest::Test
  include ActiveSupport::Testing::TimeHelpers
  include SyntheticFoundationReference
  D = Decidim::Bih::Concierge::Dialogue
  C = D::Contracts
  NOW = Time.utc(2040, 9, 10, 20)
  ORGANIZATION = Data.define(:id).new(71)

  class MemoryRedis
    attr_reader :data
    attr_accessor :conflict

    def initialize = @data = {}

    def get(key) = data[key]

    def eval(script, keys:, argv:)
      raise "Unexpected write" unless script == D::StateStore::WRITE_SCRIPT
      return 0 if conflict

      version = data[keys.first] ? JSON.parse(data[keys.first]).fetch("version") : 0
      return 0 unless version == argv.first

      data[keys.first] = argv[1]
      1
    end
  end

  class InlineRuntime
    attr_accessor :clock

    def initialize = @clock = 0.0

    def call
      budget = D::TurnBudget.new(timeout: 2, clock: -> { clock })
      D::AdmissionControl::Result.new(status: :admitted, value: yield(budget))
    end
  end

  def setup
    travel_to NOW
    install_synthetic_foundation_reference
    @old_backend = I18n.backend
    @old_locales = I18n.available_locales
    @old_locale = I18n.locale
    I18n.backend = I18n::Backend::Simple.new
    I18n.available_locales = C::LOCALES
    I18n.locale = :sr
    engine = Gem.loaded_specs.fetch("decidim-bih").full_gem_path
    I18n.backend.load_translations(File.join(engine, "config/locales/decidim_bih_dialogue.yml"),
                                   File.join(engine, "config/locales/decidim_bih_utility_scope.yml"),
                                   File.expand_path("../../config/locales/milica_foundation_answers.yml", __dir__))
    @context = C::TrustedContext.new(organization_id: 71, conversation_key: "d" * 64, capabilities: ["public_reads"], now: NOW)
    @redis = MemoryRedis.new
    @store = D::StateStore.new(redis: @redis)
    @runtime = InlineRuntime.new
    @port = DecidimApp::Bijeljina::Milica::ReadPort.allocate
    @port.instance_variable_set(:@organization, ORGANIZATION)
    @model_calls = []
    @runner = D::ProcedureRunner.new(read_port: @port, registration_port: ->(**) { flunk "No account operation" },
                                     destinations: { report: "/reports/new", account: "/account", support: "/help", neighborhood: "/board" })
    @coordinator = D::Coordinator.new(procedures: @runner, state_store: @store, runtime: @runtime,
                                      understanding: lambda { |message:, **|
                                        @model_calls << message
                                        C::Understanding.clarify(locale: "sr")
                                      })
  end

  def teardown
    restore_synthetic_foundation_reference
    travel_back
    I18n.backend = @old_backend
    I18n.available_locales = @old_locales
    I18n.locale = @old_locale
  end

  def test_two_cited_foundation_sources_can_resume_with_how_to_apply_without_the_model
    seed_foundation
    answer = @coordinator.call(message: "Gdje mogu prijaviti svoju ideju?", context: @context)
    assert_equal "answered", answer.resolution
    assert_includes answer.reply.text, "foundation.example.invalid/idea"
    refute_includes answer.reply.text, "stanja na terenu"
    refute_match(/IBAN|555-|BA395/, answer.reply.text)
    assert_empty @model_calls
    assert_equal ["lfbn:idea_call"], @store.read(context: @context).fetch("prior_evidence").fetch("facts").map { |fact| fact.fetch("source_id") }.uniq
  end

  def test_unknown_or_mixed_reference_sources_cannot_select_the_foundation
    assert_nil reference_read(["lfbn:about", "unknown:private"])
    assert_nil reference_read([])
    assert_nil reference_read("lfbn:about")
    assert_nil reference_read(["lfbn:about"], message: "Kako prijaviti rupu na putu?")
    assert_nil reference_read(["lfbn:about"], context: @context.with(capabilities: []))
    assert_raises(C::Invalid) { reference_read(["lfbn:about"], context: @context.with(organization_id: 72)) }
  end

  def test_cancel_wins_and_a_report_task_does_not_get_a_reference_followup
    seed_foundation
    result = @coordinator.call(message: "odustani", context: @context)
    assert_equal "cancelled", result.resolution
    assert_nil @store.read(context: @context).fetch("prior_evidence")
    assert_empty @model_calls

    state = @store.empty_state(@context).merge("active_task" => "report_problem", "topic" => "report")
    assert_nil @runner.public_information_follow_up(state:, context: @context, message: "Gdje mogu prijaviti svoju ideju?")
  end

  def test_cas_conflict_withholds_the_new_reference_answer
    seed_foundation
    @redis.conflict = true
    answer = @coordinator.call(message: "Gdje mogu prijaviti svoju ideju?", context: @context)
    refute_equal "answered", answer.resolution
    refute_includes answer.reply.text, "foundation.example.invalid/idea"
    assert_empty @model_calls
  end

  def test_utility_household_challenge_answers_without_repeating_pending_area_choice
    C::LOCALES.each do |locale|
      context = @context.with(conversation_key: Digest::SHA256.hexdigest(locale))
      state = @store.empty_state(context).merge("active_task" => "ask_information", "topic" => "water", "pending_slot" => "area_query",
                                                "locale" => locale, "entities" => { "area_query" => "Vrt" },
                                                "entity_provenance" => { "area_query" => "citizen" })
      assert_equal :saved, @store.write(context:, state:, expected_version: 0)
      I18n.locale = locale
      message = locale == "sr-Cyrl" ? "Значи ли то да је свака кућа у Врту без воде?" : "Znači li to da je svaka kuća u Vrtu bez vode?"
      message = "Does that mean every house in Vrt has no water?" if locale == "en"
      answer = @coordinator.call(message:, context:)
      assert_equal "answered", answer.resolution
      assert_equal I18n.t("decidim.bih.dialogue.utility_household_scope", locale:), answer.reply.text
      assert_equal "area_query", @store.read(context:).fetch("pending_slot")
      assert_equal "Vrt", @store.read(context:).dig("entities", "area_query")
    end
    assert_empty @model_calls
  end

  def test_scope_question_does_not_match_reports_or_ordinary_outage_questions
    ["Danas nema vode u Vrtu", "Prijavi da je svaka kuća bez vode", "Znači li to da je svaka kuća bez vode? Pošalji prijavu."].each do |message|
      refute D::UtilityScopeQuestion.match?(message, topic: "water")
    end
    refute D::UtilityScopeQuestion.match?("Znači li to da je svaka kuća bez vode?", topic: "report")
  end

  private

  def reference_read(source_ids, message: "Gdje mogu prijaviti svoju ideju?", context: @context)
    @port.public_reference_follow_up(source_ids:, message:, context:, locale: "sr")
  end

  def seed_foundation
    reader = DecidimApp::Bijeljina::Milica::FoundationRead.new(organization: ORGANIZATION)
    values = reader.call(topic: "community", entities: { "query" => "Postoji li fondacija koja podržava ideje građana?" }, context: @context, locale: "sr")
    read = C::ReadResult.new(**values)
    evidence = D::PriorEvidence.capture(result: read, facts: read.facts, action: "ask_information", topic: "community", now: NOW, expires_at: NOW.to_f + 600)
    assert_equal 2, evidence.fetch("facts").length
    state = @store.empty_state(@context).merge("active_task" => "ask_information", "topic" => "community", "prior_evidence" => evidence)
    assert_equal :saved, @store.write(context: @context, state:, expected_version: 0)
  end
end
# rubocop:enable Rails/RefuteMethods, Rails/I18nLocaleAssignment
