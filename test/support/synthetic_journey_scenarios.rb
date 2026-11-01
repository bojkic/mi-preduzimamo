# frozen_string_literal: true
require_relative "synthetic_service_directory"
require_relative "synthetic_transport_network"
require "pathname"

# Authored textual timetables exercise the real legacy text/calendar preparer.
# This deliberately includes an unexplained school symbol and an empty Sunday;
# neither may silently turn into a usable departure.
module SyntheticJourneyScenarios
  include SyntheticServiceDirectory
  include SyntheticTransportNetwork

  def install_synthetic_journey_scenarios
    install_synthetic_service_directory
    install_synthetic_transport
    host = DecidimApp::Bijeljina
    # An explicit fare is separate from the toy departure matrices.
    entries = host::CityServicesData::ENTRIES.map do |entry|
      next entry unless entry[:key] == :javni_prevoz
      fare = "IZMIŠLJENA TESTNA CIJENA 2,37 KM; nije stvarna tarifa."
      row = entry.merge(answer: fare, source_checked_on: "2026-09-08", answer_sections: { fares: fare },
        answer_sources: { fares: "https://community.example.invalid/synthetic/fare" })
      row[:facts] = host::CityServicesData.entry_facts(row, checked_on: Date.new(2026, 9, 8))
      row.freeze
    end
    swap_service_constant(host::CityServicesData, :ENTRIES, entries.freeze)
    host::CityDirectory.instance_variable_set(:@directory, Decidim::Bih::City::ServiceDirectory.new(entries))
    registry = host::LocalStreetRegistry
    %i(@stamp @dataset @name_index).each do |key|
      present = registry.instance_variable_defined?(key)
      @synthetic_service_caches << [registry, key, present, registry.instance_variable_get(key)]
      registry.remove_instance_variable(key) if present
    end
    street = File.join(@synthetic_service_root, "street.geojson")
    File.write(street, JSON.generate("type" => "FeatureCollection", "features" => [{ "type" => "Feature",
      "properties" => { "name" => "Izmišljena breza", "aliases" => ["Izmišljene breze"], "settlement" => "Bijeljina",
        "source_url" => "https://community.example.invalid/synthetic/street", "geometry_complete" => true },
      "geometry" => { "type" => "LineString", "coordinates" => [[0.502, 0.500], [0.5022, 0.5002]] } }]))
    swap_service_constant(registry, :DATA_PATH, Pathname.new(street))
  end

  def restore_synthetic_journey_scenarios
    restore_synthetic_transport
    restore_synthetic_service_directory
  end

  def synthetic_journey_documents
    nas = "Bijeljina (NAS)"
    # Each row is an independently invented stop/time column. No local source
    # text, coordinates or timetable is read or transformed.
    specs = {
      "G1" => { "A" => [[nas, %w(06:30 08:30 10:30 12:30 14:30 16:30)], ["Izmišljena ulica", %w(06:34 08:34 10:34 12:34 14:34 16:34)],
        ["Bijeljina (spomenik)", %w(06:37 08:37 10:37 12:37 14:37 16:37)], ["Primjerpark", %w(06:40 08:40 10:40 12:40 14:40 16:40)]],
        "B" => [["Primjerpark", %w(07:00 09:00 11:00 13:00 15:00 17:00)], ["Bijeljina (spomenik)", %w(07:03 09:03 11:03 13:03 15:03 17:03)],
          ["Izmišljena ulica", %w(07:06 09:06 11:06 13:06 15:06 17:06)], [nas, %w(07:10 09:10 11:10 13:10 15:10 17:10)]] },
      "G2" => { "A" => [[nas, %w(07:25 09:55 12:55 15:55)], ["Bijeljina (spomenik)", %w(07:30 10:00 13:00 16:00)],
        ["Bijeljina (bolnica)", %w(07:35 10:05 13:05 16:05)], ["ATC", %w(07:45 10:15 13:15 16:15)]],
        "B" => [["ATC", %w(08:00 10:30 13:30 16:30)], ["Bijeljina (bolnica)", %w(08:10 10:40 13:40 16:40)], [nas, %w(08:20 10:50 13:50 16:50)]] },
      "P1" => { "A" => [[nas, %w(06:30 08:30 12:30 16:30)], ["Bijeljina (spomenik)", %w(06:35 08:35 12:35 16:35)],
        ["Primjervrt (CSP)", %w(06:50 08:50 12:50 16:50)], ["Primjervrt (škola)", %w(06:55 08:55 12:55 16:55)]],
        "B" => [["Primjervrt (škola)", %w(06:00 08:00 12:00 16:00)], ["Primjervrt (CSP)", %w(06:05 08:05 12:05 16:05)],
          ["Bijeljina (spomenik)", %w(06:20 08:20 12:20 16:20)], [nas, %w(06:25 08:25 12:25 16:25)]] },
      "P2" => { "A" => [[nas, %w(06:50 11:40 18:40)], ["Primjerpolje (škola)", %w(07:25 12:15 19:15)]],
        "B" => [["Primjerpolje (škola)", %w(07:40 12:40 17:40)], [nas, %w(08:15 13:15 18:15)]] },
      "P3" => { "A" => [[nas, %w(07:00 11:00 17:30 18:30)], ["Primjerdalje (spomenik)", %w(07:40 11:40 18:10 19:10)], ["Izmišljeno Selo", %w(07:50 11:50 18:20 19:20)]],
        "B" => [["Izmišljeno Selo", %w(08:00 12:00 16:00)], ["Primjerdalje (spomenik)", %w(08:10 12:10 16:10)], [nas, %w(08:50 12:50 16:50)]] },
      "P13" => { "A" => [[nas, %w(07:10 12:10 18:50)], ["Primjerpolje (centar)", %w(07:35 12:35 19:15)], ["Primjerpolje (škola)", %w(07:45 12:45 19:25)]],
        "B" => [["Primjerpolje (škola)", %w(06:30 10:10 17:10)], ["Primjerpolje (centar)", %w(06:40 10:20 17:20)], [nas, %w(07:05 10:45 17:45)]] }
    }
    specs.to_h do |code, directions|
      sections = ["Radni dan\n" + synthetic_journey_table(directions, school_symbol: %w(P2 P13).include?(code)),
                  "Subota\n" + synthetic_journey_table(directions), "Nedjelja\nNema objavljenih polazaka.\n"]
      [code, sections.join("\n")]
    end
  end

  def synthetic_journey_table(directions, school_symbol: false)
    left, right = directions.values_at("A", "B")
    heading = "Smjer A#{school_symbol ? ' (Š)' : ''}".ljust(120) + "Smjer B#{school_symbol ? ' (Š)' : ''}"
    rows = [left.size, right.size].max.times.map do |index|
      a = left[index]; b = right[index]
      (a ? "#{a.first}  #{a.last.join(' ')}" : "").ljust(120) + (b ? "#{b.first}  #{b.last.join(' ')}" : "")
    end
    ([heading] + rows).join("\n") + "\n"
  end
end
