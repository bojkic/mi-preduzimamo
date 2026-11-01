# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module Goodwill
      class InviteLinksTest < ActiveSupport::TestCase
        setup do
          @organization = create_organization
          @user = FactoryBot.create(:user, :confirmed, organization: @organization, nickname: "ana")
          @links = InviteLinks.new(@user, base_url: "https://mi.example.org")
        end

        # The invite link is this host's SHORT form, /p/<nadimak> (2026-09-12):
        # config/initializers/decidim_bih_goodwill.rb sets invite_short_path and
        # config/routes.rb 302s it to the registration form with ?ref=. It lands
        # on the REGISTRATION FORM, not the hub's pozovi tab: an anonymous
        # visitor there was only told to sign in, and never registered.
        test "builds a short landing url carrying the referrer code" do
          assert_equal "ana", @links.code
          assert_equal "https://mi.example.org/p/ana", @links.landing_url
        end

        test "channel links embed the encoded landing url" do
          encoded = CGI.escape("https://mi.example.org/p/ana")
          assert_includes @links.whatsapp_url, "api.whatsapp.com/send?text="
          assert_includes @links.whatsapp_url, encoded
          assert_includes @links.facebook_url, "sharer.php?u="
          assert_includes @links.facebook_url, encoded
          assert_includes @links.viber_url, "viber://forward?text="
          assert_includes @links.viber_url, encoded
        end
      end
    end
  end
end
