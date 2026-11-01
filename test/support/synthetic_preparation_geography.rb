# frozen_string_literal: true
require "tmpdir"
require "fileutils"
require "yaml"

# Independent toy containment/inflection statements, never municipal/GIS data.
module SyntheticPreparationGeography
  def install_synthetic_preparation_geography
    @authored_prep_root = Dir.mktmpdir("authored-preparation-geography-")
    @authored_prep_constants = []
    decisions = { "sources" => { "authored_area" => "https://community.example.invalid/authored-area-decision" },
      "places" => [
        { "aliases" => ["vrt"], "mz_slug" => "mz-vrt", "kind" => "settlement", "citations" => [{ "source" => "authored_area", "item" => "17" }] },
        { "aliases" => ["jasen"], "mz_slug" => "mz-gaj", "kind" => "settlement", "citations" => [{ "source" => "authored_area", "item" => "22" }] }
      ] }
    aliases = { "revision" => "authored-preparation-v1", "reviewed_on" => "2040-01-01", "inflections" => { "lugovi" => ["lugovima"], "veliki park" => ["v park"] } }
    [[DecidimApp::Bijeljina::CityServiceAreaCrosswalk, :CONFIG_PATH, decisions, "decisions.yml"],
     [DecidimApp::Bijeljina::PlaceAliasRegistry, :CONFIG_PATH, aliases, "aliases.yml"]].each do |owner, name, data, filename|
      path = File.join(@authored_prep_root, filename)
      File.write(path, YAML.dump(data))
      @authored_prep_constants << [owner, name, owner.const_get(name, false)]
      owner.send(:remove_const, name)
      owner.const_set(name, path)
    end
    owner = DecidimApp::Bijeljina::CityServiceStationPlace
    station_path = File.join(@authored_prep_root, "station-labels.yml")
    File.write(station_path, YAML.dump("labels" => { "v park rub" => "veliki park" }))
    labels = owner.load_reviewed_station_labels(station_path)
    { REVIEWED_STATION_LABELS: labels, VERSION: owner.reviewed_labels_version(labels) }.each do |name, value|
      @authored_prep_constants << [owner, name, owner.const_get(name, false)]
      owner.send(:remove_const, name)
      owner.const_set(name, value)
    end
  rescue StandardError
    restore_synthetic_preparation_geography
    raise
  end

  def restore_synthetic_preparation_geography
    @authored_prep_constants&.reverse_each do |owner, name, prior|
      owner.send(:remove_const, name)
      owner.const_set(name, prior)
    end
    FileUtils.remove_entry_secure(@authored_prep_root) if @authored_prep_root && File.directory?(@authored_prep_root)
    @authored_prep_constants = []
  end
end
