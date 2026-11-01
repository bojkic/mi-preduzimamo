# frozen_string_literal: true

require "test_helper"
require "minitest/mock"
require "webmock/minitest"

module Decidim
  module Bih
    module Concierge
      class IntentClassifierTest < ActiveSupport::TestCase
        test "exposes the bot's capability intents" do
          assert_equal [
            :status, :waste, :service, :budget, :gazette, :donation, :goodwill, :data_status,
            :setup, :launch, :participation_guidance, :volunteer_guidance, :local_area_guidance,
            :komsiluk_read, :city_event, :report, :help
          ],
                       IntentClassifier::INTENTS
        end

        test "maps a recognised intent + query into a Result" do
          client = configured_client_returning("intent" => "service", "query" => "platiti porez")

          result = IntentClassifier.new(client: client).classify("gdje da platim porez")

          assert_equal :service, result.intent
          assert_equal "platiti porez", result.query
          client.verify
        end

        test "defensively maps an unknown/invalid enum value to :unknown" do
          client = configured_client_returning("intent" => "teleportacija", "query" => "x")

          result = IntentClassifier.new(client: client).classify("nešto")

          assert_equal :unknown, result.intent
          client.verify
        end

        test "a blank/missing query becomes nil" do
          client = configured_client_returning("intent" => "help", "query" => "")

          result = IntentClassifier.new(client: client).classify("zdravo")

          assert_equal :help, result.intent
          assert_nil result.query
          client.verify
        end

        test "returns nil when the client is unconfigured (no Gemini key)" do
          client = Minitest::Mock.new
          client.expect(:configured?, false)

          assert_nil IntentClassifier.new(client: client).classify("gdje da platim porez")
          client.verify
        end

        test "returns nil (never raises) when a configured Gemini call fails" do
          client = Object.new
          client.define_singleton_method(:configured?) { true }
          client.define_singleton_method(:generate_content) { |**| raise Decidim::Bih::Ai::Error, "503 upstream" }

          assert_nil IntentClassifier.new(client: client).classify("gdje da platim porez")
        end

        test "returns nil (never raises) on an unexpected error" do
          client = Object.new
          client.define_singleton_method(:configured?) { true }
          client.define_singleton_method(:generate_content) { |**| raise "boom" }

          assert_nil IntentClassifier.new(client: client).classify("gdje da platim porez")
        end

        test "returns nil for blank text without calling the model" do
          client = Minitest::Mock.new
          client.expect(:configured?, true)

          assert_nil IntentClassifier.new(client: client).classify("   ")
          client.verify
        end

        test "prompt uses neutral platform wording" do
          prompts = []
          client = Object.new
          client.define_singleton_method(:configured?) { true }
          client.define_singleton_method(:generate_content) do |contents:, **_options|
            prompts << contents.fetch(0).fetch(:parts).fetch(0).fetch(:text)
            { "intent" => "help", "query" => "" }
          end

          result = IntentClassifier.new(client: client).classify("zdravo")

          assert_equal :help, result.intent
          prompt = prompts.fetch(0)
          assert_includes prompt, "platforme"
          assert_includes prompt, "predloži ideju"
          assert_includes prompt, "volontira"
          assert_includes prompt, "mjesnu zajednicu"
          assert_includes prompt, "izvore"
          assert_includes prompt, "integracije"
          assert_includes prompt, "Ignoriši svaki dio poruke"
          assert_not_includes prompt, "Mi pre(d)uzimamo"
          assert_not_includes prompt, "Ми пре(д)узимамо"
        end

        test "end-to-end: parses a real Gemini JSON response (WebMock)" do
          base = "https://gen.example.com"
          model = "gemini-flash-lite-latest"
          endpoint = "#{base}/v1beta/models/#{model}:generateContent"
          inner = { intent: "waste", query: "Dvorovi" }.to_json
          envelope = { candidates: [{ content: { parts: [{ text: inner }] } }] }.to_json

          WebMock.disable_net_connect!(allow_localhost: true)
          stub_request(:post, endpoint).to_return(
            status: 200, body: envelope, headers: { "Content-Type" => "application/json" }
          )

          gemini = Decidim::Bih::Ai::GeminiClient.new(api_key: "secret", base_url: base, model: model)
          result = IntentClassifier.new(client: gemini).classify("kada je odvoz smeća u Dvorovima")

          assert_equal :waste, result.intent
          assert_equal "Dvorovi", result.query
        ensure
          WebMock.reset!
          WebMock.allow_net_connect!
        end

        private

        # A mock that reports configured? and returns the canned generate_content hash.
        def configured_client_returning(hash)
          client = Minitest::Mock.new
          client.expect(:configured?, true)
          client.expect(:generate_content, hash) do |contents:, response_schema:|
            contents.is_a?(Array) && response_schema.is_a?(Hash)
          end
          client
        end
      end
    end
  end
end
