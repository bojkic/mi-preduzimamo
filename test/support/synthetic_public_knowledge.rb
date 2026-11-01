# frozen_string_literal: true

# Invented records only. Never copy a reviewed community source into test data.
module SyntheticPublicKnowledge
  module_function

  def write(root:, day:)
    catalog = reference_catalog(day:)
    documents = { "config/bijeljina/citizen_reference_facts.yml" => catalog,
                  "config/bijeljina/directory_service_facts.yml" => {} }
    %w(billing heating recycling).each do |domain|
      pack = { "domain" => domain, "revision" => "synthetic-#{domain}-v1",
               "blockers" => [{ "id" => "synthetic-limitation", "text" => "Izmišljeni podaci nisu dokaz stanja stvarne usluge." }] }
      rows = Array.new(domain == "billing" ? 1 : 18) do |index|
        { "id" => "synthetic-#{domain}-#{index}", "text" => "Izmišljena informacija #{domain} #{index}.",
          "source_url" => "https://community.example.invalid/#{domain}", "source_label" => "Izmišljeni izvor",
          "source_on" => (day - 3).iso8601, "reviewed_on" => (day - 1).iso8601, "publishable" => domain != "billing" }
      end
      if domain == "billing"
        rows.first["id"] = "synthetic_private_technician"
        rows.first["text"] = "SYNTHETIC PRIVATE RECORD MUST NOT BE EXPORTED"
        pack["personal_bill_boundary"] = { "text" => "Privatni računi nisu javni izvor." }
        pack["billers"] = [{ "id" => "synthetic-biller", "facts" => rows }]
      else
        pack["facts"] = rows
      end
      documents["config/bijeljina/#{domain}_reviewed_facts.yml"] = pack
    end
    documents.each do |relative, value|
      path = File.join(root, relative)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, YAML.dump(value))
    end
    procedure = { "key" => "synthetic-permit", "title" => "Izmišljeni zahtjev", "owner" => "Izmišljena služba",
                  "eligibility" => "Sintetički uslov", "steps" => ["Izmišljeni prvi korak"], "required_documents" => [],
                  "fee" => { "administrative_fee_bam" => 0, "postage_amount_bam" => nil, "delivery_cost" => "postage" },
                  "processing_time" => nil, "privacy" => "Bez stvarnih ličnih podataka", "current_legal_status" => "unverified",
                  "source_url" => "https://community.example.invalid/permit", "source_checked_on" => (day - 1).iso8601,
                  "review_status" => "reviewed", "reviewed_content_hash" => "d" * 64, "location_scope" => "synthetic community",
                  "source_fragment" => "#synthetic-procedure" }
    path = File.join(root, "app/services/decidim_app/bijeljina/data/service_procedures.json")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.generate("procedures" => [procedure]))
  end

  def reference_catalog(day:)
    source = { "id" => "synthetic-publisher", "authority" => "public_authority" }
    document = { "id" => "synthetic-document", "source_id" => source.fetch("id"),
                 "url" => "https://community.example.invalid/calendar", "revision_sha256" => "a" * 64,
                 "reviewed_on" => (day - 2).iso8601, "published_on" => (day - 3).iso8601 }
    subject = { "id" => "synthetic-school", "domain" => "education", "topics" => ["education"],
                "match_groups" => [["izmišljena škola"]], "geographic_scope" => "synthetic community" }
    fact = { "id" => "synthetic-calendar", "subject_id" => subject.fetch("id"), "document_id" => document.fetch("id"),
             "text" => "Izmišljeni kalendar škole.", "next_action" => "Provjerite izmišljeni izvor.",
             "review_status" => "reviewed", "reviewed_on" => (day - 1).iso8601, "review_expires_on" => (day + 30).iso8601,
             "facet" => "calendar", "kind" => "reference" }
    announcement = fact.merge("id" => "synthetic-event", "kind" => "announced_event", "text" => "Izmišljeni budući događaj.")
    [source, document, subject, fact, announcement].each do |row|
      row["reviewed_sha256"] = DecidimApp::Bijeljina::CitizenReferenceCatalog.revision_for(row)
    end
    { "version" => 1, "sources" => [source], "documents" => [document], "subjects" => [subject], "facts" => [fact, announcement] }
  end
end
