# frozen_string_literal: true

require "test_helper"
require "capybara"

module Decidim
  module Bih
    class InvitePageTest < ActionDispatch::IntegrationTest
      include ::Devise::Test::IntegrationHelpers

      setup do
        @organization = create_organization
        host! @organization.host
        @user = FactoryBot.create(:user, :confirmed, organization: @organization, nickname: "ana")
      end

      test "shows the invite link to a signed-in user" do
        sign_in @user
        # Legacy /biceriseno/pozovi 301s to the hub; test canonical hub URL.
        get "/biceriseno/zajednistvo?tab=pozovi"

        assert_response :success
        # The link the citizen copies is the short /p/<nadimak> form, which 302s
        # to the registration form: an anonymous visitor landing on the hub tab
        # was only told to sign in, and never registered. The tab itself still
        # accepts old ?ref= links (below), and offers the same link as a QR code.
        assert_select "section#pozovi input[readonly]" do |inputs|
          assert_equal 1, inputs.length
          assert_equal "#{request.base_url}/p/ana", inputs.first["value"]
        end
        assert_select "section#pozovi .mi-invite-qr svg"
        assert_select "section#pozovi .mi-invite-qr a[download='pozovi-ana.svg']"
      end

      test "captures an inbound ref code into the session via the hub" do
        # The hub's pozovi tab captures ?ref= into the session just like the old
        # InviteController did. Test through the hub canonical URL.
        get "/biceriseno/zajednistvo?tab=pozovi&ref=somebody"

        assert_response :success
        assert_equal "somebody", session[:goodwill_ref]
      end

      test "legacy pozovi redirect preserves the ref param" do
        # GET /biceriseno/pozovi?ref=X redirects to the hub preserving the ref.
        get "/biceriseno/pozovi?ref=somebody"

        assert_equal 301, response.status
        assert_includes response.location, "tab=pozovi"
        assert_includes response.location, "ref=somebody"
      end
    end
  end
end
