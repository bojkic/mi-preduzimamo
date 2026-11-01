# frozen_string_literal: true

require "test_helper"
require "capybara"

module DecidimApp
  module Bijeljina
    module Milica
      # What a rewards question actually asks is a PRICE, and almost always the
      # price of one reward. The measured answer was eight descriptions with no
      # cost at all, truncated at eight of the catalogue's nine — a reply that
      # could answer neither the price question nor the catalogue question.
      #
      # Task 7 put the cost into each reward's own sentence. This narrows WHICH
      # rewards are in the answer, and keeps the catalogue link so a narrowed
      # answer never reads as a complete shelf.
      class RewardPriceReadTest < ActiveSupport::TestCase
        CATALOGUE = [
          ["naljepnice", "MI! naljepnice", 150],
          ["zahvalnica", "Digitalna zahvalnica", 200],
          ["torba", "Platnena torba", 300],
          ["pozivnica", "Pozivnica za događaj zajednice", 400],
          ["majica", "MI! majica", 500],
          ["partner_kupon", "Partnerski kupon zajednice", 600],
          ["radionica", "Mjesto na radionici ili mentorstvu", 700],
          ["termos", "MI! termos", 800],
          ["godisnje_priznanje", "Godišnje priznanje", 1200]
        ].freeze

        setup do
          travel_to Time.utc(2026, 9, 14, 12)
          @organization = create_organization
          CATALOGUE.each { |key, title, cost| reward(key:, title: { "sr" => title }, cost:) }
          @reader = PlatformCatalogRead.new(organization: @organization)
        end

        teardown do
          travel_back
        end

        # b2c14: "Koliko bodova košta MI majica?" returned eight other rewards.
        test "a named reward is the only reward in the answer and it states its cost" do
          result = read("Koliko bodova košta MI majica?")

          assert_equal ["reward:majica"], ids(result)
          assert_includes result[:facts].first["text"], I18n.t("decidim_app.milica.rewards.cost", cost: 500, locale: :sr)
          assert_equal 500, result[:facts].first["points_cost"]
        end

        test "a reward named only by a word of its title is still found" do
          result = read("koliko košta platnena torba")

          assert_equal ["reward:torba"], ids(result)
        end

        # b2c15: "Koje su dvije najjeftinije dostupne nagrade?"
        test "the cheapest n are exactly n and are the cheapest" do
          result = read("Koje su dvije najjeftinije dostupne nagrade?")

          assert_equal ["reward:naljepnice", "reward:zahvalnica"], ids(result)
        end

        test "an open catalogue question returns at most three with the catalogue link" do
          result = read("Koje nagrade mogu dobiti?")

          assert_equal 3, result[:facts].length
          assert_includes result[:warnings], "reward_catalog_not_complete_inventory"
          assert_equal Decidim::Bih.public_path("zajednistvo?tab=nagrade"), result[:source]["url"]
        end

        # The launch invitation is a threshold, not a purchase, and it is
        # correctly absent from the spend catalogue. Asking for a price must
        # never offer the unrelated 400-point "Pozivnica za događaj zajednice"
        # as if it were the launch invitation (b2c16).
        test "an auto issued threshold reward is never offered as a price" do
          reward(key: "pozivnica_lansiranje", title: { "sr" => "Pozivnica za lansiranje" }, cost: 20,
                 auto_issue_at_threshold: true, deducts_points: false, stock: 310)

          %w(pozivnica_lansiranje pozivnica).each do |key|
            assert_not_includes ids(read("koliko bodova košta nagrada")), "reward:#{key}"
          end
        end

        test "a short word in a reward title never identifies it" do
          # "MI" is two characters and appears in three titles; it must not
          # single any of them out.
          result = read("koliko košta MI")

          assert_equal 3, result[:facts].length
        end

        private

        def ids(result) = result[:facts].map { |fact| fact["id"] }

        def read(query)
          @reader.call(topic: "rewards", entities: { "query" => query }, context:, locale: "sr")
        end

        def context
          Decidim::Bih::Concierge::Dialogue::Contracts::TrustedContext.new(
            organization_id: @organization.id, conversation_key: "c" * 64, capabilities: ["public_reads"], now: Time.current
          )
        end

        def reward(**attributes)
          Decidim::Bih::Goodwill::Reward.create!(organization: @organization, active: true, **attributes)
        end
      end
    end
  end
end
