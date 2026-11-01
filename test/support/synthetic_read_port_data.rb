# frozen_string_literal: true
require_relative "synthetic_conversation_data"

# Independent fictional rows, not transformed local GIS or schedule exports.
module SyntheticReadPortData
  include SyntheticConversationData
  CONTACTS = {
    "health" => ["zdravstvo_apoteke", "000 000 101"],
    "social_welfare" => ["socijalna_zastita", "000 000 102"],
    "agriculture" => ["poljoprivreda_podsticaji", "000 000 103"],
    "permits" => ["gradjevinske_dozvole_legalizacija", "000 000 104"],
    "education" => ["upis_skola_vrtic", "000 000 105"],
    "animals" => ["psi_lutalice", "000 000 106"]
  }.freeze

  def install_synthetic_read_port_data(day:)
    install_synthetic_conversation_data(day:)
    host = DecidimApp::Bijeljina
    path = host::WasteSchedule::ROUTE_REGISTRY_PATH
    registry = JSON.parse(File.read(path))
    specs = [
      ["synthetic-village", "Измишљено село", 5, 1],
      ["synthetic-r2-d1", "Измишљена липа", 2, 1],
      ["synthetic-wednesday", "Измишљени јасен", 4, 3],
      ["synthetic-forest-2", "Измишљена шума", 2, 1],
      ["synthetic-forest-3", "Измишљена шума", 3, 4],
      ["synthetic-willow-1", "Измишљена врба", 1, 2],
      ["synthetic-willow-3", "Измишљена врба", 3, 5]
    ]
    registry["rows"] += specs.map do |id, place, district, weekday|
      { "id" => id, "place" => place, "settlement" => "Bijeljina", "district" => district,
        "weekday" => weekday, "scope" => "household", "source_pdf_page" => 7 }
    end
    File.write(path, JSON.generate(registry))
    host::WasteSchedule.remove_instance_variable(:@default) if host::WasteSchedule.instance_variable_defined?(:@default)
    swap_service_constant(host::WasteSchedule, :SOURCE_CAPTURED_ON, day - 10)
    cards = CONTACTS.map do |topic, (key, phone)|
      title = topic == "health" ? "Izmišljeni dom zdravlja" : "Izmišljena služba #{topic}"
      answer = "#{title}: IZMIŠLJENI KONTAKT #{phone}, ne pozivati. Pregledano #{(day - 2).strftime('%-d.%-m.%Y')}."
      answer += " Raspored dežurnih apoteka nemam u provjerenom izvoru. IZMIŠLJENI HITNI KONTAKT 000 000 199." if topic == "health"
      entry = { key: key.to_sym, title:, keywords: [topic, title], answer:,
        source_url: "https://community.example.invalid/#{key}", source_checked_on: (day - 2).iso8601,
        record_kind: "service_guidance", location_scope: "citywide", verification_scope: "source_guidance" }
      entry[:facts] = host::CityServicesData.entry_facts(entry, checked_on: day - 2)
      entry.freeze
    end
    keys = cards.map { |row| row.fetch(:key) }
    entries = host::CityServicesData::ENTRIES.reject { |row| keys.include?(row[:key]) } + cards
    swap_service_constant(host::CityServicesData, :ENTRIES, entries.freeze)
    host::CityDirectory.instance_variable_set(:@directory, Decidim::Bih::City::ServiceDirectory.new(entries))
  rescue StandardError
    restore_synthetic_service_directory
    raise
  end
end
