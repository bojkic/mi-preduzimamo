# frozen_string_literal: true

require "date"
require "json"
require "tmpdir"
require "fileutils"

# Fully authored region review, never loaded by application defaults.
module SyntheticWeatherRegion
  SOURCE_URL = "https://weather.example.invalid/feed"

  def synthetic_weather_region_data
    { "version" => 1, "organization_host" => "community.example.invalid", "source_url" => SOURCE_URL,
      "provider_area_code" => "TEST-REGION-A", "region_label" => "Izmišljena pregledana regija",
      "community_label" => "Izmišljena zajednica", "evidence_url" => "https://review.example.invalid/authored-region#feature-a",
      "reviewed_on" => "2040-09-13", "valid_until" => "2041-06-01", "review_state" => "reviewed" }
  end

  def install_synthetic_weather_region
    @synthetic_weather_region_prior_path = ENV["MI_WEATHER_REGION_CONFIG_PATH"]
    @synthetic_weather_region_root = Dir.mktmpdir("authored-weather-region-")
    @synthetic_weather_region_path = File.join(@synthetic_weather_region_root, "review.json")
    write_synthetic_weather_region
    ENV["MI_WEATHER_REGION_CONFIG_PATH"] = @synthetic_weather_region_path
  end

  def write_synthetic_weather_region(**changes)
    File.write(@synthetic_weather_region_path, JSON.generate(synthetic_weather_region_data.merge(changes.transform_keys(&:to_s))))
  end

  def restore_synthetic_weather_region
    prior = @synthetic_weather_region_prior_path
    prior.nil? ? ENV.delete("MI_WEATHER_REGION_CONFIG_PATH") : ENV["MI_WEATHER_REGION_CONFIG_PATH"] = prior
    FileUtils.remove_entry_secure(@synthetic_weather_region_root) if @synthetic_weather_region_root && File.directory?(@synthetic_weather_region_root)
  end
end
