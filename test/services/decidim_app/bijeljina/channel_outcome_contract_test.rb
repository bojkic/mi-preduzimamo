# frozen_string_literal: true

require "test_helper"
require "active_support"
require "active_support/core_ext"

# This contract also runs with the engine's minitest-only helper, without Rails
# boot, database access or provider requests.
engine = Gem.loaded_specs.fetch("decidim-bih").full_gem_path
require File.join(engine, "app/services/decidim/bih/concierge/dialogue/coordinator")
require File.join(engine, "app/services/decidim/bih/concierge/usage_aggregate_recorder")
require File.join(engine, "app/services/decidim/bih/concierge/reply_outcome")
require File.join(engine, "app/services/decidim/bih/concierge/answer_intents")
require_relative "../../../../app/services/decidim_app/bijeljina/external_chat_concierge"
require_relative "../../../../app/services/decidim_app/bijeljina/concierge"
require_relative "../../../../app/services/decidim_app/bijeljina/web_concierge"
require_relative "../../../../app/services/decidim_app/bijeljina/milica/report_conversation"
require_relative "../../../../app/services/decidim_app/bijeljina/milica/chat_report_intake"
require_relative "../../../../app/services/decidim_app/bijeljina/milica/channel_conversation_context"
require File.join(engine, "app/services/decidim/bih/concierge/session_store")

