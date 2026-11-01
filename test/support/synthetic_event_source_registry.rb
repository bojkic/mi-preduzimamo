# frozen_string_literal: true
require_relative "public_reference_source_registry"
require "tmpdir"
require "fileutils"
require "yaml"

# Explicit test registry, never production defaults. All provider bodies and
# article revisions must be authored by the calling test, not fetched upstream.
module SyntheticEventSourceRegistry
  def self.included(base)
    base.include(PublicReferenceSourceRegistry)
    base.setup do
      sources = DecidimApp::Bijeljina::CityServiceSources
      rows = sources::SOURCES.map do |row|
        url = case row.fetch(:key)
              when "water_service" then "https://water.example.invalid/v2/notices/"
              when "city_official_notices" then "https://city.example.invalid/notices/"
              else "https://#{row.fetch(:key).tr('_', '-')}.example.invalid/source"
              end
        row.merge(source_url: url).freeze
      end
      sources.send(:remove_const, :SOURCES)
      sources.const_set(:SOURCES, rows.freeze)
      @synthetic_event_alias_directory = Dir.mktmpdir("synthetic-event-aliases-")
      path = File.join(@synthetic_event_alias_directory, "aliases.yml")
      File.write(path, YAML.dump("revision" => "synthetic-event-v1", "inflections" => { "izmisljeno polje" => ["Izmišljenom polju"] }))
      owner = DecidimApp::Bijeljina::PlaceAliasRegistry
      @synthetic_event_prior_alias_path = owner::CONFIG_PATH
      owner.send(:remove_const, :CONFIG_PATH)
      owner.const_set(:CONFIG_PATH, path)
    end
    base.teardown do
      if @synthetic_event_prior_alias_path
        owner = DecidimApp::Bijeljina::PlaceAliasRegistry
        owner.send(:remove_const, :CONFIG_PATH)
        owner.const_set(:CONFIG_PATH, @synthetic_event_prior_alias_path)
      end
      FileUtils.remove_entry_secure(@synthetic_event_alias_directory) if @synthetic_event_alias_directory && File.directory?(@synthetic_event_alias_directory)
    end
    # PublicReferenceSourceRegistry restores the exact original constant after
    # this additional test-only URL transformation; no default remains enabled.
  end
end
