# frozen_string_literal: true

require "test_helper"
# Integration tests that render Decidim layouts need Capybara loaded so
# Decidim::UrlOptionResolver can reference Capybara.server_port.
require "capybara"

class KomsilukControllerTest < ActionDispatch::IntegrationTest
  include ::Devise::Test::IntegrationHelpers
  include ActiveJob::TestHelper

  setup do
    clear_enqueued_jobs
    clear_performed_jobs

    @organization = Decidim::Bih::LocalArea # touch the namespace to ensure autoload
    @organization = create_organization
    host! @organization.host

    @user = FactoryBot.create(:user, :confirmed, organization: @organization)

    # Decoupled model: MZ has boundary for point-resolution; komšiluk has no parent.
    @mz = Decidim::Bih::LocalArea.create!(
      organization: @organization,
      kind: "mz",
      slug: "mz-ctrl",
      name: { "sr" => "Test MZ", "en" => "Test MZ" },
      boundary: {
        "type" => "Polygon",
        "coordinates" => [
          [[19.210, 44.750], [19.220, 44.750], [19.220, 44.760], [19.210, 44.760], [19.210, 44.750]]
        ]
      }
    )
    @komsiluk = Decidim::Bih::LocalArea.create!(
      organization: @organization,
      kind: "komsiluk",
      slug: "komsiluk-ctrl",
      name: { "sr" => "Test Komšiluk", "en" => "Test Neighbourhood" },
      primary_mz_slug: "mz-ctrl",
      boundary: {
        "type" => "Polygon",
        "coordinates" => [
          [[19.210, 44.755], [19.220, 44.755], [19.220, 44.760], [19.210, 44.760], [19.210, 44.755]]
        ]
      }
    )
  end

  teardown do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  # ─── Authentication gate ──────────────────────────────────────────────

  test "GET /biceriseno/komsiluk redirects when not signed in" do
    get "/biceriseno/komsiluk"
    assert_redirected_to %r{/users/sign_in}
  end

  test "GET /biceriseno/komsiluk renders picker when signed in" do
    sign_in @user
    get "/biceriseno/komsiluk"
    assert_response :success
  end

  test "registration handoff permits installation and opens the map before address and list" do
    sign_in @user
    get "/biceriseno/komsiluk?setup=1&app=1"
    assert_response :success
    assert_select "script[src*='mi-install.js']"
    assert_select "#mi-install-context[data-allowed='1']"
    assert_select ".mi-komsiluk-setup details[open] #bih-komsiluk-map", count: 1
    assert_operator response.body.index('id="bih-komsiluk-map"'), :<, response.body.index('id="bih-address-suggest"')
    assert_operator response.body.index('id="bih-address-suggest"'), :<, response.body.index('id="bih-komsiluk-select"')

    get "/biceriseno/komsiluk"
    assert_select "#mi-install-context[data-allowed='0']"
  end

  # ─── areas.json endpoint (public — only geometry, no citizen data) ────

  test "GET /biceriseno/komsiluk/areas returns GeoJSON without login" do
    get "/biceriseno/komsiluk/areas"
    assert_response :success
    data = response.parsed_body
    assert_equal "FeatureCollection", data["type"]
  end

  test "areas.json is tenant-scoped — no data from other orgs" do
    other_org = create_organization
    k_other = Decidim::Bih::LocalArea.create!(
      organization: other_org,
      kind: "komsiluk",
      slug: "k-other",
      name: { "sr" => "Other K" }
    )

    get "/biceriseno/komsiluk/areas"
    data = response.parsed_body
    ids = data["features"].map { |f| f["properties"]["id"] }
    assert_not_includes ids, k_other.id
  end

  test "areas.json contains ONLY geometry, name, id — no citizen data" do
    get "/biceriseno/komsiluk/areas"
    data = response.parsed_body
    data["features"].each do |feature|
      props = feature["properties"]
      assert props.has_key?("id")
      assert props.has_key?("name")
      assert props.has_key?("slug")
      # Must NOT expose citizen data
      assert_not props.has_key?("user_id")
      assert_not props.has_key?("citizens")
      assert_not props.has_key?("komsiluk_id_user")
      # mz_id (old parent link) should no longer be in the response
      assert_not props.has_key?("mz_id")
    end
  end

  test "areas.json features include primary_mz_slug" do
    get "/biceriseno/komsiluk/areas"
    data = response.parsed_body
    feature = data["features"].find { |f| f.dig("properties", "slug") == "komsiluk-ctrl" }
    assert_not_nil feature
    assert feature["properties"].has_key?("primary_mz_slug")
  end

  # ─── PATCH update — source=map with lat/lon → MZ resolved by point ───

  test "PATCH update with source=map and lat/lon stores point-resolved mz_id" do
    sign_in @user
    assert_difference("Decidim::Bih::CitizenProfile.count", 1) do
      patch "/biceriseno/komsiluk", params: {
        komsiluk_id: @komsiluk.id,
        source: "map",
        lat: 44.757,
        lon: 19.215
      }
    end
    assert_redirected_to "/biceriseno/komsiluk"

    profile = Decidim::Bih::CitizenProfile.find_by(decidim_organization_id: @organization.id, decidim_user_id: @user.id)
    assert_not_nil profile
    assert_equal @komsiluk.id, profile.komsiluk_id
    assert_equal @mz.id, profile.mz_id
    assert_equal "map", profile.source
    # Address is NEVER a column in citizen_profiles
    assert_not profile.attributes.has_key?("address")
  end

  test "PATCH update with source=map and no lat/lon falls back to primary_mz" do
    sign_in @user
    patch "/biceriseno/komsiluk", params: { komsiluk_id: @komsiluk.id, source: "map" }
    assert_redirected_to "/biceriseno/komsiluk"

    profile = Decidim::Bih::CitizenProfile.find_by(decidim_organization_id: @organization.id, decidim_user_id: @user.id)
    # Falls back to komsiluk.primary_mz (mz-ctrl)
    assert_equal @mz.id, profile.mz_id
  end

  test "PATCH update with source=address stores komsiluk_id, mz_id, source — address absent" do
    sign_in @user
    patch "/biceriseno/komsiluk", params: {
      komsiluk_id: @komsiluk.id,
      source: "address",
      lat: 44.757,
      lon: 19.215
    }
    assert_redirected_to "/biceriseno/komsiluk"

    profile = Decidim::Bih::CitizenProfile.find_by(decidim_organization_id: @organization.id, decidim_user_id: @user.id)
    assert_equal "address", profile.source
    assert_not profile.attributes.has_key?("address")
    assert_equal @komsiluk.id, profile.komsiluk_id
    assert_equal @mz.id, profile.mz_id
  end

  test "PATCH update with source=address resolves mz from transient point without primary mz" do
    komsiluk_without_primary = Decidim::Bih::LocalArea.create!(
      organization: @organization,
      kind: "komsiluk",
      slug: "komsiluk-address-no-primary",
      name: { "sr" => "Address Komsiluk", "en" => "Address Neighbourhood" },
      boundary: {
        "type" => "Polygon",
        "coordinates" => [
          [[19.212, 44.756], [19.218, 44.756], [19.218, 44.759], [19.212, 44.759], [19.212, 44.756]]
        ]
      }
    )

    sign_in @user
    patch "/biceriseno/komsiluk", params: {
      komsiluk_id: komsiluk_without_primary.id,
      source: "address",
      lat: 44.757,
      lon: 19.215
    }

    profile = Decidim::Bih::CitizenProfile.find_by(decidim_organization_id: @organization.id, decidim_user_id: @user.id)
    assert_equal "address", profile.source
    assert_equal komsiluk_without_primary.id, profile.komsiluk_id
    assert_equal @mz.id, profile.mz_id
    assert_not profile.attributes.has_key?("address")
  end

  test "PATCH update with source=dropdown stores primary_mz as mz_id (no point)" do
    sign_in @user
    patch "/biceriseno/komsiluk", params: { komsiluk_id: @komsiluk.id, source: "dropdown" }

    profile = Decidim::Bih::CitizenProfile.find_by(decidim_organization_id: @organization.id, decidim_user_id: @user.id)
    assert_equal "dropdown", profile.source
    assert_equal @komsiluk.id, profile.komsiluk_id
    # mz from primary_mz (komsiluk.primary_mz_slug = "mz-ctrl")
    assert_equal @mz.id, profile.mz_id
  end

  # ─── BLOCKER 2 regression guard: flat dropdown picker ────────────────
  # Komšiluci are decoupled from MZ (no parent_id). The edit page must render
  # the flat komšiluk list so the user can select any komšiluk directly.
  test "GET edit page renders flat komsiluk dropdown with all org komsiluci" do
    @komsiluk2 = Decidim::Bih::LocalArea.create!(
      organization: @organization,
      kind: "komsiluk",
      slug: "komsiluk-ctrl-2",
      name: { "sr" => "Drugi Komsiluk", "en" => "Second Neighbourhood" }
    )

    sign_in @user
    get "/biceriseno/komsiluk"

    assert_response :success
    # Both komšiluci must appear as <option> elements with their DB ids.
    assert_select "select[name='komsiluk_id'] option[value='#{@komsiluk.id}']", minimum: 1
    assert_select "select[name='komsiluk_id'] option[value='#{@komsiluk2.id}']", minimum: 1
  end

  test "PATCH dropdown source stores komsiluk_id and primary_mz without a point" do
    sign_in @user
    patch "/biceriseno/komsiluk", params: { komsiluk_id: @komsiluk.id, source: "dropdown" }

    assert_redirected_to "/biceriseno/komsiluk"
    profile = Decidim::Bih::CitizenProfile.find_by(
      decidim_organization_id: @organization.id,
      decidim_user_id: @user.id
    )
    assert_not_nil profile
    assert_equal @komsiluk.id, profile.komsiluk_id
    # MZ resolved via komsiluk.primary_mz_slug ("mz-ctrl" → @mz)
    assert_equal @mz.id, profile.mz_id
    assert_equal "dropdown", profile.source
  end

  test "PATCH update is idempotent (re-selectable)" do
    sign_in @user
    patch "/biceriseno/komsiluk", params: { komsiluk_id: @komsiluk.id, source: "map", lat: 44.757, lon: 19.215 }

    assert_no_difference("Decidim::Bih::CitizenProfile.count") do
      patch "/biceriseno/komsiluk", params: { komsiluk_id: @komsiluk.id, source: "dropdown" }
    end

    profile = Decidim::Bih::CitizenProfile.find_by(decidim_organization_id: @organization.id, decidim_user_id: @user.id)
    assert_equal "dropdown", profile.source
  end

  test "PATCH update rejects invalid source" do
    sign_in @user
    patch "/biceriseno/komsiluk", params: { komsiluk_id: @komsiluk.id, source: "hacked" }
    assert_redirected_to "/biceriseno/komsiluk"
    assert_nil Decidim::Bih::CitizenProfile.find_by(decidim_organization_id: @organization.id, decidim_user_id: @user.id)
  end

  test "PATCH update rejects komsiluk from another org" do
    other_org = create_organization
    other_k = Decidim::Bih::LocalArea.create!(organization: other_org, kind: "komsiluk", slug: "k-other2", name: { "sr" => "Y" })

    sign_in @user
    patch "/biceriseno/komsiluk", params: { komsiluk_id: other_k.id, source: "map" }
    assert_redirected_to "/biceriseno/komsiluk"
    assert_nil Decidim::Bih::CitizenProfile.find_by(decidim_organization_id: @organization.id, decidim_user_id: @user.id)
  end

  test "PATCH update by signed-in user from another organization is sent to sign in" do
    outsider = create_other_org_assigned_user
    sign_in outsider

    assert_no_difference("Decidim::Bih::CitizenProfile.count") do
      assert_no_enqueued_jobs only: Decidim::Bih::Goodwill::GoodwillAwardJob do
        patch "/biceriseno/komsiluk", params: { komsiluk_id: @komsiluk.id, source: "dropdown" }
      end
    end

    assert_redirected_to %r{/users/sign_in}
    assert_nil Decidim::Bih::CitizenProfile.find_by(
      decidim_organization_id: @organization.id,
      decidim_user_id: outsider.id
    )
  end

  # ─── suggest endpoint ────────────────────────────────────────────────

  test "POST suggest returns JSON with found=false when geocoder returns nil" do
    sign_in @user
    Decidim::Bih::Geo::Geocoder.stub(:coordinates, nil) do
      post "/biceriseno/komsiluk/suggest", params: { address: "Nowhere" },
                                           headers: { "Accept" => "application/json" }
    end
    assert_response :success
    data = response.parsed_body
    assert_equal false, data["found"]
  end

  test "POST suggest returns komsiluk_id when geocoder + locator find a match" do
    sign_in @user
    Decidim::Bih::Geo::Geocoder.stub(:coordinates, { lat: 44.758, lon: 19.215 }) do
      post "/biceriseno/komsiluk/suggest", params: { address: "Ulica Cara Lazara 12" },
                                           headers: { "Accept" => "application/json" }
    end
    assert_response :success
    data = response.parsed_body
    assert_equal true, data["found"]
    assert_equal @komsiluk.id, data["komsiluk_id"]
    assert_equal 44.758, data["lat"]
    assert_equal 19.215, data["lon"]
    # The address is NOT echoed back in the response
    assert_not data.has_key?("address")
  end

  test "POST suggest with empty address returns found=false" do
    sign_in @user
    Decidim::Bih::Geo::Geocoder.stub(:coordinates, nil) do
      post "/biceriseno/komsiluk/suggest", params: { address: "" },
                                           headers: { "Accept" => "application/json" }
    end
    data = response.parsed_body
    assert_equal false, data["found"]
  end

  # Suggest is PUBLIC: the one-step registration form (which has no session
  # to gate on) uses it to pre-fill its komšiluk select. It is stateless and
  # scoped by the host's organization alone — it never reads current_user —
  # so an anonymous visitor and a signed-in citizen get the same answer, and
  # nothing is written for either.
  test "POST suggest answers without a login" do
    Decidim::Bih::Geo::Geocoder.stub(:coordinates, { lat: 44.758, lon: 19.215 }) do
      assert_no_difference("Decidim::Bih::CitizenProfile.count") do
        post "/biceriseno/komsiluk/suggest", params: { address: "Ulica Cara Lazara 12" },
                                             headers: { "Accept" => "application/json" }
      end
    end

    assert_response :success
    data = response.parsed_body
    assert_equal true, data["found"]
    assert_equal @komsiluk.id, data["komsiluk_id"]
    assert_not data.has_key?("address")
  end

  test "POST suggest by a signed-in user from another organization resolves against the host's organization only" do
    outsider = create_other_org_assigned_user
    sign_in outsider

    Decidim::Bih::Geo::Geocoder.stub(:coordinates, { lat: 44.758, lon: 19.215 }) do
      assert_no_difference("Decidim::Bih::CitizenProfile.count") do
        post "/biceriseno/komsiluk/suggest", params: { address: "Adresa iz druge organizacije" },
                                             headers: { "Accept" => "application/json" }
      end
    end

    assert_response :success
    assert_equal @komsiluk.id, response.parsed_body["komsiluk_id"]
    assert_nil Decidim::Bih::CitizenProfile.find_by(
      decidim_organization_id: @organization.id,
      decidim_user_id: outsider.id
    )
  end

  test "membership search returns choices with precision without writing a profile or selecting a first point" do
    candidates = [
      { label: "Public Street", lat: 44.758, lon: 19.215, precision: "street" },
      { label: "Public Street 12", lat: 44.758, lon: 19.215, precision: "address" }
    ]
    Decidim::Bih::Geo::Geocoder.stub(:search, candidates) do
      assert_no_difference("Decidim::Bih::CitizenProfile.count") do
        post "/biceriseno/komsiluk/suggest", params: { address: "Public Street 12", purpose: "membership" }
      end
    end
    assert_response :success
    data = response.parsed_body
    assert data.fetch("requires_selection")
    assert_equal(%w(street address), data.fetch("candidates").map { |row| row.fetch("precision") })
    assert_equal([true, false], data.fetch("candidates").map { |row| row.fetch("requires_map_confirmation") })
    assert_not data.has_key?("komsiluk_id")
    assert_not data.has_key?("lat")
  end

  # ─── Privacy: komsiluk data never in extended_data ───────────────────

  test "komsiluk assignment does not write to user extended_data" do
    sign_in @user
    patch "/biceriseno/komsiluk", params: { komsiluk_id: @komsiluk.id, source: "map", lat: 44.757, lon: 19.215 }

    @user.reload
    extended = @user.extended_data || {}
    assert_nil extended["komsiluk_id"]
    assert_nil extended["mz_id"]
    assert_not(extended.keys.any? { |k| k.to_s.include?("komsiluk") })
  end

  private

  def create_other_org_assigned_user
    other_org = create_organization
    other_mz = Decidim::Bih::LocalArea.create!(
      organization: other_org,
      kind: "mz",
      slug: "mz-ctrl-other-#{SecureRandom.hex(4)}",
      name: { "sr" => "Druga MZ" }
    )
    other_komsiluk = Decidim::Bih::LocalArea.create!(
      organization: other_org,
      kind: "komsiluk",
      slug: "komsiluk-ctrl-other-#{SecureRandom.hex(4)}",
      name: { "sr" => "Drugi Komšiluk" },
      primary_mz_slug: other_mz.slug
    )
    outsider = FactoryBot.create(:user, :confirmed, organization: other_org)
    Decidim::Bih::CitizenProfile
      .for_user(outsider, organization: other_org)
      .assign_komsiluk!(other_komsiluk, source: "dropdown")
    outsider
  end
end
