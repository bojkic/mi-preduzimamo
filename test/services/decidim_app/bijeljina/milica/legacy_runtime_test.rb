# frozen_string_literal: true

# rubocop:disable Rails/RefuteMethods -- standalone Minitest, no Rails assertions

require "test_helper"
require "minitest/mock"
require "logger"
require "stringio"
require "active_support"
require "active_support/core_ext"
engine = Gem.loaded_specs.fetch("decidim-bih").full_gem_path
require File.join(engine, "app/services/decidim/bih/concierge/dialogue/coordinator")
require_relative "../../../../../app/services/decidim_app/bijeljina/concierge"
require_relative "../../../../../app/services/decidim_app/bijeljina/web_concierge"
require_relative "../../../../../app/services/decidim_app/bijeljina/milica_personality"
require_relative "../../../../../app/services/decidim_app/bijeljina/milica/chat_report_intake"
require_relative "../../../../../app/services/decidim_app/bijeljina/milica/model_led_coordinator"

# The historical filename stays discoverable; the retired fallback is forbidden.
class DecidimApp::Bijeljina::LegacyRuntimeTest < Minitest::Test
  Web = DecidimApp::Bijeljina::WebConcierge
  Native = DecidimApp::Bijeljina::Concierge
  Host = DecidimApp::Bijeljina::Milica::ModelLedCoordinator
  Dialogue = Decidim::Bih::Concierge::Dialogue
  Reply = Decidim::Bih::Concierge::Responder::Reply
  Message = Struct.new(:text, :user, :trusted_context, keyword_init: true)
  User = Struct.new(:id, :decidim_organization_id)
  Admission = Struct.new(:status, :value) do
    def admitted? = status == :admitted
  end

  def setup
    @prior_logger = Rails.logger
    Rails.logger = Logger.new(StringIO.new)
    @previous_env = ENV.to_h.slice("MILICA_DIALOGUE_ENABLED", "MILICA_CONVERSATION_ARCHITECTURE", "MILICA_CONVERSATIONAL_WRITES_ENABLED")
    ENV["MILICA_DIALOGUE_ENABLED"] = "true"
    ENV["MILICA_CONVERSATION_ARCHITECTURE"] = "model_led"
    ENV["MILICA_CONVERSATIONAL_WRITES_ENABLED"] = "false"
    @context = Dialogue::Contracts::TrustedContext.new(organization_id: 71, conversation_key: "a" * 64, capabilities: ["public_reads"])
    @message = Message.new(text: "Autobus za Janju?", trusted_context: @context)
    @outcome = Dialogue::ProcedureRunner::Result.new(state: nil, reply: Reply.new(text: "public result", answer_intent: "service"),
                                                     resolution: "answered", fact_ids: ["e1"], handoff_offered: false, handoff_completed: false)
    @calls = []
    @coordinator = Object.new
    calls = @calls
    outcome = @outcome
    @coordinator.define_singleton_method(:call) do |**arguments|
      calls << arguments
      outcome
    end
    Web.reset!
  end

  def teardown
    Rails.logger = @prior_logger
    %w(MILICA_DIALOGUE_ENABLED MILICA_CONVERSATION_ARCHITECTURE MILICA_CONVERSATIONAL_WRITES_ENABLED).each { |key| ENV.delete(key) }
    @previous_env.each { |key, value| ENV[key] = value }
    Web.reset!
  end

  def test_missing_context_fails_closed_without_model_or_legacy_retry
    [nil, Object.new].each do |scope|
      @message.trusted_context = scope
      result = respond
      assert_equal "fallback", result.answer_intent
    end
    assert_empty @calls
    refute Web.respond_to?(:legacy_reply, true)
  end

  def test_missing_or_wrong_architecture_and_global_write_flag_do_not_dispatch
    [%w(MILICA_DIALOGUE_ENABLED false), %w(MILICA_CONVERSATION_ARCHITECTURE legacy), %w(MILICA_CONVERSATIONAL_WRITES_ENABLED true)].each do |key, value|
      old = ENV.fetch(key, nil)
      ENV[key] = value
      assert_equal "fallback", respond.answer_intent
      ENV[key] = old
    end
    assert_empty @calls
  end

  def test_enabled_context_uses_one_coordinator_and_attaches_actual_outcome
    answer = respond
    assert_same @outcome, answer.dialogue_outcome
    assert_same @message, @calls.first[:message]
    assert_same @context, @calls.first[:context]
    assert_equal 1, @calls.size
  end

  def test_message_user_must_match_trusted_actor_and_tenant
    [[User.new(5, 71), nil], [nil, 5], [User.new(6, 71), 5], [User.new(5, 72), 5]].each do |user, actor|
      @message.user = user
      @message.trusted_context = @context.with(actor_id: actor)
      assert_equal "fallback", respond.answer_intent
    end
    assert_empty @calls
    @message.user = User.new(5, 71)
    @message.trusted_context = @context.with(actor_id: 5)
    assert_equal "public result", respond.text
  end

  def test_nil_wrong_and_exception_coordinator_results_never_retry_and_personality_runs_once
    [nil, Object.new, :raise].each do |value|
      count = 0
      coordinator = Object.new
      coordinator.define_singleton_method(:call) do |**|
        count += 1
        raise "synthetic provider failure" if value == :raise

        value
      end
      personality_count = 0
      personality = lambda { |reply:, **|
        personality_count += 1
        reply
      }
      assert_equal "fallback", respond(coordinator:, personality:).answer_intent
      assert_equal 1, count
      assert_equal 1, personality_count
    end
  end

  def test_safety_precedes_disabled_model_and_preserves_typed_outcome
    ENV["MILICA_DIALOGUE_ENABLED"] = "false"
    safety = Reply.new(text: "Pozovi 123.", answer_intent: "safety")
    Web.stub(:immediate_control_reply, safety) do
      answer = respond
      assert_equal "safety_guidance", answer.dialogue_outcome.resolution
    end
    assert_empty @calls
  end

  def test_provider_admission_denials_never_enter_runtime_execution
    [:capacity, :expired, :unavailable].each do |status|
      runtime = Object.new
      runtime.define_singleton_method(:call) { |&_| Admission.new(status, nil) }
      coordinator = host(runtime:)
      coordinator.define_singleton_method(:execute) { |**| raise "Admission must not execute" }
      assert_equal("busy", coordinator.call(message: @message, context: @context).resolution)
    end
  end

  def test_nil_malformed_and_raising_admission_results_fail_closed
    [nil, Object.new, Admission.new(:admitted, nil), Admission.new(:admitted, Object.new), :raise].each do |result|
      calls = 0
      runtime = Object.new
      runtime.define_singleton_method(:call) do |&_|
        calls += 1
        raise "synthetic runtime failure" if result == :raise

        result
      end
      coordinator = host(runtime:)
      coordinator.define_singleton_method(:execute) { |**| raise "No admitted work provided" }
      assert_equal "busy", coordinator.call(message: @message, context: @context).resolution
      assert_equal 1, calls
    end
  end

  def test_admission_passes_same_budget_and_does_not_retry_execution_exception
    budget = Dialogue::TurnBudget.new(timeout: 9)
    runtime = Object.new
    runtime.define_singleton_method(:call) { |&block| Admission.new(:admitted, block.call(budget)) }
    coordinator = host(runtime:)
    calls = []
    coordinator.define_singleton_method(:execute) do |context:, **|
      calls << context.deadline
      raise "synthetic execution failure"
    end
    assert_equal "busy", coordinator.call(message: @message, context: @context).resolution
    assert_equal [budget], calls
  end

  def test_fallback_preserves_safe_shortcuts
    @message.trusted_context = nil
    Web.stub(:fallback_quick_replies, [{ label: "Support", url: "/support" }]) do
      assert_equal [{ label: "Support", url: "/support" }], respond.quick_replies
    end
  end

  def test_coordinator_cache_is_organization_bound_and_reset_rebuilds
    organization = Struct.new(:id, :host).new(71, "mi.example.test")
    builds = 0
    Web.stub(:build_coordinator, lambda { |**|
      builds += 1
      @coordinator
    }) do
      Native.stub(:organization, organization) do
        assert_same Web.send(:coordinator_for, context: @context), Web.send(:coordinator_for, context: @context)
        Web.reset!
        Web.send(:coordinator_for, context: @context)
        assert_equal 2, builds
        assert_raises(RuntimeError) { Web.send(:coordinator_for, context: @context.with(organization_id: 72)) }
      end
    end
  end

  private

  def host(runtime:)
    Host.new(organization: Struct.new(:id).new(71), client: Object.new, tools_factory: -> { raise "No tool read" },
             workflow: Object.new, state_store: Object.new, runtime:, accounting_factory: -> { raise "No provider accounting" })
  end

  def respond(coordinator: @coordinator, personality: ->(reply:, **) { reply })
    Web.stub(:report_submission_enabled?, false) do
      Web.stub(:coordinator_for, ->(**) { coordinator }) do
        DecidimApp::Bijeljina::MilicaPersonality.stub(:call, personality) { Web.respond(@message) }
      end
    end
  end
end

# rubocop:enable Rails/RefuteMethods
