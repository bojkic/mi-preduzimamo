# frozen_string_literal: true

# Standalone Minitest has refute helpers, without ActiveSupport assert_not aliases.
# rubocop:disable Rails/RefuteMethods

require "test_helper"
require File.join(Gem.loaded_specs.fetch("decidim-bih").full_gem_path,
                  "app/services/decidim/bih/concierge/dialogue/coordinator")

class MilicaRuntimeBudgetTest < Minitest::Test
  Coordinator = Decidim::Bih::Concierge::Dialogue::Coordinator
  Contracts = Decidim::Bih::Concierge::Dialogue::Contracts
  AdmissionControl = Decidim::Bih::Concierge::Dialogue::AdmissionControl
  StateStore = Decidim::Bih::Concierge::Dialogue::StateStore
  ProcedureRunner = Decidim::Bih::Concierge::Dialogue::ProcedureRunner
  Reply = Decidim::Bih::Concierge::Responder::Reply
  NOW = Time.utc(2026, 9, 5, 12)

  Organization = Data.define(:id)
  User = Data.define(:id, :organization, :admin) do
    def admin? = admin
  end
  Message = Data.define(:text, :conversation_context, :cancel, :safety_signal) do
    def cancel? = cancel == true

    def safety_signal? = safety_signal == true
  end

  unless method_defined?(:refute)
    def refute(value, message = nil)
      assert_equal false, !!value, message
    end
  end

  class ImmediateAdmission
    attr_reader :calls

    def initialize(status: :admitted)
      @status = status
      @calls = []
    end

    def with_slot(deadline:)
      calls << deadline
      return AdmissionControl::Result.new(status: @status) unless @status == :admitted

      AdmissionControl::Result.new(status: :admitted, value: yield)
    end
  end

  class TrackingStateStore
    attr_reader :read_calls, :write_calls

    def initialize(state:, write_result: :saved)
      @state = state
      @write_result = write_result
      @read_calls = []
      @write_calls = []
    end

    def read(context:)
      read_calls << context
      @state
    end

    def write(context:, state:, expected_version:)
      write_calls << { context:, state:, expected_version: }
      @write_result
    end
  end

  class TrackingUnderstanding
    attr_reader :calls

    def initialize(result)
      @result = result
      @calls = []
    end

    def call(**arguments)
      calls << arguments
      @result
    end
  end

  class TrackingProcedures
    attr_reader :calls

    def initialize(result: nil)
      @result = result
      @calls = []
    end

    def call(understanding:, state:, context:, message:)
      calls << { understanding:, state:, context:, message: }
      return @result if @result

      resolution = understanding.action == "cancel" ? "cancelled" : "answered"
      ProcedureRunner::Result.new(
        state:,
        reply: Reply.new(text: "deterministic", report: nil, answer_intent: "test", tone: "core"),
        resolution:,
        fact_ids: [],
        handoff_offered: false,
        handoff_completed: false
      )
    end

    def prior_evidence_follow_up(kind:, state:, context:, message:)
      calls << { kind:, state:, context:, message: }
      ProcedureRunner::Result.new(
        state:,
        reply: Reply.new(text: "retained", report: nil, answer_intent: "test", tone: "core"),
        resolution: "answered", fact_ids: [], handoff_offered: false, handoff_completed: false
      )
    end
  end

  class LeaseRedis
    attr_reader :leases

    def initialize
      @leases = Hash.new { |hash, key| hash[key] = {} }
    end

    def eval(script, keys:, argv:)
      return acquire(keys.first, argv) if script == AdmissionControl::ACQUIRE_SCRIPT

      leases.fetch(keys.first, {}).delete(argv.first) ? 1 : 0
    end

    private

    def acquire(key, argv)
      now, expires_at, limit, token = argv
      leases[key].delete_if { |_member, expiry| expiry <= now }
      return 0 if leases[key].size >= limit

      leases[key][token] = expires_at
      1
    end
  end

  class SlowClient
    attr_reader :calls, :elapsed, :completed

    def initialize(delay:)
      @delay = delay
      @calls = []
    end

    def configured? = true

    def generate_content(**arguments)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @completed = false
      calls << arguments
      sleep @delay
      @completed = true
      { "unused" => true }
    ensure
      @elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    end
  end

  class ManualClock
    attr_reader :now

    def initialize(now = 100.0)
      @now = now
    end

    def call = now

    def advance(seconds)
      @now += seconds
    end
  end

  class DeadlineCatchingClient
    attr_reader :calls

    def initialize(clock:)
      @clock = clock
      @calls = []
    end

    def configured? = true

    def generate_content(**arguments)
      calls << arguments
      @clock.advance(arguments.fetch(:timeout))
      raise Timeout::Error, "synthetic provider timeout"
    rescue Timeout::Error
      { "unused" => true }
    end
  end

  class ClientUnderstanding
    def initialize(client:, result:)
      @client = client
      @result = result
    end

    def call(**)
      @client.generate_content(contents: [{ role: "user", parts: [{ text: "synthetic" }] }])
      @result
    end
  end

  class LegacyResponder
    attr_reader :calls, :classifier_calls

    def initialize(reply)
      @reply = reply
      @calls = []
      @classifier_calls = 0
    end

    def respond(message)
      calls << { message:, model_allowed: Coordinator::Runtime.model_allowed? }
      @classifier_calls += 1 if Coordinator::Runtime.model_allowed?
      @reply
    end
  end

  def setup
    @original_i18n = i18n_snapshot

    locale_path = File.join(Gem.loaded_specs.fetch("decidim-bih").full_gem_path, "config/locales/decidim_bih_dialogue.yml")
    isolated_backend = I18n::Backend::Simple.new

    I18n.available_locales = Contracts::LOCALES
    I18n.backend = isolated_backend
    begin
      I18n.load_path.replace([locale_path])
      isolated_backend.eager_load!
    ensure
      I18n.load_path.replace(@original_i18n.fetch(:load_path))
    end
  end

  def teardown
    restore_i18n(@original_i18n)
  end

  def test_dialogue_translations_use_an_isolated_backend_for_every_supported_locale
    assert_equal false, @original_i18n.fetch(:backend).equal?(I18n.backend)
    assert_equal @original_i18n.fetch(:load_path), I18n.load_path
    assert_equal Contracts::LOCALES.map(&:to_sym), I18n.available_locales

    Contracts::LOCALES.each do |locale|
      assert_predicate I18n.t("decidim.bih.dialogue.clarify", locale:, raise: true), :present?
    end
    assert_raises(I18n::MissingTranslationData) do
      I18n.t("decidim.bih.goodwill.rewards.majica", locale: :sr, raise: true)
    end
  end

  def test_i18n_snapshot_restores_all_mutated_process_state
    isolated = i18n_snapshot
    I18n.backend = I18n::Backend::Simple.new
    I18n.available_locales = [:en]
    I18n.locale = :en # rubocop:disable Rails/I18nLocaleAssignment -- exercise explicit process-state restoration
    I18n.load_path.replace([])

    restore_i18n(isolated)

    assert_same isolated.fetch(:backend), I18n.backend
    assert_equal isolated.fetch(:available_locales), I18n.available_locales
    assert_equal isolated.fetch(:locale), I18n.locale
    assert_equal isolated.fetch(:load_path), I18n.load_path
  ensure
    restore_i18n(isolated) if isolated
  end

  def test_settings_deny_public_actor_or_organization_mismatch
    settings = Coordinator::Settings.new(env: enabled_env("MILICA_DIALOGUE_AUDIENCE" => "public"))

    assert settings.v1_enabled_for?(context: context, user: nil)
    assert settings.v1_enabled_for?(context: context(actor_id: 7), user: user(id: 7, organization_id: 1))
    refute settings.v1_enabled_for?(context: context(actor_id: 7), user: nil)
    refute settings.v1_enabled_for?(context: context(actor_id: 7), user: user(id: 8, organization_id: 1))
    refute settings.v1_enabled_for?(context: context(actor_id: 7), user: user(id: 7, organization_id: 2))
    refute settings.v1_enabled_for?(context: context, user: user(id: 7, organization_id: 1))
  end

  def test_settings_deny_malformed_or_slash_model_overrides
    ["models/gemini", "bad model", "/gemini", "x" * 101].each do |candidate|
      settings = Coordinator::Settings.new(env: enabled_env("MILICA_CONVERSATION_MODEL" => candidate))

      assert_nil settings.model_override
      refute settings.v1_enabled_for?(context: context, user: nil)
    end

    valid = Coordinator::Settings.new(env: enabled_env("MILICA_CONVERSATION_MODEL" => "gemini-2.5-flash"))
    assert_equal "gemini-2.5-flash", valid.model_override
  end

  def test_safety_and_supplied_credentials_bypass_state_and_understanding
    state_store = TrackingStateStore.new(state: empty_state)
    understanding = TrackingUnderstanding.new(understanding())
    procedures = TrackingProcedures.new
    admission = ImmediateAdmission.new
    coordinator = build_coordinator(state_store:, understanding:, procedures:, admission:)

    results = [
      coordinator.call(message: build_message("hitno", safety_signal: true), context: context),
      coordinator.call(message: build_message("Moj kod je 123456"), context: context)
    ]

    assert_equal %w(safety setup), (results.map { |result| result.reply.answer_intent })
    assert_equal %w(safety_guidance unsupported), results.map(&:resolution)
    assert(results.all? { |result| result.reply.report.nil? })
    assert_empty state_store.read_calls
    assert_empty understanding.calls
    assert_empty procedures.calls
    assert_empty admission.calls
  end

  def test_negative_action_cancellation_and_resume_bypass_understanding
    current = empty_state.merge(
      "active_task" => "registration",
      "suspended_task" => { "active_task" => "ask_information" }
    )
    state_store = TrackingStateStore.new(state: current)
    understanding = TrackingUnderstanding.new(understanding(action: "registration", topic: "account"))
    procedures = TrackingProcedures.new
    coordinator = build_coordinator(state_store:, understanding:, procedures:)

    cancelled = coordinator.call(message: build_message("Ne objavljuj ovo; promijeni adresu"), context: context)
    coordinator.call(message: build_message("nastavi"), context: context)

    assert_equal "cancelled", cancelled.resolution
    assert_equal "cancel", procedures.calls.first.fetch(:understanding).action
    assert_equal "help", procedures.calls.last.fetch(:understanding).action
    assert procedures.calls.last.fetch(:understanding).needs_clarification
    assert_empty understanding.calls
  end

  def test_combined_cancellation_and_protected_signals_cas_clear_without_provider_calls
    [
      build_message("Odustani, neko mi prijeti", safety_signal: true),
      build_message("Odustani, moj kod je 123456")
    ].each do |message|
      state_store = TrackingStateStore.new(state: pending_state)
      understanding = TrackingUnderstanding.new(understanding(action: "report_problem", topic: "roads"))
      procedures = real_procedures
      coordinator = build_coordinator(state_store:, understanding:, procedures:)

      result = coordinator.call(message:, context: context)

      assert_equal(message.safety_signal? ? "safety_guidance" : "cancelled", result.resolution)
      expected_intent = message.safety_signal? ? "safety" : "setup"
      assert_equal expected_intent, result.reply.answer_intent
      cancellation_copy = I18n.t("decidim.bih.dialogue.cancelled", locale: "sr")
      if message.safety_signal?
        refute_includes result.reply.text, cancellation_copy
      else
        assert_includes result.reply.text, cancellation_copy
      end
      protected_key = message.safety_signal? ? "safety" : "credentials"
      protected_locale = Coordinator.locale_for(message)
      assert_includes result.reply.text, I18n.t("decidim.bih.dialogue.#{protected_key}", locale: protected_locale)
      assert_nil result.state.fetch("active_task")
      assert_nil result.state.fetch("pending_slot")
      assert_nil result.state.fetch("suspended_task")
      assert_nil result.state.fetch("draft")
      assert_empty understanding.calls
      assert_equal 1, state_store.read_calls.size
      assert_equal 1, state_store.write_calls.size
      assert_equal 0, state_store.write_calls.first.fetch(:expected_version)
    end
  end

  def test_combined_protected_cancellation_does_not_claim_success_when_cas_fails
    [:conflict, :unavailable].each do |write_result|
      message = build_message("Odustani, moj kod je 123456")
      state_store = TrackingStateStore.new(state: pending_state, write_result:)
      understanding = TrackingUnderstanding.new(understanding(action: "report_problem", topic: "roads"))
      coordinator = build_coordinator(state_store:, understanding:, procedures: real_procedures)

      result = coordinator.call(message:, context: context)

      assert_unsupported result
      assert_equal "fallback", result.reply.answer_intent
      assert_includes result.reply.text, I18n.t("decidim.bih.dialogue.credentials", locale: Coordinator.locale_for(message))
      assert_empty understanding.calls
      assert_equal 1, state_store.write_calls.size
    end
  end

  def test_urgent_guidance_survives_failed_cancellation_without_claiming_it_was_saved
    [
      [:conflict, :admitted, pending_state, "safety_guidance"],
      [:saved, :capacity, pending_state, "safety_guidance"],
      [:saved, :admitted, nil, "safety_guidance"]
    ].each do |write_result, status, state, resolution|
      message = build_message("Odustani, neko mi prijeti", safety_signal: true)
      state_store = TrackingStateStore.new(state:, write_result:)
      understanding = TrackingUnderstanding.new(understanding())
      coordinator = build_coordinator(state_store:, understanding:, procedures: real_procedures, admission: ImmediateAdmission.new(status:))

      result = coordinator.call(message:, context: context)

      assert_unsupported(result, resolution:)
      assert_includes result.reply.text, I18n.t("decidim.bih.dialogue.safety", locale: Coordinator.locale_for(message))
      assert_empty understanding.calls
    end
  end

  def test_registration_difficulty_is_not_mistaken_for_cancellation
    state_store = TrackingStateStore.new(state: empty_state)
    understanding = TrackingUnderstanding.new(understanding(action: "registration", topic: "account"))
    procedures = TrackingProcedures.new
    coordinator = build_coordinator(state_store:, understanding:, procedures:)

    result = coordinator.call(message: build_message("Ne mogu da se registrujem"), context: context)

    assert_equal "answered", result.resolution
    assert_equal 1, understanding.calls.size
    assert_equal "registration", procedures.calls.first.fetch(:understanding).action
  end

  def test_standalone_repairs_preserve_the_task_without_understanding_or_backend_calls
    {
      "Pogrešno si me razumjela." => "sr",
      "Погрешно си ме разумјела." => "sr-Cyrl",
      "Nisi me dobro razumela" => "sr",
      "Ne, nisam rekao da šalješ." => "sr",
      "Ne, nisam rekla da šalješ." => "sr",
      "You misunderstood me." => "en"
    }.each do |text, locale|
      current = pending_state.merge("pending_slot" => nil)
      current["entities"] = current.fetch("entities").merge("area_query" => "Dvorovi")
      current["entity_provenance"] = current.fetch("entity_provenance").merge("area_query" => "citizen")
      state_store = TrackingStateStore.new(state: current)
      understanding = TrackingUnderstanding.new(understanding())
      coordinator = build_coordinator(state_store:, understanding:, procedures: real_procedures)

      result = coordinator.call(message: build_message(text), context: context)

      assert_empty understanding.calls, text
      assert_equal "clarification", result.resolution, text
      assert_equal "report_problem", result.state.fetch("active_task")
      assert_equal "roads", result.state.fetch("topic")
      assert_equal current.fetch("entities"), result.state.fetch("entities")
      assert_equal current.fetch("suspended_task"), result.state.fetch("suspended_task")
      assert_equal locale, result.state.fetch("locale")
      assert_includes result.reply.text, I18n.t("decidim.bih.dialogue.repair_clarify", locale:)
      assert_nil result.state.fetch("draft")
      assert_nil result.reply.report
      assert_empty result.fact_ids
      refute result.handoff_offered
      refute result.handoff_completed
      assert_equal 1, state_store.write_calls.size
    end
  end

  def test_standalone_repair_without_a_task_clarifies_without_a_model_call
    state_store = TrackingStateStore.new(state: empty_state)
    understanding = TrackingUnderstanding.new(understanding())
    coordinator = build_coordinator(state_store:, understanding:, procedures: real_procedures)

    result = coordinator.call(message: build_message("Pogrešno si me razumjela"), context: context)

    assert_empty understanding.calls
    assert_equal "clarification", result.resolution
    assert_equal "help", result.state.fetch("active_task")
    assert_nil result.state.fetch("suspended_task")
    refute result.handoff_completed
  end

  def test_detailed_corrections_and_no_submit_constraints_are_not_swallowed_by_the_repair_fast_path
    [
      "Pogrešno si me razumjela, u Dvorovima",
      "Ne šalji ništa bez moje potvrde.",
      "Ne mijenjaj profil bez moje potvrde.",
      "Šta znači pogrešno si me razumjela?"
    ].each do |text|
      state_store = TrackingStateStore.new(state: pending_state)
      understanding = TrackingUnderstanding.new(understanding(action: "report_problem", topic: "roads"))
      procedures = TrackingProcedures.new
      coordinator = build_coordinator(state_store:, understanding:, procedures:)

      coordinator.call(message: build_message(text), context: context)

      assert_equal 1, understanding.calls.size, text
      assert_equal "report_problem", procedures.calls.first.fetch(:understanding).action
    end
  end

  def test_failed_repair_state_save_does_not_claim_success
    [:conflict, :unavailable].each do |write_result|
      state_store = TrackingStateStore.new(state: pending_state, write_result:)
      understanding = TrackingUnderstanding.new(understanding())
      coordinator = build_coordinator(state_store:, understanding:, procedures: real_procedures)

      result = coordinator.call(message: build_message("Pogrešno si me razumjela"), context: context)

      assert_empty understanding.calls
      assert_unsupported result
      refute result.reply.text.include?(I18n.t("decidim.bih.dialogue.repair_clarify", locale: :sr))
    end
  end

  # A capacity refusal is named "busy" so the metrics can tell it from a
  # request the platform does not support; an expired turn stays unsupported.
  def test_capacity_is_busy_and_expiry_is_unsupported
    { capacity: "busy", expired: "unsupported" }.each do |status, resolution|
      state_store = TrackingStateStore.new(state: empty_state)
      understanding = TrackingUnderstanding.new(understanding())
      procedures = TrackingProcedures.new
      coordinator = build_coordinator(
        state_store:,
        understanding:,
        procedures:,
        admission: ImmediateAdmission.new(status:)
      )

      result = coordinator.call(message: build_message("Ima li vode?"), context: context)
      assert_unsupported(result, resolution:)
      assert_equal I18n.t("decidim.bih.dialogue.#{resolution == "busy" ? "busy" : "context_unavailable"}", locale: :sr, raise: true), result.reply.text
      assert_empty state_store.read_calls
      assert_empty understanding.calls
      assert_empty procedures.calls
    end
  end

  def test_state_read_failure_is_truthful_and_does_not_call_dependencies
    state_store = TrackingStateStore.new(state: nil)
    understanding = TrackingUnderstanding.new(understanding())
    procedures = TrackingProcedures.new
    coordinator = build_coordinator(state_store:, understanding:, procedures:)

    assert_unsupported coordinator.call(message: build_message("Ima li vode?"), context: context)
    assert_equal 1, state_store.read_calls.size
    assert_empty understanding.calls
    assert_empty procedures.calls
    assert_empty state_store.write_calls
  end

  def test_exact_evidence_followup_bypasses_understanding_and_uses_cas
    state = empty_state.merge("prior_evidence" => {
                                "version" => 1, "kind" => "public_read", "action" => "ask_information", "topic" => "water", "status" => "ok",
                                "facts" => [{ "id" => "notice:1", "source_id" => "water_operator" }], "scope" => { "area_slugs" => [] }, "expires_at" => NOW.to_f + 60
                              })
    store = TrackingStateStore.new(state:)
    model = TrackingUnderstanding.new(understanding)
    procedures = TrackingProcedures.new
    result = build_coordinator(state_store: store, understanding: model, procedures:).call(
      message: Message.new("Одакле ти то?", [], false, false), context: context
    )

    assert_equal "answered", result.resolution
    assert_empty model.calls
    assert_equal "source", procedures.calls.first.fetch(:kind)
    assert_equal 1, store.write_calls.length
  end

  def test_mixed_evidence_phrase_uses_normal_understanding_and_keeps_the_retained_reference
    state = empty_state.merge("prior_evidence" => {
                                "version" => 1, "kind" => "public_read", "action" => "ask_information", "topic" => "water", "status" => "ok",
                                "facts" => [{ "id" => "notice:1", "source_id" => "water_operator" }], "scope" => { "area_slugs" => [] }, "expires_at" => NOW.to_f + 60
                              })
    store = TrackingStateStore.new(state:)
    model = TrackingUnderstanding.new(understanding)
    procedures = TrackingProcedures.new

    result = build_coordinator(state_store: store, understanding: model, procedures:).call(
      message: build_message("Odakle ti to za vodu?"), context: context
    )

    assert_equal "answered", result.resolution
    assert_equal 1, model.calls.size
    assert procedures.calls.first.has_key?(:understanding)
    assert_equal 1, store.write_calls.size
  end

  def test_exact_evidence_followup_cas_conflict_never_returns_the_retained_answer
    state = empty_state.merge("prior_evidence" => {
                                "version" => 1, "kind" => "public_read", "action" => "ask_information", "topic" => "water", "status" => "ok",
                                "facts" => [{ "id" => "notice:1", "source_id" => "water_operator" }], "scope" => { "area_slugs" => [] }, "expires_at" => NOW.to_f + 60
                              })
    store = TrackingStateStore.new(state:, write_result: :conflict)
    model = TrackingUnderstanding.new(understanding)
    procedures = TrackingProcedures.new

    result = build_coordinator(state_store: store, understanding: model, procedures:).call(
      message: build_message("Odakle ti to?"), context: context
    )

    assert_unsupported result
    assert_includes result.reply.text, I18n.t("decidim.bih.dialogue.context_changed", locale: "sr")
    assert_empty model.calls
    assert_equal "source", procedures.calls.first.fetch(:kind)
  end

  def test_controls_and_secondary_leave_retained_evidence_unmodified
    evidence = {
      "version" => 1, "kind" => "public_read", "action" => "ask_information", "topic" => "water", "status" => "ok",
      "facts" => [{ "id" => "notice:1", "source_id" => "water_operator" }], "scope" => { "area_slugs" => [] }, "expires_at" => NOW.to_f + 60
    }
    [build_message("Pomoć"), build_message("Hitno", safety_signal: true)].each do |message|
      state = empty_state.merge("prior_evidence" => evidence)
      store = TrackingStateStore.new(state:)
      coordinator = build_coordinator(state_store: store, understanding: TrackingUnderstanding.new(understanding), procedures: TrackingProcedures.new)

      coordinator.call(message:, context: context)

      assert_equal evidence, state.fetch("prior_evidence")
      assert_empty store.read_calls
      assert_empty store.write_calls
    end

    state = empty_state.merge("prior_evidence" => evidence)
    store = TrackingStateStore.new(state:)
    responder = LegacyResponder.new(Reply.new(text: "Bodovi i nagrade su javno opisani.", report: nil, answer_intent: "goodwill", tone: "core"))
    secondary = Coordinator::LegacyReadAdapter.new(responder:)
    model = TrackingUnderstanding.new(understanding(topic: "goodwill"))
    coordinator = build_coordinator(state_store: store, understanding: model, procedures: TrackingProcedures.new, legacy_secondary: secondary)

    coordinator.call(message: build_message("Odakle ti to za bodove?"), context: context)

    assert_equal evidence, state.fetch("prior_evidence")
    assert_equal 1, model.calls.size
    assert_empty store.write_calls
  end

  def test_cas_failures_never_leak_candidate_success_or_completion
    candidate = ProcedureRunner::Result.new(
      state: empty_state,
      reply: Reply.new(text: "completed", report: nil, answer_intent: "service", tone: "core"),
      resolution: "answered",
      fact_ids: ["fact:1"],
      handoff_offered: true,
      handoff_completed: true
    )

    [:conflict, :unavailable].each do |write_result|
      state_store = TrackingStateStore.new(state: empty_state, write_result:)
      coordinator = build_coordinator(
        state_store:,
        understanding: TrackingUnderstanding.new(understanding),
        procedures: TrackingProcedures.new(result: candidate)
      )

      result = coordinator.call(message: build_message("Ima li vode?"), context: context)

      assert_unsupported result
      refute result.handoff_offered
      refute result.handoff_completed
      assert_empty result.fact_ids
      assert_equal 1, state_store.write_calls.size
    end
  end

  def test_slow_provider_is_interrupted_within_the_shared_execution_budget
    raw_client = SlowClient.new(delay: 0.2)
    budgeted_client = Coordinator::BudgetedClient.new(client: raw_client)
    runtime = runtime_with_redis(timeout: 0.04, token: "runtime_timeout_0001")
    coordinator = Coordinator.new(
      understanding: ClientUnderstanding.new(client: budgeted_client, result: understanding),
      procedures: TrackingProcedures.new,
      state_store: TrackingStateStore.new(state: empty_state),
      runtime:
    )
    message = build_message("Ima li vode?")
    # setup deliberately reloads translations. This execution-budget probe
    # uses a warm fallback; cold locale loading and the complete external
    # response target belong to the separate integration/capacity gate.
    I18n.t("decidim.bih.dialogue.context_unavailable", locale: Coordinator.locale_for(message), raise: true)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    result = coordinator.call(message:, context: context)

    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    assert_unsupported result
    assert_operator elapsed, :<, 0.15
    assert_equal 1, raw_client.calls.size
    assert_equal false, raw_client.completed
    assert_operator raw_client.elapsed, :<, 0.15
    assert_operator raw_client.calls.first.fetch(:timeout), :<=, 0.04
    assert_nil Coordinator::Runtime.current_budget
  end

  def test_budgeted_client_rejects_late_value_before_state_write_while_parent_remains_live
    clock = ManualClock.new
    budget_class = Decidim::Bih::Concierge::Dialogue::TurnBudget
    parent = budget_class.new(timeout: 9, clock:)
    raw_client = DeadlineCatchingClient.new(clock:)
    budgeted_client = Coordinator::BudgetedClient.new(client: raw_client)
    state_store = TrackingStateStore.new(state: empty_state)
    procedures = TrackingProcedures.new
    coordinator = Coordinator.new(
      understanding: ClientUnderstanding.new(client: budgeted_client, result: understanding),
      procedures:,
      state_store:,
      runtime: Coordinator::Runtime.new(admission: ImmediateAdmission.new, timeout: 9)
    )

    result = budget_class.stub(:new, parent) do
      coordinator.call(message: build_message("Ima li vode?"), context: context)
    end

    assert_unsupported result
    assert_equal 1, raw_client.calls.size
    assert_operator parent.remaining_seconds, :>, 0
    assert_empty procedures.calls
    assert_empty state_store.write_calls
    assert_nil Coordinator::Runtime.current_budget
  end

  def test_admission_is_shared_and_never_allows_a_third_active_runtime
    redis = LeaseRedis.new
    runtimes = 3.times.map do |index|
      runtime_with_redis(redis:, timeout: 1.0, token: format("runtime_slot_%08d", index))
    end
    third_yielded = false
    third = nil

    first = runtimes[0].call do
      second = runtimes[1].call do
        third = runtimes[2].call { third_yielded = true }
        :second
      end
      assert second.admitted?
      :first
    end

    assert first.admitted?
    assert_equal :capacity, third.status
    refute third_yielded
    assert_empty redis.leases.values.flat_map(&:keys)
  end

  def test_legacy_read_adapter_returns_only_typed_text_and_never_reenters_a_model
    source_reply = Reply.new(
      text: "Javni odgovor",
      report: nil,
      sticker: :prijavljeno,
      quick_replies: [{ label: "Detalji", url: "/pages/detalji" }],
      answer_intent: "donation",
      tone: "core"
    )
    responder = LegacyResponder.new(source_reply)
    adapter = Coordinator::LegacyReadAdapter.new(responder:)

    result = adapter.call(message: build_message("Kako donirati?"), understanding: understanding(topic: "donation"))

    assert_instance_of Coordinator::LegacyReadAdapter::Result, result
    assert_instance_of Reply, result.reply
    assert_equal "answered", result.resolution
    assert_nil result.reply.report
    assert_nil result.reply.sticker
    assert_equal [false], (responder.calls.map { |call| call.fetch(:model_allowed) })
    assert_equal 0, responder.classifier_calls
    assert Coordinator::Runtime.model_allowed?
  end

  def test_legacy_read_adapter_rejects_report_or_untyped_reply
    report = Reply.new(text: "not safe", report: Object.new, answer_intent: "donation")
    assert_raises(Contracts::Invalid) do
      Coordinator::LegacyReadAdapter.new(responder: LegacyResponder.new(report)).call(
        message: build_message("Pitanje"),
        understanding: understanding(topic: "donation")
      )
    end

    untyped = Struct.new(:text, :report).new("looks similar", nil)
    assert_raises(Contracts::Invalid) do
      Coordinator::LegacyReadAdapter.new(responder: LegacyResponder.new(untyped)).call(
        message: build_message("Pitanje"),
        understanding: understanding(topic: "donation")
      )
    end
  end

  def test_real_coordinator_secondary_read_has_no_second_classifier_or_media
    source_reply = Reply.new(text: "Bodovi i nagrade su javno opisani.", report: nil, sticker: :hvala,
                             answer_intent: "goodwill", tone: "core")
    responder = LegacyResponder.new(source_reply)
    legacy = Coordinator::LegacyReadAdapter.new(responder:)
    model_understanding = TrackingUnderstanding.new(understanding(topic: "goodwill"))
    procedures = TrackingProcedures.new
    state_store = TrackingStateStore.new(state: empty_state)
    coordinator = build_coordinator(
      state_store:,
      understanding: model_understanding,
      procedures:,
      legacy_secondary: legacy
    )

    # "Kako funkcionišu bodovi?" is an earning question the fast path answers
    # without the model, and "Šta su bodovi zajedništva?" is now a points
    # EXPLANATION the fast path answers too (points_explainer_route.rb). This
    # test needs a goodwill question that still reaches the model.
    result = coordinator.call(message: build_message("A šta je sa bodovima za volontiranje?"), context: context)

    assert_equal "answered", result.resolution
    assert_nil result.reply.report
    assert_nil result.reply.sticker
    assert_equal 1, model_understanding.calls.size
    assert_equal 0, responder.classifier_calls
    assert_empty procedures.calls
    assert_empty state_store.write_calls
  end

  private

  def i18n_snapshot
    {
      backend: I18n.backend,
      available_locales: I18n.available_locales.dup,
      locale: I18n.locale,
      load_path: I18n.load_path.dup
    }
  end

  def restore_i18n(snapshot)
    I18n.backend = snapshot.fetch(:backend)
    I18n.available_locales = snapshot.fetch(:available_locales)
    I18n.locale = snapshot.fetch(:locale) # rubocop:disable Rails/I18nLocaleAssignment -- restore the locale captured before setup
    I18n.load_path.replace(snapshot.fetch(:load_path))
  end

  def enabled_env(overrides = {})
    {
      "MILICA_DIALOGUE_ENABLED" => "true",
      "MILICA_DIALOGUE_AUDIENCE" => "public",
      "MILICA_DIALOGUE_COHORT_USER_IDS" => "",
      "MILICA_COMPOSITION_ENABLED" => "false",
      "MILICA_CONVERSATIONAL_WRITES_ENABLED" => "false",
      "MILICA_CONVERSATION_MODEL" => ""
    }.merge(overrides)
  end

  def context(organization_id: 1, actor_id: nil)
    Contracts::TrustedContext.new(
      organization_id:,
      conversation_key: "a" * 64,
      actor_id:,
      capabilities: %w(public_reads report_guidance registration_handoff),
      now: NOW
    )
  end

  def user(id:, organization_id:, admin: false)
    User.new(id:, organization: Organization.new(id: organization_id), admin:)
  end

  def build_message(text, cancel: false, safety_signal: false)
    Message.new(text:, conversation_context: [], cancel:, safety_signal:)
  end

  def empty_state
    StateStore.new.empty_state(context)
  end

  def pending_state
    suspended = empty_state.slice(*StateStore::TASK_KEYS).merge(
      "active_task" => "ask_information",
      "topic" => "water",
      "entities" => { "area_query" => "Dvorovi" },
      "entity_provenance" => { "area_query" => "citizen" }
    )
    empty_state.merge(
      "active_task" => "report_problem",
      "topic" => "roads",
      "pending_slot" => "area_query",
      "entities" => { "description" => "Pokvarena lampa" },
      "entity_provenance" => { "description" => "citizen" },
      "suspended_task" => suspended,
      "draft" => { "reference" => "draft_reference_01", "revision" => 2, "expires_at" => NOW.to_f + 300 }
    )
  end

  def real_procedures
    unavailable_port = Object.new
    unavailable_port.define_singleton_method(:call) { |**| raise "Cancellation must not call a port" }
    ProcedureRunner.new(
      read_port: unavailable_port,
      registration_port: unavailable_port,
      destinations: { report: "/reports/new", account: "/account", neighborhood: "/neighborhood", support: "/support" }
    )
  end

  def understanding(action: "ask_information", topic: "water")
    Contracts::Understanding.parse(
      action:,
      topic:,
      entities: {},
      operation: "start",
      needs_clarification: false,
      secondary: nil,
      locale: "sr"
    )
  end

  def build_coordinator(state_store:, understanding:, procedures:, admission: ImmediateAdmission.new, legacy_secondary: nil)
    Coordinator.new(
      understanding:,
      procedures:,
      state_store:,
      runtime: Coordinator::Runtime.new(admission:, timeout: 1.0),
      legacy_secondary:
    )
  end

  def runtime_with_redis(timeout:, token:, redis: LeaseRedis.new)
    admission = AdmissionControl.new(
      redis:,
      limit: 2,
      lease_ttl: 1.0,
      redis_timeout: 0.005,
      max_work_seconds: 0.5,
      token_factory: -> { token }
    )
    Coordinator::Runtime.new(admission:, timeout:)
  end

  def assert_unsupported(result, resolution: "unsupported")
    assert_instance_of ProcedureRunner::Result, result
    assert_equal resolution, result.resolution
    assert_nil result.reply.report
    refute result.handoff_completed
  end
end

# rubocop:enable Rails/RefuteMethods
