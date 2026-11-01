# frozen_string_literal: true

require "test_helper"
require "capybara"

module DecidimApp
  # The public GraphQL endpoint stays open (GraphiQL is public by owner
  # decision), so its abuse limits are pinned here: Decidim ships depth,
  # complexity, alias and recursion limits; the host adds a document size cap.
  class ApiQueryLimitsTest < ActionDispatch::IntegrationTest
    setup do
      @organization = create_organization
      host! @organization.host
    end

    def gql(query, headers: {})
      post "/api", params: { query: }.to_json, headers: { "CONTENT_TYPE" => "application/json" }.merge(headers)
      response.parsed_body
    end

    test "schema keeps conservative depth and complexity limits" do
      assert_operator Decidim::Api::Schema.max_depth, :<=, 15
      assert_operator Decidim::Api::Schema.max_complexity, :<=, 5000
      assert_operator Decidim::Api.max_aliases, :<=, 5
    end

    test "normal public query still works" do
      body = gql("{ organization { name { translation(locale: \"sr\") } } }")
      assert_response :success
      assert_nil body["errors"], body.inspect
      assert body.dig("data", "organization")
    end

    test "same nesting within the limit passes validation" do
      body = gql("query { assemblies { children { children { id } } } }")
      assert_nil body["errors"], body.inspect.slice(0, 300)
    end

    test "over-deep query is rejected on depth" do
      depth = Decidim::Api::Schema.max_depth + 5
      body = gql("query { assemblies { #{"children { " * depth}id #{"} " * depth}} }")
      messages = body["errors"].to_a.pluck("message").join(" ")
      assert_includes messages, "Query has depth of #{depth + 2}, which exceeds max depth of #{Decidim::Api::Schema.max_depth}"
      assert_nil body["data"]
    end

    test "standard introspection query fits the size cap and still runs for the schema" do
      query = GraphQL::Introspection::INTROSPECTION_QUERY
      assert_operator query.bytesize, :<, ApiQuerySizeLimit::MAX_QUERY_BYTES / 4
      result = Decidim::Api::Schema.execute(query,
                                            context: { current_organization: @organization, can_introspect: true, scopes: Doorkeeper::OAuth::Scopes.from_string("api:read") })
      assert_nil result["errors"], result.to_h.inspect.slice(0, 300)
      assert result.dig("data", "__schema", "types").present?
    end

    test "query of exactly the size cap is still executed" do
      prefix = "{ organization { name { translation(locale: \"sr\") } } } #"
      body = gql(prefix + ("x" * (ApiQuerySizeLimit::MAX_QUERY_BYTES - prefix.bytesize)))
      assert_response :success
      assert_nil body["errors"], body.inspect.slice(0, 300)
      assert body.dig("data", "organization", "name", "translation")
    end

    test "oversized query is refused before the schema runs" do
      calls = 0
      Decidim::Api::Schema.stub(:execute, ->(*, **) { calls += 1 }) do
        body = gql("{ organization { name { translation(locale: \"sr\") } } } ##{"x" * ApiQuerySizeLimit::MAX_QUERY_BYTES}")
        assert_response :payload_too_large
        assert body["errors"].present?
      end
      assert_equal 0, calls
    end

    test "size cap counts bytes, not characters" do
      calls = 0
      # 7 000 three-byte characters are 21 000 bytes but only 7 000 characters.
      query = "{ organization { name { translation(locale: \"sr\") } } } ##{"\u20ac" * 7_000}"
      assert_operator query.length, :<, ApiQuerySizeLimit::MAX_QUERY_BYTES
      Decidim::Api::Schema.stub(:execute, ->(*, **) { calls += 1 }) do
        gql(query)
        assert_response :payload_too_large
      end
      assert_equal 0, calls
    end

    # GHSA-rmxg-5p3r-j6hh needs the optional file-parser cache. Keep it
    # disabled, and prove ordinary anonymous API queries do not consult it.
    test "file parser caching stays disabled after application boot" do
      assert_equal false, Rails.application.config.graphql.parser_cache
      assert_nil GraphQL::Language::Parser.cache
    end

    test "anonymous API query does not consult the file parser cache" do
      unexpected_cache = Object.new
      def unexpected_cache.fetch(*)
        raise "File parser cache unexpectedly used for an HTTP query"
      end

      GraphQL::Language::Parser.stub(:cache, unexpected_cache) do
        body = gql("{ organization { name { translation(locale: \"sr\") } } }")
        assert_response :success
        assert_nil body["errors"], body.inspect
        assert body.dig("data", "organization", "name", "translation")
      end
    end

    test "anonymous introspection stays refused over HTTP and its setting is unchanged" do
      assert_not Decidim::Api.enable_anonymous_introspection
      body = gql("{ __schema { queryType { name } } }")
      assert_includes body["errors"].to_a.pluck("message").join(" "), "Introspection is disabled for this request"
      assert_nil body.dig("data", "__schema")
    end
  end
end
