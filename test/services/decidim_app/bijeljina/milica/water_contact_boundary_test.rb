# frozen_string_literal: true

require "test_helper"
require "ostruct"
require "webmock/minitest"
require_relative "../../../../support/synthetic_service_directory"

module DecidimApp
  module Bijeljina
    module Milica
      class WaterContactBoundaryTest < ActiveSupport::TestCase
        include SyntheticServiceDirectory
        Dialogue = Decidim::Bih::Concierge::Dialogue
        CONTACT = "https://community.example.invalid/vodovod_servis"

        # Task-owned conversation fixture; no Redis, model or real message delivery.
        class Store
          attr_reader :state

          def initialize(context)
            @normalizer = Dialogue::StateStore.new
            reset(context)
          end

          def read(**) = @state
          def reset(context) = @state = @normalizer.empty_state(context)

          def write(context:, state:, expected_version:)
            return :conflict unless expected_version == @state.fetch("version")

            @state = @normalizer.send(:normalize_state, state.merge("version" => expected_version + 1), now: context.now)
            :saved
          end
        end

        setup do
          config = WebMock::Config.instance
          @webmock_config = %i(allow_net_connect allow_localhost allow net_http_connect_on_start).to_h { |key| [key, config.public_send(key)] }
          WebMock.disable_net_connect!
          install_synthetic_service_directory
          @organization = create_organization
          @context = Dialogue::Contracts::TrustedContext.new(
            organization_id: @organization.id, actor_id: nil, conversation_key: "c" * 64,
            capabilities: %w(public_reads report_guidance), now: Time.utc(2040, 9, 16, 10)
          )
          @store = Store.new(@context)
          @model_calls = 0
          client = Object.new
          owner = self
          client.define_singleton_method(:generate_content) do |**|
            owner.instance_variable_set(:@model_calls, owner.instance_variable_get(:@model_calls) + 1)
            raise "Unexpected model call for a deterministic water boundary"
          end
          runtime = Object.new
          runtime.define_singleton_method(:call) do |&block|
            OpenStruct.new(admitted?: true, value: block.call(Dialogue::TurnBudget.new(timeout: 9)))
          end
          @coordinator = ModelLedCoordinator.new(
            organization: @organization, client:, tools_factory: ->(**) { raise "Unexpected public model tools" },
            workflow: Object.new, state_store: @store, runtime:,
            accounting_factory: -> { ->(**, &block) { block.call } }
          )
        end

        teardown do
          restore_synthetic_service_directory
          WebMock.reset!
          @webmock_config.each { |key, prior| WebMock::Config.instance.public_send("#{key}=", prior) }
        end

        def ask(text, architecture:)
          message = Decidim::Bih::Concierge::WebMessage.new(text, trusted_context: @context)
          result = ConversationMemory.stub(:enabled?, false) { @coordinator.call(message:, context: @context) }
          assert_equal "answered", result.resolution
          assert_equal architecture, result.diagnostics.fetch("architecture")
          assert_equal 0, @model_calls
          result.reply.text
        end

        test "bill complaint and personal balance follow-up use the configured source without reading an account" do
          first = ask("Račun za vodu je pogrešan, kako da uložim reklamaciju?", architecture: "water_bill_contact_boundary")
          assert_includes first, CONTACT
          assert_includes first, "ne mogu pregledati tvoj račun niti poslati reklamaciju"
          assert_includes first, "broj računa ne šalji u chat"
          followup = ask("Koliko dugujem vodovodu?", architecture: "water_bill_contact_boundary")
          assert_includes followup, CONTACT
          assert_includes followup, "ne mogu vidjeti tvoj račun za vodu ni stanje duga"
        end

        test "water reporting contact and its follow-up never imply live channel availability or receipt" do
          first = ask("Koji je kontakt vodovoda da prijavim kvar?", architecture: "water_contact_boundary")
          assert_includes first, CONTACT
          assert_includes first, "Poruka meni u chatu nije prijava vodovodu"
          followup = ask("Je li ovaj kontakt provjeren?", architecture: "water_contact_boundary")
          assert_includes followup, CONTACT
          assert_includes followup, "Nemam potvrdu da je pojedini telefon ili kanal dostupan baš sada"
          assert_includes followup, "ne potvrđuje da je ranija prijava zaprimljena"
        end

        test "receipt boundary keeps the platform lookup route and makes no new report" do
          text = nil
          assert_no_difference("Decidim::Bih::Report.count") do
            text = ask("Možeš li potvrditi da je moja ranija prijava kvara zaprimljena?", architecture: "report_receipt_boundary")
          end
          assert_includes text, CONTACT
          assert_includes text, "Ne mogu iz ovog razgovora potvrditi"
          assert_includes text, Decidim::Bih.public_url("prijave-pronadji", base_url: "https://#{@organization.host}")
          assert_includes text, "Sama poruka u chatu nije potvrda prijema"
        end

        test "water safety keeps the evidence limitation and never treats service notices as quality proof" do
          first = ask("Da li je voda zdravstveno ispravna za piće?", architecture: "water_safety_boundary")
          assert_includes first, CONTACT
          assert_includes first, "Ne mogu potvrditi zdravstvenu ispravnost vode"
          assert_includes first, "servisne objave i analiza kvaliteta su različite provjere"
          followup = ask("Šta ti nedostaje za potvrdu ispravnosti vode?", architecture: "water_safety_boundary")
          assert_includes followup, CONTACT
          assert_includes followup, "aktuelan nalaz kvaliteta vode"
        end

        test "all four boundaries stay useful without a configured water entry and never inherit a contact" do
          swap_service_constant(CityServicesData, :ENTRIES, [].freeze)
          CityDirectory.instance_variable_set(:@directory, Decidim::Bih::City::ServiceDirectory.new([]))
          [
            ["Račun za vodu je pogrešan, kome da pošaljem reklamaciju?", "water_bill_contact_boundary"],
            ["Koji je kontakt vodovoda da prijavim kvar?", "water_contact_boundary"],
            ["Potvrdi da je moja ranija prijava kvara zaprimljena.", "report_receipt_boundary"],
            ["Da li je voda zdravstveno ispravna za piće?", "water_safety_boundary"]
          ].each do |question, architecture|
            @store.reset(@context)
            text = ask(question, architecture:)
            assert_includes text, "trenutno nisu dostupni za ovu zajednicu"
            assert_no_match(/https?:\/\/(?!#{Regexp.escape(@organization.host)})/, text)
            assert_no_match(/@[a-z0-9.-]+\.[a-z]{2,}|\+387/, text)
          end
        end

        test "unreviewed future wrong-identity and unapproved URLs never become a contact" do
          entry = CityDirectory.for(@organization).find(:vodovod_servis)
          [
            { verification_scope: "unreviewed" }, { source_checked_on: "2041-01-01" },
            { key: :parking }, { source_url: "https://other.example.invalid/contact" },
            { source_url: "https://user:secret@community.example.invalid/contact" },
            { source_url: "file:///tmp/synthetic-contact" }
          ].each do |changes|
            directory = Object.new
            row = entry.merge(changes)
            directory.define_singleton_method(:find) { |_| row }
            CityDirectory.stub(:for, ->(organization) { assert_equal @organization, organization; directory }) do
              text = @coordinator.send(:reviewed_water_contact_guidance, context: @context, locale: "sr")
              assert_includes text, "trenutno nisu dostupni za ovu zajednicu"
              assert_no_match(/https?:|file:/, text)
            end
          end
        end

        test "the real typed reader rejects a different organization context" do
          foreign = @context.with(organization_id: @organization.id + 1)
          assert_raises(Dialogue::Contracts::Invalid) do
            @coordinator.send(:reviewed_water_contact_guidance, context: foreign, locale: "sr")
          end
        end

        test "a context without public read permission never receives the configured contact" do
          no_reads = @context.with(capabilities: %w(report_guidance))
          text = @coordinator.send(:reviewed_water_contact_guidance, context: no_reads, locale: "sr")
          assert_includes text, "trenutno nisu dostupni za ovu zajednicu"
          assert_not_includes text, CONTACT
        end
      end
    end
  end
end
