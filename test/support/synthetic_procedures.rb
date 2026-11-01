# frozen_string_literal: true

require "date"
require "digest"

# Entirely authored procedure cards. Stable old keys name reference interfaces;
# titles, provider codes, forms, rules, URLs and documents are invented.
module SyntheticProcedures
  def install_synthetic_procedures(day: Date.new(2040, 9, 9), organization_host: "community.example.invalid")
    owner = DecidimApp::Bijeljina::ServiceProcedures
    @synthetic_procedure_cache_present = owner.instance_variable_defined?(:@all)
    @synthetic_procedure_prior_cache = owner.instance_variable_get(:@all)
    @synthetic_procedure_prior_hosts = owner::REVIEWED_HOSTS
    owner.send(:remove_const, :REVIEWED_HOSTS)
    owner.const_set(:REVIEWED_HOSTS, ["community.example.invalid"].freeze)
    owner.instance_variable_set(:@all, synthetic_procedure_cards(day:, organization_host:))
  end

  def restore_synthetic_procedures
    owner = DecidimApp::Bijeljina::ServiceProcedures
    if @synthetic_procedure_prior_hosts
      owner.send(:remove_const, :REVIEWED_HOSTS)
      owner.const_set(:REVIEWED_HOSTS, @synthetic_procedure_prior_hosts)
    end
    owner.remove_instance_variable(:@all) if owner.instance_variable_defined?(:@all)
    owner.instance_variable_set(:@all, @synthetic_procedure_prior_cache) if @synthetic_procedure_cache_present
  end

  def synthetic_procedure_cards(day:, organization_host: "community.example.invalid")
    %w(maticar pracenje_predmeta e_registar registry_b4_1).map do |key|
      card = { key:, title: "Izmišljeni postupak #{key}", owner: "Izmišljena nadležna služba",
               source_url: "https://community.example.invalid/procedures/#{key}", source_checked_on: day.iso8601,
               source_fragment: key == "registry_b4_1" ? "registry_detail" : "entry__article",
               eligibility: "Izmišljeni uslov; nije uputstvo za stvarni postupak.",
               steps: ["Izmišljeni korak za #{key}.", "Taksa nije navedena za ovaj izmišljeni primjer."],
               required_documents: nil, fee: nil, processing_time: nil, effective_from: nil, effective_until: nil,
               location_scope: "Izmišljena zajednica", record_kind: "procedure", review_status: "reviewed",
               privacy: "Bez stvarnih ličnih podataka.", current_legal_status: "not_verified",
               reviewed_content_hash: Digest::SHA256.hexdigest(synthetic_procedure_plaintext(key)),
               aliases: [], source_aliases: ["https://community.example.invalid/mirror/#{key}"] }
      if key == "maticar"
        card.merge!(aliases: ["e-matičar"], channel: "online", document_kind: "birth_extract", organization_host:,
                    steps: ["Izmišljeni online zahtjev po pregledanom uputstvu službe.", "Lične identifikatore unosite samo u službeni obrazac."],
                    fee: { administrative_fee_bam: 0, delivery_cost: "postage", postage_amount_bam: nil },
                    delivery: { document_method: "postal", instructions_method: "email" })
      elsif key == "registry_b4_1"
        card.merge!(provider_procedure_code: "ТЕСТ_4", source_page_id: "test-page-A", aliases: ["TEST_4", "ТЕСТ_4", "izmišljena potvrda"],
                    form_download_url: nil, required_documents: ["Izmišljeni dokument A", "Izmišljeni dokument B", "Izmišljeni dokument C"],
                    processing_time: { guaranteed_completion: false, text: "Izmišljeni zakonski rok nije obećanje završetka." })
      end
      card.freeze
    end.freeze
  end

  def synthetic_procedure_plaintext(key)
    "AUTORSKI IZMIŠLJENI IZVOR #{key}. Pravila u ovom testu nisu stvarna usluga."
  end

  def synthetic_procedure_html(key)
    text = synthetic_procedure_plaintext(key)
    key == "registry_b4_1" ? "<main><div class='col-lg-9'><div class='card'>#{text}</div></div></main>" : "<div class='entry__article'>#{text}</div>"
  end
end
