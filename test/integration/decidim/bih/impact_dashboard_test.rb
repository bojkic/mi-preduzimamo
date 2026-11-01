# frozen_string_literal: true

require "test_helper"
require "capybara"

module Decidim
  module Bih
    class ImpactDashboardTest < ActionDispatch::IntegrationTest
      FakeTotals = Struct.new(:total, :count, :currency, :as_of, keyword_init: true) # rubocop:disable Lint/StructNewOverride
      FakeProject = Struct.new(:title, :donate_url, :totals, keyword_init: true)
      FakeProvider = Struct.new(:totals, :donate_url, :currency_label, :project_mappings, keyword_init: true)

      setup do
        @organization = create_organization
        host! @organization.host
        @original_provider = Decidim::Bih.donations_provider
        Decidim::Bih.donations_provider = FakeProvider.new(
          totals: FakeTotals.new(total: 1250, count: 8, currency: "BAM", as_of: Time.current),
          donate_url: "https://fondacijabijeljina.com",
          currency_label: "KM",
          project_mappings: [
            FakeProject.new(
              title: "Novi vrtić u Ledincima",
              donate_url: "https://fondacijabijeljina.com?utm_campaign=novi-vrtic",
              totals: FakeTotals.new(total: 300, count: 2, currency: "BAM", as_of: Time.current)
            )
          ]
        )
        @citizen = FactoryBot.create(:user, :confirmed, organization: @organization, name: "Skriveni Građanin")
        @mz = LocalArea.create!(
          organization: @organization,
          kind: "mz",
          slug: "mz-centar",
          name: { "sr" => "Centar" }
        )
        @komsiluk = LocalArea.create!(
          organization: @organization,
          kind: "komsiluk",
          slug: "komsiluk-centar",
          primary_mz_slug: @mz.slug,
          name: { "sr" => "Centar sjever" }
        )
      end

      teardown do
        Decidim::Bih.donations_provider = @original_provider
      end

      test "renders aggregate impact figures anonymously" do
        3.times do |idx|
          Report.create!(
            organization: @organization,
            description: "Tajni opis #{idx}",
            status: idx.zero? ? "rijeseno" : "u_obradi",
            category: "putevi",
            mz_slug: @mz.slug,
            reporter_email: "gradjanin#{idx}@example.org",
            reporter_phone: "+387 65 123 45#{idx}",
            latitude: 44.755 + idx,
            longitude: 19.215 + idx
          )
        end
        3.times do |idx|
          KomsilukPost.create!(
            organization: @organization,
            author: @citizen,
            komsiluk: @komsiluk,
            category: "general",
            title: "Privatan naslov #{idx}",
            body: "Privatan tekst #{idx}"
          )
        end
        opportunity = VolunteerOpportunity.create!(
          organization: @organization,
          title: "Akcija koju ne moramo prikazati",
          description: "Volonterski opis",
          active: true,
          review_status: "approved",
          starts_at: 1.day.from_now
        )
        create_legacy_volunteer_log!(
          organization: @organization,
          opportunity:,
          user: @citizen,
          hours: 5,
          status: "approved"
        )
        VolunteerAvailability.create!(
          organization: @organization,
          user: @citizen,
          availability: "Samo poslije posla",
          interests: "Privatne napomene"
        )
        Goodwill::Ledger.new.award(@citizen, 120, reason: "volunteer_hour")

        get "/biceriseno/uticaj"

        assert_response :success
        assert_includes response.body, "Pregled uticaja"
        assert_includes response.body, "1.250 KM"
        assert_includes response.body, "Trendovi"
        assert_includes response.body, "Zadnjih 30 dana"
        assert_includes response.body, "Nove prijave"
        assert_includes response.body, "Potvrđeni sati"
        assert_includes response.body, "Novi vrtić u Ledincima"
        assert_includes response.body, "300 KM"
        assert_includes response.body, "Potvrđeni volonterski sati"
        assert_includes response.body, "Centar"
        assert_includes response.body, "&lt;3"
        assert_includes response.body, "/biceriseno/mapa"
        assert_includes response.body, "/biceriseno/mapa-problema"
        assert_includes response.body, "/biceriseno/volontiranje"

        assert_not_includes response.body, "Tajni opis"
        assert_not_includes response.body, "gradjanin0@example.org"
        assert_not_includes response.body, "+387 65"
        assert_not_includes response.body, "44.755"
        assert_not_includes response.body, "19.215"
        assert_not_includes response.body, "Privatan naslov"
        assert_not_includes response.body, "Privatan tekst"
        assert_not_includes response.body, "Samo poslije posla"
        assert_not_includes response.body, "Privatne napomene"
        assert_not_includes response.body, "Skriveni Građanin"
      end
    end
  end
end
