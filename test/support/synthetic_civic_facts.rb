# frozen_string_literal: true

# Entirely invented civic facts, never extracted from provider documents.
module SyntheticCivicFacts
  module_function

  def write(root:, day:)
    fact = lambda do |id, text, **extra|
      { "id" => id, "text" => text, "source_url" => "https://civic.example.invalid/synthetic/#{id}",
        "source_label" => "Izmišljeni izvor", "source_on" => (day - 3).iso8601,
        "reviewed_on" => day.iso8601, "publishable" => true }.merge(extra.transform_keys(&:to_s))
    end
    blocker = ->(id) { { "id" => id, "text" => "Izmišljeni izvor ne potvrđuje ovu informaciju.", "unblock" => "Pregledajte odgovarajući novi izvor prije objave." } }
    common = { "reviewed_on" => day.iso8601, "revision" => "#{day.iso8601}.1" }
    heating = common.merge("domain" => "heating", "facts" => [
      fact.call("synthetic_heating_overview", "Izmišljene informacije o grijanju."),
      fact.call("synthetic_private_contact", "SYNTHETIC_PRIVATE_CONTACT 9,99 8,888 7,777 6,666 5,555 4,444", publishable: false)
    ], "blockers" => [blocker.call("synthetic_coverage_unknown")])
    recycling = common.merge("domain" => "recycling", "facts" => [
      fact.call("synthetic_recycling_overview", "Izmišljeni spisak materijala je nepotpun."),
      fact.call("synthetic_recycling_self_haul", "Izmišljena pravila samostalne predaje.", only_for: "self_haul")
    ], "blockers" => [blocker.call("synthetic_locations_unknown"), blocker.call("synthetic_glass_unknown")],
    "recyclables_collected_verbatim" => ["izmišljeni materijal A", "izmišljeni materijal B", "izmišljena amblaža"], "glass_listed" => false)
    billers = %w(waste water electricity heating city_levies).map do |id|
      { "id" => id, "provider" => "Izmišljena služba #{id}", "complaint_route" => "Izmišljeni postupak prigovora.", "tokens" => [id],
        "facts" => [fact.call("synthetic_biller_#{id}", "Izmišljene informacije o obračunu #{id}.")] }
    end
    billing = common.merge("domain" => "billing", "billers" => billers,
      "blockers" => [blocker.call("synthetic_tariff_unreviewed"), blocker.call("synthetic_fee_unreviewed")],
      "excluded_authenticated_paths" => ["https://civic.example.invalid/private-account", "https://civic.example.invalid/private-email"])
    [heating, recycling, billing].each do |data|
      File.write(File.join(root, "#{data.fetch('domain')}_reviewed_facts.yml"), YAML.dump(data))
    end
  end
  # The reader's stable identifiers are part of its reference-adapter contract;
  # every narrative, amount, date and provider below is invented independently.
  def write_reader_contract(root:, day:)
    write(root:, day:)
    load_pack = ->(name) { YAML.safe_load_file(File.join(root, "#{name}_reviewed_facts.yml")) }
    fact = lambda do |id, text, **extra|
      { "id" => id, "text" => text, "source_url" => "https://civic.example.invalid/synthetic/#{id}",
        "source_label" => "Izmišljeni izvor", "source_on" => (day - 3).iso8601,
        "reviewed_on" => day.iso8601, "publishable" => true }.merge(extra.transform_keys(&:to_s))
    end
    blocker = lambda do |id, text, severity = "high"|
      { "id" => id, "text" => text, "unblock" => "Pregledajte novi izvor prije uključivanja odgovora.", "severity" => severity }
    end
    billing = load_pack.call("billing")
    billing["personal_bill_boundary"] = {
      "text" => "Ja to ne mogu vidjeti: izmišljeni privatni račun zahtijeva nalog pružaoca usluge.",
      "warning_codes" => ["personal_bill_requires_provider_account"]
    }
    billing["blockers"] = [
      blocker.call("komunalac_tariff_is_a_scan", "Izmišljeni izvor nema čitljivu tarifu; neću izmišljati iznos."),
      blocker.call("komunalna_naknada_rates_are_stale", "Izmišljena tarifa iz 2039. nije potvrđena kao važeća. SINTETIČKI KONTAKT."),
      blocker.call("heating_tariff_is_a_scan", "Izmišljeni cjenovnik nije čitljiv; iznos ne mogu pročitati."),
      blocker.call("electricity_price_not_published", "Regulatorna komisija je izmišljeni referentni izvor; cijena ovdje nije potvrđena."),
      blocker.call("payment_details_must_be_reread_at_source", "Izmišljene podatke o plaćanju treba ponovo provjeriti na izvoru.", "low"),
      blocker.call("synthetic_caveat_two", "Izmišljeno dodatno ograničenje dva.", "low"),
      blocker.call("synthetic_caveat_three", "Izmišljeno dodatno ograničenje tri.", "low")
    ]
    mapping = { "waste" => ["komunalac_tariff_is_a_scan", "payment_details_must_be_reread_at_source", "synthetic_caveat_two", "synthetic_caveat_three"],
                "water" => [], "electricity" => ["electricity_price_not_published"],
                "heating" => ["heating_tariff_is_a_scan"], "city_levies" => ["komunalna_naknada_rates_are_stale"] }
    billing.fetch("billers").each do |row|
      id = row.fetch("id")
      row["tokens"] = ["komunalna naknada"] if id == "city_levies"
      row["subject"] = "Izmišljeni račun #{id}"
      row["source_url"] = "https://civic.example.invalid/#{id}"
      row["complaint_route"] = "IZMIŠLJENI KONTAKT ZA PRIGOVOR — bez stvarne adrese ili broja."
      row["blockers"] = mapping.fetch(id)
    end
    water = billing.fetch("billers").find { |row| row.fetch("id") == "water" }
    water["facts"] = [fact.call("synthetic_water_tariff", "IZMIŠLJENI TEST: 2,34 bez PDV-a, odluka 01.04.2040.", source_on: (day - 8).iso8601)]
    heating_biller = billing.fetch("billers").find { |row| row.fetch("id") == "heating" }
    heating_biller["facts"] = [fact.call("synthetic_heating_payment", "SINTETIČKA BANKA — izmišljena obavijest 08.04.2040., bez broja računa.",
                                                source_on: (day - 1).iso8601, warning_codes: ["payment_details_must_be_reread_at_source"])]
    waste = billing.fetch("billers").find { |row| row.fetch("id") == "waste" }
    waste["facts"] = Array.new(3) { |index| fact.call("synthetic_waste_#{index}", "Izmišljeno pravilo obračuna #{index}.") }
    recycling = load_pack.call("recycling")
    recycling["collector"] = { "name" => "IZMIŠLJENI SAKUPLJAČ", "source_url" => "https://civic.example.invalid/recycling" }
    recycling["recyclables_collected"] = recycling.fetch("recyclables_collected_verbatim").map(&:dup)
    recycling["facts"] = [
      fact.call("synthetic_recycling_overview", "IZMIŠLJENI SAKUPLJAČ: SINTETIČKI KONTAKT, bez stvarnog telefona."),
      fact.call("synthetic_recycling_self_haul", "IZMIŠLJENA DEPONIJA: primjer samostalne predaje.", only_for: "self_haul")
    ]
    recycling["blockers"] = [
      blocker.call("container_locations_not_published", "Izmišljeni raspored lokacija nigdje nije objavljen."),
      blocker.call("glass_collection_unstated", "Staklo nije na tom objavljenom spisku; ne zaključujte da se prihvata ili odbija."),
      blocker.call("no_what_goes_where_guide", "Izmišljeni izvor nema pregledan vodič za pojedinačne posude.")
    ]
    heating = load_pack.call("heating")
    heating["provider"] = { "name" => "Izmišljeno grijanje", "source_url" => "https://civic.example.invalid/heating" }
    heating["facts"] = [fact.call("heating_provider", "SINTETIČKI KONTAKT za izmišljeno grijanje."),
                          fact.call("heating_network_footprint_unknown", "Izmišljeni obuhvat nije potvrđen za pojedinačnu zgradu.")]
    heating["blockers"] = [blocker.call("heating_network_footprint_not_published", "Izmišljeni obuhvat mreže nije javno objavljen. Ne izvoditi zaključak o konkretnoj zgradi.")]
    [billing, recycling, heating].each { |data| File.write(File.join(root, "#{data.fetch('domain')}_reviewed_facts.yml"), YAML.dump(data)) }
  end

end
