# frozen_string_literal: true

# This client and its fake-HTTP tests intentionally work without ActiveSupport.
# rubocop:disable Rails/NegateInclude
# Explicit keyword protocol is shared by generation and counting.
# rubocop:disable Metrics/ParameterLists

require "json"
require "net/http"
require "timeout"
require "uri"

module DecidimApp
  module Bijeljina
    module Milica
      # API-key generation only. The caller owns evidence filtering, tool authority,
      # schema validation, spend reservation and the whole-turn deadline. This class
      # never runs tools, retries calls or logs request/response content.
      # Protocol: https://ai.google.dev/api/generate-content
      # Thinking: https://ai.google.dev/gemini-api/docs/generate-content/thinking
      class GeminiConversationClient
        ENDPOINTS = {
          "https://aiplatform.googleapis.com" => "/v1/publishers/google/models/",
          "https://generativelanguage.googleapis.com" => "/v1beta/models/"
        }.freeze
        THINKING_LEVELS = {
          "gemini-3.5-flash-lite" => %w(minimal low medium high),
          "gemini-3.8-flash" => %w(low medium high)
        }.freeze
        USAGE_KEYS = %w(promptTokenCount candidatesTokenCount totalTokenCount thoughtsTokenCount cachedContentTokenCount toolUsePromptTokenCount).freeze
        FINISH_REASONS = %w(STOP MAX_TOKENS SAFETY RECITATION LANGUAGE OTHER BLOCKLIST PROHIBITED_CONTENT SPII MALFORMED_FUNCTION_CALL IMAGE_SAFETY UNEXPECTED_TOOL_CALL
                            TOO_MANY_TOOL_CALLS).freeze
        MAX_BODY_BYTES = 2 * 1024 * 1024
        SPAN_ERROR_CODES = %w(deadline_exceeded empty_response http_error invalid_configuration invalid_contents invalid_schema
                              invalid_settings invalid_structured_output invalid_tools malformed_response missing_candidate
                              missing_function_call request_too_large response_too_large transport_error unexpected_function_call
                              unfinished_response unsupported_usage).freeze

        class Error < StandardError
          attr_reader :code, :http_status, :finish_reason, :usage

          def initialize(code, http_status: nil, finish_reason: nil, usage: {})
            @code = code
            @http_status = http_status
            @finish_reason = finish_reason
            @usage = usage.freeze
            super("Gemini conversation request failed: #{code}")
          end
        end

        # Net::HTTP retains this exact String as response.body, so the existing
        # accounting observer can verify provider bytes after the callback.
        class BoundedBody < String
          def <<(chunk)
            raise Error.new(:response_too_large), cause: nil if bytesize + chunk.bytesize > MAX_BODY_BYTES

            super
          end
        end

        Result = Struct.new(:content, :text, :function_calls, :structured, :finish_reason, :usage, :model_version, keyword_init: true) do
          # Content/signatures are ephemeral continuation state, never telemetry.
          def inspect
            "#<#{self.class.name} finish_reason=#{finish_reason} usage=#{usage.inspect}>"
          end
          alias_method :to_s, :inspect

          def pretty_print(printer)
            printer.text(inspect)
          end
        end
        TokenCount = Struct.new(:total_tokens, :cached_content_tokens, keyword_init: true)

        attr_reader :model, :base_url

        def initialize(api_key:, model:, base_url:, settings:, transport: nil, observer: nil,
                       clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
          fail_with(:invalid_configuration) unless api_key.is_a?(String) && !api_key.empty? && !api_key.match?(/[\r\n]/)
          fail_with(:invalid_configuration) unless ENDPOINTS.has_key?(base_url) && THINKING_LEVELS.has_key?(model)
          @api_key = api_key.dup.freeze
          @model = model.dup.freeze
          @base_url = base_url.dup.freeze
          @settings = normalize_settings(settings)
          @transport = transport || method(:https_request)
          @observer = observer
          @clock = clock
        end

        def inspect
          "#<#{self.class.name} model=#{model} base_url=#{base_url}>"
        end

        # deadline must expose remaining_seconds; the same budget is reused by
        # every planner/composer/tool-loop call. transport is an injectable callable
        # taking uri:, headers:, body:, timeout: and returning {status:, body:}.
        def generate_content(contents:, deadline:, system_instruction: nil, tools: [], response_schema: nil, tool_mode: "AUTO", settings: nil)
          observe("generation") do
            body = request_body(contents, system_instruction, tools, response_schema, tool_mode, settings)
            payload = request("generateContent", body, deadline)
            parse_generation(payload, body, structured: !response_schema.nil?)
          end
        end

        # Count the complete generation prompt, including system/tool declarations.
        # Google exposes different countTokens envelopes on these two endpoints.
        def count_tokens(contents:, deadline:, system_instruction: nil, tools: [], response_schema: nil, tool_mode: "AUTO", settings: nil)
          observe("token_count") do
            body = request_body(contents, system_instruction, tools, response_schema, tool_mode, settings)
            body = if base_url == "https://generativelanguage.googleapis.com"
                     { "generateContentRequest" => body.merge("model" => "models/#{model}") }
                   else
                     body.except("toolConfig")
                   end
            payload = request("countTokens", body, deadline)
            fail_with(:malformed_response) unless nonnegative_integer?(payload["totalTokens"])
            cached = payload["cachedContentTokenCount"]
            fail_with(:malformed_response) unless cached.nil? || nonnegative_integer?(cached)
            TokenCount.new(total_tokens: payload.fetch("totalTokens"), cached_content_tokens: cached).freeze
          end
        end

        private

        # Optional content-free spans. A telemetry failure cannot change a
        # citizen answer or expose provider request/response material.
        def observe(phase)
          return yield unless @observer

          started = @clock.call
          result = yield
          result
        rescue StandardError => error
          raise
        ensure
          emit_span(phase, started, result, error) if started
        end

        def emit_span(phase, started, result, error)
          usage = result.respond_to?(:usage) ? result.usage : (error.usage if error.respond_to?(:usage))
          event = { phase: phase, status: error ? "error" : "ok",
                    duration_ms: [((@clock.call - started) * 1000).round(3), 0].max }
          if error
            code = error.is_a?(Error) ? error.code.to_s : nil
            event[:error_code] = SPAN_ERROR_CODES.include?(code) ? code : "internal_error"
          end
          if usage.is_a?(Hash)
            { "promptTokenCount" => :input_tokens, "candidatesTokenCount" => :candidate_tokens,
              "thoughtsTokenCount" => :thought_tokens, "cachedContentTokenCount" => :cached_input_tokens }.each do |field, name|
              value = usage[field]
              event[name] = value if value.is_a?(Integer) && value >= 0
            end
          elsif result.is_a?(TokenCount)
            event[:input_tokens] = result.total_tokens
            event[:cached_input_tokens] = result.cached_content_tokens if result.cached_content_tokens
          end
          @observer.call(**event.freeze)
        rescue StandardError
          nil
        end

        def normalize_settings(settings)
          fail_with(:invalid_settings) unless settings.is_a?(Hash)
          values = settings.transform_keys(&:to_s)
          fail_with(:invalid_settings) unless (values.keys - %w(max_output_tokens candidate_count temperature thinking_level)).empty?
          fail_with(:invalid_settings) unless bounded_integer?(values["max_output_tokens"], 1..65_536)
          fail_with(:invalid_settings) unless [nil, 1].include?(values["candidate_count"])
          temperature = values["temperature"]
          fail_with(:invalid_settings) unless temperature.nil? || valid_temperature?(temperature)
          level = values["thinking_level"]
          fail_with(:invalid_settings) unless valid_thinking_level?(level)
          values.merge("candidate_count" => 1, "thinking_level" => level.downcase).freeze
        end

        def request_body(contents, system_instruction, tools, response_schema, tool_mode, settings)
          # JSON copy isolates returned continuation state and accepts symbol keys.
          contents, tools, response_schema = json_copy([contents, tools, response_schema])
          fail_with(:invalid_contents) unless contents.is_a?(Array) && !contents.empty?
          contents.each { |content| validate_content(content) }
          validate_tools(tools)
          fail_with(:invalid_tools) unless %w(AUTO ANY NONE).include?(tool_mode)
          config = generation_config(settings, response_schema)
          body = { "contents" => contents, "generationConfig" => config }
          unless system_instruction.nil?
            fail_with(:invalid_contents) unless system_instruction.is_a?(String) && !system_instruction.empty?
            body["systemInstruction"] = { "parts" => [{ "text" => system_instruction }] }
          end
          unless tools.empty?
            body["tools"] = tools
            body["toolConfig"] = { "functionCallingConfig" => { "mode" => tool_mode } }
          end
          body
        end

        def generation_config(settings, response_schema)
          fail_with(:invalid_settings) unless settings.nil? || settings.is_a?(Hash)
          chosen = settings ? normalize_settings(@settings.merge(settings.transform_keys(&:to_s))) : @settings
          config = { "candidateCount" => 1, "maxOutputTokens" => chosen.fetch("max_output_tokens"), "thinkingConfig" => { "thinkingLevel" => chosen.fetch("thinking_level") } }
          config["temperature"] = chosen["temperature"] if chosen.has_key?("temperature")
          if response_schema
            fail_with(:invalid_schema) unless response_schema.is_a?(Hash) && !response_schema.empty?
            config.merge!("responseMimeType" => "application/json", "responseSchema" => response_schema)
          end
          config
        end

        def valid_thinking_level?(level)
          level.is_a?(String) && THINKING_LEVELS.fetch(model).include?(level.downcase)
        end

        def validate_content(content)
          fail_with(:invalid_contents) unless content.is_a?(Hash) && %w(user model).include?(content["role"])
          fail_with(:invalid_contents) unless content["parts"].is_a?(Array) && !content["parts"].empty?
          content["parts"].each { |part| validate_part(part) }
        end

        def validate_tools(tools)
          fail_with(:invalid_tools) unless tools.is_a?(Array)
          tools.each do |tool|
            fail_with(:invalid_tools) unless tool.is_a?(Hash) && tool.keys == ["functionDeclarations"]
            declarations = tool["functionDeclarations"]
            fail_with(:invalid_tools) unless declarations.is_a?(Array) && !declarations.empty?
            declarations.each { |declaration| validate_declaration(declaration) }
          end
        end

        def validate_declaration(declaration)
          fail_with(:invalid_tools) unless declaration.is_a?(Hash) && declaration["name"].is_a?(String)
          fail_with(:invalid_tools) unless declaration["name"].match?(/\A[a-zA-Z_][a-zA-Z0-9_-]{0,63}\z/)
          fail_with(:invalid_tools) unless (declaration.keys - %w(name description parameters parametersJsonSchema)).empty?
        end

        def validate_part(part)
          fail_with(:invalid_contents) unless part.is_a?(Hash)
          # Text/function protocol only; no URL/file/media or provider-side tools.
          fail_with(:invalid_contents) unless (part.keys - %w(text functionCall functionResponse thought thoughtSignature partMetadata)).empty?
          payloads = part.keys & %w(text functionCall functionResponse)
          fail_with(:invalid_contents) unless payloads.length == 1 || (payloads.empty? && part.has_key?("thoughtSignature"))
          validate_part_metadata(part)
          %w(functionCall functionResponse).each { |key| validate_function_part(part[key], key) if part.has_key?(key) }
        end

        def validate_part_metadata(part)
          fail_with(:invalid_contents) if part.has_key?("text") && !part["text"].is_a?(String)
          fail_with(:invalid_contents) if part.has_key?("thoughtSignature") && !part["thoughtSignature"].is_a?(String)
          fail_with(:invalid_contents) if part.has_key?("thought") && ![true, false].include?(part["thought"])
        end

        def validate_function_part(value, key)
          fail_with(:invalid_contents) unless value.is_a?(Hash) && value["name"].is_a?(String)
          field = key == "functionCall" ? "args" : "response"
          fail_with(:invalid_contents) unless value.fetch(field, key == "functionCall" ? {} : nil).is_a?(Hash)
        end

        def request(operation, body, deadline)
          timeout = remaining(deadline)
          encoded = JSON.generate(body)
          fail_with(:request_too_large) if encoded.bytesize > MAX_BODY_BYTES
          uri = URI("#{base_url}#{ENDPOINTS.fetch(base_url)}#{model}:#{operation}")
          response = Timeout.timeout(timeout) do
            @transport.call(uri: uri, headers: { "Content-Type" => "application/json", "x-goog-api-key" => @api_key }, body: encoded, timeout: timeout)
          end
          status = response.fetch(:status).to_i
          fail_with(:http_error, http_status: status) unless status == 200
          raw = response.fetch(:body)
          fail_with(:malformed_response) unless raw.is_a?(String)
          fail_with(:response_too_large) if raw.bytesize > MAX_BODY_BYTES
          parsed = JSON.parse(raw)
          fail_with(:malformed_response) unless parsed.is_a?(Hash)
          begin
            remaining(deadline)
          rescue Error
            fail_with(:deadline_exceeded, usage: extract_usage(parsed))
          end
          parsed
        rescue Error
          raise
        rescue Timeout::Error
          fail_with(:deadline_exceeded)
        rescue JSON::ParserError, KeyError, TypeError
          fail_with(:malformed_response)
        rescue StandardError
          fail_with(:transport_error)
        end

        def https_request(uri:, headers:, body:, timeout:)
          # Ignore proxy environment and disable Net::HTTP's implicit retry.
          http = Net::HTTP.new(uri.host, uri.port, nil)
          http.use_ssl = true
          http.open_timeout = http.read_timeout = http.write_timeout = timeout
          http.max_retries = 0
          request = Net::HTTP::Post.new(uri.request_uri, headers)
          request.body = body
          response_body = +""
          status = nil
          http.start do |connection|
            connection.request(request) do |response|
              status = response.code.to_i
              # The existing journal observer can already have buffered/frozen
              # the body. Net::HTTP exposes no public already-read predicate.
              response_body = response.instance_variable_get(:@read) ? response.body : response.read_body(BoundedBody.new)
              fail_with(:malformed_response) unless response_body.is_a?(String)
              fail_with(:response_too_large, http_status: status) if response_body.bytesize > MAX_BODY_BYTES
            end
          end
          { status: status, body: response_body }
        end

        def parse_generation(payload, body, structured:)
          usage = extract_usage(payload)
          candidate = completed_candidate(payload, usage)
          reason = candidate.fetch("finishReason")
          content = validated_model_content(candidate, usage, reason)
          calls = content["parts"].filter_map { |part| part["functionCall"] }
          validate_calls(calls, body, usage)
          text = content["parts"].reject { |part| part["thought"] }.filter_map { |part| part["text"] }.join
          parsed = parse_structured(text, usage, reason) if structured && calls.empty?
          fail_with(:empty_response, usage: usage) if text.empty? && calls.empty?
          Result.new(content: content, text: text, function_calls: calls, structured: parsed, finish_reason: reason,
                     usage: usage.freeze, model_version: safe_model_version(payload["modelVersion"])).freeze
        end

        def completed_candidate(payload, usage)
          candidates = payload["candidates"]
          fail_with(:missing_candidate, usage: usage) unless candidates.is_a?(Array) && candidates.length == 1 && candidates.first.is_a?(Hash)
          candidate = candidates.first
          reason = candidate["finishReason"]
          reason = "UNKNOWN" unless FINISH_REASONS.include?(reason)
          fail_with(:unfinished_response, finish_reason: reason, usage: usage) unless reason == "STOP"
          candidate
        end

        def validated_model_content(candidate, usage, reason)
          content = candidate["content"]
          fail_with(:malformed_response, usage: usage) unless content.is_a?(Hash) && content["role"] == "model" && content["parts"].is_a?(Array) && !content["parts"].empty?
          begin
            content["parts"].each { |part| validate_part(part) }
          rescue Error
            fail_with(:malformed_response, usage: usage, finish_reason: reason)
          end
          fail_with(:malformed_response, usage: usage) if content["parts"].any? { |part| part.has_key?("functionResponse") }
          content
        end

        def validate_calls(calls, body, usage)
          names = body.fetch("tools", []).flat_map { |tool| tool.fetch("functionDeclarations").map { |declaration| declaration.fetch("name") } }
          mode = body.dig("toolConfig", "functionCallingConfig", "mode")
          fail_with(:missing_function_call, usage: usage) if mode == "ANY" && calls.empty?
          forbidden_calls = mode == "NONE"
          fail_with(:unexpected_function_call, usage: usage) if !calls.empty? && (forbidden_calls || calls.any? { |call| !names.include?(call["name"]) })
        end

        def safe_model_version(version)
          version if version.is_a?(String) && version.match?(/\Agemini-[a-zA-Z0-9._-]{1,100}\z/)
        end

        def parse_structured(text, usage, reason)
          parsed = JSON.parse(text)
          fail_with(:invalid_structured_output, usage: usage, finish_reason: reason) unless parsed.is_a?(Hash)
          parsed
        rescue JSON::ParserError
          fail_with(:invalid_structured_output, usage: usage, finish_reason: reason)
        end

        def bounded_integer?(value, range)
          value.is_a?(Integer) && range.cover?(value)
        end

        def valid_temperature?(value)
          value.is_a?(Numeric) && value.finite? && (0..2).cover?(value)
        end

        def extract_usage(payload)
          metadata = payload["usageMetadata"]
          return {} unless metadata.is_a?(Hash)

          known = metadata.select { |key, value| USAGE_KEYS.include?(key) && nonnegative_integer?(value) }
          unsupported = metadata.any? do |key, value|
            key.end_with?("TokenCount") && !USAGE_KEYS.include?(key) && value != 0
          end
          fail_with(:unsupported_usage, usage: known) if unsupported
          known
        end

        def remaining(deadline)
          value = deadline.remaining_seconds
          fail_with(:deadline_exceeded) unless value.is_a?(Numeric) && value.finite? && value.positive?
          value
        end

        def nonnegative_integer?(value)
          value.is_a?(Integer) && value >= 0
        end

        def json_copy(value)
          JSON.parse(JSON.generate(value))
        rescue JSON::GeneratorError, JSON::ParserError, TypeError
          fail_with(:invalid_contents)
        end

        def fail_with(code, **details)
          raise Error.new(code, **details), cause: nil
        end
      end
    end
  end
end

# rubocop:enable Metrics/ParameterLists
# rubocop:enable Rails/NegateInclude
