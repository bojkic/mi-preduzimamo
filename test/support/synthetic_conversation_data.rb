# frozen_string_literal: true
require_relative "synthetic_service_directory"
require_relative "synthetic_civic_facts"
require_relative "synthetic_public_knowledge"
require "json"

# Authored catalogs for real conversation readers. No provider calls, real
# contacts, local schedules or production-derived rows are installed.
module SyntheticConversationData
  include SyntheticServiceDirectory

  def install_synthetic_conversation_data(day:)
    install_synthetic_service_directory
    host = DecidimApp::Bijeljina
    [[host::CivicDomainFacts, :@cache], [host::WasteSchedule, :@default]].each do |owner, name|
      present = owner.instance_variable_defined?(name)
      @synthetic_service_caches << [owner, name, present, owner.instance_variable_get(name)]
      owner.remove_instance_variable(name) if present
    end
    directory = File.join(@synthetic_service_root, "civic")
    FileUtils.mkdir_p(directory)
    SyntheticCivicFacts.write_reader_contract(root: directory, day:)
    # Independent invented fault-contact assertion, with no dialable number.
    path = File.join(directory, "billing_reviewed_facts.yml")
    data = YAML.safe_load_file(path)
    electricity = data.fetch("billers").find { |row| row.fetch("id") == "electricity" }
    electricity["facts"] << { "id" => "synthetic-electricity-fault", "text" => "IZMIŠLJENI KONTAKT KVAROVA; opcija TEST; smjena 09–12; dežurstvo 00–24.",
      "source_url" => "https://civic.example.invalid/electricity-fault", "source_label" => "Izmišljena služba",
      "source_on" => (day - 1).iso8601, "reviewed_on" => day.iso8601, "publishable" => true }
    File.write(path, YAML.dump(data))
    swap_service_constant(host::CivicDomainFacts, :CONFIG_DIR, directory)
    swap_service_constant(host::CivicDomainFacts, :REVIEWED_HOSTS, ["civic.example.invalid"].freeze)
    host::CivicDomainFacts.reset!
    host::CivicDomainFacts.billers # Real validation before the tools are created.
    card = { key: "synthetic-permit", title: "Izmišljeni zahtjev", owner: "Izmišljena služba",
      eligibility: "Izmišljeni uslov", steps: ["Prvi izmišljeni korak"], required_documents: [],
      fee: { administrative_fee_bam: 0, postage_amount_bam: nil }, processing_time: nil,
      source_url: "https://community.example.invalid/permit", source_checked_on: day.iso8601,
      reviewed_content_hash: "d" * 64, record_kind: "procedure", review_status: "reviewed", location_scope: "Izmišljena zajednica", current_legal_status: "unverified" }
    host::ServiceProcedures.instance_variable_set(:@all, [card.freeze].freeze)
    @synthetic_conversation_knowledge_root = File.join(@synthetic_service_root, "knowledge")
    SyntheticPublicKnowledge.write(root: @synthetic_conversation_knowledge_root, day:)
    install_synthetic_conversation_waste(day:)
  rescue StandardError
    restore_synthetic_service_directory
    raise
  end

  def synthetic_conversation_knowledge(organization:, source_checker:)
    host = DecidimApp::Bijeljina::Milica
    projection = host::PublicFilesystemKnowledge.new(root: @synthetic_conversation_knowledge_root)
    host::PublicKnowledgeTools.new(organization:, registry_epoch: "public-tools-v1:#{organization.id}", source_checker:, projection:)
  end

  def install_synthetic_conversation_waste(day:)
    host = DecidimApp::Bijeljina
    path = File.join(@synthetic_service_root, "waste-routes.json")
    registry = { "captured_on" => (day - 2).iso8601, "valid_from" => "#{day.year}-01-01", "valid_until" => "#{day.year}-12-31",
      "timezone" => "Europe/Sarajevo", "rows" => [{ "id" => "synthetic-waste-street", "place" => "Izmišljena breza",
        "settlement" => "Bijeljina", "district" => 1, "weekday" => 1, "scope" => "household",
        "aliases" => ["Izmišljena breza"], "source_pdf_page" => 1 }] }
    File.write(path, JSON.generate(registry))
    text = File.join(@synthetic_service_root, "waste.txt")
    File.write(text, "IZMIŠLJENI TESTNI PAKET; strukturisana ulica je jedini raspored.")
    { BUNDLED_TEXT_PATH: text, ROUTE_REGISTRY_PATH: path, DATA_YEAR: day.year, SOURCE_CAPTURED_ON: day - 2,
      DEFAULT_SCHEDULE_URL: "https://community.example.invalid/waste" }.each { |key, value| swap_service_constant(host::WasteSchedule, key, value) }
    rows = host::CityServiceSources::SOURCES.map do |row|
      row[:key] == "waste_schedule" ? row.merge(source_url: "https://community.example.invalid/waste", label: "Izmišljeni raspored") : row
    end
    swap_service_constant(host::CityServiceSources, :SOURCES, rows.freeze)
    host::WasteSchedule.default # Exercise the actual optional-file parser.
  end
end
