# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "yaml"
require_relative "synthetic_civic_facts"

# Explicit authored optional civic catalogue. Restores the original constants
# and exact prior cache; never installed by the global test helper.
module SyntheticCivicConfiguration
  def install_synthetic_civic_configuration(day: Date.current)
    owner = DecidimApp::Bijeljina::CivicDomainFacts
    @synthetic_civic_prior_constants = { CONFIG_DIR: owner::CONFIG_DIR, REVIEWED_HOSTS: owner::REVIEWED_HOSTS }
    @synthetic_civic_cache_present = owner.instance_variable_defined?(:@cache)
    @synthetic_civic_prior_cache = owner.instance_variable_get(:@cache)
    @synthetic_civic_root = Dir.mktmpdir("authored-civic-configuration-")
    SyntheticCivicFacts.write_reader_contract(root: @synthetic_civic_root, day:)
    path = File.join(@synthetic_civic_root, "billing_reviewed_facts.yml")
    data = YAML.safe_load_file(path)
    tokens = { "waste" => %w(otpad smec komunaln), "water" => %w(voda vode vodu),
      "electricity" => %w(struja struje struju kwh), "heating" => %w(grijanje grijanja toplana toplani),
      "city_levies" => ["komunalna naknada"] }
    data.fetch("billers").each { |row| row["tokens"] = tokens.fetch(row.fetch("id")) }
    File.write(path, YAML.dump(data))
    { CONFIG_DIR: @synthetic_civic_root, REVIEWED_HOSTS: ["civic.example.invalid"].freeze }.each do |key, value|
      owner.send(:remove_const, key)
      owner.const_set(key, value)
    end
    owner.reset!
    owner.billers
  rescue StandardError
    restore_synthetic_civic_configuration
    raise
  end

  def restore_synthetic_civic_configuration
    return unless @synthetic_civic_prior_constants

    owner = DecidimApp::Bijeljina::CivicDomainFacts
    @synthetic_civic_prior_constants.each do |key, value|
      owner.send(:remove_const, key)
      owner.const_set(key, value)
    end
    owner.remove_instance_variable(:@cache) if owner.instance_variable_defined?(:@cache)
    owner.instance_variable_set(:@cache, @synthetic_civic_prior_cache) if @synthetic_civic_cache_present
    FileUtils.remove_entry_secure(@synthetic_civic_root) if @synthetic_civic_root && File.directory?(@synthetic_civic_root)
    @synthetic_civic_prior_constants = nil
  end
end
