# frozen_string_literal: true

# Queued native protocol fixtures isolate the remote provider and each test
# admission key. Real leases, actor checks, state, readers and protected execution remain active.
require "securerandom"
module NativeMilicaProvider
  class Client
    attr_reader :calls, :responses

    def initialize
      @calls = []
      @responses = []
    end

    def queue_final(text:, kind: "clarification", ids: [])
      @responses << ->(**) { final(text:, kind:, ids:) }
    end

    def queue_protected(name, arguments = {})
      @responses << ->(**) { tool(name, arguments) }
    end

    def queue_public(name, arguments = {}, &compose)
      queue_protected(name, arguments)
      @responses << lambda do |contents:, **|
        envelope = contents.last.fetch("parts").first.fetch("functionResponse").fetch("response")
        records = envelope.fetch("evidence", [])
        text = compose ? compose.call(envelope) : records.map { |record| record.fetch("text") }.join("\n")[0, 1900]
        if records.empty?
          final(text: text.presence || "Nema pregledanih podataka za ovaj upit.", kind: "limitation", ids: [])
        else
          final(text:, kind: "answer", ids: current_citation_ids(envelope))
        end
      end
    end

    # Echo current tool response handles exactly. Do not repair fabricated IDs
    # in queue_final: explicit invalid fixtures must still fail the real host.
    def current_citation_ids(envelope)
      envelope.fetch("evidence", []).first(40).map { |record| record.fetch("id") }
    end

    def queue_error
      @responses << ->(**) { raise "Synthetic native provider failure" }
    end

    def generate_content(**arguments)
      @calls << arguments
      response = @responses.shift
      # Neutral fixture for HTTP/token tests that make no answer-quality claim.
      return final(text: "Šta želiš provjeriti?", kind: "clarification", ids: []) unless response

      response.call(**arguments)
    end

    def final(text:, kind:, ids:)
      payload = { "kind" => kind, "answer" => text, "evidence_ids" => ids }
      result(content: { "role" => "model", "parts" => [{ "text" => JSON.generate(payload) }] }, function_calls: [], structured: payload)
    end

    def tool(name, arguments)
      call = { "name" => name, "args" => arguments.stringify_keys, "id" => "native-test-call" }
      result(content: { "role" => "model", "parts" => [{ "functionCall" => call, "thoughtSignature" => "synthetic-native-signature" }] }, function_calls: [call])
    end

    def result(content:, function_calls:, structured: nil)
      DecidimApp::Bijeljina::Milica::GeminiConversationClient::Result.new(
        content:, function_calls:, structured:, text: structured && JSON.generate(structured), finish_reason: "STOP",
        usage: { "promptTokenCount" => 12, "candidatesTokenCount" => 5, "thoughtsTokenCount" => 0 }, model_version: "offline-fixture"
      )
    end
  end

  def install_native_provider
    @native_original_resolver = Decidim::Bih.concierge_resolver
    Decidim::Bih.concierge_resolver = -> { DecidimApp::Bijeljina::WebConcierge }
    @native_admission_class = Decidim::Bih::Concierge::Dialogue::AdmissionControl
    @native_original_admission_new = @native_admission_class.method(:new)
    original_admission_new = @native_original_admission_new
    admission_key = "milica:native-provider-test:#{SecureRandom.hex(16)}"
    # Parallel functional tests must not spend one another's deployment-wide
    # capacity. Requests within this test still share real bounded Redis leases;
    # explicit keys used by capacity scenarios retain their original meaning.
    @native_admission_class.define_singleton_method(:new) do |**arguments|
      original_admission_new.call(key: admission_key, **arguments)
    end
    @native_provider = Client.new
    @native_provider_class = DecidimApp::Bijeljina::Milica::GeminiConversationClient
    @native_original_new = @native_provider_class.method(:new)
    client = @native_provider
    @native_provider_class.define_singleton_method(:new) { |**| client }
    @native_flags = %w(MILICA_DIALOGUE_ENABLED MILICA_CONVERSATION_ARCHITECTURE MILICA_CONVERSATIONAL_WRITES_ENABLED).index_with { |key| ENV.fetch(key, nil) }
    ENV["MILICA_DIALOGUE_ENABLED"] = "true"
    ENV["MILICA_CONVERSATION_ARCHITECTURE"] = "model_led"
    ENV["MILICA_CONVERSATIONAL_WRITES_ENABLED"] = "false"
    DecidimApp::Bijeljina::WebConcierge.reset!
  end

  def uninstall_native_provider
    Decidim::Bih.concierge_resolver = @native_original_resolver
    @native_admission_class&.define_singleton_method(:new, @native_original_admission_new) if @native_original_admission_new
    @native_provider_class&.define_singleton_method(:new, @native_original_new) if @native_original_new
    @native_flags&.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    DecidimApp::Bijeljina::WebConcierge.reset!
  end
end
