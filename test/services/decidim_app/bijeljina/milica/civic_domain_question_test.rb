# frozen_string_literal: true

require "test_helper"
require_relative "../../../../support/synthetic_civic_configuration"

module DecidimApp
  module Bijeljina
    module Milica
      # The four misroutings named in the conversation review, each pinned from
      # both sides: the question that must now be caught, and the neighbouring
      # question that must keep its old, correct answer.
      class CivicDomainQuestionTest < ActiveSupport::TestCase
        include SyntheticCivicConfiguration
        setup { install_synthetic_civic_configuration }
        teardown { restore_synthetic_civic_configuration }
        test "a recycling question is no longer answered from the waste calendar" do
          question = classify("waste", "Gdje su kontejneri za staklo i plastiku?")

          assert_equal :recycling, question.domain
          assert_equal :location, question.focus
        end

        test "a mixed-waste collection question keeps the waste schedule" do
          assert_nil classify("waste", "Kada se odvozi smeće u Izmišljenom polju?")
          assert_nil classify("waste", "Koji dan je odvoz smeća za Izmišljenu ulicu?")
        end

        test "bulky waste stays its own service" do
          assert_nil classify("waste", "Gdje da bacim kabasti otpad?")
          assert_nil classify("unknown", "Kada je odvoz glomaznog otpada, stari namještaj?")
        end

        test "a billing question is not answered from the outage feed" do
          question = classify("water", "Zašto mi je račun za vodu ogroman?")

          assert_equal :billing, question.domain
          assert_equal "water", question.biller
          assert_equal :personal, question.focus
        end

        test "an outage question is not answered with a tariff" do
          assert_nil classify("water", "Nema vode u Izmišljenom naselju")
          assert_nil classify("electricity", "Nestala je struja, kad se vraća?")
          assert_nil classify("heating", "Nema grijanja u mojoj zgradi")
        end

        test "a transport fare question is never claimed by billing" do
          assert_nil classify("transport", "Koliko košta karta za autobus?")
          # Even with the topic lost, the fare vocabulary keeps it away.
          assert_nil classify("unknown", "Koliko košta mjesečna karta za gradski prevoz?")
        end

        test "a parking tariff question keeps its reviewed parking answer" do
          assert_nil classify("parking", "Koliko košta sat parkinga u crvenoj zoni?")
          assert_nil classify("unknown", "Cijena parkiranja u plavoj zoni?")
        end

        test "each biller is routed to from its own vocabulary" do
          assert_equal "waste", classify("unknown", "Račun za odvoz smeća je prevelik").biller
          assert_equal "electricity", classify("unknown", "Kolika je zatezna kamata na račun za struju?").biller
          assert_equal "heating", classify("unknown", "Na koji račun se plaća grijanje?").biller
          assert_equal "city_levies", classify("city_service", "Kolika je komunalna naknada po kvadratu?").biller
        end

        test "an unrouted billing question asks which bill rather than guessing" do
          question = classify("city_service", "Zašto mi je račun toliki?")

          assert_equal :billing, question.domain
          assert_nil question.biller
        end

        test "a bare payment verb with no bill and no provider is not claimed" do
          # "Kako da platim na mojoj lokaciji" names neither a bill nor a
          # biller; asking "which of the five?" would be a worse answer than the
          # one it already had.
          assert_nil classify("city_service", "Kako da platim na mojoj lokaciji")
          assert_nil classify("unknown", "Gdje mogu platiti?")
        end

        test "the house-on-the-heating-network question is recognised as its own case" do
          question = classify("heating", "Da li je moja zgrada priključena na toplanu?")

          assert_equal :heating_network, question.domain
          assert_equal :coverage, question.focus
          assert_equal :heating_network, classify("unknown", "Je li moja ulica na toplovodnoj mreži?").domain
          # The plainest wording of the same question, with no "priključen".
          assert_equal :heating_network, classify("heating", "Da li je moja kuća na toplani?").domain
        end

        test "a price question without a billing noun is still a tariff question" do
          assert_equal "water", classify("water", "Koliko je kubik vode?").biller
          assert_equal "electricity", classify("electricity", "Koliko je kWh struje?").biller
          # A quantity question with no measured unit is not about money.
          assert_nil classify("unknown", "Koliko je sati?")
          # A unit of time in a frequency question is not a price either.
          assert_nil classify("waste", "Koliko puta mjesečno se odvozi smeće?")
        end

        test "a bare material word without a disposal cue is not a recycling question" do
          assert_nil classify("unknown", "Koji papiri trebaju za registraciju vozila?")
        end

        test "PET counts as packaging only in a packaging phrase" do
          assert_equal :recycling, classify("waste", "Gdje se odlaže PET ambalaža?").domain
          # "pet" is also five and the short form of petak; a day question must
          # not become a recycling answer.
          assert_nil classify("waste", "Koji dan je odvoz, pet ili subota?")
          assert_nil classify("waste", "Kontejner nije praznjen pet dana")
        end

        test "self-haul is distinguished from a container question" do
          assert_equal :self_haul, classify("waste", "Gdje da odnesem staklo na deponiju?").focus
          assert_equal :location, classify("waste", "Gdje je najbliži kontejner za reciklažu?").focus
        end

        test "asking whether the truck came is not the same as asking which day" do
          assert CivicDomainQuestion.observed_collection?("Nisu pokupili smeće u Izmišljenom polju")
          assert CivicDomainQuestion.observed_collection?("Da li su odvezli smeće danas?")
          assert CivicDomainQuestion.observed_collection?("Kontejner nije praznjen već sedmicu")
          assert_not CivicDomainQuestion.observed_collection?("Kada se odvozi smeće u Izmišljenom polju?")
          assert_not CivicDomainQuestion.observed_collection?("")
        end

        test "an empty question is left alone" do
          assert_nil classify("waste", "")
          assert_nil DecidimApp::Bijeljina::Milica::CivicDomainQuestion.call(topic: "waste", entities: {})
        end

        private

        def classify(topic, query)
          CivicDomainQuestion.call(topic:, entities: { "query" => query })
        end
      end
    end
  end
end
