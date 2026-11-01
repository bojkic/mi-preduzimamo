# frozen_string_literal: true

# Authored source-check projection for reader/coordinator contracts. The real
# snapshot reader, source-version hashing and tenant guard remain in use.
module SyntheticPublicCallSnapshot
  Row = Struct.new(:source_version, :check_payload, keyword_init: true)
  class Store
    attr_accessor :row
    attr_reader :requested_keys

    def initialize
      @requested_keys = []
    end

    def version_for(*) = "authored-public-call-source-v1"

    def snapshot(source_key:)
      @requested_keys << source_key
      @row
    end
  end

  def synthetic_public_call(**changes)
    { "id" => "authored-agricultural-call", "kind" => "public_call", "title" => "IZMIŠLJENI javni poziv za poljoprivredu",
      "source_url" => "https://community.example.invalid/calls/authored-agriculture", "source_published_on" => "2040-09-01",
      "opens_on" => "2040-09-04", "closes_on" => "2040-10-02", "temporal_status" => "bounded_window",
      "deadline_evidence" => "IZMIŠLJENI period podnošenja zahtjeva, ne rok ocjenjivanja.",
      "coverage" => { "geographic_scope" => "citywide_eligibility", "area_slugs" => [] },
      "warnings" => [], "eligibility_evidence" => "Uslovi su samo izmišljeni primjer.",
      "application_url" => "https://community.example.invalid/calls/application",
      "application_evidence" => "Zahtjev se podnosi prema objavljenom postupku.",
      "attachments" => [{ "url" => "https://community.example.invalid/forms/authored-application.pdf", "label" => "Izmišljeni obrazac" }] }
      .merge(changes.transform_keys(&:to_s))
  end

  def with_synthetic_public_call_snapshot(items:, organization:, now:)
    owner = DecidimApp::Bijeljina::CityServiceSources
    prior = owner::SOURCES
    parent = DecidimApp::Bijeljina::PublicCallsPreparation::PARENT_SOURCE_KEY
    rows = prior.map do |source|
      source[:key] == parent ? source.merge(enabled: true, source_url: "https://community.example.invalid/calls/",
                                            label: "Izmišljeni pozivi zajednice", provider: "Izmišljeni izdavalac").freeze : source
    end
    raise "test must explicitly provide the parent source shape" unless rows.any? { |source| source[:key] == parent }

    owner.send(:remove_const, :SOURCES)
    owner.const_set(:SOURCES, rows.freeze)
    store = Store.new
    store.row = Row.new(source_version: DecidimApp::Bijeljina::PublicCallsPreparation.version_for(store:),
                        check_payload: { "status" => "ok", "organization_id" => organization.id,
                                         "checked_at" => now.iso8601, "items" => items, "coverage" => { "complete_inventory" => false } })
    yield store
  ensure
    if prior
      owner.send(:remove_const, :SOURCES)
      owner.const_set(:SOURCES, prior)
    end
  end
end
