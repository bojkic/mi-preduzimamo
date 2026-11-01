# frozen_string_literal: true

require "test_helper"
require "capybara"

module Decidim
  module Bih
    # Round 11, Item 6 — org names link to profiles on the gifts page.
    class OrgDiscoveryTest < ActionDispatch::IntegrationTest
      include ::Devise::Test::IntegrationHelpers

      setup do
        @organization = create_organization
        host! @organization.host
        @user = FactoryBot.create(:user, :confirmed, organization: @organization)
        @group = FactoryBot.create(:user, :confirmed, organization: @organization,
                                                      extended_data: { "group" => true })
        @group.update!(name: "Udruženje aktivnih")
        @profile = Decidim::Bih::PartnerProfile.create!(
          organization: @organization,
          display_name: "Udruženje aktivnih",
          slug: "udruzenje-aktivnih",
          kind: "association",
          verification_status: "verified",
          legacy_user_group: @group,
          verified_at: Time.current
        )
      end

      test "gifts page links each org name to its profile" do
        get "/biceriseno/podrzi"
        assert_redirected_to %r{/biceriseno/zajednistvo\?locale=sr&tab=podrzi\z}
        follow_redirect!
        assert_response :success
        # The org name should appear inside an <a> tag pointing to the profile
        assert_includes response.body, "/biceriseno/organizacija/#{@profile.slug}"
        assert_includes response.body, "Udruženje aktivnih"
      end

      test "org profile page is accessible by link" do
        get "/biceriseno/organizacija/#{@profile.slug}"
        assert_response :success
        assert_includes response.body, "Udruženje aktivnih"
      end
    end
  end
end
