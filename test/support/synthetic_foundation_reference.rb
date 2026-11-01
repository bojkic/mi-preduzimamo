# frozen_string_literal: true
require "tmpdir"
require "fileutils"
require "yaml"

# Authored reference only; no real office address, contact or grant availability.
module SyntheticFoundationReference
  def install_synthetic_foundation_reference
    @synthetic_foundation_contacts = %i(public_support_name public_support_address public_support_email public_support_website).to_h do |key|
      [key, Decidim::Bih.public_send(key)]
    end
    values = { public_support_name: "Izmišljena fondacija", public_support_address: "Izmišljena ulica 42, Testni grad",
               public_support_email: "office@foundation.example.invalid", public_support_website: "https://foundation.example.invalid" }
    values.each { |key, value| Decidim::Bih.public_send("#{key}=", value) }
    @synthetic_foundation_metadata = {
      "reviewed_on" => (Date.current - 1).iso8601, "review_expires_on" => (Date.current + 39).iso8601,
      "reviewed_at" => 1.day.ago.iso8601,
      "sources" => { "about" => { "id" => "lfbn:about", "url" => "https://foundation.example.invalid/about" },
                     "idea_call" => { "id" => "lfbn:idea_call", "url" => "https://foundation.example.invalid/idea", "current_open_status" => "unverified" } }
    }
    @synthetic_foundation_directory = Dir.mktmpdir("synthetic-foundation-reference-")
    path = File.join(@synthetic_foundation_directory, "reference.yml")
    File.write(path, YAML.dump(@synthetic_foundation_metadata))
    reader = DecidimApp::Bijeljina::Milica::FoundationRead
    @synthetic_foundation_prior_path = reader::METADATA_PATH
    reader.send(:remove_const, :METADATA_PATH)
    reader.const_set(:METADATA_PATH, path.freeze)
  rescue StandardError
    restore_synthetic_foundation_reference
    raise
  end

  def restore_synthetic_foundation_reference
    if defined?(@synthetic_foundation_prior_path)
      reader = DecidimApp::Bijeljina::Milica::FoundationRead
      reader.send(:remove_const, :METADATA_PATH)
      reader.const_set(:METADATA_PATH, @synthetic_foundation_prior_path)
      remove_instance_variable(:@synthetic_foundation_prior_path)
    end
    @synthetic_foundation_contacts&.each { |key, value| Decidim::Bih.public_send("#{key}=", value) }
    @synthetic_foundation_contacts = nil
    if @synthetic_foundation_directory && File.directory?(@synthetic_foundation_directory)
      FileUtils.remove_entry_secure(@synthetic_foundation_directory)
    end
  end
end
