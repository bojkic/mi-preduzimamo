# frozen_string_literal: true

# Authored fixture: no provider captures, real contacts or local calendar data.
module SyntheticCitizenReferences
  module_function

  def data
    pack = { "version" => 1, "sources" => [], "documents" => [], "subjects" => [], "facts" => [] }
    specs = [
      ["employment", "employment", ["city_service"], [["biro", "zavod za zaposljavanje", "zavoda za zaposljavanje"]]],
      ["health", "health", ["health"], [["stomatolo"], ["dom zdravlja", "doma zdravlja", "domu zdravlja"]]],
      ["intercity", "intercity_travel", ["transport"], [["izmišljeni prevoz"]]],
      ["agriculture", "agriculture", ["agriculture"], [["gorivo"]]],
      ["primary", "education", ["education"], [["raspust", "kalendar"]]],
      ["secondary", "education", ["education"], [["raspust", "kalendar"]]],
      ["culture", "culture", ["community"], [["izmišljena predstava"]]]
    ]
    subject_ids = {}
    specs.each do |key, domain, topics, groups|
      subject_id = case key
                   when "primary", "secondary" then "synthetic:calendar:#{key}:2040-2041"
                   else "synthetic:#{key}"
                   end
      subject_ids[key] = subject_id
      pack["sources"] << { "id" => key, "authority" => key == "culture" ? "owner_attributed_press" : "public_authority" }
      pack["documents"] << { "id" => key, "source_id" => key, "url" => "https://community.example.invalid/#{key}",
        "published_on" => key == "health" ? nil : "2040-05-12", "reviewed_on" => "2040-09-15",
        "revision_basis" => "response_bytes", "revision_sha256" => Digest::SHA256.hexdigest("invented bytes #{key}") }
      pack["subjects"] << { "id" => subject_id, "domain" => domain, "topics" => topics, "match_groups" => groups,
        "geographic_scope" => "Izmišljena zajednica", "unknown_features" => ["Nepregledane činjenice nisu dostupne."] }
    end
    atom = lambda do |key, id, facet, text, **extra|
      pack["facts"] << { "id" => id, "subject_id" => subject_ids.fetch(key), "document_id" => key,
        "kind" => "reviewed_reference", "facet" => facet, "text" => text,
        "next_action" => "Provjerite izmišljeni izvor prije stvarne upotrebe.", "period_years" => [],
        "review_status" => "reviewed", "reviewed_on" => "2040-09-15", "review_expires_on" => "2041-09-15"
      }.merge(extra.transform_keys(&:to_s))
    end
    # This identifier is a routing contract in CitizenReferenceRead.
    atom.call("employment", "employment:biro-contact", "contact", "SINTETIČKI KONTAKT BIROA — bez stvarnog telefona.")
    atom.call("employment", "synthetic:vacancies", "vacancy_search", "Izmišljeni oglasi: mjesto rada provjerite u svakom oglasu; broj slobodnih mjesta nije poznat.")
    atom.call("health", "health:dentistry-hours", "hours", "Izmišljeno radno vrijeme Doma zdravlja: nedjelja 09–11.", review_expires_on: "2040-10-15")
    atom.call("intercity", "synthetic:intercity-office", "contact", "SINTETIČKI KONTAKT PREVOZNIKA — bez stvarnog telefona.")
    atom.call("agriculture", "agriculture:fuel-forms-window", "procedure", "Izmišljeni rok obrazaca za gorivo.", effective_until: "2040-11-16", period_years: [2040])
    atom.call("agriculture", "synthetic:fuel-location", "location", "Izmišljeno mjesto za preuzimanje obrazaca.", period_years: [2040])
    %w(primary secondary).each do |key|
      atom.call(key, "synthetic:#{key}:winter", "winter_break", "IZMIŠLJENI TEST: 8–19. januara 2041; ne potvrđuje promjenu gradskog prevoza.",
        period_years: [2040, 2041], occurs_from: "2041-01-08", occurs_until: "2041-01-20")
      atom.call(key, "synthetic:#{key}:spring", "spring_break", "Izmišljeni proljećni raspust.",
        period_years: [2040, 2041], occurs_from: "2041-04-01", occurs_until: "2041-04-07")
    end
    atom.call("culture", "synthetic:announcement", "event", "Izmišljena predstava je najavljena, bez potvrde trenutnog programa.",
      kind: "announced_event", starts_at: "2040-09-16T18:00:00+02:00", effective_until: "2040-09-17")
    %w(sources documents subjects facts).each do |layer|
      pack.fetch(layer).each { |row| row["reviewed_sha256"] = DecidimApp::Bijeljina::CitizenReferenceCatalog.revision_for(row) }
    end
    pack
  end
end
