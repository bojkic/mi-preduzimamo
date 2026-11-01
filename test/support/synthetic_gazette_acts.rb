# frozen_string_literal: true

require "digest"

# Entirely authored public-act examples. No actual decision, identifier,
# excerpt, local project or legal rule is copied into the public fixtures.
module SyntheticGazetteActs
  ISSUE_HASH = Digest::SHA256.hexdigest("authored-gazette-issue-v1")
  ISSUE_NUMBER = "01/2040"

  def install_synthetic_gazette_acts
    owner = DecidimApp::Bijeljina::GazetteActs
    @synthetic_acts_cache_present = owner.instance_variable_defined?(:@all)
    @synthetic_acts_prior_cache = owner.instance_variable_get(:@all)
    owner.instance_variable_set(:@all, synthetic_gazette_acts.freeze)
  end

  def restore_synthetic_gazette_acts
    owner = DecidimApp::Bijeljina::GazetteActs
    owner.remove_instance_variable(:@all) if owner.instance_variable_defined?(:@all)
    owner.instance_variable_set(:@all, @synthetic_acts_prior_cache) if @synthetic_acts_cache_present
  end

  def synthetic_gazette_acts
    first = { id: "authored-act-a", title: "IZMIŠLJENA ODLUKA O TESTNOM TRGU", provider_act_id: "TEST-ACT-2040-A",
              issue_number: ISSUE_NUMBER, issue_content_hash: ISSUE_HASH, source_pdf_pages: [3],
              source_url: "https://community.example.invalid/authored-issue.pdf#page=3",
              summary: "Potpuno izmišljeni primjer, nije stvarna odluka.", adopted_on: "2040-03-02",
              published_on: "2040-03-09", effective_from: "2040-03-10", effective_basis: "Izmišljena izvorna odredba.",
              legal_basis: "Izmišljeni izvor, ne pravni savjet.", source_checked_on: "2040-09-14",
              current_legal_status: "not_verified", keywords: ["Izmišljeni trg", "testni trg"], amends: [] }
    second = first.merge(id: "authored-act-b", title: "IZMIŠLJENA IZMJENA TESTNOG PRAVILA", provider_act_id: "TEST-ACT-2040-B",
                         keywords: ["izmišljena izmjena"],
                         amends: [{ provider_act_id: nil, target_identity_verified: false, relationship: "amends" }])
    [first.freeze, second.freeze]
  end
end
