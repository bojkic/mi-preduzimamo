# frozen_string_literal: true

require "test_helper"
require "capybara"

module DecidimApp
  # Scanner probes for non-HTML formats must get a bare 404, not a 500.
  class NonHtmlNotFoundTest < ActionDispatch::IntegrationTest
    setup do
      @organization = create_organization
      host! @organization.host
      # Exercise the real exceptions app (production behaviour), not the
      # developer debug page the test environment shows.
      env = Rails.application.env_config
      @saved_env = env.slice("action_dispatch.show_exceptions", "action_dispatch.show_detailed_exceptions")
      env["action_dispatch.show_exceptions"] = :all
      env["action_dispatch.show_detailed_exceptions"] = false
    end

    teardown do
      Rails.application.env_config.merge!(@saved_env) if @saved_env
    end

    %w(json xml yaml txt).each do |ext|
      test "unknown .#{ext} path answers a bodyless 404" do
        get "/no-such-thing-p3.#{ext}"
        assert_response :not_found
        assert_empty response.body
      end
    end

    test "Accept json on an unknown path answers a bodyless 404" do
      get "/no-such-thing-p3", headers: { "Accept" => "application/json" }
      assert_response :not_found
      assert_empty response.body
    end

    test "bare Accept */* still renders the HTML 404 page as before" do
      get "/no-such-thing-p3", headers: { "Accept" => "*/*" }
      assert_response :not_found
      assert_includes response.media_type, "html"
      assert_operator response.body.bytesize, :>, 1000
      assert_includes response.body, "<html"
    end

    test "HTML 404 page is unchanged" do
      get "/no-such-thing-p3"
      assert_response :not_found
      assert_includes response.media_type, "html"
      assert_predicate response.body, :present?
    end
  end
end
