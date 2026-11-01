# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "yaml"
require "digest"

# Authored atomic office facts. No actual phone, address or captured city page.
# Standalone: also exercises the real source validator without Rails or a DB.
module SyntheticDirectoryFacts
  def install_synthetic_directory_facts
    owner = DecidimApp::Bijeljina::DirectoryServiceFacts
    @synthetic_atomic_constants = { PATH: owner::PATH, REVIEWED_HOSTS: owner::REVIEWED_HOSTS }
    @synthetic_atomic_cache = [owner.instance_variable_defined?(:@data), owner.instance_variable_get(:@data)]
    @synthetic_atomic_root = Dir.mktmpdir("authored-atomic-facts-")
    social = %w(phone hours).map do |facet|
      atomic_directory_fact("social", facet, aliases: ["Centar"], default: true,
        source: facet == "hours" ? "https://provider.example.invalid/social/hours" : "https://community.example.invalid/social/contact")
    end
    permits = [atomic_directory_fact("permits", "phone", aliases: ["dozvol"], default: true),
      atomic_directory_fact("permits", "address", aliases: ["dozvol"], default: true),
      atomic_directory_fact("legalization", "phone", aliases: ["legaliz"], default: false)]
    health = [atomic_directory_fact("switchboard", "phone", aliases: ["dom zdravlja"], default: true),
      atomic_directory_fact("family", "phone", aliases: ["porodicn"], default: false)]
    path = File.join(@synthetic_atomic_root, "facts.yml")
    File.write(path, YAML.dump("socijalna_zastita" => social, "gradjevinske_dozvole_legalizacija" => permits, "zdravstvo_apoteke" => health))
    { PATH: path, REVIEWED_HOSTS: %w(community.example.invalid provider.example.invalid).freeze }.each do |key, value|
      owner.send(:remove_const, key)
      owner.const_set(key, value)
    end
    owner.remove_instance_variable(:@data) if owner.instance_variable_defined?(:@data)
    owner.data
  rescue StandardError
    restore_synthetic_directory_facts
    raise
  end

  def restore_synthetic_directory_facts
    return unless @synthetic_atomic_constants

    owner = DecidimApp::Bijeljina::DirectoryServiceFacts
    @synthetic_atomic_constants.each do |key, value|
      owner.send(:remove_const, key)
      owner.const_set(key, value)
    end
    owner.remove_instance_variable(:@data) if owner.instance_variable_defined?(:@data)
    owner.instance_variable_set(:@data, @synthetic_atomic_cache.last) if @synthetic_atomic_cache.first
    FileUtils.remove_entry_secure(@synthetic_atomic_root) if @synthetic_atomic_root && File.directory?(@synthetic_atomic_root)
    @synthetic_atomic_constants = nil
  end

  def atomic_directory_fact(subject, facet, aliases:, default:, source: nil)
    { "id" => "authored:#{subject}:#{facet}", "logical_id" => "authored:#{subject}:#{facet}",
      "fact_revision" => "authored-v1", "document_id" => "authored:#{subject}", "publisher_id" => "authored-office",
      "source_document_sha256" => Digest::SHA256.hexdigest("authored-office:#{subject}:#{facet}"),
      "subject_id" => "authored:#{subject}", "aliases" => aliases, "default_subject" => default, "predicate" => facet,
      "text" => "IZMIŠLJENI #{subject.upcase} #{facet.upcase} — ne koristiti za kontakt.",
      "source_url" => source || "https://community.example.invalid/#{subject}/#{facet}",
      "source_checked_on" => "2026-09-15", "review_state" => "reviewed", "source_locator" => "authored-fixture:#{subject}:#{facet}" }
  end
end
