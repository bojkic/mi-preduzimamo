# frozen_string_literal: true

require "digest"
require "date"

# Authored issue metadata and HTML, not a copied municipal archive. Minimal PDF
# prefix bytes are only content-hash test inputs, not proof of document parsing.
module SyntheticReferenceArchive
  URL = "https://community.example.invalid/archive/2026.html"

  def install_synthetic_reference_archive
    @synthetic_archive_constants = []
    swap_archive_constant(DecidimApp::Bijeljina::CityReferenceRefresh, :GAZETTE_URL, URL)
    swap_archive_constant(DecidimApp::Bijeljina::GazetteData, :ENTRIES, synthetic_archive_entries.freeze)
    swap_archive_constant(DecidimApp::Bijeljina::GazetteData, :BASE, URL)
    swap_archive_constant(DecidimApp::Bijeljina::GazetteData, :SOURCE_CAPTURED_ON, Date.new(2026, 9, 9))
  end

  def restore_synthetic_reference_archive
    @synthetic_archive_constants&.reverse_each do |owner, name, prior|
      owner.send(:remove_const, name)
      owner.const_set(name, prior)
    end
    @synthetic_archive_constants = []
  end

  def swap_archive_constant(owner, name, value)
    @synthetic_archive_constants << [owner, name, owner.const_get(name, false)]
    owner.send(:remove_const, name)
    owner.const_set(name, value)
  end

  def synthetic_archive_entries
    7.downto(1).map do |issue|
      url = "https://community.example.invalid/archive/authored-issue-#{issue}.pdf"
      { title: "Измишљени службени гласник", number: "#{issue.to_s.rjust(2, '0')}/2026", date: "14. јуна 2026. године",
        url:, summary: "IZMIŠLJENI raniji pregled, ne stvarna odluka.", source_pdf_pages: [1], summary_source_url: url,
        summary_provenance: "reviewed_excerpt", content_hash: Digest::SHA256.hexdigest("%PDF-1.4 authored original-#{issue}"),
        source_checked_on: "2026-09-09", reviewed_acts: [] }.freeze
    end
  end

  def synthetic_archive_html(issues: (1..7))
    links = issues.to_a.reverse.map do |issue|
      %(<a href="/archive/authored-issue-#{issue}.pdf">Измишљени службени гласник #{issue.to_s.rjust(2, '0')}/2026 од 14. јуна 2026. године</a>)
    end
    "<html><body>#{links.join}</body></html>"
  end
end
