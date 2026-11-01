# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "yaml"
require "digest"
require_relative "../../app/services/decidim_app/bijeljina/city_services_data"
require_relative "../../app/services/decidim_app/bijeljina/city_directory"
require_relative "../../app/services/decidim_app/bijeljina/service_procedures"
require_relative "../../app/services/decidim_app/bijeljina/citizen_reference_catalog"
require_relative "synthetic_citizen_references"

# Authored fixture only. No actual tariffs, SMS destinations, contacts or GIS.
# Restores all constants/caches it changes, including the optional references.
module SyntheticServiceDirectory
  def install_synthetic_service_directory
    @synthetic_service_constants = []
    @synthetic_service_caches = []
    @synthetic_service_root = Dir.mktmpdir("synthetic-service-directory-")
    host = DecidimApp::Bijeljina
    [[host::CityDirectory, :@directory], [host::ParkingZones, :@default], [host::DirectoryServiceFacts, :@data],
     [host::ServiceProcedures, :@all], [host::CitizenReferenceCatalog, :@default]].each do |owner, name|
      present = owner.instance_variable_defined?(name)
      @synthetic_service_caches << [owner, name, present, present ? owner.instance_variable_get(name) : nil]
      owner.remove_instance_variable(name) if present
    end
    swap_service_constant(host::DirectoryServiceFacts, :PATH, write_synthetic_service_facts)
    swap_service_constant(host::DirectoryServiceFacts, :REVIEWED_HOSTS, ["community.example.invalid"].freeze)
    swap_service_constant(host::ServiceProcedures, :REVIEWED_HOSTS, ["community.example.invalid"].freeze)
    # Exercise the real configured-source validator, never replace it.
    host::DirectoryServiceFacts.data
    install_synthetic_parking
    host::CitizenReferenceCatalog.instance_variable_set(:@default, host::CitizenReferenceCatalog.new(data: SyntheticCitizenReferences.data))
    host::ServiceProcedures.instance_variable_set(:@all, [].freeze)
    entries = synthetic_service_entries
    swap_service_constant(host::CityServicesData, :SOURCE_VERIFIED_ON, Date.new(2040, 9, 14))
    swap_service_constant(host::CityServicesData, :CONTACT_CARDS_CHECKED_ON, Date.new(2040, 9, 14))
    swap_service_constant(host::CityServicesData, :PARKING_ANSWER_SECTIONS, entries.find { |row| row[:key] == :parking }.fetch(:answer_sections))
    swap_service_constant(host::CityServicesData, :ENTRIES, entries.freeze)
    host::CityDirectory.instance_variable_set(:@directory, Decidim::Bih::City::ServiceDirectory.new(entries))
    sources = host::CityServiceSources::REFERENCE_SOURCES.map do |row|
      row.deep_dup.merge(enabled: row.fetch(:enabled, true), label: "Izmišljeni izvor #{row.fetch(:key)}", provider: "Izmišljeni pružalac")
    end
    sources << { key: "synthetic_directory", label: "Izmišljeni imenik", provider: "Izmišljena služba",
                 enabled: true, source_url: "https://community.example.invalid/directory",
                 source_kind: "authored_test_catalog", scrape_cadence: host::CityServiceSources::WEEKLY,
                 update_cadence: "authored_fixture_only", location_granularity: "none",
                 delivery_modes: [host::CityServiceSources::ON_DEMAND], viber: host::CityServiceSources::ROUTINE_ONLY }
    swap_service_constant(host::CityServiceSources, :SOURCES, sources.freeze)
  rescue StandardError
    restore_synthetic_service_directory
    raise
  end

  def restore_synthetic_service_directory
    @synthetic_service_constants&.reverse_each do |owner, name, prior|
      owner.send(:remove_const, name)
      owner.const_set(name, prior)
    end
    @synthetic_service_caches&.reverse_each do |owner, name, present, prior|
      owner.remove_instance_variable(name) if owner.instance_variable_defined?(name)
      owner.instance_variable_set(name, prior) if present
    end
    FileUtils.remove_entry_secure(@synthetic_service_root) if @synthetic_service_root && File.directory?(@synthetic_service_root)
    @synthetic_service_constants = []
    @synthetic_service_caches = []
  end

  def swap_service_constant(owner, name, value)
    @synthetic_service_constants << [owner, name, owner.const_get(name, false)]
    owner.send(:remove_const, name)
    owner.const_set(name, value)
  end

  def write_synthetic_service_facts
    rows = %w(phone hours).map do |predicate|
      { "id" => "synthetic-social:#{predicate}", "logical_id" => "synthetic-social:#{predicate}", "fact_revision" => "authored-v1",
        "document_id" => "synthetic-social", "publisher_id" => "synthetic-service", "source_document_sha256" => Digest::SHA256.hexdigest("authored-social-source"),
        "subject_id" => "synthetic-social-office", "default_subject" => true, "aliases" => ["Centar za socijalni rad"],
        "predicate" => predicate, "text" => predicate == "phone" ? "IZMIŠLJENI TELEFON — ne pozivati." : "IZMIŠLJENO RADNO VRIJEME 09–11.",
        "source_url" => "https://community.example.invalid/social-#{predicate}", "source_checked_on" => "2040-09-14", "review_state" => "reviewed",
        "source_locator" => "authored-test:#{predicate}" }
    end
    path = File.join(@synthetic_service_root, "facts.yml")
    File.write(path, YAML.dump("socijalna_zastita" => rows))
    path
  end

  def install_synthetic_parking
    host = DecidimApp::Bijeljina::ParkingZones
    amounts = { "white" => { label: "bijela / zona centar", sms: "TEST-W", hourly_fening: 235 },
                "red" => { label: "crvena / I zona", sms: "TEST-R", hourly_fening: 185 },
                "blue" => { label: "plava / II zona", sms: "TEST-B", hourly_fening: 95, daily_sms: "TEST-D", daily_fening: 475 } }.transform_values(&:freeze).freeze
    tariffs = { "white" => amounts.fetch("white").merge(hourly: "2,35 KM/h").freeze,
                "red" => amounts.fetch("red").merge(hourly: "1,85 KM/h").freeze,
                "blue" => amounts.fetch("blue").merge(hourly: "0,95 KM/h", daily_price: "4,75 KM").freeze }.freeze
    streets = [
      { street_name: "Izmišljena lipa", normalized_street_name: "izmisljena lipa", aliases: ["izmisljena lipa", "izmisljene lipe"], zone: "white", segment_note: "Izmišljeni segment A." },
      { street_name: "Izmišljena breza", normalized_street_name: "izmisljena breza", aliases: ["izmisljena breza"], zone: "red", segment_note: "Izmišljeni segment B." },
      { street_name: "Izmišljeni javor", normalized_street_name: "izmisljeni javor", aliases: ["izmisljeni javor"], zone: "blue", segment_note: "Izmišljeni segment C." }
    ].map(&:freeze).freeze
    { SOURCE_URL: "https://community.example.invalid/parking", SOURCE_MAP_URL: "https://community.example.invalid/parking-map",
      SOURCE_CAPTURED_ON: Date.new(2040, 9, 14), TARIFF_VERIFIED_ON: Date.new(2040, 9, 14),
      TARIFF_AMOUNTS: amounts, MONTHLY_FENING: { red_and_blue: 6300, blue: 4200 }.freeze,
      TARIFFS: tariffs, BUNDLED_STREET_ROWS: streets }.each { |name, value| swap_service_constant(host, name, value) }
  end

  def synthetic_service_entries
    host = DecidimApp::Bijeljina
    payment = "Plaćanje SMS-om: bijela / zona centar TEST-W (2,35 KM/h), crvena / I zona TEST-R (1,85 KM/h), " \
              "plava / II zona TEST-B (0,95 KM/h); dnevna karta za plavu zonu TEST-D (4,75 KM)."
    monthly = "Univerzalna mjesečna karta za crvenu i plavu zonu je 63 KM, a mjesečna karta za plavu zonu 42 KM."
    sections = { operator: "IZMIŠLJENI PARKING — primjeri nisu uputstvo za stvarno plaćanje.", payment: payment,
                 monthly: monthly, zones: "Izmišljena mapa: Izmišljena breza i Izmišljeni javor; uvijek provjeri znak zone na ulici." }.transform_values(&:freeze).freeze
    specs = [
      [:parking, "Izmišljeni parking", ["parking", "parkiranje", "parking zone", "SMS parking"]],
      [:prijava_problema, "Prijava problema — Sistem 48", ["sistem 48", "48", "prijava problema", "kvar"]],
      [:gradjevinske_dozvole_legalizacija, "Građevinske dozvole i legalizacija", ["lokacijski uslovi", "uslovi", "građevinska dozvola", "gradnja"]],
      [:maticar, "Matičar", ["matičar", "e-matičar", "izvod"]],
      [:socijalna_zastita, "Centar za socijalni rad", ["socijalni rad", "centar za socijalni rad"]],
      [:otpad, "Odvoz otpada", ["otpad", "smeće", "komunalac", "odvoz"]],
      [:vodovod_servis, "Voda", ["voda", "vodovod"]],
      [:struja_iskljucenja, "Električna energija", ["struja", "električna energija"]],
      [:javni_prevoz, "Javni prevoz", ["javni prevoz", "autobus"]]
    ]
    specs.map do |key, title, keywords|
      entry = { key: key, title: title, keywords: keywords, answer: "IZMIŠLJENI IMENIK: #{title}.",
                source_url: "https://community.example.invalid/#{key == :parking ? 'parking' : key}", source_checked_on: "2040-09-14",
                record_kind: "service_guidance", location_scope: "citywide", verification_scope: "source_guidance",
                effective_from: nil, effective_until: nil }
      entry.merge!(answer_sections: sections, answer: sections.values.join(" ")) if key == :parking
      entry[:facts] = host::CityServicesData.entry_facts(entry, checked_on: Date.new(2040, 9, 14))
      entry.freeze
    end
  end
end
