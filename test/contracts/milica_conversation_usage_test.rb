# frozen_string_literal: true

require "bundler/setup"
require "minitest/autorun"
require_relative "../../app/services/decidim_app/bijeljina/milica/gemini_conversation_client"
require_relative "../../app/services/decidim_app/bijeljina/milica/conversation_usage"

class MilicaConversationUsageTest < Minitest::Test
  Usage = DecidimApp::Bijeljina::Milica::ConversationUsage
  Client = DecidimApp::Bijeljina::Milica::GeminiConversationClient
  Deadline = Struct.new(:expired) { def expired? = expired }
  Response = Struct.new(:usage)

  class Ledger
    attr_reader :committed, :settled, :reservations

    def initialize
      @committed = @settled = @reservations = 0
    end

    def eval(script, keys:, argv:)
      raise "unscoped aggregate" unless keys.first.end_with?(":1:20260916")

      if script == Usage::RESERVE
        return 0 if @committed + argv[0] > argv[1]

        @committed += argv[0]
        @reservations += 1
      else
        @committed += argv[0] - argv[1]
        @settled += argv[0]
      end
      1
    end
  end

  def setup
    @ledger = Ledger.new
    @usage = Usage.new(organization_id: 1, model: "gemini-3.5-flash-lite", redis: @ledger, day: "20260916")
    @deadline = Deadline.new(false)
  end

  def test_accounting_span_marks_unknown_usage_and_keeps_reservation
    spans = []
    @usage = Usage.new(organization_id: 1, model: "gemini-3.5-flash-lite", redis: @ledger, day: "20260916",
                       observer: ->(**event) { spans << event })
    assert_raises(Client::Error) { @usage.call(component: :planner, deadline: @deadline) { raise Client::Error, :timeout } }
    assert_equal 50_000, @ledger.committed
    assert_equal({ phase: "accounting", component: "planner", status: "provider_error",
                   attempts: 1, reserved: true, settled: false, usage_unknown: true }, spans.first.except(:duration_ms))
  end

  def test_accounting_span_records_cached_input_without_changing_estimated_price
    spans = []
    @usage = Usage.new(organization_id: 1, model: "gemini-3.5-flash-lite", redis: @ledger, day: "20260916",
                       observer: ->(**event) { spans << event })
    @usage.call(component: :continuation, deadline: @deadline) do
      Response.new({ "promptTokenCount" => 1000, "candidatesTokenCount" => 100,
                     "thoughtsTokenCount" => 20, "cachedContentTokenCount" => 200 })
    end
    assert_equal 200, @usage.receipts.first.fetch("cached_input_tokens")
    assert_equal 200, spans.first.fetch(:cached_input_tokens)
    assert_equal 600, spans.first.fetch(:estimated_cost_micro_usd)
    assert_equal true, spans.first.fetch(:settled)
    assert_equal false, spans.first.fetch(:usage_unknown)
    refute_includes spans.first.keys, :model_text
  end

  def test_accounting_observer_failure_does_not_change_settlement
    @usage = Usage.new(organization_id: 1, model: "gemini-3.5-flash-lite", redis: @ledger, day: "20260916",
                       observer: ->(**) { raise "private observer failure" })
    response = Response.new({ "promptTokenCount" => 100, "candidatesTokenCount" => 10 })
    assert_equal response, @usage.call(component: :planner, deadline: @deadline) { response }
    assert_equal 1, @ledger.reservations
    assert_equal 55, @ledger.settled
  end

  def test_failed_unknown_request_holds_cost_and_does_not_retry
    assert_raises(Client::Error) { @usage.call(component: :planner, deadline: @deadline) { raise Client::Error, :timeout } }
    assert_equal 1, @usage.attempts
    assert_equal 50_000, @ledger.committed
    assert_empty @usage.receipts
  end

  def test_known_usage_on_provider_error_is_settled_without_calling_it_success
    assert_raises(Client::Error) do
      @usage.call(component: :planner, deadline: @deadline) do
        raise Client::Error.new(:malformed, usage: { "promptTokenCount" => 1000, "candidatesTokenCount" => 100, "thoughtsTokenCount" => 20 })
      end
    end
    assert_equal 600, @ledger.committed
    assert_equal 120, @usage.receipts.first["output_tokens"]
  end

  def test_third_call_cannot_bypass_fixed_mode_turn_cap
    @usage = Usage.new(organization_id: 1, model: "gemini-3.5-flash-lite", redis: @ledger, day: "20260916", max_attempts: 2)
    2.times { @usage.call(component: :planner, deadline: @deadline) { Response.new({}) } }
    assert_raises(Usage::Limit) { @usage.call(component: :composer, deadline: @deadline) { flunk "third request dispatched" } }
    assert_equal 2, @ledger.reservations
  end

  def test_ninth_call_cannot_bypass_default_adaptive_turn_cap
    response = Response.new({ "promptTokenCount" => 0, "candidatesTokenCount" => 0 })
    8.times { @usage.call(component: :planner, deadline: @deadline) { response } }
    assert_raises(Usage::Limit) { @usage.call(component: :composer, deadline: @deadline) { flunk "ninth request dispatched" } }
    assert_equal 8, @ledger.reservations
  end

  def test_exhausted_daily_reservation_blocks_dispatch
    usage = Usage.new(organization_id: 1, model: "gemini-3.5-flash-lite", redis: @ledger, day: "20260916", daily_ceiling_usd: 0.04)
    assert_raises(Usage::Limit) { usage.call(component: :planner, deadline: @deadline) { flunk "over-budget request dispatched" } }
    assert_equal 0, usage.attempts
  end

  def test_expired_turn_never_reserves
    assert_raises(Usage::Limit) { @usage.call(component: :planner, deadline: Deadline.new(true)) { flunk "expired turn dispatched" } }
    assert_equal 0, @ledger.reservations
  end
end
