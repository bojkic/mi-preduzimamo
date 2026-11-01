# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"
require_relative "../../../../support/synthetic_civic_facts"

module DecidimApp
  module Bijeljina
    module Milica
      # The three added domains answered end to end through the read port, with
      # the states the plan requires kept distinct: routed, blocked, unmapped,
      # and refused-because-personal.
      class CivicDomainReadTest < ActiveSupport::TestCase
        setup do
          @organization = create_organization
          @now = Time.utc(2040, 4, 9, 12, 0)
          @fixture_root = Dir.mktmpdir("synthetic-civic-reader-")
          SyntheticCivicFacts.write_reader_contract(root: @fixture_root, day: @now.to_date)
          @prior_directory = CivicDomainFacts::CONFIG_DIR
          @prior_hosts = CivicDomainFacts::REVIEWED_HOSTS
          @prior_cache = CivicDomainFacts.instance_variable_get(:@cache)
          CivicDomainFacts.send(:remove_const, :CONFIG_DIR)
          CivicDomainFacts.const_set(:CONFIG_DIR, @fixture_root)
          CivicDomainFacts.send(:remove_const, :REVIEWED_HOSTS)
          CivicDomainFacts.const_set(:REVIEWED_HOSTS, ["civic.example.invalid"].freeze)
          CivicDomainFacts.reset!
        end

        teardown do
          CivicDomainFacts.send(:remove_const, :CONFIG_DIR)
          CivicDomainFacts.const_set(:CONFIG_DIR, @prior_directory)
          CivicDomainFacts.send(:remove_const, :REVIEWED_HOSTS)
          CivicDomainFacts.const_set(:REVIEWED_HOSTS, @prior_hosts)
          CivicDomainFacts.instance_variable_set(:@cache, @prior_cache)
          FileUtils.remove_entry(@fixture_root) if @fixture_root && File.directory?(@fixture_root)
        end

        # ------------------------------------------------------------------
        # Recycling
        # ------------------------------------------------------------------

        test "the container question no longer returns the mixed-waste day" do
          result = ask("waste", "Gdje su kontejneri za staklo i plastiku?")

          assert_equal "ok", result.status
          text = result.facts.map { |fact| fact.fetch("text") }.join(" ")
          assert_includes result.warnings, CivicDomainRead::RECYCLING_SEPARATION
          assert_includes result.warnings, "container_locations_not_published"
          assert_no_match(/srijeda|ponedjeljak|utorak|četvrtak|petak/i, text)
          assert_includes text, "IZMIŠLJENI SAKUPLJAČ"
          assert_includes text, "SINTETIČKI KONTAKT"
          assert_equal "unmapped", result.coverage.fetch("status")
          assert_equal false, result.coverage.fetch("container_locations_published")
        end

        test "recycling never emits a location, a bin colour or a recycling day" do
          text = ask("waste", "Gdje je najbliži kontejner za reciklažu?").facts.map { |fact| fact.fetch("text") }.join(" ")

          assert_no_match(/žut\w*|zelen\w*|plav\w* (?:kant|posud|kontejner)/i, text)
          assert_no_match(/\b(?:ulica|ulici)\s+[[:upper:]]/, text)
          assert_includes text, "nigdje nije objavljen"
        end

        test "glass is reported as absent from the published list, not as refused" do
          result = ask("waste", "Da li se staklo odvozi u Bijeljini?")

          assert_equal "ok", result.status
          text = result.facts.map { |fact| fact.fetch("text") }.join(" ")
          assert_includes result.warnings, "glass_collection_unstated"
          assert_includes text, "Staklo nije na tom objavljenom spisku"
          assert_equal false, result.validity.fetch("glass_collection_known")
        end

        test "the landfill hours are offered only to someone hauling waste themselves" do
          container = ask("waste", "Gdje su kontejneri za reciklažu?").facts.map { |fact| fact.fetch("text") }.join(" ")
          self_haul = ask("waste", "Gdje da odnesem staklo na deponiju?").facts.map { |fact| fact.fetch("text") }.join(" ")

          assert_not_includes container, "IZMIŠLJENA DEPONIJA"
          assert_includes self_haul, "IZMIŠLJENA DEPONIJA"
        end

        # ------------------------------------------------------------------
        # Billing
        # ------------------------------------------------------------------

        test "an unrouted billing question asks which bill and offers all five" do
          result = ask("city_service", "Zašto mi je račun toliki?")

          assert_equal "ambiguous", result.status
          assert_includes result.warnings, "billing_provider_required"
          assert_equal 5, result.candidates.size
          assert_equal(%w(waste water electricity heating city_levies), result.candidates.map { |row| row.fetch("id") })
        end

        test "a personal bill is routed to the provider, never attempted" do
          result = ask("water", "Zašto mi je račun za vodu ogroman?")

          assert_equal "ok", result.status
          assert_includes result.warnings, "personal_bill_requires_provider_account"
          assert_equal "excluded_provider_account_required", result.coverage.fetch("personal_data_scope")
          text = result.facts.map { |fact| fact.fetch("text") }.join(" ")
          assert_includes text, "Ja to ne mogu vidjeti"
          # The authenticated provider lookups found during source review stay
          # out of every answer.
          CivicDomainFacts.excluded_authenticated_paths.each { |path| assert_not_includes text, path }
          result.facts.each { |fact| assert_not CivicDomainFacts.excluded_authenticated_path?(fact["source_url"]) }
        end

        test "a published tariff carries the decision it rests on" do
          result = ask("water", "Koliko košta kubik vode?")

          assert_equal "ok", result.status
          text = result.facts.map { |fact| fact.fetch("text") }.join(" ")
          assert_includes text, "2,34"
          assert_includes text, "01.04.2040"
          assert_includes text, "bez PDV-a"
          fact = result.facts.find { |row| row.fetch("text").include?("2,34") }
          assert_equal "2040-04-01", fact.fetch("source_published_on")
          assert_equal "2040-04-09", fact.fetch("reviewed_on")
        end

        test "a blocked waste tariff is answered as blocked, never as a number" do
          result = ask("waste", "Koliko košta odvoz smeća mjesečno?")

          assert_equal "ok", result.status
          assert_includes result.warnings, "komunalac_tariff_is_a_scan"
          assert_includes result.warnings, "reviewed_amount_not_available"
          assert_equal false, result.validity.fetch("amount_available")
          text = result.facts.map { |fact| fact.fetch("text") }.join(" ")
          assert_includes text, "neću izmišljati iznos"
          assert_not_includes text, "9,99"
        end

        test "the stale komunalna naknada rates are not presented as current" do
          result = ask("city_service", "Kolika je komunalna naknada po kvadratu?")

          assert_equal "city_levies", result.coverage.fetch("biller")
          assert_includes result.warnings, "komunalna_naknada_rates_are_stale"
          text = result.facts.map { |fact| fact.fetch("text") }.join(" ")
          assert_includes text, "2039"
          assert_not_includes text, "8,888"
          assert_includes text, "SINTETIČKI KONTAKT"
        end

        test "the changed heating payment accounts carry their date" do
          result = ask("heating", "Na koji račun se plaća grijanje?")

          assert_equal "heating", result.coverage.fetch("biller")
          fact = result.facts.find { |row| row.fetch("text").include?("SINTETIČKA BANKA") }
          assert_equal "2040-04-08", fact.fetch("source_published_on")
          assert_includes fact.fetch("text"), "08.04.2040"
          assert_includes fact.fetch("warning_codes"), "payment_details_must_be_reread_at_source"
        end

        test "a price the provider does not publish is a blocker, not a silence" do
          heating = ask("heating", "Koliko košta grijanje po kvadratu?")
          electricity = ask("electricity", "Koliko je kWh struje?")

          assert_includes heating.warnings, "heating_tariff_is_a_scan"
          assert_equal false, heating.validity.fetch("amount_available")
          assert_includes heating.facts.map { |fact| fact.fetch("text") }.join(" "), "iznos ne mogu pročitati"
          assert_includes electricity.warnings, "electricity_price_not_published"
          assert_equal false, electricity.validity.fetch("amount_available")
          assert_includes electricity.facts.map { |fact| fact.fetch("text") }.join(" "), "Regulatorna komisija"
        end

        test "the busiest billing answer still carries the provider route" do
          # Personal waste bill: boundary, three published facts, the blocked
          # tariff, the route and the bank-account caveat. The route is the one
          # thing a truncated list must not lose.
          result = ask("waste", "Zašto mi je moj račun za smeće toliki i kome da se žalim?")

          assert_operator result.facts.size, :<=, 8
          assert_equal 8, result.facts.size, "the synthetic nine-fact input must exercise the cap"
          kinds = result.facts.map { |fact| fact.fetch("kind") }
          assert_includes kinds, "billing_next_step"
          assert_includes kinds, "billing_boundary"
          assert_includes result.facts.map { |fact| fact.fetch("text") }.join(" "), "IZMIŠLJENI KONTAKT ZA PRIGOVOR"
        end

        test "a billing answer is labelled as not being an outage answer" do
          assert_includes ask("electricity", "Kolika je zatezna kamata na račun?").warnings, "billing_is_not_an_outage_answer"
        end

        # ------------------------------------------------------------------
        # Heating network coverage
        # ------------------------------------------------------------------

        test "is-my-house-on-the-network is unmapped coverage, not a yes or a no" do
          result = ask("heating", "Da li je moja zgrada priključena na toplanu?")

          assert_equal "ok", result.status
          assert_includes result.warnings, "heating_network_footprint_not_published"
          assert_includes result.warnings, "coverage_unmapped"
          assert_equal "unmapped", result.coverage.fetch("status")
          assert_equal false, result.validity.fetch("household_coverage_known")
          text = result.facts.map { |fact| fact.fetch("text") }.join(" ")
          assert_includes text, "nije javno objavljen"
          assert_includes text, "SINTETIČKI KONTAKT"
          assert_no_match(/\bjeste\b|\bnije priključena\b/, text)
        end

        # ------------------------------------------------------------------
        # Boundaries
        # ------------------------------------------------------------------

        test "public reads are required for every added domain" do
          %w(waste water heating).each do |topic|
            result = port.call(action: "ask_information", topic:, entities: { "query" => "Gdje su kontejneri za staklo?" },
                               context: context(capabilities: []))
            assert_equal "not_authorized", result.status, topic
          end
        end

        test "a Cyrillic locale gets a Cyrillic reply from the same reviewed facts" do
          result = port.call(action: "ask_information", topic: "waste",
                             entities: { "query" => "Gdje su kontejneri za staklo i plastiku?" },
                             context: context(capabilities: ["public_reads"]), locale: "sr-Cyrl")

          assert_equal "ok", result.status
          assert_match(/[Ѐ-ӿ]/, result.facts.first.fetch("text"))
        end

        test "missing community data is unavailable across civic readers without other service facts" do
          CivicDomainFacts.send(:remove_const, :CONFIG_DIR)
          CivicDomainFacts.const_set(:CONFIG_DIR, "")
          CivicDomainFacts.reset!
          { "water" => "Koliko košta kubik vode?", "waste" => "Gdje su kontejneri za reciklažu?",
            "heating" => "Da li je moja zgrada priključena na toplanu?" }.each do |topic, query|
            result = ask(topic, query)
            assert_equal "unavailable", result.status
            assert_includes result.warnings, "reviewed_civic_facts_unavailable"
            assert_empty result.facts
          end
        end

        private

        def ask(topic, query)
          port.call(action: "ask_information", topic:, entities: { "query" => query },
                    context: context(capabilities: ["public_reads"]))
        end

        def port
          ReadPort.new(organization: @organization).tap do |reader|
            reader.define_singleton_method(:log_failure) { |error, _action| raise error }
          end
        end

        def context(capabilities: [])
          Decidim::Bih::Concierge::Dialogue::Contracts::TrustedContext.new(
            organization_id: @organization.id, conversation_key: "c" * 64, actor_id: nil,
            account_state: "anonymous", capabilities:, now: @now, deadline: nil
          )
        end
      end
    end
  end
end
