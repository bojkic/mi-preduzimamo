# frozen_string_literal: true

require "test_helper"
require "capybara"

module DecidimApp
  class SocialRegistrationHandoffsTest < ActionDispatch::IntegrationTest
    TOKEN = "a" * 43
    PHONE = "+38765123456"

    setup do
      @organization = create_organization
      host! @organization.host
      @payload = {
        "version" => 1,
        "organization_id" => @organization.id,
        "channel" => "instagram",
        "sender_digest" => "b" * 64,
        "phone" => PHONE,
        "expires_at" => 5.minutes.from_now.iso8601
      }
    end

    test "GET previews without claiming and keeps the credential out of the DOM" do
      claim_called = false

      with_forgery_protection do
        with_store(claim: ->(**) { claim_called = true }) do
          preview_handoff
        end
      end

      assert_response :success
      assert_select "form[action='#{social_registration_handoff_path}'][method='post']"
      assert_select "input[name='authenticity_token']"
      assert_not_includes response.body, TOKEN
      assert_not_includes response.body, PHONE
      assert_not claim_called
      assert_private_token_headers
    end

    test "POST atomically claims then redirects to a clean registration URL" do
      with_store do
        preview_handoff
        post social_registration_handoff_path
      end

      assert_redirected_to "/registracija"
      assert_not_includes response.location, TOKEN
      assert_not_includes response.location, PHONE
      assert_private_token_headers
    end

    test "replay fails closed without a success redirect" do
      claims = 0
      claim = lambda do |**|
        claims += 1
        claims == 1 ? @payload : nil
      end

      with_store(claim:) do
        preview_handoff
        post social_registration_handoff_path
        preview_handoff
        post social_registration_handoff_path
      end

      assert_response :unprocessable_entity
      assert_private_token_headers
    end

    test "invalid preview expiry fails before the atomic claim" do
      @payload["expires_at"] = ""
      claim_called = false

      with_store(claim: ->(**) { claim_called = true }) do
        preview_handoff
        post social_registration_handoff_path
      end

      assert_response :unprocessable_entity
      assert_not claim_called
      assert_private_token_headers
    end

    test "POST requires CSRF proof before claiming the preview" do
      claims = 0
      claim = lambda do |**|
        claims += 1
        @payload
      end

      with_forgery_protection do
        with_store(claim:) do
          preview_handoff
          post social_registration_handoff_path
          assert_response :unprocessable_entity
          assert_equal 0, claims

          preview_handoff
          csrf_token = css_select("input[name='authenticity_token']").first["value"]
          post social_registration_handoff_path, params: { authenticity_token: csrf_token }
          assert_redirected_to "/registracija"
          assert_equal 1, claims
        end
      end
    end

    test "social handoff query parameter is filtered" do
      filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)

      assert_not_equal TOKEN, filter.filter_param("social_handoff", TOKEN)
    end

    private

    def preview_handoff
      get social_registration_handoff_path, params: { social_handoff: TOKEN }
      assert_redirected_to social_registration_handoff_path
      assert_not_includes response.location, TOKEN
      follow_redirect!
    end

    def with_forgery_protection
      previous = ActionController::Base.allow_forgery_protection
      ActionController::Base.allow_forgery_protection = true
      yield
    ensure
      ActionController::Base.allow_forgery_protection = previous
    end

    def with_store(claim: ->(**) { @payload })
      store = DecidimApp::Bijeljina::SocialRegistrationHandoff
      store.stub(:available?, true) do
        store.stub(:peek, ->(**) { @payload }) do
          store.stub(:claim, claim) { yield }
        end
      end
    end

    def assert_private_token_headers
      assert_includes response.headers["Cache-Control"], "no-store"
      assert_equal "no-referrer", response.headers["Referrer-Policy"]
      assert_equal "noindex, nofollow", response.headers["X-Robots-Tag"]
    end
  end
end
