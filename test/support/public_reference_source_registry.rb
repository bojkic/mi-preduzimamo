# frozen_string_literal: true

# Explicit reference-adapter registry for unit contracts. Never installed by
# application defaults. Provider bodies/fetches still need test-owned fixtures.
module PublicReferenceSourceRegistry
  def self.included(base)
    base.setup do
      sources = DecidimApp::Bijeljina::CityServiceSources
      @public_prior_city_sources = sources::SOURCES
      rows = sources::REFERENCE_SOURCES.map do |row|
        row.deep_dup.merge(enabled: row.fetch(:enabled, true), label: "Izmišljeni izvor #{row.fetch(:key)}", provider: "Izmišljeni pružalac")
      end
      sources.send(:remove_const, :SOURCES)
      sources.const_set(:SOURCES, rows.freeze)
    end
    base.teardown do
      sources = DecidimApp::Bijeljina::CityServiceSources
      sources.send(:remove_const, :SOURCES)
      sources.const_set(:SOURCES, @public_prior_city_sources)
    end
  end
end
