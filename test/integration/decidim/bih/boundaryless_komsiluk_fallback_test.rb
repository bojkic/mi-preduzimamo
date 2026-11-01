# frozen_string_literal: true

require "test_helper"
require "capybara"

# END-TO-END proof that the NON-POLYGON fallback still works for another host or
# an emergency setup: a komšiluk created with NO boundary geometry can be joined
# via the dropdown picker, and
# the joined citizen can then read and post on the Komšiluk board. Also asserts
# AreaLocator silently skips a nil-boundary komšiluk rather than crashing.
module Decidim
  module Bih
    class BoundarylessKomsilukFallbackTest < ActionDispatch::IntegrationTest
      include ::Devise::Test::IntegrationHelpers

      setup do
        @organization = create_organization
        host! @organization.host

        # A boundary-less komšiluk — exactly what the flat importer produces.
        @komsiluk = Decidim::Bih::LocalArea.create!(
          organization: @organization, kind: "komsiluk", slug: "centar-sjever",
          name: { "sr" => "Centar Sjever", "en" => "Centar Sjever" }
        )

        @user = FactoryBot.create(:user, :confirmed, organization: @organization)
      end

      # ── Model / assignment layer ──────────────────────────────────────────────

      test "a boundary-less komsiluk is model-valid" do
        assert @komsiluk.valid?
        assert_nil @komsiluk.boundary
        assert_nil @komsiluk.primary_mz
      end

      test "assign_komsiluk! via dropdown tolerates a nil primary_mz / nil boundary" do
        profile = Decidim::Bih::CitizenProfile.for_user(@user, organization: @organization)
        assert_nothing_raised do
          profile.assign_komsiluk!(@komsiluk, source: "dropdown")
        end

        assert profile.reload.assigned?
        assert_equal @komsiluk.id, profile.komsiluk_id
        assert_nil profile.mz_id, "no MZ resolvable without a boundary or primary_mz_slug"
        assert_equal "dropdown", profile.source
      end

      test "dropdown assignment resolves mz from primary_mz_slug when one is set" do
        mz = Decidim::Bih::LocalArea.create!(
          organization: @organization, kind: "mz", slug: "mz-centar",
          name: { "sr" => "Centar" }
        )
        @komsiluk.update!(primary_mz_slug: "mz-centar")

        profile = Decidim::Bih::CitizenProfile.for_user(@user, organization: @organization)
        profile.assign_komsiluk!(@komsiluk, source: "dropdown")

        assert_equal mz.id, profile.reload.mz_id
      end

      # ── AreaLocator robustness ────────────────────────────────────────────────

      test "AreaLocator skips a nil-boundary komsiluk instead of crashing" do
        locator = Decidim::Bih::Geo::AreaLocator.new
        result = nil
        assert_nothing_raised do
          result = locator.locate_komsiluk(lat: 44.756, lon: 19.214, organization: @organization)
        end
        assert_nil result, "no polygon ⇒ no point match (must not raise)"

        resolve = nil
        assert_nothing_raised do
          resolve = locator.resolve(lat: 44.756, lon: 19.214, organization: @organization)
        end
        assert_nil resolve[:komsiluk]
        assert_nil resolve[:mz]
      end

      # ── Dropdown picker (controller) ──────────────────────────────────────────

      test "the boundary-less komsiluk appears in the dropdown picker" do
        sign_in @user
        get "/biceriseno/komsiluk"
        assert_response :success
        assert_includes response.body, "Centar Sjever"
        # Rendered as a selectable <option value="id">
        assert_includes response.body, "value=\"#{@komsiluk.id}\""
      end

      test "PATCH /biceriseno/komsiluk via dropdown assigns the boundary-less komsiluk" do
        sign_in @user
        patch "/biceriseno/komsiluk", params: {
          komsiluk_id: @komsiluk.id,
          source: "dropdown"
        }
        assert_response :redirect

        profile = Decidim::Bih::CitizenProfile.find_by(
          decidim_organization_id: @organization.id,
          decidim_user_id: @user.id
        )
        assert_not_nil profile
        assert profile.assigned?
        assert_equal @komsiluk.id, profile.komsiluk_id
        assert_nil profile.mz_id
      end

      # ── End-to-end: read + post on the board after dropdown join ───────────────

      test "after a dropdown join the citizen can READ the board" do
        Decidim::Bih::CitizenProfile.for_user(@user, organization: @organization)
                                    .assign_komsiluk!(@komsiluk, source: "dropdown")

        sign_in @user
        get "/biceriseno/komsiluk-board"
        assert_response :success
      end

      test "after a dropdown join + sms the citizen can POST to the board" do
        Decidim::Bih::CitizenProfile.for_user(@user, organization: @organization)
                                    .assign_komsiluk!(@komsiluk, source: "dropdown")
        grant_sms_auth(@user)

        sign_in @user
        assert_difference("Decidim::Bih::KomsilukPost.count", 1) do
          post "/biceriseno/komsiluk-board", params: {
            komsiluk_post: { category: "general", title: "Pozdrav komšije", body: "Test poruka" }
          }
        end
        assert_response :redirect

        created = Decidim::Bih::KomsilukPost.order(:created_at).last
        assert_equal @komsiluk.id, created.komsiluk_id
        assert_equal @user.id, created.decidim_user_id
      end

      test "a citizen posts and then reads back their own post on a boundary-less komsiluk" do
        Decidim::Bih::CitizenProfile.for_user(@user, organization: @organization)
                                    .assign_komsiluk!(@komsiluk, source: "dropdown")
        grant_sms_auth(@user)

        sign_in @user
        post "/biceriseno/komsiluk-board", params: {
          komsiluk_post: { category: "general", title: "Vidljiva objava", body: "Tijelo objave" }
        }

        get "/biceriseno/komsiluk-board"
        assert_response :success
        assert_includes response.body, "Vidljiva objava"
      end

      private

      def grant_sms_auth(user)
        Decidim::Authorization.find_or_initialize_by(user: user, name: "sms").tap do |auth|
          auth.granted_at = Time.current
          auth.save!
        end
      end
    end
  end
end
