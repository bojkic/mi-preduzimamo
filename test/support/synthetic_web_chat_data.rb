# frozen_string_literal: true
require_relative "synthetic_read_port_data"
require_relative "synthetic_transport_network"

module SyntheticWebChatData
  include SyntheticReadPortData
  include SyntheticTransportNetwork

  def install_synthetic_web_chat_data
    install_synthetic_read_port_data(day: Date.new(2040, 9, 16))
    install_synthetic_transport
    host = DecidimApp::Bijeljina
    # Transport installs only its own source. Preserve the other explicitly
    # installed fictional/reference readers for this HTTP group as well.
    rows = @synthetic_transport_prior_sources.reject { |row| row[:key] == "public_transport" } + host::CityServiceSources::SOURCES
    swap_service_constant(host::CityServiceSources, :SOURCES, rows.freeze)
    entries = host::CityServicesData::ENTRIES.map do |entry|
      next entry unless entry[:key] == :javni_prevoz

      row = entry.merge(answer: "IZMIŠLJENA TESTNA CIJENA 2,37 KM; nije stvarna tarifa.")
      row[:facts] = host::CityServicesData.entry_facts(row, checked_on: Date.new(2040, 9, 14))
      row.freeze
    end
    police = { key: :policija, title: "Izmišljena policijska služba", keywords: ["policija"],
      answer: "IZMIŠLJENI TESTNI KONTAKT 000 000 107; ne pozivati.", source_url: "https://community.example.invalid/policija",
      source_checked_on: "2040-09-14", record_kind: "service_guidance", location_scope: "citywide", verification_scope: "source_guidance" }
    police[:facts] = host::CityServicesData.entry_facts(police, checked_on: Date.new(2040, 9, 14))
    entries << police.freeze
    swap_service_constant(host::CityServicesData, :ENTRIES, entries.freeze)
    host::CityDirectory.instance_variable_set(:@directory, Decidim::Bih::City::ServiceDirectory.new(entries))
  end

  def restore_synthetic_web_chat_data
    # Restore transport first; the shared directory stack restores the original
    # source registry last, after both independent fixture installers.
    restore_synthetic_transport
    restore_synthetic_service_directory
  end
end
