# frozen_string_literal: true
require_relative "synthetic_service_directory"
require_relative "synthetic_gazette_acts"

# Authored budget and issue metadata. Real budget/index parsers remain active;
# no imported fiscal figures, decisions or excerpts are used.
module SyntheticPublicCatalogs
  include SyntheticServiceDirectory

  def install_synthetic_public_catalogs
    install_synthetic_service_directory
    host = DecidimApp::Bijeljina
    [[host::Budget, :@default], [host::Gazette, :@index], [host::Gazette, :@revision]].each do |owner, name|
      present = owner.instance_variable_defined?(name)
      @synthetic_service_caches << [owner, name, present, owner.instance_variable_get(name)]
      owner.remove_instance_variable(name) if present
    end
    @synthetic_catalog_env = %w(MI_BUDGET_SOURCE_URL MI_BUDGET_HEADLINE_TOTAL MI_BUDGET_TABLE_PAGE MI_GAZETTE_SOURCE_URL BIJELJINA_GAZETTE_URL).to_h { |key| [key, ENV[key]] }
    ENV["MI_BUDGET_SOURCE_URL"] = "https://community.example.invalid/authored-budget.pdf"
    ENV["MI_BUDGET_HEADLINE_TOTAL"] = "999999.00"
    ENV["MI_BUDGET_TABLE_PAGE"] = "8"
    ENV["MI_GAZETTE_SOURCE_URL"] = "https://community.example.invalid/authored-gazette"
    ENV.delete("BIJELJINA_GAZETTE_URL")
    text = <<~TEXT
      IZMIŠLJENI BUDŽET I PLAN ZA 2040. GODINU — nije stvarni budžet.
      Korisnici budžeta — prvi autorski blok
      Измишљени центар    12.345,00
      Измишљени вртић     23.456,00
      Korisnici budžeta — drugi autorski blok
      Измишљено одјељење  34.567,00
      Измишљена заштита   45.678,00
      Измишљени музеј     56.789,00
      УКУПНО             999.999,00
    TEXT
    path = File.join(@synthetic_service_root, "budget.txt")
    File.write(path, text)
    { BUNDLED_TEXT_PATH: path, YEAR: 2040, SOURCE_CAPTURED_ON: Date.new(2040, 9, 14),
      DEFAULT_SOURCE_URL: "https://community.example.invalid/authored-budget.pdf" }.each do |name, value|
      swap_service_constant(host::Budget, name, value)
    end
    entries = [{ number: SyntheticGazetteActs::ISSUE_NUMBER, title: "Izmišljeni glasnik", date: "14. септембра 2040. године",
      url: "https://community.example.invalid/authored-issue.pdf", summary: "IZMIŠLJENI PRIMJER — nije stvarna odluka.",
      source_checked_on: "2040-09-14", published_on: "2040-09-14", source_pdf_pages: [1],
      content_hash: SyntheticGazetteActs::ISSUE_HASH }.freeze].freeze
    swap_service_constant(host::GazetteData, :ENTRIES, entries)
    swap_service_constant(host::GazetteData, :BASE, "https://community.example.invalid/authored-gazette")
    swap_service_constant(host::GazetteData, :SOURCE_CAPTURED_ON, Date.new(2040, 9, 14))
    swap_service_constant(host::CityServiceSources, :SOURCE_REVIEWED_ON, Date.new(2040, 9, 14))
  rescue StandardError
    restore_synthetic_public_catalogs
    raise
  end

  def restore_synthetic_public_catalogs
    @synthetic_catalog_env&.each { |key, prior| prior.nil? ? ENV.delete(key) : ENV[key] = prior }
    @synthetic_catalog_env = nil
    restore_synthetic_service_directory
  end
end
