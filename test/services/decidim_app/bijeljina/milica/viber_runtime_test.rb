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
require_relative "../../../../../app/services/decidim_app/bijeljina/milica_personality"
require_relative "../../../../../app/services/decidim_app/bijeljina/channel_notification_opt_out"
require_relative "../../../../../app/services/decidim_app/bijeljina/milica/chat_report_intake"
require_relative "../../../../../app/services/decidim_app/bijeljina/milica/channel_conversation_context"
require_relative "../../../../../app/services/decidim_app/bijeljina/web_concierge"

class DecidimApp::Bijeljina::MilicaViberRuntimeTest < Minitest::Test
  Native = DecidimApp::Bijeljina::Concierge
  Web = DecidimApp::Bijeljina::WebConcierge
  Milica = DecidimApp::Bijeljina::Milica
  Message = Struct.new(:text, :sender, :channel, :image_url, keyword_init: true)
  Reply = Decidim::Bih::Concierge::Responder::Reply

  def setup
    @prior_logger = Rails.logger
    Rails.logger = Logger.new(StringIO.new)
    @calls = []
    @downstream = []
    @scope = Decidim::Bih::Concierge::Dialogue::Contracts::TrustedContext.new(organization_id: 71, conversation_key: "a" * 64, capabilities: ["public_reads"])
    @reply = Reply.new(text: "Model-led result", answer_intent: "service")
    @identity = Object.new
    @identity.define_singleton_method(:linked_user) { |**| nil }
    Native.reset!
  end

  def teardown
    Rails.logger = @prior_logger
  end

  def test_native_channels_use_same_dialogue_and_existing_delivery_sequence
    %w(viber viber_bm).each do |channel|
      @downstream.clear
      message = Message.new(text: "pitanje", sender: "synthetic", channel:)
      with_pipeline do
        assert_same @reply, Native.process_message(message)
      end
      assert_equal [:usage, *(channel == "viber_bm" ? [:business] : []), :deliver, :remember], @downstream
      assert_equal channel, @calls.last.first.channel
      assert_same @scope, @calls.last.last
    end
    assert_equal 2, @calls.size
    refute Native.respond_to?(:responder_for)
  end

  def test_missing_response_and_exception_do_not_retry_but_keep_delivery_sequence
    [nil, :raise].each do |failure|
      @calls.clear
      @downstream.clear
      with_pipeline(response: failure) do
        answer = Native.process_message(Message.new(text: "pitanje", sender: "synthetic", channel: "viber"))
        assert_equal "fallback", answer.answer_intent
      end
      assert_equal 1, @calls.size
      assert_equal [:usage, :deliver, :remember], @downstream
    end
  end

  def test_linking_prelude_and_verified_token_never_enter_dialogue
    prelude = Reply.new(text: "Verified", answer_intent: "account_linking")
    [[prelude, nil], [nil, prelude]].each do |protected_reply, token_reply|
      with_pipeline(prelude: protected_reply, magic: token_reply) do
        result = Native.process_message(Message.new(text: "123456", sender: "synthetic", channel: "viber"))
        assert_same prelude, result
      end
    end
    assert_empty @calls
  end

  def test_provider_notification_opt_out_precedes_conversation_and_does_not_claim_model_answer
    opt_out = DecidimApp::Bijeljina::ChannelNotificationOptOut
    message = Message.new(text: "STOP", sender: "synthetic", channel: "viber_bm")
    Native.stub(:organization, Struct.new(:id).new(71)) do
      opt_out.stub(:reply, "Notifications stopped") do
        Native.stub(:deliver, ->(*, **) { @downstream << :deliver }) do
          Native.stub(:conversation_store, ->(*, **) { flunk "opt out precedes model context" }) do
            assert_equal "Notifications stopped", Native.process_message(message).text
          end
        end
      end
    end
    assert_equal [:deliver], @downstream
  end

  def test_unresolved_or_wrong_identity_context_never_reaches_model
    with_pipeline(scope: ->(**) { raise ArgumentError, "wrong actor" }) do
      answer = Native.respond(Message.new(text: "Moji bodovi", sender: "synthetic", channel: "viber_bm"))
      assert_equal "fallback", answer.answer_intent
    end
    assert_empty @calls
  end

  private

  def with_pipeline(response: @reply, prelude: nil, magic: nil, scope: @scope)
    values = {
      organization: Struct.new(:id, :host).new(71, "mi.example.test"), identity_for: @identity, protected_prelude: prelude,
      conversation_store: Struct.new(:context).new([]), magic_link_verify_reply: magic,
      record_usage: ->(*, **) { @downstream << :usage }, deliver: ->(*, **) { @downstream << :deliver },
      remember_turn: ->(*, **) { @downstream << :remember }, remember_business_contact: ->(*) { @downstream << :business }
    }
    with_methods(values) do
      Milica::ChatReportIntake.stub(:enabled?, false) do
        Milica::ChannelConversationContext.stub(:call, scope) do
          DecidimApp::Bijeljina::ChannelNotificationOptOut.stub(:reply, nil) do
            DecidimApp::Bijeljina::MilicaPersonality.stub(:call, ->(reply:, **) { reply }) do
              Web.stub(:dialogue_turn, lambda { |message:, context:, **|
                @calls << [message, context]
                raise "synthetic unavailable" if response == :raise

                response ? [response, nil] : nil
              }) { yield }
            end
          end
        end
      end
    end
  end

  def with_methods(values)
    target = Native.singleton_class
    originals = values.to_h { |name, _| [name, [target.instance_method(name), target.private_method_defined?(name)]] }
    values.each do |name, value|
      target.send(:define_method, name) { |*args, **kwargs, &block| value.is_a?(Proc) ? value.call(*args, **kwargs, &block) : value }
    end
    yield
  ensure
    originals&.each do |name, (method, visibility)|
      target.send(:define_method, name, method)
      target.send(:private, name) if visibility
    end
  end
end

# rubocop:enable Rails/RefuteMethods
