# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/synthetic_event_source_registry"

module DecidimApp
  module Bijeljina
    # What a resident reads on the board. The alert exists to answer "is my
    # power going off, when, and where" — so the date is not optional, and the
    # utility's internal circuit identifiers are not part of the answer.
    class CityServiceCitizenCopyTest < ActiveSupport::TestCase
      include SyntheticEventSourceRegistry
      setup do
        # Keep a deliberately internal label distinct from the fictional provider.
        sources = CityServiceSources
        rows = sources::SOURCES.map do |row|
          row.fetch(:key) == "electricity_outages" ? row.merge(label: "synthetic planned outages").freeze : row
        end
        sources.send(:remove_const, :SOURCES)
        sources.const_set(:SOURCES, rows.freeze)
        @organization = create_organization
        Decidim::Bih::LocalArea.create!(organization: @organization, kind: "mz", slug: "mz-synthetic-field", name: { "sr" => "Izmišljeno polje" })
        @ingestor = CityServiceEventIngestor.new(organization: @organization)
        @now = Time.utc(2040, 9, 22, 4)
      end

      test "a planned outage tells the citizen which day" do
        assert_match(/23\.09\.2040\./, event.summary, "the summary must carry the date, not only a clock range")
        assert_match(/08:00 do 10:00/, event.summary)
      end

      test "the utility's internal circuit identifiers stay out of the citizen text" do
        assert_no_match(/TJ:/, event.summary)
        assert_no_match(/Objekat:/, event.summary)
      end

      test "the reason the power is off is kept, because a resident acts on it" do
        assert_match(/Razlog: Priključenje nove TS/, event.summary)
      end

      test "the internal identifiers are still retained as operator evidence" do
        metadata = event.extraction_metadata

        assert_equal "TESTNA JEDINICA", metadata["tj"]
        assert_equal "TESTNI OBJEKAT A", metadata["feeder"]
      end

      test "the source is credited by its name, not by an internal English label" do
        source = CityServiceSources.fetch("electricity_outages")

        assert_equal "Izmišljeni pružalac", source.fetch(:provider)
        assert_match(/planned outages/, source.fetch(:label), "the label is an internal key and must never reach a citizen")
      end

      test "every source credits an institution a citizen recognises, never an internal label" do
        CityServiceSources.all.each do |source|
          assert source[:provider].present?, "#{source.fetch(:key)} has no provider name to credit"
          assert_no_match(/\b(planned|notices|schedule|information|reports|routes)\b/i, source.fetch(:provider),
                          "#{source.fetch(:key)} credits what looks like an internal label")
        end
      end

      private

      def event
        @event ||= @ingestor.ingest(source_key: "electricity_outages", html: html, fetched_at: @now).events.sole
      end

      def html
        <<~HTML
          <p>23.09.2040.</p><table>
          <tr><th>TJ</th><th>Objekat</th><th>Područje</th><th>Razlog</th><th>Početak</th><th>Završetak</th></tr>
          <tr><td>TESTNA JEDINICA</td><td>TESTNI OBJEKAT A</td><td>Naseljena mjesta: Izmišljeni vrt, Izmišljeno polje Testni dio</td><td>Priključenje nove TS</td><td>08:00</td><td>10:00</td></tr>
          </table>
        HTML
      end
    end
  end
end