# This file intentionally uses pure Minitest in the DB-free lane.
# rubocop:disable Rails/RefuteMethods
class ChannelOutcomeContractTest < Minitest::Test
  Recorder = Decidim::Bih::Concierge::UsageAggregateRecorder
  Native = DecidimApp::Bijeljina::Concierge
  External = DecidimApp::Bijeljina::ExternalChatConcierge
  Result = Decidim::Bih::Concierge::Dialogue::ProcedureRunner::Result
  Message = Struct.new(:text, :image_url, :channel, :sender, keyword_init: true)
  Reply = Struct.new(:text, :answer_intent, :dialogue_outcome, :quick_replies, :sticker, keyword_init: true)
  CHANNELS = %w(whatsapp messenger instagram viber_bm viber).freeze

  def test_every_channel_passes_typed_safety_dimensions_without_claiming_an_answer
    CHANNELS.each do |channel|
      attributes = record(channel:, reply: safety_reply)
      assert_equal channel, attributes.fetch(:channel)
      assert_equal "fallback", attributes.fetch(:outcome)
      assert_equal "safety", attributes.fetch(:answer_intent)
      dimensions = attributes.fetch(:outcome_dimensions)
      assert_equal "safety_guidance", dimensions.resolution
      refute dimensions.action_receipt
      refute dimensions.grounded_answer
      refute dimensions.handoff_completed
      refute dimensions.handoff_offered
    end
  end

  def test_blank_input_stays_blank_without_counting_a_generated_safety_reply
    CHANNELS.each do |channel|
      attributes = record(channel:, reply: safety_reply, text: "")
      assert_equal "blank", attributes.fetch(:outcome)
      assert_nil attributes.fetch(:outcome_dimensions)
    end
  end

  def test_untyped_and_forged_outcomes_keep_the_legacy_bucket_without_typed_counters
    [nil, { resolution: "submitted", action_receipt: true }].each do |untyped|
      CHANNELS.each do |channel|
        reply = Reply.new(text: "Uputstvo", answer_intent: "service", dialogue_outcome: untyped)
        attributes = record(channel:, reply:)
        assert_equal "success", attributes.fetch(:outcome)
        assert_nil attributes.fetch(:outcome_dimensions)
      end
    end
  end

  def test_native_civic_boundary_retains_the_actual_returned_outcome_for_usage
    raw_reply = Decidim::Bih::Concierge::Responder::Reply.new(text: "Pozovi 123.", answer_intent: "safety", report: nil)
    result = Result.new(state: nil, reply: raw_reply, resolution: "safety_guidance", fact_ids: [], handoff_offered: false, handoff_completed: false)
    boundary = Object.new
    boundary.define_singleton_method(:call) { |**| [raw_reply, result] }
    message = Message.new(text: "Opasnost", channel: "viber_bm", sender: "opaque-sender")
    reply = nil
    with_native_scope do
      DecidimApp::Bijeljina::Milica::ChatReportIntake.stub(:enabled?, true) do
        DecidimApp::Bijeljina::Milica::ReportConversation.stub(:new, ->(**) { boundary }) do
          reply = Native.respond(message)
          assert_same result, reply.dialogue_outcome
        end
      end
    end
    assert_equal "safety_guidance", record(channel: "viber_bm", reply:).fetch(:outcome_dimensions).resolution
  end

  def test_real_native_safety_prelude_is_typed_before_usage_without_civic_or_model_work
    with_emergency_translations do
      message = Message.new(text: "Gori mi kuća", channel: "viber_bm", sender: "opaque-sender")
      reply = nil
      sessions = Object.new
      sessions.define_singleton_method(:for_organization) { |_| self }
      Native.stub(:identity_for, Object.new) do
        Native.stub(:organization, Struct.new(:id).new(1)) do
          Decidim::Bih::Concierge::SessionStore.stub(:new, sessions) do
            DecidimApp::Bijeljina::WebConcierge.stub(:dialogue_turn, ->(**) { flunk "safety precedes model" }) do
              reply = Native.respond(message)
              assert_includes reply.text, "123"
              assert_safety_outcome(reply.dialogue_outcome)
            end
          end
        end
      end
      assert_equal "safety_guidance", record(channel: "viber_bm", reply:).fetch(:outcome_dimensions).resolution
    end
  end

  def test_real_web_immediate_control_is_typed_with_dialogue_disabled_without_model_work
    with_emergency_translations do
      web = DecidimApp::Bijeljina::WebConcierge
      message = Message.new(text: "Gori mi kuća", channel: "web_chat")
      web.stub(:enabled_for?, false) do
        web.stub(:coordinator_for, ->(**) { flunk "emergency must precede the model" }) do
          reply, outcome = web.send(:route, message, context: nil)
          assert_includes reply.text, "123"
          assert_same reply, outcome.reply
          assert_safety_outcome(outcome)
        end
      end
    end
  end

  def test_civic_reply_intent_cannot_claim_the_deterministic_safety_outcome
    reply = Decidim::Bih::Concierge::Responder::Reply.new(text: "Synthetic civic result", answer_intent: "safety")
    with_native_scope do
      DecidimApp::Bijeljina::WebConcierge.stub(:dialogue_turn, [reply, nil]) do
        assert_same reply, Native.respond(Message.new(text: "Pitanje", sender: "opaque", channel: "viber"))
        refute reply.respond_to?(:dialogue_outcome)
      end
    end
  end

  private

  def with_native_scope(&block)
    identity = Object.new
    identity.define_singleton_method(:linked_user) { |**| nil }
    Native.stub(:protected_prelude, nil) do
      Native.stub(:identity_for, identity) do
        Native.stub(:organization, Struct.new(:id).new(1)) do
          DecidimApp::Bijeljina::Milica::ChannelConversationContext.stub(:call, Object.new, &block)
        end
      end
    end
  end

  def assert_safety_outcome(outcome)
    assert_equal "safety_guidance", outcome.resolution
    assert_nil outcome.state
    assert_empty outcome.fact_ids
    refute outcome.handoff_offered
    refute outcome.handoff_completed
    assert_nil outcome.reply.report
  end

  def with_emergency_translations
    previous = { backend: I18n.backend, available: I18n.available_locales }
    I18n.backend = I18n::Backend::Simple.new
    I18n.available_locales = [:sr, :en]
    # Replacing load_path reloads the prior backend and loses its other locales.
    # Load this test's catalogue directly into its own backend instead.
    I18n.backend.load_translations(File.join(Gem.loaded_specs.fetch("decidim-bih").full_gem_path, "config/locales/decidim_bih_dialogue.yml"))
    I18n.with_locale(:sr) { yield }
  ensure
    I18n.available_locales = previous.fetch(:available)
    I18n.backend = previous.fetch(:backend)
  end

  def safety_reply
    result = Result.new(state: { "topic" => "unknown" }, reply: nil, resolution: "safety_guidance",
                        fact_ids: [], handoff_offered: false, handoff_completed: false)
    Reply.new(text: "Pozovi vatrogasce na 123.", answer_intent: "safety", dialogue_outcome: result)
  end

  def record(channel:, reply:, text: "Vidim požar")
    organization = Struct.new(:id, :host).new(7, "mi.example.test")
    message = Message.new(text:, image_url: nil, channel:, sender: "opaque-sender")
    captured = []
    Recorder.stub(:call, ->(**attributes) { captured << attributes }) do
      if %w(viber viber_bm).include?(channel)
        Native.stub(:organization, organization) { Native.send(:record_usage, message, reply, channel:) }
      else
        adapter = External.new(organization:, message:, session_store: Object.new)
        adapter.send(:record_usage, reply)
      end
    end
    assert_equal 1, captured.size
    captured.first
  end
end

# rubocop:enable Rails/RefuteMethods
