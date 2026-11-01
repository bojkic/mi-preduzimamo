# frozen_string_literal: true

require "bundler/setup"
require "minitest/autorun"
require "minitest/mock"
require "active_support"
require "active_support/core_ext/object/blank"
require "active_support/core_ext/hash/keys"
require "active_support/core_ext/string/access"
require "i18n"

engine_root = Gem.loaded_specs.fetch("decidim-bih").full_gem_path
require File.join(engine_root, "app/services/decidim/bih/text")
require File.join(engine_root, "app/services/decidim/bih/concierge/answer_intents")
require File.join(engine_root, "app/services/decidim/bih/concierge/stickers")
require File.join(engine_root, "app/services/decidim/bih/concierge/responder")
require_relative "../../app/services/decidim_app/bijeljina/milica_personality"

# Synthetic completed replies through the actual personality layer and engine
# reply type; no Rails boot, database, provider, or citizen transcripts.
class MilicaFactualPersonalityTest < Minitest::Test
  Personality = DecidimApp::Bijeljina::MilicaPersonality
  Reply = Decidim::Bih::Concierge::Responder::Reply
  Message = Struct.new(:text, :conversation_context, keyword_init: true)
  BODY = "Mogu pomoći. Informacije: https://example.test/usluga".freeze

  def setup
    super
    @previous_locales = I18n.available_locales
    I18n.available_locales = %w(en sr)
    @config = YAML.safe_load_file(File.expand_path("../../config/milica/personality.yml", __dir__), aliases: false).deep_stringify_keys
  end

  def teardown
    I18n.available_locales = @previous_locales
    super
  end

  def test_service_and_setup_remain_factual_even_with_preset_playful_tone
    %w(service setup).product([nil, "playful"], Personality::CHANNELS).each do |intent, tone, channel|
      reply = build_reply(intent:, tone:)

      result = apply(reply, channel:)

      assert_same reply, result
      assert_factual result, tone: "neighborly"
    end
  end

  def test_repeated_setup_failures_keep_core_tone_and_no_persona_decoration
    context = [
      { "answer_intent" => "fallback", "bot" => "Sintetički prethodni odgovor." },
      { "answer_intent" => "unknown", "bot" => "Sintetički drugi odgovor." }
    ]

    result = apply(build_reply(intent: "setup", tone: "playful"), context:)

    assert_factual result, tone: "core"
  end

  def test_core_safety_and_functional_reply_fields_are_preserved
    [["service", nil, "Neko mi prijeti"], ["setup", "core", "Kako dalje?"]].each do |intent, tone, text|
      action = { label: "Otvori uputstvo", url: "https://example.test/uputstvo" }
      report = Object.new
      reply = build_reply(intent:, tone:)
      reply.quick_replies = [action]
      reply.report = report
      reply.sticker = :prijavljeno

      result = apply(reply, text:)

      assert_equal "core", result.tone
      assert_equal BODY, result.text
      assert_nil result.phrase_id
      assert_same report, result.report
      assert_same action, result.quick_replies.first
      assert_equal :prijavljeno, result.sticker
      assert_equal intent, result.answer_intent
    end
  end

  def test_unrelated_playful_and_critical_safety_paths_are_unchanged
    playful = Reply.new(text: BODY, answer_intent: "launch", tone: "playful")
    critical = Reply.new(text: BODY, answer_intent: "safety")

    apply(playful)
    apply(critical)

    assert_equal "playful", playful.tone
    assert playful.phrase_id.start_with?("search.")
    assert playful.text.end_with?(BODY)
    assert_includes Decidim::Bih::Concierge::Stickers::PERSONA_IDS, playful.sticker
    assert_factual critical, tone: "core"
  end

  def test_transport_and_parking_decorations_never_cross_topics_or_add_a_false_request
    %w(transport parking).each do |topic|
      30.times do |index|
        reply = Reply.new(text: "Provjeren odgovor. https://example.test/map", answer_intent: "service", tone: "playful")
        persona = Personality.new(reply:, channel: "web_chat", message: Message.new(text: "Uputstvo do stajališta #{index}", conversation_context: []))
        persona.define_singleton_method(:topic) { topic }
        result = Personality.stub(:config, @config) { I18n.with_locale(:sr) { persona.call } }
        assert result.text.end_with?("Provjeren odgovor. https://example.test/map")
        assert result.phrase_id.start_with?(topic + ".")
        if topic == "transport"
          refute_match(/parking|kazna|zon[au]|[Nn]apiši ulicu|[Rr]eci vrijeme|[Nn]ašla sam liniju|[Pp]resjedanje nije/, result.text)
        else
          refute_match(/autobus|polazak|presjedanje/, result.text)
        end
      end
    end
  end

  private

  def build_reply(intent:, tone:)
    Reply.new(text: BODY, answer_intent: intent, tone:, phrase_id: "public_data.01", sticker: :milica_tablet)
  end

  def apply(reply, text: "Pokaži informacije", context: [], channel: "web_chat")
    Personality.stub(:config, @config) do
      I18n.with_locale(:sr) do
        Personality.call(reply:, message: Message.new(text:, conversation_context: context), channel:)
      end
    end
  end

  def assert_factual(reply, tone:)
    assert_equal BODY, reply.text
    assert_equal tone, reply.tone
    assert_nil reply.phrase_id
    assert_nil reply.sticker
  end
end
