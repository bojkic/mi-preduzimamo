# frozen_string_literal: true

require "test_helper"

class EmergencyContinuationTest < ActiveSupport::TestCase
  Dialogue = Decidim::Bih::Concierge::Dialogue
  Helper = DecidimApp::Bijeljina::Milica::EmergencyContinuation

  test "threat with cancellation clears protected task draft and public frame using the existing version" do
    context = Dialogue::Contracts::TrustedContext.new(organization_id: 1, conversation_key: "e" * 64, now: Time.current, capabilities: ["public_reads"])
    store = Dialogue::StateStore.new
    previous = store.empty_state(context).merge("version" => 7, "active_task" => "report_problem", "pending_slot" => "area_query")
    writes = []
    store.stub(:read, previous) do
      store.stub(:write, lambda { |**args|
        writes << args
        :saved
      }) do
        result = Helper.call(message: danger_message, context:, store:)
        assert_equal "safety_guidance", result.resolution
        assert_includes result.reply.text, I18n.t("decidim.bih.dialogue.safety", locale: :sr)
        assert_nil result.state.fetch("active_task")
        assert_nil result.state.fetch("draft")
        assert_nil result.state.fetch(Dialogue::ConversationFrame::KEY)
      end
    end
    assert_equal 1, writes.size
    assert_equal 7, writes.first.fetch(:expected_version)
    assert_equal 7, writes.first.fetch(:state).fetch("version")
  end

  test "fresh danger returns a card when state cannot be read" do
    context = Dialogue::Contracts::TrustedContext.new(organization_id: 1, conversation_key: "c" * 64,
                                                      now: Time.current, capabilities: ["public_reads"])
    store = Dialogue::StateStore.new
    store.stub(:read, ->(**) { raise IOError, "unavailable ciphertext/store" }) do
      result = Helper.call(message: Struct.new(:text).new("Gori kuća!"), context:, store:)
      assert_equal "safety_guidance", result.resolution
      assert_nil result.state
      assert_includes result.reply.text, "123"
    end
  end

  test "state write failure never hides the cancellation danger answer" do
    context = Dialogue::Contracts::TrustedContext.new(organization_id: 1, conversation_key: "f" * 64, now: Time.current, capabilities: ["public_reads"])
    store = Dialogue::StateStore.new
    store.stub(:read, store.empty_state(context)) do
      store.stub(:write, ->(**) { raise IOError, "synthetic store unavailable" }) do
        result = Helper.call(message: danger_message, context:, store:)
        assert_equal "safety_guidance", result.resolution
        assert_nil result.state
        assert_includes result.reply.text, I18n.t("decidim.bih.dialogue.safety", locale: :sr)
        assert_not_includes result.reply.text, "synthetic"
      end
    end
  end

  test "cancelled fire still opens the new bounded emergency contact context" do
    context = Dialogue::Contracts::TrustedContext.new(organization_id: 1, conversation_key: "a" * 64, now: Time.current, capabilities: ["public_reads"])
    store = Dialogue::StateStore.new
    previous = store.empty_state(context).merge("version" => 3, "active_task" => "report_problem", "pending_slot" => "area_query")
    store.stub(:read, previous) do
      store.stub(:write, :saved) do
        result = Helper.call(message: Struct.new(:text).new("Odustajem. Gori kuća!"), context:, store:)
        assert_equal "safety_guidance", result.resolution
        assert_nil result.state.fetch("active_task")
        assert result.state.fetch(Dialogue::StateStore::SAFETY_CONTEXT_KEY).present?
      end
    end
  end

  private

  def danger_message
    Struct.new(:text).new("Odustajem, ne objavljuj. Neko mi prijeti")
  end
end
