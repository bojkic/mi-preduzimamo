# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/synthetic_service_directory"

module DecidimApp
  module Bijeljina
    # Verifies configured host wiring with an authored 24-category directory.
    # No municipal contact details, prices or official records are shipped.
    class CityDirectoryTest < ActiveSupport::TestCase
      include SyntheticServiceDirectory
      setup { install_synthetic_service_directory }
      teardown { restore_synthetic_service_directory }

      test "exposes a ServiceDirectory built from the configured authored entries" do
        assert_instance_of Decidim::Bih::City::ServiceDirectory,
                           CityDirectory.directory
      end

      test "returns the expanded authored service entries" do
        keys = CityDirectory.all.map { |entry| entry[:key] }

        assert_operator CityDirectory.all.size, :>=, 24
        assert_equal([:otpad, :parking, :maticar, :pracenje_predmeta, :e_registar,
                      :prijava_problema, :kontakt_grada, :struja_iskljucenja,
                      :vodovod_servis, :toplana_grijanje, :javni_prevoz,
                      :putevi_saobracaj, :civilna_zastita, :vremenska_upozorenja,
                      :vodostaji, :kvalitet_vazduha, :sluzbena_obavjestenja,
                      :policija_bezbjednost, :zdravstvo_apoteke, :socijalna_zastita,
                      :poljoprivreda_podsticaji, :gradjevinske_dozvole_legalizacija,
                      :upis_skola_vrtic, :psi_lutalice].sort, keys.sort)
      end

      test "each contact card names the dialogue topic the read port maps to it" do
        expected = { "health" => :zdravstvo_apoteke, "social_welfare" => :socijalna_zastita,
                     "agriculture" => :poljoprivreda_podsticaji, "permits" => :gradjevinske_dozvole_legalizacija,
                     "education" => :upis_skola_vrtic, "animals" => :psi_lutalice }

        expected.each do |topic, key|
          entry = CityDirectory.find(key)

          assert_equal topic, entry.fetch(:topic), key
          assert_equal key, Milica::ReadPort::DIRECTORY_TOPIC_KEYS.fetch(topic), topic
          assert_equal "2040-09-14", entry.fetch(:source_checked_on), key
          assert_includes entry.fetch(:answer), "provjeren", key
          assert_match(%r{\Ahttps://community\.example\.invalid/}, entry.fetch(:source_url), key)
        end
        assert_equal expected.keys.sort, CityDirectory.all.filter_map { |entry| entry[:topic] }.sort
      end

      test "memoizes the directory instance" do
        assert_same CityDirectory.directory, CityDirectory.directory
      end

      test "resolves a parking query to the parking entry" do
        results = CityDirectory.search("parking")

        assert_equal :parking, results.first[:key]
      end

      test "resolves a 'rodni list' query to the matičar entry" do
        results = CityDirectory.search("rodni list")

        assert_includes results.map { |entry| entry[:key] }, :maticar
      end

      test "answers a rodni list fee question from matičar, not public transport" do
        result = CityDirectory.search("koliko košta rodni list?").first

        assert_equal :maticar, result.fetch(:key)
        assert_includes result.fetch(:answer), "administrativna taksa"
        assert_includes result.fetch(:answer), "poštarine"
        assert_not_includes result.fetch(:answer), "javni gradski prevoz"
      end

      test "resolves public transport and air-quality questions to deeper source entries" do
        transport = CityDirectory.search("red voznje javnog prevoza")
        air = CityDirectory.search("kvalitet vazduha pm10")

        assert_equal :javni_prevoz, transport.first[:key]
        assert_equal :kvalitet_vazduha, air.first[:key]
      end

      test "resolves utility and warning questions to official source entries" do
        water = CityDirectory.search("vodovod servisne informacije")
        civil = CityDirectory.search("civilna zastita poplava upozorenje")

        assert_equal :vodovod_servis, water.first[:key]
        assert_equal :civilna_zastita, civil.first[:key]
      end

      test "does not treat a generic bot capability question as a city-service match" do
        assert_empty CityDirectory.search("sta sve mozes da uradis")
      end

      test "ranks pothole and street problem text as problem-report guidance" do
        results = CityDirectory.search("imam rupu na putu kod skole sta da radim")

        assert_equal :prijava_problema, results.first[:key]
        assert_not_equal :otpad, results.first[:key]
      end

      test "find resolves a known key and accepts a string" do
        assert_equal :otpad, CityDirectory.find("otpad")[:key]
        assert_includes CityDirectory.find(:parking)[:source_url], "community.example.invalid"
      end
      private

      # This class needs all supported categories; the shared nine-entry fixture
      # intentionally stays minimal for its other consumers.
      def synthetic_service_entries
        topics = { zdravstvo_apoteke: "health", socijalna_zastita: "social_welfare",
          poljoprivreda_podsticaji: "agriculture", gradjevinske_dozvole_legalizacija: "permits",
          upis_skola_vrtic: "education", psi_lutalice: "animals" }
        additions = {
          pracenje_predmeta: ["Praćenje predmeta", ["praćenje predmeta"]],
          e_registar: ["Elektronski registar", ["e registar"]],
          kontakt_grada: ["Kontakt zajednice", ["kontakt zajednice"]],
          toplana_grijanje: ["Toplana i grijanje", ["toplana", "grijanje"]],
          putevi_saobracaj: ["Putevi i saobraćaj", ["putevi", "saobraćaj"]],
          civilna_zastita: ["Civilna zaštita", ["civilna zastita", "poplava", "upozorenje"]],
          vremenska_upozorenja: ["Vremenska upozorenja", ["vrijeme", "meteo"]],
          vodostaji: ["Vodostaji", ["vodostaj", "rijeka"]],
          kvalitet_vazduha: ["Kvalitet vazduha", ["kvalitet vazduha", "pm10"]],
          sluzbena_obavjestenja: ["Službena obavještenja", ["službena obavještenja"]],
          policija_bezbjednost: ["Policija i bezbjednost", ["policija", "bezbjednost"]],
          zdravstvo_apoteke: ["Zdravstvo i apoteke", ["zdravstvo", "apoteka"]],
          poljoprivreda_podsticaji: ["Poljoprivreda i podsticaji", ["poljoprivreda", "podsticaji"]],
          upis_skola_vrtic: ["Upis u školu i vrtić", ["upis", "vrtić"]],
          psi_lutalice: ["Briga o životinjama", ["psi", "lutalice"]]
        }
        base = super
        extras = additions.map do |key, (title, keywords)|
          { key: key, title: title, keywords: keywords, source_url: "https://community.example.invalid/#{key}",
            source_checked_on: "2040-09-14", answer: "IZMIŠLJENI provjereni kontakt za test: #{title}." }
        end
        (base + extras).map do |row|
          row = row.dup
          row[:topic] = topics.fetch(row[:key]) if topics.key?(row[:key])
          row[:answer] = "IZMIŠLJENI provjereni kontakt za test. #{row[:answer]}" if row[:topic]
          case row[:key]
          when :maticar
            row[:keywords] = row[:keywords] + ["rodni list"]
            row[:answer] = "IZMIŠLJENI PRIMJER: administrativna taksa i troškovi poštarine zavise od lokalne procedure."
          when :prijava_problema
            row[:keywords] = row[:keywords] + ["rupa na putu", "ulica", "rupu"]
          when :javni_prevoz
            row[:keywords] = row[:keywords] + ["red vožnje", "javnog prevoza"]
          when :vodovod_servis
            row[:keywords] = row[:keywords] + ["servisne informacije"]
          end
          row.freeze
        end
      end
    end
  end
end
