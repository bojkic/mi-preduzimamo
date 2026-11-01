# frozen_string_literal: true

# Explicit test-only endpoints. No source document is fetched from a real
# institution; every body and observation must be authored by the test.
module SyntheticCitizenNoticeSources
  def self.included(base)
    base.setup do
      @synthetic_prior_notice_sources = DecidimApp::Bijeljina::CitizenNoticePilots::SOURCES
      urls = { "bihamk_border" => "https://border.example.invalid/current",
        "pio_notices" => "https://pension.example.invalid/feed", "jfdz_notices" => "https://benefit.example.invalid/sr" }
      rows = @synthetic_prior_notice_sources.to_h do |key, row|
        [key, row.merge(url: urls.fetch(key), label: "Autorski testni izvor #{key}").freeze]
      end
      owner = DecidimApp::Bijeljina::CitizenNoticePilots
      owner.send(:remove_const, :SOURCES)
      owner.const_set(:SOURCES, rows.freeze)
    end
    base.teardown do
      if @synthetic_prior_notice_sources
        owner = DecidimApp::Bijeljina::CitizenNoticePilots
        owner.send(:remove_const, :SOURCES)
        owner.const_set(:SOURCES, @synthetic_prior_notice_sources)
      end
    end
  end
end
