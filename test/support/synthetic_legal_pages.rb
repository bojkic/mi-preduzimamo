# frozen_string_literal: true

# Authored publication-copy fixture, not a real community's legal documents.
module SyntheticLegalPages
  module_function

  def configuration
    titles = { "terms-of-service" => "Izmišljeni uslovi", "privacy-policy" => "Izmišljena privatnost",
               "cookie-policy" => "Izmišljeni kolačići", "data-processing" => "Izmišljena obrada" }
    pages = titles.each_with_index.to_h do |(slug, title), index|
      text = case slug
             when "privacy-policy" then "IZMIŠLJENI TEST: rok čuvanja A, obrađivač B i način zahtjeva C."
             when "terms-of-service" then "IZMIŠLJENI TEST: bodovi, nagrade, donacije i glasanje imaju zasebna pravila."
             else "IZMIŠLJENI TEST: lokalna pravila određuje vaša zajednica."
             end
      [slug, { "title" => title, "summary" => "Izmišljeni sažetak: #{title}.", "weight" => (index + 1) * 10,
               "updated_on" => slug == "privacy-policy" ? "2040-02-03" : "2040-01-02",
               "sections" => [["Izmišljena pravila", [text]],
                              ["Kontakt", ["Primjer kontakta: legal@community.example.invalid i community.example.invalid."]]] }]
    end
    { "topic_title" => "Izmišljeni pravni dokumenti", "topic_description" => "Izmišljeni sadržaj samo za test.",
      "contact_email" => "legal@community.example.invalid", "contact_domain" => "community.example.invalid", "pages" => pages }
  end
end
