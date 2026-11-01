# frozen_string_literal: true

require "test_helper"
require "webmock/minitest"
require_relative "../../../support/synthetic_conversation_data"
require_relative "../../../support/synthetic_procedures"

module DecidimApp
  module Bijeljina
    class MilicaPreparedReadContractTest < ActiveSupport::TestCase
      include SyntheticConversationData
      include SyntheticProcedures
      Dialogue = Decidim::Bih::Concierge::Dialogue
      NOW = Time.utc(2040, 9, 9, 12)

      setup do
        config = WebMock::Config.instance
        @webmock_config = %i(allow_net_connect allow_localhost allow net_http_connect_on_start).to_h { |key| [key, config.public_send(key)] }
        WebMock.disable_net_connect!
        travel_to NOW
        install_synthetic_conversation_data(day: NOW.to_date)
        install_synthetic_procedures(day: NOW.to_date)
        sources = CityServiceSources::SOURCES.map do |row|
          row.merge(source_url: "https://#{row.fetch(:key).tr('_', '-')}.example.invalid/source").freeze
        end
        swap_service_constant(CityServiceSources, :SOURCES, sources.freeze)
        @organization = create_organization
        @context = Dialogue::Contracts::TrustedContext.new(organization_id: @organization.id, conversation_key: "e" * 64,
                                                           now: NOW, capabilities: ["public_reads"])
        @port = Milica::ReadPort.new(organization: @organization)
      end

      teardown do
        restore_synthetic_procedures
        restore_synthetic_service_directory
        travel_back
        WebMock.reset!
        @webmock_config.each { |key, value| WebMock::Config.instance.public_send("#{key}=", value) }
      end

      test "every new reader family crosses host dispatch and engine rendering with source and effective dates intact" do
        [
          ["air_quality", Milica::SourceRead, {}],
          ["budget", Milica::ReferenceRead, {}],
          ["volunteer", Milica::PlatformCatalogRead, {}],
          ["public_calls", Milica::PublicCallsReader, {}],
          ["city_service", Milica::ProcedureRead, { "query" => "matičar" }]
        ].each do |topic, adapter_class, entities|
          calls = []
          adapter = Object.new
          adapter.define_singleton_method(:call) do |**arguments|
            calls << arguments
            {
              status: "ok", checked_at: NOW.iso8601, source: { "id" => "prepared_source", "label" => "Prepared source", "url" => "https://prepared.example.invalid/" },
              facts: [{ "id" => "prepared:#{topic}", "kind" => "public_fact", "text" => "Prepared #{topic} fixture", "source_id" => "prepared_source",
                        "validity" => { "starts_at" => "2040-09-10", "ends_at" => "2040-09-30" }, "reviewed_on" => "2040-09-08" }],
              warnings: ["eligibility_must_be_checked_in_official_call"]
            }
          end
          adapter_class.stub(:new, ->(**) { adapter }) do
            runner = Dialogue::ProcedureRunner.new(read_port: @port, registration_port: ->(**) { raise "unexpected registration" },
                                                   destinations: { account: "/nalog", report: "/prijavi", neighborhood: "/komsiluk", support: "/pomoc" })
            understanding = Dialogue::Contracts::Understanding.parse(action: "ask_information", topic:, entities:, operation: "start",
                                                                     locale: "sr", needs_clarification: false, secondary: nil)
            result = runner.call(understanding:, context: @context, state: Dialogue::StateStore.new.empty_state(@context), message: "Prikaži javne podatke")
            assert_equal "answered", result.resolution, topic
            assert_equal 1, calls.size, topic
            assert_includes result.reply.text, "Prepared #{topic} fixture"
            assert_includes result.reply.text, Dialogue::TimeText.call("2040-09-30", locale: "sr", now: NOW)
            assert_includes result.reply.text, "Prepared source"
            assert_includes result.reply.text, I18n.t("decidim.bih.dialogue.read_warning_eligibility", locale: "sr")
            assert_nil result.reply.report
          end
        end
      end

      test "new typed source and catalogue routes preserve unavailable and unreviewed states instead of inventing facts" do
        %w(unavailable unreviewed stale empty).each do |status|
          adapter = Object.new
          adapter.define_singleton_method(:call) { |**| { status:, warnings: ["source_not_current"] } }
          Milica::PublicCallsReader.stub(:new, ->(**) { adapter }) do
            result = @port.call(action: "ask_information", topic: "public_calls", entities: {}, context: @context, locale: "sr")
            assert_equal status, result.status
            assert_empty result.facts
          end
        end
      end

      test "public read capability is checked before entering any new reader" do
        context = @context.with(capabilities: [])
        Milica::SourceRead.stub(:new, ->(**) { raise "adapter entered without capability" }) do
          result = @port.call(action: "ask_information", topic: "air_quality", entities: {}, context:, locale: "sr")
          assert_equal "not_authorized", result.status
          assert_empty result.facts
        end
      end

      test "a date-only historical service fact reaches the renderer with its effective day and no claim of restored service" do
        area = Decidim::Bih::LocalArea.create!(organization: @organization, kind: "mz", slug: "mz-date-contract", name: { "sr" => "Datum" })
        zone = Time.find_zone!("Europe/Sarajevo")
        CityServiceEvent.create!(organization: @organization, source_key: "water_service", source_label: "Izmišljeni vodovod",
                                 source_fingerprint: "date-only-contract", source_url: CityServiceSources.fetch("water_service").fetch(:source_url),
                                 event_type: "planned_interruption", severity: "service_outage", targeting_level: "mz",
                                 affected_area_slugs: [area.slug], title: "Obavještenje o radovima", summary: "Najavljen prekid vodosnabdijevanja.",
                                 starts_at: zone.local(2040, 9, 8), ends_at: zone.local(2040, 9, 9), fetched_at: NOW,
                                 state: "published", lifecycle: "scheduled", parser_version: "fixture",
                                 extraction_metadata: { "temporal_precision" => "day", "coverage" => { "status" => "resolved" } })
        entities = { "area_query" => "Datum", "date" => "2040-09-08" }
        read = @port.call(action: "ask_information", topic: "water", entities:, context: @context, locale: "sr")
        assert_equal "ok", read.status
        assert_equal "2040-09-08", read.facts.sole.dig("validity", "date")
        assert_nil read.facts.sole["starts_at"]
        assert_nil read.facts.sole["ends_at"]
        assert_includes read.warnings, "planned_end_not_confirmed_restoration"

        runner = Dialogue::ProcedureRunner.new(read_port: @port, registration_port: ->(**) { raise "unexpected registration" },
                                               destinations: { account: "/nalog", report: "/prijavi", neighborhood: "/komsiluk", support: "/pomoc" })
        understanding = Dialogue::Contracts::Understanding.parse(action: "ask_information", topic: "water", entities:, operation: "start",
                                                                 locale: "sr", needs_clarification: false, secondary: nil)
        result = runner.call(understanding:, context: @context, state: Dialogue::StateStore.new.empty_state(@context), message: "Voda u MZ Datum 2040-09-08")
        assert_equal "answered", result.resolution
        assert_includes result.reply.text, I18n.t("decidim.bih.dialogue.fact_service_day", locale: "sr", time: Dialogue::TimeText.call("2040-09-08", locale: "sr", now: NOW))
        assert_includes result.reply.text, I18n.t("decidim.bih.dialogue.read_warning_planned_end", locale: "sr")
      end

      test "Latin Cyrillic and ASCII tomorrow water questions resolve the same actual local service window" do
        area = Decidim::Bih::LocalArea.create!(organization: @organization, kind: "mz", slug: "mz-izmisljeno-polje", name: { "sr" => "Izmišljeno polje", "sr-Cyrl" => "Измишљено поље" })
        zone = Time.find_zone!("Europe/Sarajevo")
        event = CityServiceEvent.create!(organization: @organization, source_key: "water_service", source_label: "Izmišljeni vodovod",
                                         source_fingerprint: "tomorrow-water-contract", source_url: CityServiceSources.fetch("water_service").fetch(:source_url),
                                         event_type: "planned_interruption", severity: "service_outage", targeting_level: "mz", affected_area_slugs: [area.slug],
                                         title: "Radovi u Izmišljenom polju", summary: "Planirani prekid vodosnabdijevanja.",
                                         starts_at: zone.local(2040, 9, 10, 8), ends_at: zone.local(2040, 9, 10, 14), fetched_at: NOW,
                                         state: "published", lifecycle: "scheduled", parser_version: "fixture")
        runner = Dialogue::ProcedureRunner.new(read_port: @port, registration_port: ->(**) { raise "unexpected registration" },
                                               destinations: { account: "/nalog", report: "/prijavi", neighborhood: "/komsiluk", support: "/pomoc" })
        [
          ["bs", "Izmišljeno polje", "sutra", "Ima li vode u Izmišljenom polju sutra?"],
          ["sr-Cyrl", "Измишљено поље", "сутра", "Има ли воде у Измишљеном пољу сутра?"],
          ["sr", "Izmišljeno polje", "sutra", "Ima li prekida vodosnabdijevanja u Izmišljenom polju sutra?"]
        ].each do |locale, area_query, time_expression, message|
          entities = { "area_query" => area_query, "time_expression" => time_expression }
          read = @port.call(action: "ask_information", topic: "water", entities:, context: @context, locale:)
          assert_equal "ok", read.status, locale
          assert_equal ["service_event:#{event.id}"], read.facts.map { |fact| fact.fetch("id") }, locale
          assert_equal zone.local(2040, 9, 10), Time.iso8601(read.validity.fetch("starts_at")), locale
          assert_equal zone.local(2040, 9, 11), Time.iso8601(read.validity.fetch("ends_at")), locale
          understanding = Dialogue::Contracts::Understanding.parse(action: "ask_information", topic: "water", entities:, operation: "start",
                                                                   locale:, needs_clarification: false, secondary: nil)
          result = runner.call(understanding:, context: @context, state: Dialogue::StateStore.new.empty_state(@context), message:)
          assert_equal "answered", result.resolution, locale
          assert_equal ["service_event:#{event.id}"], result.fact_ids, locale
          assert_includes result.reply.text, Dialogue::TimeText.call(zone.local(2040, 9, 10, 8), locale: locale, now: NOW), locale
        end
      end
    end
  end
end
