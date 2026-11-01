# frozen_string_literal: true

require "test_helper"

module DecidimApp
  module Bijeljina
    class BotDataStatusTest < ActiveSupport::TestCase
      include ActiveSupport::Testing::TimeHelpers

      setup do
        @organization = create_organization
        Decidim::Bih::LocalArea.create!(
          organization: @organization,
          kind: "mz",
          slug: "mz-data-status",
          name: { "sr" => "MZ Data Status" },
          predsjednik: "Jovan Jovanović",
          telefon: "055-111-222"
        )
      end

      teardown { travel_back }

      test "names the reviewed data kinds, the public integrations and the honest limits" do
        travel_to Time.zone.local(2026, 6, 29, 12, 0, 0) do
          text = BotDataStatus.new(organization: @organization).answer(locale: "sr")

          assert_includes text, "MI!"
          assert_includes text, "imenik gradskih usluga"
          assert_includes text, "odvoza otpada"
          assert_includes text, "parking zone"
          assert_includes text, "budžet"
          assert_includes text, "Službeni glasnik"
          assert_includes text, "mjesne zajednice"
          assert_includes text, "Integracije dostupne botu"
          assert_includes text, "Gemini"
          assert_includes text, "Infobip"
          assert_includes text, "Odoo"
          assert_includes text, "Sistem 48"
          assert_includes text, "Svježina podataka"
          assert_includes text, "izvor i vrijeme provjere"
          assert_includes text, "servisni FAQ je proširen"
          assert_not_includes text, "GEMINI_API_KEY"
          assert_not_includes text, "ODOO_API_KEY"
          assert_not_includes text, "INFOBIP_API_KEY"
        end
      end

      # Task 10, item 5. An anonymous visitor asked what data the bot has and
      # got an operational inventory back: catalogue row counts, the configured
      # source count, the scrape cadences, the Viber-candidate count, the
      # OK/warn/fail freshness tally and the NAMES of the sources currently
      # failing. Those figures belong to the operator surfaces, not to a public
      # chat reply.
      test "withholds catalogue counts, scrape cadences and the names of unhealthy sources" do
        CityServiceEvent.create!(
          organization: @organization,
          source_key: "electricity_outages",
          source_fingerprint: "bot-data-status-electricity",
          event_type: "planned_outage",
          severity: "service_outage",
          targeting_level: "mz",
          title: "Planirano isključenje struje",
          summary: "Dvorovi 09:00-12:00",
          source_url: "https://example.test/outages",
          parser_version: "test",
          state: "published",
          starts_at: 1.hour.ago,
          ends_at: 1.hour.from_now
        )

        text = BotDataStatus.new(organization: @organization).answer(locale: "sr")

        ["izvora", "na sat", "na 4 sata", "dnevno", "sedmično", "za provjeru", "kandidati za Viber",
         "odgovora u imeniku", "područja za odvoz", "ulica u pregledu", "budžetske stavke",
         "izdanja Službenog glasnika", "mjesnih zajednica", "trenutno objavljenih"].each do |operational|
          assert_not_includes text, operational
        end

        CityDataFreshness.statuses(organization: @organization, source_checks: [])
                         .select { |row| %w(warn fail).include?(row.fetch(:status).to_s) }
                         .each { |row| assert_not_includes text, row.fetch(:label).to_s }

        # The only digits left are the ones in a published integration name.
        assert_equal ["48"], text.scan(/\d+/)
      end

      test "localizes the public summary to Cyrillic when requested" do
        text = BotDataStatus.new(organization: @organization).answer(locale: "sr-Cyrl")

        assert_match(/\p{Cyrillic}/, text)
        assert_includes text, "МИ!"
      end
    end
  end
end
