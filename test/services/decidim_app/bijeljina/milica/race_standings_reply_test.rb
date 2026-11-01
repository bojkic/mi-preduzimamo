# frozen_string_literal: true

require "test_helper"

module DecidimApp
  module Bijeljina
    module Milica
      # "Ko trenutno vodi?" returned the same eight-item reward catalogue in
      # three independent fresh sessions, and one phrasing of the race question
      # returned the foundation's donation blurb with two bank accounts and an
      # IBAN. This drives the real Responder against the REAL cached standings
      # table — the same rows the projector screen reads, never the Scorer and
      # never a server-side HTTP call to this app's own /ekran.json.
      class RaceStandingsReplyTest < ActiveSupport::TestCase
        class FakeDirectory
          def search(_query, **) = []
        end

        class FakeWaste
          def collection_days_for(_query) = nil
        end

        setup do
          @organization = create_organization
          @grad = area(kind: "komsiluk", slug: "racanska", name: "Račanska", zona: "grad")
          @selo = area(kind: "komsiluk", slug: "velika-obarska", name: "Velika Obarska", zona: "selo")
          @computed_at = Time.utc(2026, 9, 14, 8, 30)
        end

        test "the standings answer names both leaders, timestamps them and links the race tab" do
          standing(@grad, zona: "grad", score: 128, rank_overall: 1, rank_in_zone: 1)
          standing(@selo, zona: "selo", score: 44, rank_overall: 2, rank_in_zone: 1)

          reply = respond("Ko trenutno vodi?")

          assert_equal "launch", reply.answer_intent
          assert_includes reply.text, "Račanska"
          assert_includes reply.text, "128"
          assert_includes reply.text, "Velika Obarska"
          assert_includes reply.text, "44"
          assert_includes reply.text, "14.09.2026. 10:30"
          assert_includes reply.text, "zajednistvo?tab=trka"
          assert_not_includes reply.text, "tab=tabla"
        end

        # The public projector screen and the chat must agree, because they are
        # the same rows: this reads both through their own owners.
        test "the chat leaders are the leaders the public projection reports" do
          standing(@grad, zona: "grad", score: 128, rank_overall: 1, rank_in_zone: 1)
          standing(@selo, zona: "selo", score: 44, rank_overall: 2, rank_in_zone: 1)
          projection = Decidim::Bih::Race::Standings.new(@organization)

          reply = respond("ko vodi u trci")

          Decidim::Bih::LocalArea::ZONES.each do |zone|
            leader = projection.leader(zone)
            assert_includes reply.text, leader.display_name, zone
            assert_includes reply.text, leader.score.to_s, zone
          end
        end

        test "an empty league says so instead of borrowing the other league's leader" do
          standing(@grad, zona: "grad", score: 128, rank_overall: 1, rank_in_zone: 1)

          reply = respond("Ko trenutno vodi?")

          assert_includes reply.text, I18n.t("decidim.bih.dialogue.race_standings_no_leader", locale: :sr,
                                                                                              zone: I18n.t("decidim.bih.dialogue.race_standings_zone_selo", locale: :sr))
          assert_not_includes reply.text, "Velika Obarska"
        end

        test "a frozen table is labelled final and is never timestamped as live" do
          standing(@grad, zona: "grad", score: 128, rank_overall: 1, rank_in_zone: 1, final: true)
          standing(@selo, zona: "selo", score: 44, rank_overall: 2, rank_in_zone: 1, final: true)

          reply = respond("Ko trenutno vodi?")

          assert_includes reply.text, I18n.t("decidim.bih.dialogue.race_standings_final", locale: :sr,
                                                                                          url: Decidim::Bih.public_path("zajednistvo?tab=trka"))
          assert_not_includes reply.text, "14.09.2026"
        end

        test "a race answer never carries the foundation's payment details" do
          standing(@grad, zona: "grad", score: 128, rank_overall: 1, rank_in_zone: 1)

          assert_no_match(/IBAN|\bra[cč]un\b|\d{3}-\d{6,}/i, respond("Ko trenutno vodi?").text)
        end

        private

        def respond(text)
          Decidim::Bih::Concierge::Responder.new(
            organization: @organization,
            directory: FakeDirectory.new,
            waste_schedule: FakeWaste.new,
            race_standings: Decidim::Bih::Race::Standings.new(@organization),
            goodwill_user_resolver: ->(_message) {}
          ).respond(Struct.new(:text, :user, :image_url, :latitude, :longitude).new(text, nil, nil, nil, nil))
        end

        def area(kind:, slug:, name:, **attributes)
          Decidim::Bih::LocalArea.create!(organization: @organization, kind:, slug:, name: { "sr" => name }, **attributes)
        end

        def standing(komsiluk, **attributes)
          Decidim::Bih::Race::Standing.create!(organization: @organization, komsiluk:, computed_at: @computed_at, **attributes)
        end
      end
    end
  end
end
