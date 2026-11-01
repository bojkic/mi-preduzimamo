# frozen_string_literal: true

require "test_helper"
require "webmock/minitest"
require "ostruct"

module Decidim
  module Bih
    module Ai
      class GeminiClientTest < ActiveSupport::TestCase
        BASE = "https://gen.example.com"
        MODEL = "gemini-flash-lite-latest"
        KEY = "secret-key"
        ENDPOINT = "#{BASE}/v1beta/models/#{MODEL}:generateContent".freeze

        # Explicit credentials keep the test isolated from the global ENV.
        def client
          GeminiClient.new(api_key: KEY, base_url: BASE, model: MODEL)
        end

        def envelope(inner)
          { candidates: [{ content: { parts: [{ text: inner.to_json }] } }] }.to_json
        end

        setup { WebMock.disable_net_connect!(allow_localhost: true) }
        teardown do
          WebMock.reset!
          WebMock.allow_net_connect!
        end

        test "configured? requires an api key" do
          assert client.configured?
          assert_not GeminiClient.new(api_key: nil).configured?
        end

        test "model and base_url default from Decidim::Bih::Config.gemini" do
          # The client must NOT duplicate ENV defaults — it must take its model
          # and base_url from the single boot-validated Config source, so the
          # values the live request uses can never drift from what validate!
          # warns about.
          Decidim::Bih::Config.stub(:gemini, { api_key: nil, model: "config-model-x", base_url: "https://config.example.com" }) do
            c = GeminiClient.new(api_key: KEY)
            assert_equal "config-model-x", c.model
            assert_equal "https://config.example.com", c.base_url
          end
        end

        test "generate_content posts to the model endpoint with the key and returns parsed inner JSON" do
          stub = stub_request(:post, ENDPOINT)
                 .with(headers: { "Content-Type" => "application/json", "x-goog-api-key" => KEY })
                 .to_return(status: 200, body: envelope({ "category" => "putevi" }),
                            headers: { "Content-Type" => "application/json" })

          result = client.generate_content(contents: [{ role: "user", parts: [{ text: "hi" }] }])

          assert_requested(stub)
          assert_equal({ "category" => "putevi" }, result)
        end

        test "uses the Vertex AI path when the base url is aiplatform" do
          vertex = GeminiClient.new(api_key: KEY, base_url: "https://aiplatform.googleapis.com", model: MODEL)
          stub = stub_request(:post, "https://aiplatform.googleapis.com/v1/publishers/google/models/#{MODEL}:generateContent")
                 .with(headers: { "x-goog-api-key" => KEY })
                 .to_return(status: 200, body: envelope({ "ok" => true }))

          vertex.generate_content(contents: [{ parts: [{ text: "x" }] }])
          assert_requested(stub)
        end

        test "passes the response_schema through in generationConfig" do
          schema = { type: "object", properties: { category: { type: "string" } } }
          stub = stub_request(:post, ENDPOINT)
                 .with(headers: { "x-goog-api-key" => KEY },
                       body: hash_including(
                         "generationConfig" => hash_including(
                           "response_mime_type" => "application/json",
                           "response_schema" => hash_including("type" => "object")
                         )
                       ))
                 .to_return(status: 200, body: envelope({ "ok" => true }))

          client.generate_content(contents: [{ parts: [{ text: "x" }] }], response_schema: schema)
          assert_requested(stub)
        end

        test "serializes the approved generation limits with camelCase wire keys" do
          schema = { type: "object", properties: { category: { type: "string" } } }
          limits = { max_output_tokens: 512, candidate_count: 1, thinking_budget: 0 }
          original_schema = Marshal.load(Marshal.dump(schema))
          original_limits = limits.dup
          stub = stub_request(:post, ENDPOINT)
                 .with(headers: { "x-goog-api-key" => KEY },
                       body: hash_including(
                         "generationConfig" => {
                           "responseMimeType" => "application/json",
                           "responseSchema" => {
                             "type" => "object",
                             "properties" => { "category" => { "type" => "string" } }
                           },
                           "maxOutputTokens" => 512,
                           "candidateCount" => 1,
                           "thinkingConfig" => { "thinkingBudget" => 0 }
                         }
                       ))
                 .to_return(status: 200, body: envelope({ "ok" => true }))

          client.generate_content(contents: [{ parts: [{ text: "x" }] }], response_schema: schema,
                                  generation_limits: limits)

          assert_requested(stub)
          assert_equal original_schema, schema
          assert_equal original_limits, limits
        end

        test "accepts the approved output-token boundaries" do
          stub = stub_request(:post, ENDPOINT)
                 .with(headers: { "x-goog-api-key" => KEY })
                 .to_return(status: 200, body: envelope({ "ok" => true }))

          [1, 65_536].each do |max_output_tokens|
            client.generate_content(
              contents: [],
              generation_limits: { max_output_tokens:, candidate_count: 1, thinking_budget: 0 }
            )
          end

          assert_requested(stub, times: 2)
        end

        test "rejects incomplete, non-symbol, and out-of-range generation limits before network" do
          invalid = [
            [],
            "limits",
            { "max_output_tokens" => 512, "candidate_count" => 1, "thinking_budget" => 0 },
            { max_output_tokens: true, candidate_count: 1, thinking_budget: 0 },
            {},
            { max_output_tokens: 512 },
            { max_output_tokens: 512, candidate_count: 1, thinking_budget: 0, extra: true },
            { max_output_tokens: "512", candidate_count: 1, thinking_budget: 0 },
            { max_output_tokens: 512, candidate_count: 1.0, thinking_budget: 0 },
            { max_output_tokens: 512, candidate_count: 1, thinking_budget: 0.0 },
            { max_output_tokens: 0, candidate_count: 1, thinking_budget: 0 },
            { max_output_tokens: 65_537, candidate_count: 1, thinking_budget: 0 },
            { max_output_tokens: 512, candidate_count: 2, thinking_budget: 0 },
            { max_output_tokens: 512, candidate_count: 1, thinking_budget: 1 }
          ]

          invalid.each do |limits|
            assert_raises(ArgumentError) do
              client.generate_content(contents: [], generation_limits: limits)
            end
          end
        end

        test "passes an optional system instruction as a separate content field" do
          stub = stub_request(:post, ENDPOINT)
                 .with(
                   headers: { "x-goog-api-key" => KEY },
                   body: hash_including(
                     "systemInstruction" => {
                       "parts" => [{ "text" => "Classify intent only; never authorize actions." }]
                     }
                   )
                 )
                 .to_return(status: 200, body: envelope({ "ok" => true }))

          client.generate_content(
            contents: [{ role: "user", parts: [{ text: "x" }] }],
            system_instruction: "Classify intent only; never authorize actions."
          )

          assert_requested(stub)
        end

        test "omits systemInstruction when the optional value is blank" do
          stub = stub_request(:post, ENDPOINT)
                 .with { |request| JSON.parse(request.body).exclude?("systemInstruction") }
                 .to_return(status: 200, body: envelope({ "ok" => true }))

          client.generate_content(contents: [{ parts: [{ text: "x" }] }], system_instruction: "  ")

          assert_requested(stub)
        end

        test "a per-call timeout sets both Faraday transport timeouts without changing the default" do
          gemini = client
          fake_connection = Object.new
          captured = nil
          response = Struct.new(:status, :body) do
            def success? = true
          end.new(200, envelope({ "ok" => true }))
          fake_connection.define_singleton_method(:post) do |_path, &block|
            request = Struct.new(:headers, :body, :options).new({}, nil, OpenStruct.new)
            block.call(request)
            captured = request
            response
          end

          result = gemini.stub(:connection, fake_connection) do
            gemini.generate_content(contents: [{ parts: [{ text: "x" }] }], timeout: 1.25)
          end

          assert_equal({ "ok" => true }, result)
          assert_in_delta 1.25, captured.options.timeout
          assert_in_delta 1.25, captured.options.open_timeout
          assert_equal GeminiClient::DEFAULT_TIMEOUT, gemini.instance_variable_get(:@timeout)
        end

        test "non-200 errors retain HTTP status without disclosing provider response content" do
          body = { error: { api_key: KEY, phone: "38765111222", message: "quota exceeded" } }.to_json
          stub_request(:post, ENDPOINT).with(headers: { "x-goog-api-key" => KEY }).to_return(status: 400, body: body)
          error = assert_raises(Decidim::Bih::Ai::Error) do
            client.generate_content(contents: [{ parts: [{ text: "x" }] }])
          end

          assert_equal "Gemini API error (HTTP 400)", error.message
          assert_not_includes error.message, KEY
          assert_not_includes error.message, "38765111222"
          assert_not_includes error.message, "quota exceeded"
          assert_not_includes error.message, body
        end

        test "raises when an unconfigured client is called" do
          assert_raises(Decidim::Bih::Ai::Error) do
            GeminiClient.new(api_key: nil).generate_content(contents: [])
          end
        end

        test "tolerates markdown-fenced JSON content from the model" do
          # On the Vertex path the model sometimes wraps JSON in a ```json fence
          # despite response_mime_type; the client must still parse it.
          fenced = "```json\n{\"category\":\"putevi\"}\n```"
          body = { candidates: [{ content: { parts: [{ text: fenced }] } }] }.to_json
          stub_request(:post, ENDPOINT).with(headers: { "x-goog-api-key" => KEY }).to_return(status: 200, body: body)

          result = client.generate_content(contents: [{ parts: [{ text: "x" }] }])

          assert_equal({ "category" => "putevi" }, result)
        end

        test "raises when the model returns non-JSON content" do
          body = { candidates: [{ content: { parts: [{ text: "not json" }] } }] }.to_json
          stub_request(:post, ENDPOINT).with(headers: { "x-goog-api-key" => KEY }).to_return(status: 200, body: body)
          assert_raises(Decidim::Bih::Ai::Error) do
            client.generate_content(contents: [{ parts: [{ text: "x" }] }])
          end
        end
      end
    end
  end
end
