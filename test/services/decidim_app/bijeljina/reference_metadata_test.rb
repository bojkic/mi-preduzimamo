# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/synthetic_service_directory"
require_relative "../../../support/synthetic_procedures"

module DecidimApp
  module Bijeljina
    class ReferenceMetadataTest < ActiveSupport::TestCase
      include SyntheticServiceDirectory
      include SyntheticProcedures

      setup do
        install_synthetic_service_directory
        install_synthetic_procedures(day: Date.new(2040, 5, 6))
        swap_service_constant(ParkingZones, :SOURCE_CAPTURED_ON, Date.new(2040, 3, 19))
        entries = CityServicesData::ENTRIES.map(&:dup)
        entries.each do |entry|
          entry[:source_checked_on] = entry[:key] == :vodovod_servis ? "2040-04-22" : "2040-05-06"
          entry[:facts] = CityServicesData.entry_facts(entry, checked_on: Date.iso8601(entry[:source_checked_on]))
        end
        entries += [
          { key: :e_registar, title: "Izmišljeni registar", keywords: ["registar"],
            source_url: "https://community.example.invalid/registry", source_checked_on: "2040-05-06", answer: "IZMIŠLJENI IZVOR." },
          { key: :pracenje_predmeta, title: "Izmišljeno praćenje", keywords: ["predmet"],
            source_url: "https://community.example.invalid/forms/authored-status-enquiry", source_checked_on: "2040-05-06",
            answer: "IZMIŠLJENI PRIMJER: lične podatke unesite samo u službeni obrazac, ne u razgovor s Milicom." }
        ]
        swap_service_constant(CityServicesData, :ENTRIES, entries.map(&:freeze).freeze)
        CityDirectory.instance_variable_set(:@directory, Decidim::Bih::City::ServiceDirectory.new(entries))
        # Independent issue fixtures: twelve invented current-year metadata
        # rows and one earlier capture; no municipal PDF or excerpt is copied.
        issues = 12.downto(1).map do |number|
          { number: "#{number}/2040", title: "IZMIŠLJENI glasnik #{number}",
            url: "https://community.example.invalid/issue-#{number}.pdf", published_on: "2040-04-17",
            source_checked_on: "2040-05-06", source_pdf_pages: number == 12 ? [1] : [],
            summary_provenance: number == 12 ? "sampled_pdf_heading" : "issue_metadata_only" }
        end
        issues << { number: "7/2039", title: "IZMIŠLJENI raniji glasnik", url: "https://community.example.invalid/earlier.pdf",
          source_checked_on: "2039-07-11", source_pdf_pages: [] }
        swap_service_constant(GazetteData, :ENTRIES, issues.map(&:freeze).freeze)
      end

      teardown do
        restore_synthetic_procedures
        restore_synthetic_service_directory
      end

      test "current year archive includes all twelve authored issue links with honest PDF coverage" do
        current = GazetteData::ENTRIES.select { |entry| entry.fetch(:number).end_with?("/2040") }
        assert_equal 12, current.size
        metadata = GazetteData.metadata_for("12/2040")
        assert_equal "2040-04-17", metadata[:published_on]
        assert_equal "2040-05-06", metadata[:source_checked_on]
        assert_equal [1], metadata[:source_pdf_pages]
        assert_equal "sampled_pdf_heading", metadata[:summary_provenance]
        assert_equal "issue_metadata_only", GazetteData.metadata_for("11/2040")[:summary_provenance]
        assert_not metadata[:full_text_indexed]
        assert_equal "2039-07-11", GazetteData.metadata_for("7/2039")[:source_checked_on]
      end

      test "parking directory uses canonical amounts and does not refresh street map dates" do
        entry = CityDirectory.find(:parking)
        assert_equal ParkingZones.payment_description, entry[:answer_sections][:payment]
        assert_equal 235, ParkingZones::TARIFF_AMOUNTS.fetch("white").fetch(:hourly_fening)
        assert_equal "2040-09-14", entry[:facts].find { |fact| fact[:id] == "parking_tariffs" }[:source_checked_on]
        assert_equal "2040-03-19", entry[:facts].find { |fact| fact[:id] == "parking_map" }[:source_checked_on]
      end

      test "procedure cards keep unknown requirements and processing deadlines unknown" do
        card = CityDirectory.procedure_for(:maticar)
        assert_equal 0, card[:fee][:administrative_fee_bam]
        assert_nil card[:fee][:postage_amount_bam]
        assert_nil card[:processing_time]
        assert_nil card[:required_documents]
        assert_equal "https://community.example.invalid/registry", CityDirectory.find(:e_registar)[:source_url]
      end

      test "case tracking links directly to the actual enquiry form without a fictitious required case number" do
        entry = CityDirectory.find(:pracenje_predmeta)
        assert_includes entry[:source_url], "authored-status-enquiry"
        assert_not_includes entry[:answer], "potreban je broj predmeta"
        assert_includes entry[:answer], "ne u razgovor s Milicom"
      end

      test "a procedure capture time is independent of unrelated directory reviews" do
        assert_equal "2040-05-06", CityDirectory.metadata_for(:maticar)[:source_checked_on]
        assert_equal "2040-04-22", CityDirectory.metadata_for(:vodovod_servis)[:source_checked_on]
      end
    end
  end
end
