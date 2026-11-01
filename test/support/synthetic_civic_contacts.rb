# frozen_string_literal: true

require_relative "synthetic_service_directory"

# Authored public-office role facts; no actual person, office, phone or address.
module SyntheticCivicContacts
  include SyntheticServiceDirectory

  def install_synthetic_civic_contacts
    install_synthetic_service_directory
    rows = {
      "gradjevinske_dozvole_legalizacija" => ["building_permit_office", %w(phone email address form)],
      "socijalna_zastita" => ["social_work_office", %w(phone email address hours)],
      "otpad" => ["waste_service", %w(phone email)],
      "vodovod_servis" => ["water_service", %w(phone email)]
    }.to_h do |key, (role, fields)|
      facts = fields.map { |field| synthetic_civic_contact_fact(role:, field:) }
      facts << synthetic_civic_contact_fact(role: "unrelated_private_subject", field: "phone").merge(
        "id" => "synthetic-wrong-role:#{key}", "logical_id" => "synthetic-wrong-role:#{key}",
        "text" => "WRONG ROLE MUST NOT APPEAR", "default_subject" => true
      )
      [key, facts]
    end
    @synthetic_civic_contact_path = File.join(@synthetic_service_root, "role-contacts.yml")
    File.write(@synthetic_civic_contact_path, YAML.dump(rows))
    swap_service_constant(DecidimApp::Bijeljina::DirectoryServiceFacts, :PATH, @synthetic_civic_contact_path)
    DecidimApp::Bijeljina::DirectoryServiceFacts.instance_variable_set(:@data, nil)
    DecidimApp::Bijeljina::DirectoryServiceFacts.data
  end

  def restore_synthetic_civic_contacts
    restore_synthetic_service_directory
  end

  def synthetic_civic_contact_fact(role:, field:)
    labels = { "phone" => "IZMIŠLJENI TELEFON SLUŽBE — ne pozivati.",
               "email" => "IZMIŠLJENI JAVNI E-MAIL SLUŽBE office@example.invalid.",
               "address" => "IZMIŠLJENA ADRESA SLUŽBE.", "hours" => "IZMIŠLJENO RADNO VRIJEME 09–11.",
               "form" => "IZMIŠLJENI OBRAZAC ZA ZAHTJEV." }
    { "id" => "synthetic-contact:#{role}:#{field}", "logical_id" => "synthetic-contact:#{role}:#{field}",
      "fact_revision" => "authored-v1", "document_id" => "synthetic-contact-document", "publisher_id" => "synthetic-service",
      "source_document_sha256" => Digest::SHA256.hexdigest("authored-civic-contact"), "subject_id" => role,
      "default_subject" => false, "predicate" => field, "text" => labels.fetch(field),
      "source_url" => "https://community.example.invalid/civic/#{role}/#{field}",
      "source_checked_on" => "2040-09-14", "review_state" => "reviewed", "source_locator" => "authored-test:#{role}:#{field}" }
  end

  def rewrite_synthetic_civic_contacts
    data = YAML.safe_load_file(@synthetic_civic_contact_path)
    yield data
    File.write(@synthetic_civic_contact_path, YAML.dump(data))
    DecidimApp::Bijeljina::DirectoryServiceFacts.instance_variable_set(:@data, nil)
  end
end
