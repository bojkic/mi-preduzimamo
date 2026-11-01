# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/synthetic_event_source_registry"

module DecidimApp
  module Bijeljina
    # Notices already on the board predate the corrections. Bringing them into
    # line must never overwrite something an operator wrote by hand.
    class CityServiceBoardTextBackfillTest < ActiveSupport::TestCase
      include SyntheticEventSourceRegistry
      LEGACY_SUMMARY = "Planirano isključenje električne energije za Naseljena mjesta: Izmišljeni vrt od 08:00 do 10:00. " \
                       "TJ: TESTNA JEDINICA; Objekat: TESTNI OBJEKAT A; Razlog: Priključenje nove TS"
      LEGACY_CREDIT = "Izvor: Izmišljeni pružalac planned outages https://example.test/outages"

      setup do
        # The exact retired label must agree with the configured source label.
        rows = CityServiceSources::SOURCES.map do |row|
          row.fetch(:key) == "electricity_outages" ? row.merge(label: "Izmišljeni pružalac planned outages").freeze : row
        end
        CityServiceSources.send(:remove_const, :SOURCES)
        CityServiceSources.const_set(:SOURCES, rows.freeze)
        @organization = create_organization
        @mz = Decidim::Bih::LocalArea.create!(organization: @organization, kind: "mz", slug: "mz-synthetic-field", name: { "sr" => "Izmišljeno polje" })
        @komsiluk = Decidim::Bih::LocalArea.create!(organization: @organization, kind: "komsiluk", slug: "komsiluk-synthetic-field",
                                                    name: { "sr" => "Izmišljeno polje 1" }, parent: @mz, primary_mz_slug: "mz-synthetic-field",
                                                    overlapping_mz_slugs: ["mz-synthetic-field"])
        @backfill = CityServiceBoardTextBackfill.new(organization: @organization)
      end

      test "a notice the parser wrote gains the date and loses the circuit identifiers" do
        event, post = published(summary: LEGACY_SUMMARY)

        result = @backfill.call(apply: true)

        assert_equal [event.id], result.events_rewritten
        assert_equal [post.id], result.posts_rewritten
        assert_empty result.skipped

        body = post.reload.body

        assert_includes body, "23.09.2040."
        assert_not_includes body, "TJ: TESTNA JEDINICA"
        assert_not_includes body, "TESTNI OBJEKAT A"
        assert_includes body, "Razlog: Priključenje nove TS."
        assert_includes body, "Izvor: Izmišljeni pružalac"
        assert_not_includes body, "planned outages"
        assert_includes body, "https://example.test/outages", "the source link must survive"
        assert_equal event.reload.summary, body.split(" Izvor:").first
      end

      # The guard protects the operator's WORDS. The source credit is generated
      # text and wrong either way, so it is still corrected.
      test "an operator's own wording survives, while the wrong credit is still fixed" do
        event, post = published(summary: "Operater je ovo prepisao rukom.")

        @backfill.call(apply: true)

        assert_equal "Operater je ovo prepisao rukom.", event.reload.summary
        assert post.reload.body.start_with?("Operater je ovo prepisao rukom.")
        assert_includes post.body, "Izvor: Izmišljeni pružalac"
        assert_not_includes post.body, "planned outages"
      end

      # If the post no longer opens with the notice it was generated from, we
      # cannot find the notice inside it without guessing. Report, do not guess.
      test "a post edited independently of its notice is reported and left alone" do
        event, post = published(summary: LEGACY_SUMMARY)
        post.update!(body: "Neko je ovu objavu potpuno prepisao.")

        result = @backfill.call(apply: true)

        assert_equal [post.id], result.skipped
        assert_empty result.posts_rewritten
        assert_equal "Neko je ovu objavu potpuno prepisao.", post.reload.body
        # The notice itself is still the parser's own text, and the admin panel
        # and Milica both read it, so it is corrected regardless of what became
        # of this one board copy.
        assert_includes event.reload.summary, "23.09.2040."
      end

      test "a dry run reports the same work and writes nothing" do
        _event, post = published(summary: LEGACY_SUMMARY)
        original = post.body

        assert_equal 1, @backfill.call.posts_rewritten.size
        assert_equal original, post.reload.body
      end

      test "running it twice changes nothing the second time" do
        published(summary: LEGACY_SUMMARY)
        @backfill.call(apply: true)

        second = @backfill.call(apply: true)

        assert_empty second.events_rewritten
        assert_empty second.posts_rewritten
        assert_empty second.skipped
      end

      test "a citizen's own post is never touched" do
        citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
        own = Decidim::Bih::KomsilukPost.create!(organization: @organization, komsiluk: @komsiluk, author: citizen,
                                                 body: "#{LEGACY_SUMMARY} #{LEGACY_CREDIT}", status: "open", category: "safety", title: "Planirano isključenje struje")
        published(summary: LEGACY_SUMMARY)

        @backfill.call(apply: true)

        assert_equal "#{LEGACY_SUMMARY} #{LEGACY_CREDIT}", own.reload.body
      end

      private

      def published(summary:)
        post = Decidim::Bih::KomsilukPost.create!(organization: @organization, komsiluk: @komsiluk, author: nil,
                                                  body: "#{summary} #{LEGACY_CREDIT}", status: "open", category: "safety", title: "Planirano isključenje struje")
        event = CityServiceEvent.create!(
          organization: @organization, source_key: "electricity_outages", source_label: "Izmišljeni pružalac planned outages",
          provider: "Izmišljeni pružalac", source_url: "https://example.test/outages",
          source_fingerprint: "board-backfill-#{post.id}", parser_version: "electricity_outage_parser_v3",
          event_type: "planned_outage", severity: "service_outage", targeting_level: "komsiluk",
          affected_area_slugs: ["komsiluk-synthetic-field"], title: "Planirano isključenje struje: Naseljena mjesta: Izmišljeni vrt",
          summary:, affected_text: "Naseljena mjesta: Izmišljeni vrt",
          starts_at: Time.find_zone!("Europe/Sarajevo").parse("2040-09-23 08:00"),
          ends_at: Time.find_zone!("Europe/Sarajevo").parse("2040-09-23 10:00"),
          state: "board_published", komsiluk_post_ids: [post.id],
          extraction_metadata: { "tj" => "TESTNA JEDINICA", "feeder" => "TESTNI OBJEKAT A", "reason" => "Priključenje nove TS" }
        )
        [event, post]
      end
    end
  end
end
