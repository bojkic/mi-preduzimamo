# frozen_string_literal: true

require "test_helper"
# The Decidim layout resolves default URL options via Capybara.server_port in tests.
require "capybara"

module Decidim
  module Bih
    # HTTP coverage for the public recognition leaderboard at /biceriseno/tabla.
    class LeaderboardPageTest < ActionDispatch::IntegrationTest
      setup do
        @organization = create_organization
        host! @organization.host
        @previous_cache = Rails.cache
        Rails.cache = ActiveSupport::Cache::MemoryStore.new
      end

      teardown do
        Rails.cache = @previous_cache
      end

      def award(user, amount, reason)
        Decidim::Bih::Goodwill::Ledger.new.award(user, amount, reason:)
      end

      # Convenience: GET the hub's tabla tab directly (canonical URL post-reorg).
      def get_tabla(params = {})
        get "/biceriseno/zajednistvo", params: { tab: "tabla" }.merge(params)
      end

      test "GET tabla renders the leaderboard ordered by contribution" do
        alice = FactoryBot.create(:user, :confirmed, organization: @organization, name: "Ana Anić")
        bob = FactoryBot.create(:user, :confirmed, organization: @organization, name: "Bojan Bošić")
        award(alice, 30, "proposal")
        award(bob, 100, "volunteer_hour")

        get_tabla

        assert_response :success
        assert_includes response.body, "Ana Anić"
        assert_includes response.body, "Bojan Bošić"
        # Higher score ranks first: Bojan (100) before Ana (30).
        assert response.body.index("Bojan Bošić") < response.body.index("Ana Anić")
        # Recognition level/title is shown (Bojan at 100 pts -> "Aktivista" in sr).
        assert_includes response.body, "Aktivista"
      end

      test "GET tabla renders gracefully when no one has points yet" do
        get_tabla

        assert_response :success
      end

      test "GET tabla does not show earners from another organization" do
        other = create_organization
        outsider = FactoryBot.create(:user, :confirmed, organization: other, name: "Tuđi korisnik")
        award(outsider, 500, "volunteer_hour")

        get_tabla

        assert_response :success
        assert_not_includes response.body, "Tuđi korisnik"
      end

      test "the monthly window renders a citizen-of-the-month hero" do
        alice = FactoryBot.create(:user, :confirmed, organization: @organization, name: "Ana Anić")
        travel_to(2.months.ago) { award(alice, 90, "volunteer_hour") }
        award(alice, 20, "report")

        get_tabla(period: "month")

        assert_response :success
        assert_includes response.body, "Ana Anić"
        assert_includes response.body, "Komšija mjeseca"
      end

      test "the weekly window renders and an unknown period falls back to all-time" do
        alice = FactoryBot.create(:user, :confirmed, organization: @organization, name: "Ana Anić")
        award(alice, 30, "proposal")

        get_tabla(period: "week")
        assert_response :success

        get_tabla(period: "bogus")
        assert_response :success
        assert_includes response.body, "Ana Anić"
      end

      test "leaderboard cache refreshes after a new earn transaction" do
        alice = FactoryBot.create(:user, :confirmed, organization: @organization, name: "Ana Anić")
        bob = FactoryBot.create(:user, :confirmed, organization: @organization, name: "Bojan Bošić")
        award(alice, 30, "proposal")

        get_tabla
        assert_includes response.body, "Ana Anić"
        assert_not_includes response.body, "Bojan Bošić"

        award(bob, 100, "volunteer_hour")
        get_tabla

        assert_includes response.body, "Bojan Bošić"
        assert response.body.index("Bojan Bošić") < response.body.index("Ana Anić")
      end

      test "public recognition opt-out removes a citizen from an already cached board" do
        alice = FactoryBot.create(:user, :confirmed, organization: @organization, name: "Ana Skrivena")
        award(alice, 100, "volunteer_hour")

        get_tabla
        assert_includes response.body, "Ana Skrivena"

        Decidim::Bih::PublicRecognition.set_enabled!(alice, false)
        get_tabla

        assert_response :success
        assert_not_includes response.body, "Ana Skrivena"
      end

      test "legacy GET /biceriseno/tabla redirects to hub tabla tab" do
        get "/biceriseno/tabla"
        assert_redirected_to "/biceriseno/zajednistvo?tab=tabla"
        assert_equal 301, response.status
      end
    end
  end
end
