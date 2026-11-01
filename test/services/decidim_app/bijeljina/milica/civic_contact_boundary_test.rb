# frozen_string_literal: true

require "test_helper"
require "ostruct"
require "json"
require "webmock/minitest"
require_relative "../../../../support/synthetic_civic_contacts"
require_relative "../../../../support/synthetic_public_call_snapshot"
require_relative "../../../../support/synthetic_procedures"
require_relative "../../../../support/synthetic_gazette_acts"
require_relative "../../../../support/synthetic_weather_region"

module DecidimApp
  module Bijeljina
    module Milica
      class CivicContactBoundaryTest < ActiveSupport::TestCase
        include SyntheticCivicContacts
        include SyntheticPublicCallSnapshot
        include SyntheticProcedures
        include SyntheticGazetteActs
        include SyntheticWeatherRegion
        Dialogue = Decidim::Bih::Concierge::Dialogue

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
          install_synthetic_civic_contacts
          @prior_budget_env = %w(MI_BUDGET_SOURCE_URL MI_BUDGET_HEADLINE_TOTAL MI_BUDGET_TABLE_PAGE MI_GAZETTE_SOURCE_URL).to_h { |key| [key, ENV[key]] }
          @prior_campaign_path = ENV["MI_BULKY_WASTE_CAMPAIGNS_PATH"]
          ENV.delete("MI_BULKY_WASTE_CAMPAIGNS_PATH")
          swap_service_constant(CivicDomainFacts, :REVIEWED_HOSTS, ["community.example.invalid"].freeze)
          @organization = create_organization
          @context = Dialogue::Contracts::TrustedContext.new(
            organization_id: @organization.id, actor_id: nil, conversation_key: "c" * 64,
            capabilities: %w(public_reads report_guidance), now: Time.utc(2040, 9, 16, 10),
            deadline: Dialogue::TurnBudget.new(timeout: 9)
          )
          @store = Store.new(@context)
          @model_calls = 0
          client = Object.new
          owner = self
          client.define_singleton_method(:generate_content) do |**|
            owner.instance_variable_set(:@model_calls, owner.instance_variable_get(:@model_calls) + 1)
            raise "Unexpected model call for a deterministic civic boundary"
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
          @prior_campaign_path ? ENV["MI_BULKY_WASTE_CAMPAIGNS_PATH"] = @prior_campaign_path : ENV.delete("MI_BULKY_WASTE_CAMPAIGNS_PATH")
          @prior_budget_env.each { |key, prior| prior.nil? ? ENV.delete(key) : ENV[key] = prior }
          restore_synthetic_civic_contacts
          WebMock.reset!
          @webmock_config.each { |key, prior| WebMock::Config.instance.public_send("#{key}=", prior) }
        end

        def ask(text, architecture:, resolution: "answered")
          message = Decidim::Bih::Concierge::WebMessage.new(text, trusted_context: @context)
          result = ConversationMemory.stub(:enabled?, false) { @coordinator.call(message:, context: @context) }
          assert_equal resolution, result.resolution
          assert_equal architecture, result.diagnostics.fetch("architecture")
          assert_equal 0, @model_calls
          result.reply.text
        end

        def guidance(key, details:, context: @context, locale: "sr")
          @coordinator.send(:reviewed_service_contact_guidance, key:, details:, context:, locale:)
        end

        def seed_public_subject(subject)
          state = @store.state
          captured = Dialogue::AnswerContext.capture(kind: "public_card", subject:, anchor: "synthetic-contact-context",
                                                     now: @context.now, state_expires_at: state.fetch("expires_at"))
          assert_equal :saved, @store.write(context: @context, state: state.merge(Dialogue::AnswerContext::KEY => captured),
                                            expected_version: state.fetch("version"))
        end

        def install_budget(amount: "12.345,00", year: 2040)
          owner = DecidimApp::Bijeljina::Budget
          present = owner.instance_variable_defined?(:@default)
          @synthetic_service_caches << [owner, :@default, present, owner.instance_variable_get(:@default)]
          owner.remove_instance_variable(:@default) if present
          path = File.join(@synthetic_service_root, "authored-budget-conversation.txt")
          File.write(path, "IZMIŠLJENI BUDŽET ZA #{year}. GODINU\nИзмишљени центар за социјални рад #{amount}\nИзмишљени музеј 23.456,00\nУКУПНО 999.999,00\n")
          { BUNDLED_TEXT_PATH: path, YEAR: year, SOURCE_CAPTURED_ON: Date.new(2040, 9, 14) }.each do |name, value|
            swap_service_constant(owner, name, value)
          end
          ENV["MI_BUDGET_SOURCE_URL"] = "https://community.example.invalid/authored-budget.pdf"
          ENV["MI_BUDGET_HEADLINE_TOTAL"] = "999999.00"
          ENV["MI_BUDGET_TABLE_PAGE"] = "8"
        end

        test "social work budget uses own reviewed year allocation source and page" do
          install_budget
          text = ask("Koliko je u budžetu za 2040. za Centar za socijalni rad?", architecture: "social_work_budget_2026")
          assert_includes text, "12.345,00 KM"
          assert_includes text, "plan za 2040"
          assert_includes text, "authored-budget.pdf, strana 8"
          assert_includes text, "Pregledano 2040-09-14"
          assert_includes text, "nije isto što i ukupan iznos socijalne zaštite"
          assert_includes text, "ne potvrđuje tvoje pravo na pomoć"
          assert_not_includes text, "4.153.400"
          assert_not_includes text, "Bijeljina"
        end

        test "social budget followup rereads allocation and never promotes a plan to spending" do
          install_budget
          ask("Koliki je budžet za socijalni rad 2040?", architecture: "social_work_budget_2026")
          install_budget(amount: "67.890,00")
          text = ask("Da li je taj iznos potrošen?", architecture: "social_work_budget_2026")
          assert_includes text, "67.890,00 KM"
          assert_not_includes text, "12.345,00 KM"
          assert_includes text, "nije podatak o izvršenoj potrošnji"
          assert_includes text, "isplatu"
          assert_includes @store.state.dig(Dialogue::AnswerContext::KEY, "anchor"), "2040"
        end

        test "total budget uses explicit headline and never the partial line sum" do
          install_budget
          text = ask("Koliki je ukupni budžet za 2040?", architecture: "city_budget_total")
          assert_includes text, "999.999,00 KM"
          assert_not_includes text, "35.801,00 KM"
          assert_includes text, "ne predstavljaju zbir svih budžetskih stavki"
          assert_includes text, "authored-budget.pdf"
          assert_not_includes text, "98.610.220"
        end

        test "total budget without reviewed headline does not turn parser output into a grand total" do
          install_budget
          ENV.delete("MI_BUDGET_HEADLINE_TOTAL")
          text = ask("Koliki je ukupni budžet za 2040?", architecture: "city_budget_total")
          assert_includes text, "Ukupan budžet nije zasebno potvrđen"
          assert_includes text, "ne sabiram izdvojene stavke"
          assert_not_includes text, "999.999,00 KM"
          assert_not_includes text, "35.801,00 KM"
        end

        test "another fiscal year followup never inherits either a total or a social allocation" do
          install_budget
          [["Koliki je ukupni budžet za 2040?", "city_budget_total"],
           ["Koliki je budžet za socijalni rad 2040?", "social_work_budget_2026"]].each do |question, architecture|
            @store.reset(@context)
            ask(question, architecture:)
            text = ask("A za 2041?", architecture:)
            assert_includes text, "Nemam dostupan pregledani budžetski podatak"
            assert_includes text, "ne znači da je budžet nula"
            assert_not_includes text, "999.999,00 KM"
            assert_not_includes text, "12.345,00 KM"
            assert_includes @store.state.dig(Dialogue::AnswerContext::KEY, "anchor"), "2041"
          end
        end

        test "switch from social allocation to headline keeps the requested year across source changes" do
          install_budget
          ask("Koliki je budžet za socijalni rad 2040?", architecture: "social_work_budget_2026")
          install_budget(year: 2041)
          text = ask("A koliki je ukupni budžet?", architecture: "city_budget_total")
          assert_includes text, "Nemam dostupan pregledani budžetski podatak"
          assert_not_includes text, "999.999,00 KM"
          assert_includes @store.state.dig(Dialogue::AnswerContext::KEY, "anchor"), "2040"
        end

        test "budget conversation without configured source states unavailable without a local fallback" do
          install_budget
          ENV.delete("MI_BUDGET_SOURCE_URL")
          text = ask("Koliki je ukupni budžet za 2040?", architecture: "city_budget_total")
          assert_includes text, "Nemam dostupan pregledani budžetski podatak"
          assert_not_includes text, "999.999"
          assert_not_includes text, "bijeljina"
        end

        test "budget guidance respects public read capability before exposing amounts" do
          install_budget
          denied = Dialogue::Contracts::TrustedContext.new(organization_id: @organization.id,
            conversation_key: "d" * 64, capabilities: [], now: @context.now, deadline: Dialogue::TurnBudget.new)
          message = Decidim::Bih::Concierge::WebMessage.new("Ukupni budžet za 2040?", trusted_context: denied)
          text = @coordinator.send(:reviewed_budget_guidance, message:, state: @store.state, context: denied, locale: "sr")
          assert_includes text, "Nemam dostupan pregledani budžetski podatak"
          assert_not_includes text, "999.999"
        end

        test "social allocation with no reviewed page never inherits the old page number" do
          install_budget
          ENV.delete("MI_BUDGET_TABLE_PAGE")
          text = ask("Koliki je budžet za socijalni rad 2040?", architecture: "social_work_budget_2026")
          assert_includes text, "12.345,00 KM"
          assert_includes text, "authored-budget.pdf"
          assert_not_includes text, "strana 17"
          assert_not_includes text, "strana 8"
        end

        def install_gazette(content_hash: SyntheticGazetteActs::ISSUE_HASH, reviewed_on: Date.new(2040, 9, 14))
          host = DecidimApp::Bijeljina
          [[host::GazetteActs, :@all], [host::Gazette, :@index], [host::Gazette, :@revision]].each do |owner, name|
            present = owner.instance_variable_defined?(name)
            @synthetic_service_caches << [owner, name, present, owner.instance_variable_get(name)]
            owner.remove_instance_variable(name) if present
          end
          host::GazetteActs.instance_variable_set(:@all, synthetic_gazette_acts.freeze)
          entry = { number: SyntheticGazetteActs::ISSUE_NUMBER, title: "Izmišljeni glasnik",
                    date: "14. септембра 2040. године", url: "https://community.example.invalid/authored-issue.pdf",
                    summary: "IZMIŠLJENO IZDANJE", content_hash:, source_checked_on: reviewed_on&.iso8601,
                    source_pdf_pages: [1] }.freeze
          { ENTRIES: [entry].freeze, BASE: "https://community.example.invalid/authored-gazette",
            SOURCE_CAPTURED_ON: reviewed_on }.each { |name, value| swap_service_constant(host::GazetteData, name, value) }
          ENV["MI_GAZETTE_SOURCE_URL"] = "https://community.example.invalid/authored-gazette"
        end

        test "reviewed act conversation preserves own identifier dates pages and unverified current law" do
          install_gazette
          text = ask("Koja je odluka TEST-ACT-2040-A u glasniku?", architecture: "gazette_reviewed_act")
          assert_includes text, "TEST-ACT-2040-A"
          assert_includes text, "Donesena 2040-03-02, objavljena 2040-03-09"
          assert_includes text, "stupanje na snagu: 2040-03-10"
          assert_includes text, "Pregledane stranice: 3"
          assert_includes text, "authored-issue.pdf#page=3"
          assert_includes text, "sadašnje važenje nisu potvrđeni"
          assert_not_includes text, "Sokolskog"
          assert_not_includes text, "LER-02/26"
        end

        test "act legal status followup rereads exact revision instead of repeating stale prose" do
          install_gazette
          ask("Koja je odluka TEST-ACT-2040-A u glasniku?", architecture: "gazette_reviewed_act")
          install_gazette(content_hash: "b" * 64)
          text = ask("Da li je još važeća bez izmjena?", architecture: "gazette_reviewed_act")
          assert_includes text, "Nemam dostupan pojedinačno pregledani akt"
          assert_not_includes text, "TEST-ACT-2040-A"
          assert_not_includes text, "2040-03-10"
          assert_includes text, "ne potvrđuju da odluka danas važi bez izmjena"
        end

        test "act conversation without a reviewed index is unavailable without raising or local fallback" do
          install_gazette(reviewed_on: nil)
          text = ask("Koja je odluka TEST-ACT-2040-A u glasniku?", architecture: "gazette_reviewed_act")
          assert_includes text, "Nemam dostupan pojedinačno pregledani akt"
          assert_not_includes text, "TEST-ACT-2040-A"
          assert_not_includes text, "authored-issue.pdf"
        end

        test "archive conversation uses own source and partial entries without fixed count or city" do
          install_gazette
          text = ask("Gdje mogu pronaći glasnik za 2040?", architecture: "gazette_archive_boundary")
          assert_includes text, "https://community.example.invalid/authored-gazette"
          assert_includes text, "2040-09-14"
          assert_includes text, "01/2040"
          assert_includes text, "authored-issue.pdf"
          assert_includes text, "nije potpuna arhiva"
          assert_not_includes text, "Bijeljina"
          assert_not_includes text, "2026"
        end

        test "archive missing act followup never becomes proof of nonadoption" do
          install_gazette
          ask("Gdje mogu pronaći glasnik?", architecture: "gazette_archive_boundary")
          text = ask("Ako odluke nema u indeksu, da li nije usvojena?", architecture: "gazette_archive_boundary")
          assert_includes text, "01/2040"
          assert_includes text, "ne dokazuje da nije usvojena"
          assert_includes text, "nije potpuna arhiva"
        end

        test "changed archive publisher cannot borrow the old local reviewed catalog" do
          install_gazette
          ask("Gdje mogu pronaći glasnik?", architecture: "gazette_archive_boundary")
          ENV["MI_GAZETTE_SOURCE_URL"] = "https://other-publisher.example.invalid/archive"
          text = ask("Ako odluke nema u indeksu?", architecture: "gazette_archive_boundary")
          assert_includes text, "arhiva trenutno nije dostupna"
          assert_not_includes text, "authored-gazette"
          assert_not_includes text, "authored-issue.pdf"
          assert_not_includes text, "01/2040"
        end

        test "future archive review cannot supply a reviewed act or archive answer" do
          install_gazette(reviewed_on: Date.new(2040, 9, 17))
          text = ask("Koja je odluka TEST-ACT-2040-A u glasniku?", architecture: "gazette_reviewed_act")
          assert_includes text, "Nemam dostupan pojedinačno pregledani akt"
          @store.reset(@context)
          text = ask("Gdje mogu pronaći glasnik?", architecture: "gazette_archive_boundary")
          assert_includes text, "arhiva trenutno nije dostupna"
          assert_not_includes text, "01/2040"
        end

        def with_public_support(name: "Autorski operater", email: "support@example.invalid", website: "https://community.example.invalid/support")
          settings = Decidim::Bih
          prior = %i(public_support_name public_support_email public_support_website).to_h { |key| [key, settings.public_send(key)] }
          settings.public_support_name = name
          settings.public_support_email = email
          settings.public_support_website = website
          yield
        ensure
          prior&.each { |key, value| settings.public_send("#{key}=", value) }
        end

        test "platform support uses own explicit operator contact without claiming municipal service or submission" do
          with_public_support do
            text = ask("Kako da kontaktiram podršku MI platforme?", architecture: "platform_support_contact")
            assert_includes text, "Autorski operater"
            assert_includes text, "support@example.invalid"
            assert_includes text, "https://community.example.invalid/support"
            assert_includes text, "ne kontakt gradske komunalne službe"
            assert_includes text, "nije poslao zahtjev podršci"
            assert_not_includes text, "fondacijabijeljina.com"
          end
        end

        test "missing platform support never inherits a Foundation contact" do
          with_public_support(name: nil, email: nil, website: nil) do
            text = ask("Kako da kontaktiram podršku MI platforme?", architecture: "platform_support_contact")
            assert_includes text, "kontakt operatera ove instalacije trenutno nije podešen"
            assert_not_includes text, "fondacijabijeljina.com"
            assert_not_includes text, "contactus"
          end
        end

        test "partial support configuration exposes only valid configured channels" do
          with_public_support(email: "not-an-email") do
            text = ask("Kako da kontaktiram podršku MI platforme?", architecture: "platform_support_contact")
            assert_includes text, "https://community.example.invalid/support"
            assert_not_includes text, "not-an-email"
            assert_not_includes text, "E-mail:"
          end
        end

        test "platform support followup rereads operator contact after configuration changes" do
          with_public_support do
            ask("Kako da kontaktiram podršku MI platforme?", architecture: "platform_support_contact")
            Decidim::Bih.public_support_email = "new-support@example.invalid"
            Decidim::Bih.public_support_website = nil
            text = ask("Koji je kontakt?", architecture: "platform_support_contact")
            assert_includes text, "new-support@example.invalid"
            assert_not_includes text, "https://community.example.invalid/support"
          end
        end

        test "public content removal uses own operator and policy without claiming deletion or sending" do
          with_public_support do
            text = ask("Kome da pišem za brisanje javne objave?", architecture: "public_content_removal_guidance")
            assert_includes text, "support@example.invalid"
            assert_includes text, "#{@organization.host}/biceriseno/pages/privacy-policy"
            assert_includes text, "nisam poslala zahtjev niti uklonila objavu"
            assert_includes text, "ne kroz ovaj chat"
            assert_not_includes text, "fondacijabijeljina.com"
          end
        end

        test "public content removal with no operator contact cannot invent a channel" do
          with_public_support(name: nil, email: nil, website: nil) do
            text = ask("Kome da pišem za brisanje javne objave?", architecture: "public_content_removal_guidance")
            assert_includes text, "kontakt operatera ove instalacije trenutno nije podešen"
            assert_includes text, "nisam poslala zahtjev niti uklonila objavu"
            assert_not_includes text, "office@"
          end
        end

        test "donation aggregate receipt boundary uses own operator without exposing personal payment fields" do
          with_public_support do
            text = ask("Da li zbir donacija potvrđuje moju pojedinačnu uplatu?", architecture: "donation_aggregate_receipt_boundary")
            assert_includes text, "ne potvrđuje tvoju pojedinačnu uplatu"
            assert_includes text, "potvrdu platnog servisa ili banke"
            assert_includes text, "support@example.invalid"
            assert_includes text, "ne šalji broj računa"
            assert_not_includes text, "fondacijabijeljina.com"
          end
        end

        test "donation receipt guidance without configured operator contact keeps payment limitation" do
          with_public_support(name: nil, email: nil, website: nil) do
            text = ask("Da li zbir donacija potvrđuje moju pojedinačnu uplatu?", architecture: "donation_aggregate_receipt_boundary")
            assert_includes text, "kontakt operatera ove instalacije trenutno nije podešen"
            assert_includes text, "ne potvrđuje tvoju pojedinačnu uplatu"
            assert_not_includes text, "fondacijabijeljina.com"
          end
        end

        def with_material_catalog
          prior = @coordinator.instance_variable_get(:@tools_factory)
          @coordinator.instance_variable_set(:@tools_factory, ->(**) { ConversationTools.new(organization: @organization, clock: -> { Time.current }) })
          travel_to @context.now do
            yield
          end
        ensure
          @coordinator.instance_variable_set(:@tools_factory, prior)
        end

        def material_owner(organization: @organization, **changes)
          Decidim::Bih::PartnerProfile.create!(organization:, display_name: "Autorska organizacija",
            slug: "authored-material-#{SecureRandom.hex(4)}", kind: "association",
            verification_status: "verified", verified_at: @context.now - 1.hour, **changes)
        end

        def material_need(owner, **changes)
          # As in the catalogue's moderation fixtures, bypass the author form
          # to independently exercise public approval/publication filtering.
          row = Decidim::Bih::ContributionNeed.new(organization: owner.organization, partner_profile: owner,
            need_type: "equipment", title: "AUTORSKA JAVNA POTREBA", description: "Autorski javni opis potrebe.",
            quantity: 1, unit: "kom", review_status: "approved", fulfillment_status: "open",
            published_at: @context.now - 1.hour, needed_by: @context.now.to_date + 2, **changes)
          row.save!(validate: false)
          row
        end

        test "material catalogue uses current approved tenant records without exposing draft closed or foreign needs" do
          with_material_catalog do
            owner = material_owner
            visible = material_need(owner)
            material_need(owner, title: "AUTHORED_DRAFT_MARKER", published_at: nil)
            material_need(owner, title: "AUTHORED_CLOSED_MARKER", fulfillment_status: "fulfilled")
            material_need(owner, title: "AUTHORED_FUTURE_MARKER", published_at: @context.now + 1.day)
            material_need(material_owner(verification_status: "suspended"), title: "AUTHORED_SUSPENDED_MARKER")
            material_need(material_owner(organization: create_organization), title: "AUTHORED_FOREIGN_MARKER")
            text = ask("Koje su javne materijalne potrebe?", architecture: "material_support_catalog")
            assert_includes text, visible.title
            assert_includes text, @organization.host
            %w(AUTHORED_DRAFT_MARKER AUTHORED_CLOSED_MARKER AUTHORED_FUTURE_MARKER AUTHORED_SUSPENDED_MARKER AUTHORED_FOREIGN_MARKER).each { |marker| assert_not_includes text, marker }
            assert_includes text, "kontakt iz same objave"
            assert_includes text, "nije evidentirana donacija"
            assert_includes text, "Nisam poslala ponudu niti potvrdila prihvatanje"
            assert_not_includes text, "fondacijabijeljina.com"
          end
        end

        test "empty material catalogue offers only the configured public operator without promising acceptance" do
          with_material_catalog do
            with_public_support do
              text = ask("Koje su javne materijalne potrebe?", architecture: "material_support_catalog")
              assert_includes text.downcase, "u trenutno pregledanom"
              assert_includes text, "support@example.invalid"
              assert_includes text, "https://community.example.invalid/support"
              assert_includes text, "nije potvrda da operater prima ili prihvata materijal"
              assert_not_includes text, "Lokalnoj fondaciji"
              assert_not_includes text, "fondacijabijeljina.com"
            end
          end
        end

        test "empty material catalogue with no support channel invents no Foundation fallback" do
          with_material_catalog do
            with_public_support(name: nil, email: nil, website: nil) do
              text = ask("Koje su javne materijalne potrebe?", architecture: "material_support_catalog")
              assert_includes text, "kontakt operatera ove instalacije trenutno nije podešen"
              assert_includes text, "nije evidentirana donacija"
              assert_not_includes text, "fondacijabijeljina.com"
              assert_not_includes text, "office@"
            end
          end
        end

        test "material offer followup rereads newly published and later fulfilled needs" do
          with_material_catalog do
            with_public_support do
              ask("Koje su javne materijalne potrebe?", architecture: "material_support_catalog")
              need = material_need(material_owner)
              text = ask("Mogu li ponuditi opremu bez novca?", architecture: "material_support_offer_boundary")
              assert_includes text, need.title
              assert_not_includes text, "nisam našla otvorenu"
              need.update_columns(fulfillment_status: "fulfilled")
              text = ask("Mogu li ponuditi opremu bez novca?", architecture: "material_support_offer_boundary")
              assert_not_includes text, need.title
              assert_includes text, "nisam našla otvorenu"
            end
          end
        end

        test "material offer followup rereads support changes instead of carrying an earlier contact" do
          with_material_catalog do
            with_public_support do
              ask("Koje su javne materijalne potrebe?", architecture: "material_support_catalog")
              Decidim::Bih.public_support_email = "changed-support@example.invalid"
              Decidim::Bih.public_support_website = nil
              text = ask("Mogu li ponuditi opremu bez novca?", architecture: "material_support_offer_boundary")
              assert_includes text, "changed-support@example.invalid"
              assert_not_includes text, "https://community.example.invalid/support"
              assert_not_includes text, "fondacijabijeljina.com"
            end
          end
        end

        test "unavailable or unsupported material catalogue cannot be described as an empty inventory" do
          with_material_catalog do
            with_public_support do
              # Exercise the tool-envelope seam: unsupported is a valid tool
              # status, while the typed source reader deliberately rejects it.
              %w(unavailable unsupported).each do |status|
                @store.reset(@context)
                registry = Object.new
                registry.define_singleton_method(:call) do |context:, **|
                  Dialogue::EvidenceEnvelope.new(organization_id: context.organization_id, registry_epoch: "authored-material-v1",
                    status:, warnings: ["authored_material_source_unavailable"], query_scope: { "operation" => "read_catalog" })
                end
                tools = OpenStruct.new(registry:, eligibility: ->(**) { true })
                factory = @coordinator.instance_variable_get(:@tools_factory)
                text = begin
                  @coordinator.instance_variable_set(:@tools_factory, ->(**) { tools })
                  ask("Koje su javne materijalne potrebe?", architecture: "material_support_catalog")
                ensure
                  @coordinator.instance_variable_set(:@tools_factory, factory)
                end
                assert_includes text, "Trenutno ne mogu provjeriti"
                assert_includes text, "Nedostupan pregled nije potvrda da potreba nema"
                assert_includes text, "support@example.invalid"
                assert_not_includes text, "nisam našla otvorenu"
              end
            end
          end
        end

        test "a material question or offer followup records no pledge or acceptance" do
          with_material_catalog do
            need = material_need(material_owner)
            counts = [Decidim::Bih::ContributionNeed.count, Decidim::Bih::PartnerProfile.count]
            ask("Koje su javne materijalne potrebe?", architecture: "material_support_catalog")
            text = ask("Ako samo pitam, znači li da sam nešto obećao?", architecture: "material_support_no_commitment")
            assert_includes text, "nije ponuda ni obećanje"
            assert_includes text, "Nisam poslala poruku, evidentirala donaciju niti rezervisala materijal"
            assert_equal counts, [Decidim::Bih::ContributionNeed.count, Decidim::Bih::PartnerProfile.count]
            assert_equal "open", need.reload.fulfillment_status
          end
        end

        test "material contact guidance preserves configured channels across all four locales" do
          with_material_catalog do
            with_public_support do
              %w(sr sr-Cyrl bs hr).each do |locale|
                message = Decidim::Bih::Concierge::WebMessage.new("Koje su javne materijalne potrebe?", trusted_context: @context)
                result = ConversationMemory.stub(:enabled?, false) do
                  @coordinator.send(:direct_material_support, message:, state: @store.state, context: @context, locale:)
                end
                assert_equal "material_support_catalog", result.diagnostics.fetch("architecture")
                assert_equal locale.to_s, result.reply.locale.to_s
                assert_includes result.reply.text, "support@example.invalid"
                assert_includes result.reply.text, "https://community.example.invalid/support"
                assert_not_includes result.reply.text, "fondacijabijeljina.com"
              end
            end
          end
        end

        def with_community_launch(**changes)
          prior = ENV["MI_LAUNCH_EVENT_CONFIG_PATH"]
          path = File.join(@synthetic_service_root, "authored-launch-event.json")
          data = { "version" => 1, "organization_host" => @organization.host, "event_key" => "authored-community-launch",
            "title" => "AUTORSKI DAN ZAJEDNICE", "source_url" => "https://#{@organization.host}/events/authored-launch",
            "opens_at" => (@context.now - 1.hour).iso8601, "closes_at" => (@context.now + 1.hour).iso8601,
            "enabled" => true, "sms_fallback" => false }.merge(changes.transform_keys(&:to_s))
          writer = lambda do |**updates|
            data.merge!(updates.transform_keys(&:to_s))
            File.write(path, JSON.generate(data))
            ENV["MI_LAUNCH_EVENT_CONFIG_PATH"] = path
          end
          writer.call
          yield writer, path
        ensure
          prior.nil? ? ENV.delete("MI_LAUNCH_EVENT_CONFIG_PATH") : ENV["MI_LAUNCH_EVENT_CONFIG_PATH"] = prior
        end

        test "launch question uses the configured community future date rather than the inherited local event" do
          with_community_launch(opens_at: "2041-01-17T18:00:00Z", closes_at: "2041-01-17T20:00:00Z") do
            text = ask("Kada je lansiranje ove zajednice?", architecture: "past_launch_event")
            assert_includes text, "AUTORSKI DAN ZAJEDNICE"
            assert_includes text, "17.01.2041. u 19:00 +01:00"
            assert_includes text, "još nije počeo"
            assert_includes text, "https://#{@organization.host}/events/authored-launch"
            assert_not_includes text, "17. septembar 2026"
            assert_not_includes text, "Trku komšiluka možeš"
          end
        end

        test "current launch window is not an invitation reservation or entrance right" do
          with_community_launch do
            text = ask("Da li je lansiranje još otvoreno?", architecture: "past_launch_event")
            assert_includes text, "Podešeni termin je sada u toku"
            assert_includes text, "nije poslao pozivnicu, rezervisao mjesto niti potvrdio tvoje pravo ulaska"
            assert_includes text, "Trka komšiluka i lansiranje imaju odvojene termine"
          end
        end

        test "a past configured window does not prove that the launch actually happened" do
          with_community_launch(opens_at: (@context.now - 3.hours).iso8601, closes_at: (@context.now - 1.hour).iso8601) do
            text = ask("Da li se događaj lansiranja održao?", architecture: "past_launch_event")
            assert_includes text, "Podešeni termin je prošao"
            assert_includes text, "ne potvrđuje da je događaj održan"
          end
        end

        test "missing or disabled launch configuration cannot confirm the date in the question" do
          with_public_support do
            with_community_launch do |write, _path|
              [-> { ENV.delete("MI_LAUNCH_EVENT_CONFIG_PATH") }, -> { write.call(enabled: false) }].each do |change|
                @store.reset(@context)
                change.call
                text = ask("Da li je lansiranje 17. septembra 2026. već prošlo?", architecture: "past_launch_event")
                assert_includes text, "Ne mogu potvrditi datum iz pitanja"
                assert_includes text, "support@example.invalid"
                assert_not_includes text, "AUTORSKI DAN ZAJEDNICE"
                assert_not_includes text, "fondacijabijeljina.com"
              end
            end
          end
        end

        test "malformed or foreign launch configuration discloses no event payload or inherited date" do
          with_public_support(name: nil, email: nil, website: nil) do
            with_community_launch do |write, path|
              [-> { File.write(path, "{AUTHORED_PRIVATE_EVENT_MARKER") },
               -> { write.call(organization_host: "foreign.example.invalid", source_url: "https://foreign.example.invalid/private-event") }].each do |change|
                @store.reset(@context)
                change.call
                text = ask("Kada je lansiranje ove zajednice?", architecture: "past_launch_event")
                assert_includes text, "Ne mogu potvrditi datum iz pitanja"
                assert_not_includes text, "AUTHORED_PRIVATE_EVENT_MARKER"
                assert_not_includes text, "foreign.example.invalid"
                assert_not_includes text, "17. septembar 2026"
              end
            end
          end
        end

        test "launch followup rereads changed and then disabled configuration" do
          with_community_launch do |write, _path|
            ask("Kada je lansiranje ove zajednice?", architecture: "past_launch_event")
            write.call(title: "DRUGI AUTORSKI DOGAĐAJ", opens_at: "2041-01-17T18:00:00Z", closes_at: "2041-01-17T20:00:00Z")
            text = ask("Da li je lansiranje još otvoreno?", architecture: "past_launch_event")
            assert_includes text, "DRUGI AUTORSKI DOGAĐAJ"
            assert_includes text, "još nije počeo"
            assert_not_includes text, "AUTORSKI DAN ZAJEDNICE"
            write.call(enabled: false)
            text = ask("Da li je lansiranje još otvoreno?", architecture: "past_launch_event")
            assert_not_includes text, "DRUGI AUTORSKI DOGAĐAJ"
            assert_includes text, "Ne mogu potvrditi datum iz pitanja"
          end
        end

        test "launch date predicate keeps personal invitation and reward questions on their original route" do
          ["Imam li pozivnicu za lansiranje?", "Moja pozivnica za lansiranje 17.9.2040?"].each do |text|
            assert_not @coordinator.send(:past_launch_event_question?, text, context: @context)
          end
        end

        test "configured launch dates keep source URLs and no private invitation claims in all four locales" do
          with_community_launch do
            %w(sr sr-Cyrl bs hr).each do |locale|
              @store.reset(@context)
              text = locale == "sr-Cyrl" ? "Када је лансирање ове заједнице?" : "Kada je lansiranje ove zajednice?"
              message = Decidim::Bih::Concierge::WebMessage.new(text, trusted_context: @context)
              result = I18n.with_locale(locale) do
                ConversationMemory.stub(:enabled?, false) { @coordinator.call(message:, context: @context) }
              end
              assert_equal "past_launch_event", result.diagnostics.fetch("architecture")
              assert_equal locale, result.reply.locale.to_s
              assert_includes result.reply.text, "https://#{@organization.host}/events/authored-launch"
              assert_not_includes result.reply.text, "fondacijabijeljina.com"
            end
          end
        end

        class PensionSnapshots
          Row = Struct.new(:source_version, :check_payload, :last_good_payload, keyword_init: true)
          attr_accessor :row
          attr_reader :reads

          def initialize(row)
            @row = row
            @reads = []
          end

          def snapshot(source_key:)
            @reads << source_key
            @row if source_key == CitizenNoticePilots.snapshot_key("pio_notices")
          end

          def check(**) = raise("Unexpected non-pension source read")
        end

        def pension_notice_record(**changes)
          { "id" => "authored-pension-notice", "kind" => "payment_start_notice", "subject_id" => "pio_notices",
            "subject_label" => "Autorski javni fond", "text" => "Autorska javna objava o početku isplate.",
            "payment_starts_on" => "2040-09-16", "period_covered" => "2040-08", "source_published_on" => "2040-09-15",
            "source_url" => "https://notices.example.invalid/pension/authored-a", "personal_status" => false,
            "warnings" => ["payment_start_not_individual_receipt"] }.merge(changes.transform_keys(&:to_s))
        end

        def with_pension_snapshot(records: [pension_notice_record], checked_at: @context.now, failed: false, version: nil, missing: false)
          prior_sources = CitizenNoticePilots::SOURCES
          own_sources = prior_sources.deep_dup
          own_sources["pio_notices"] = { url: "https://notices.example.invalid/pension/feed", label: "Autorski javni fond", max_age: 2.days }
          CitizenNoticePilots.send(:remove_const, :SOURCES)
          CitizenNoticePilots.const_set(:SOURCES, own_sources.freeze)
          payload = { "status" => records.empty? ? "empty" : "ok", "records" => records, "checked_at" => checked_at.iso8601,
            "pilot_key" => "pio_notices", "personal_status_supported" => false }
          row = PensionSnapshots::Row.new(source_version: version || CitizenNoticePilots.version_for("pio_notices"),
            check_payload: failed ? { "status" => "unavailable", "pilot_key" => "pio_notices" } : payload,
            last_good_payload: payload.deep_dup)
          snapshots = PensionSnapshots.new(missing ? nil : row)
          prior_factory = @coordinator.instance_variable_get(:@tools_factory)
          @coordinator.instance_variable_set(:@tools_factory, ->(**) { ConversationTools.new(organization: @organization, source_checker: snapshots, clock: -> { Time.current }) })
          travel_to @context.now do
            yield snapshots
          end
        ensure
          @coordinator.instance_variable_set(:@tools_factory, prior_factory) if defined?(prior_factory)
          if prior_sources
            CitizenNoticePilots.send(:remove_const, :SOURCES)
            CitizenNoticePilots.const_set(:SOURCES, prior_sources)
          end
        end

        test "pension period guidance uses actual prepared publication month and start without the old fixed notice" do
          rows = [pension_notice_record, pension_notice_record(id: "authored-other-month", period_covered: "2040-07", payment_starts_on: "2040-08-02"),
                  pension_notice_record(id: "authored-other-year", period_covered: "2039-08", payment_starts_on: "2039-09-03")]
          with_pension_snapshot(records: rows) do |snapshots|
            text = ask("Da li postoji PIO objava o isplati penzija za avgust 2040?", architecture: "pio_public_notice")
            assert_includes text, "2040-08"
            assert_includes text, "2040-09-16"
            assert_includes text, "Datum javne objave: 2040-09-15"
            assert_includes text, "https://notices.example.invalid/pension/authored-a"
            assert_not_includes text, "2040-08-02"
            assert_not_includes text, "2039-09-03"
            assert_not_includes text, "24605"
            assert_not_includes text, "8.9.2026"
            assert_operator snapshots.reads.size, :>=, 2
          end
        end

        test "missing or empty prepared pension data cannot confirm a historical hardcoded payment" do
          [{ missing: true }, { records: [] }].each do |options|
            @store.reset(@context)
            with_pension_snapshot(**options) do
              text = ask("Da li je PIO objavio isplatu za avgust 2026?", architecture: "pio_public_notice")
              assert_includes text, "Nemam potvrđenu javnu objavu"
              assert_includes text, "ne dokazuje da isplata nije počela"
              assert_not_includes text, "24605"
              assert_not_includes text, "8.9.2026"
            end
          end
        end

        test "pension month year and ambiguous periods cannot borrow another notice" do
          with_pension_snapshot do
            ["avgust 2039", "juli 2040", "avgust 2039 i 2040", "avgust i juli 2040"].each do |period|
              @store.reset(@context)
              text = ask("PIO objava o isplati za #{period}?", architecture: "pio_public_notice")
              assert_includes text, "Nemam potvrđenu javnu objavu"
              assert_not_includes text, "2040-09-16"
              assert_not_includes text, "https://notices.example.invalid/pension/authored-a"
            end
          end
        end

        test "failed stale wrong version future publication or nonpublic cached benefits are not current payment evidence" do
          options = [{ failed: true }, { checked_at: @context.now - 3.days }, { version: "authored-obsolete-version" },
            { records: [pension_notice_record(source_published_on: "2040-09-17")] },
            { records: [pension_notice_record(payment_starts_on: "AUTHORED_PRIVATE_DATE_MARKER")] },
            { records: [pension_notice_record(period_covered: "2040-99")] },
            { records: [pension_notice_record(personal_status: true)] },
            { records: [pension_notice_record(subject_id: "authored-other-subject")] }]
          options.each do |changes|
            @store.reset(@context)
            with_pension_snapshot(**changes) do
              text = ask("PIO objava o isplati za avgust 2040?", architecture: "pio_public_notice")
              assert_not_includes text, "2040-09-16"
              assert_not_includes text, "AUTHORED_PRIVATE_DATE_MARKER"
              assert_not_includes text, "https://notices.example.invalid/pension/authored-a"
              assert_includes text, "Javna objava ne potvrđuje tvoje pravo ni uplatu"
            end
          end
        end

        test "previous month pension query selects its actual month across a year boundary" do
          with_pension_snapshot do
            text = ask("PIO objava o isplati za prethodni mjesec?", architecture: "pio_public_notice")
            assert_includes text, "2040-08"
          end
          @context = @context.with(now: Time.utc(2041, 1, 15, 10))
          @store.reset(@context)
          row = pension_notice_record(period_covered: "2040-12", source_published_on: "2041-01-14", payment_starts_on: "2041-01-15")
          with_pension_snapshot(records: [row]) do
            text = ask("PIO objava o isplati za prethodni mjesec?", architecture: "pio_public_notice")
            assert_includes text, "2040-12"
            assert_includes text, "2041-01-15"
          end
        end

        test "public pension notice never proves arrival on a personal bank account" do
          with_pension_snapshot do |snapshots|
            ask("PIO objava o isplati za avgust 2040?", architecture: "pio_public_notice")
            reads = snapshots.reads.size
            text = ask("Da li je novac stigao na moj račun?", architecture: "pio_personal_receipt_boundary")
            assert_includes text, "ne potvrđuje da je novac stigao na tvoj račun"
            assert_includes text, "ne šalji broj računa"
            assert_equal reads, snapshots.reads.size
          end
        end

        test "announced future pension start remains an announcement and rereads changed prepared data" do
          with_pension_snapshot(records: [pension_notice_record(payment_starts_on: "2040-09-17")]) do |snapshots|
            text = ask("PIO objava o isplati za avgust 2040?", architecture: "pio_public_notice")
            assert_includes text, "2040-09-17"
            assert_includes text, "Najavljeni početak je u budućnosti"
            snapshots.row.check_payload["records"][0]["payment_starts_on"] = "2040-09-18"
            text = ask("PIO objava o isplati za avgust 2040?", architecture: "pio_public_notice")
            assert_includes text, "2040-09-18"
            assert_not_includes text, "2040-09-17"
          end
        end

        test "pension notice period and source survive all four locale boundaries" do
          with_pension_snapshot do
            %w(sr sr-Cyrl bs hr).each do |locale|
              @store.reset(@context)
              query = { "sr" => "PIO objava o isplati za avgust 2040?", "sr-Cyrl" => "ПИО објава о исплати за август 2040?",
                "bs" => "PIO objava o isplati za august 2040?", "hr" => "PIO objava o isplati za kolovoz 2040?" }.fetch(locale)
              message = Decidim::Bih::Concierge::WebMessage.new(query, trusted_context: @context)
              result = I18n.with_locale(locale) do
                ConversationMemory.stub(:enabled?, false) { @coordinator.call(message:, context: @context) }
              end
              assert_equal "pio_public_notice", result.diagnostics.fetch("architecture")
              assert_equal locale, result.reply.locale.to_s
              assert_includes result.reply.text, "2040-08"
              assert_includes result.reply.text, "https://notices.example.invalid/pension/authored-a"
            end
          end
        end

        # Consumer contract double: real immutable evidence envelopes, no provider
        # or timetable reader. Actual authored matrices are covered separately.
        def published_boarding_consumer_tools(status: "ok", origins: ["authored-stop-a"], map: true)
          calls = []
          state = { eligible: true, status:, origins:, map: }
          eligibility = ->(**) { state.fetch(:eligible) }
          registry = Object.new
          registry.define_singleton_method(:call) do |name:, arguments:, context:, **|
            calls << [name, arguments.deep_dup]
            records = if name == "published_boarding_points"
                        state.fetch(:status) == "ok" ? state.fetch(:origins).each_with_index.map do |id, index|
                          { "id" => "boarding-#{index}", "document_id" => "authored-table", "revision" => "authored-v1",
                            "text" => "Authored table membership", "source_url" => "https://community.example.invalid/authored-table",
                            "facts" => { "origin_id" => id, "origin_label" => "Testni centar #{index}", "destination_label" => "Testni vrt",
                              "route_code" => "T1", "evidence_purpose" => "published_same_trip_column_membership_not_departure" } }
                        end : []
                      elsif state.fetch(:map)
                        [{ "id" => "authored-map", "document_id" => "authored-stops", "revision" => "authored-v1",
                           "text" => "Authored stop map", "facts" => { "stop_id" => arguments.fetch("stop_id"),
                             "walking_map_url" => "https://www.google.com/maps/dir/?api=1&destination=0.5,0.5" } }]
                      else
                        []
                      end
            envelope_status = name == "published_boarding_points" ? state.fetch(:status) : (state.fetch(:map) ? "ok" : "unsupported")
            Dialogue::EvidenceEnvelope.new(organization_id: context.organization_id, registry_epoch: "authored-consumer-v1",
              status: envelope_status, evidence: records, warnings: ["partial_reviewed_transport_network"],
              query_scope: { "operation" => name })
          end
          [OpenStruct.new(registry:, eligibility:), calls, state]
        end

        def published_boarding_consumer(tools)
          @coordinator.send(:reviewed_published_boarding_guidance,
            request: { "origin_query" => "centar", "destination_query" => "Testni vrt" }, context: @context, tools:)
        end

        test "boarding consumer uses reviewed physical identity without fabricating planning window" do
          tools, calls = published_boarding_consumer_tools
          result = published_boarding_consumer(tools)
          assert_equal "answered", result.fetch(:resolution)
          assert_equal 2, result.fetch(:tool_calls)
          assert_equal %w(published_boarding_points walking_directions), calls.map(&:first)
          assert_equal({ "origin_query" => "centar", "destination_query" => "Testni vrt" }, calls.first.last)
          assert_equal({ "stop_id" => "authored-stop-a" }, calls.last.last)
          assert_includes result.fetch(:answer), "Testni centar 0"
          assert_includes result.fetch(:answer), "community.example.invalid/authored-table"
          assert_includes result.fetch(:answer), "Pješačka ruta, udaljenost, strana ukrcavanja i pristupačnost nisu provjerene"
          assert_not_includes result.fetch(:answer), "P12"
          assert_not_includes result.fetch(:answer), "gradbijeljina.org"
        end

        test "boarding consumer leaves several physical origins unresolved" do
          tools, calls = published_boarding_consumer_tools(origins: %w(authored-stop-a authored-stop-b))
          result = published_boarding_consumer(tools)
          assert_equal "clarification", result.fetch(:resolution)
          assert_equal 1, calls.size
          assert_includes result.fetch(:answer), "više kandidata"
          assert_not_includes result.fetch(:answer), "google.com"
        end

        test "boarding consumer distinguishes unavailable ambiguous and unsupported without absence proof" do
          { "unavailable" => "source_unavailable", "ambiguous" => "clarification", "unsupported" => "unsupported" }.each do |status, resolution|
            tools, calls = published_boarding_consumer_tools(status:)
            result = published_boarding_consumer(tools)
            assert_equal resolution, result.fetch(:resolution)
            assert_equal 1, calls.size
            assert_includes result.fetch(:answer), "To ne dokazuje da prevoz ne postoji"
            assert_not_includes result.fetch(:answer), "Testni centar 0"
          end
        end

        test "boarding consumer does not invent map when navigation cannot provide one" do
          tools, = published_boarding_consumer_tools(map: false)
          result = published_boarding_consumer(tools)
          assert_equal "answered", result.fetch(:resolution)
          assert_includes result.fetch(:answer), "Nemam provjerenu mapu"
          assert_not_includes result.fetch(:answer), "google.com"
        end

        test "boarding consumer refuses evidence after source eligibility is revoked" do
          tools, _, state = published_boarding_consumer_tools
          state[:eligible] = false
          assert_raises(Dialogue::Contracts::Invalid) { published_boarding_consumer(tools) }
        end

        test "boarding consumer revalidates both envelopes immediately before output" do
          tools, calls = published_boarding_consumer_tools
          checks = 0
          tools.eligibility = ->(**) { checks += 1; checks <= 4 }
          assert_raises(Dialogue::Contracts::Invalid) { published_boarding_consumer(tools) }
          assert_equal 2, calls.size
          assert_operator checks, :>, 4
        end

        test "central boarding request takes destination from citizen in Latin and Cyrillic" do
          ["U centru sam, kako da dođem do stajališta za Testni vrt?",
           "У центру сам, како да дођем до стајалишта за Тестни врт?"].each do |text|
            request = @coordinator.send(:central_published_stop_request, text)
            assert_equal "centar", request.fetch("origin_query")
            assert_equal "Testni vrt", request.fetch("destination_query")
            assert @coordinator.send(:central_janja_stop_question?, text)
            assert_not request.key?("date")
          end
          assert_nil @coordinator.send(:central_published_stop_request, "Kako da dođem do stajališta?")
        end

        test "boarding followup rereads stored endpoints and never restores old city default" do
          tools, calls = published_boarding_consumer_tools
          @coordinator.instance_variable_set(:@tools_factory, ->(**) { tools })
          ask("U centru sam, kako da dođem do stajališta za Testni vrt?", architecture: "central_janja_stop_assumption")
          assert_equal "published_boarding", @store.state.dig(Dialogue::ConversationSlots::KEY, "journey", "query_kind")
          text = ask("Može približna pješačka ruta?", architecture: "central_janja_walk_boundary")
          assert_equal 4, calls.size
          assert_equal calls[0], calls[2]
          assert_includes text, "nisu provjerene"
          assert_not_includes text, "Bijeljina"
        end

        test "legacy boarding followup without saved endpoints asks for fresh places" do
          @store.state[Dialogue::AnswerContext::KEY] = Dialogue::AnswerContext.capture(kind: "public_card", subject: "central_janja_stop",
            anchor: "Legacy authored question", now: @context.now, state_expires_at: @store.state.fetch("expires_at"))
          text = ask("Može približna ruta?", architecture: "central_janja_walk_boundary", resolution: "clarification")
          assert_includes text, "Napiši polazište i odredište"
          assert_not_includes text, "P12"
        end

        def install_campaign(**changes)
          row = { "id" => "authored-campaign", "text" => "IZMIŠLJENA NAJAVA KABASTOG OTPADA.",
                  "coverage_text" => "Samo izmišljeno područje Testni vrt, prema uslovima iz najave.",
                  "source_url" => "https://community.example.invalid/notices/authored-campaign", "source_on" => "2040-09-10",
                  "reviewed_on" => "2040-09-14", "review_valid_until" => "2040-10-01", "starts_on" => "2040-09-14",
                  "ends_on" => "2040-09-15", "review_state" => "reviewed", "publishable" => true }.merge(changes.transform_keys(&:to_s))
          path = File.join(@synthetic_service_root, "bulky-campaigns.json")
          File.write(path, JSON.generate({ "format" => 1, "organization_host" => @organization.host, "campaigns" => [row] }))
          ENV["MI_BULKY_WASTE_CAMPAIGNS_PATH"] = path
        end

        test "initial bulky waste answer keeps a reviewed historical announcement without inventing a new date" do
          install_campaign
          text = ask("Kome da se obratim za odvoz stare sofe?", architecture: "bulky_waste_window")
          assert_includes text, "IZMIŠLJENA NAJAVA KABASTOG OTPADA"
          assert_includes text, "2040-09-14 – 2040-09-15"
          assert_includes text, "Objavljeni period je prošao"
          assert_includes text, "Testni vrt"
          assert_includes text, "/notices/authored-campaign"
          assert_includes text, "pregledano 2040-09-14"
          assert_includes text, "IZMIŠLJENI TELEFON SLUŽBE"
          assert_includes text, "ne potvrđuju odvoz za tvoju adresu"
          assert_not_includes text, "2026"
          followup = ask("Koji je kontakt za termin odvoza?", architecture: "bulky_waste_contact_followup")
          assert_includes followup, "ne potvrđuje aktuelnu akciju odvoza ili novi termin"
        end

        test "initial bulky waste current and future windows never become live collection promises" do
          [["2040-09-16", "2040-09-16", "to nije potvrda da odvoz upravo traje"],
           ["2040-09-17", "2040-09-20", "period tek predstoji"]].each do |start, finish, expected|
            @store.reset(@context)
            install_campaign(starts_on: start, ends_on: finish)
            text = ask("Kada je odvoz kabastog otpada?", architecture: "bulky_waste_window")
            assert_includes text, expected
            assert_includes text, "Obuhvat iz najave"
            assert_includes text, "ne potvrđuju odvoz za tvoju adresu"
          end
        end

        test "initial bulky waste with no reviewed campaign keeps own contact and ordinary waste limitation" do
          text = ask("Kada je odvoz kabastog otpada?", architecture: "bulky_waste_window")
          assert_includes text, "Nemam dostupnu pregledanu najavu"
          assert_includes text, "IZMIŠLJENI TELEFON SLUŽBE"
          assert_includes text, "Redovni raspored kućnog otpada nije potvrda odvoza namještaja"
          assert_not_includes text, "2026"
        end

        test "unreviewed expired or unpublished campaigns do not enter the initial answer" do
          [{ review_state: "pending" }, { review_valid_until: "2040-09-15" }, { publishable: false }].each do |changes|
            @store.reset(@context)
            install_campaign(**changes)
            text = ask("Kada je odvoz kabastog otpada?", architecture: "bulky_waste_window")
            assert_includes text, "Nemam dostupnu pregledanu najavu"
            assert_not_includes text, "IZMIŠLJENA NAJAVA KABASTOG OTPADA"
            assert_not_includes text, "/notices/authored-campaign"
          end
        end

        test "campaign typed read preserves tenant actor capability deadline and locale boundaries" do
          install_campaign
          reader = ReadPort.new(organization: @organization)
          [@context.with(organization_id: @organization.id + 1), @context.with(actor_id: Decidim::User.maximum(:id).to_i + 1)].each do |context|
            assert_raises(Dialogue::Contracts::Invalid) { reader.bulky_waste_campaigns(context:) }
          end
          assert_raises(Dialogue::Contracts::Invalid) { reader.bulky_waste_campaigns(context: @context, locale: "invalid") }
          [@context.with(capabilities: %w(report_guidance)),
           @context.with(deadline: Process.clock_gettime(Process::CLOCK_MONOTONIC) - 1)].each do |context|
            result = reader.bulky_waste_campaigns(context:)
            assert_includes %w(not_authorized unavailable), result.status
            assert_empty result.facts
          end
          result = reader.bulky_waste_campaigns(context: @context, locale: "sr-Cyrl")
          assert_equal "ok", result.status
          assert_equal false, result.validity.fetch("live_status")
          assert_equal @organization.host.downcase, result.coverage.fetch("organization_host")
        end

        def with_agricultural_snapshot(items: [synthetic_public_call])
          with_synthetic_public_call_snapshot(items:, organization: @organization, now: @context.now) do |store|
            CityServiceSourceCheckStore.stub(:new, store) { yield store }
          end
        end

        test "agricultural timing uses this community's separate past current and future application windows" do
          items = [synthetic_public_call(id: "past", closes_on: "2040-09-15"), synthetic_public_call(id: "current"),
                   synthetic_public_call(id: "future", opens_on: "2040-09-17", closes_on: "2040-10-10")]
          with_agricultural_snapshot(items:) do
            text = ask("Da li je otvoren javni poziv za poljoprivredu?", architecture: "agricultural_call_timing")
            assert_includes text, "Objavljeni rok ovog poziva je prošao"
            assert_includes text, "Današnji datum je unutar objavljenog perioda"
            assert_includes text, "Objavljeni početak podnošenja zahtjeva tek predstoji"
            assert_includes text, "2040-09-17"
            assert_includes text, "community.example.invalid/calls/authored-agriculture"
            assert_includes text, "različite vrste mogu imati različite rokove"
            assert_not_includes text, "2026"
            assert_not_includes text, "gradbijeljina.org"
            assert_equal "agricultural_call", @store.state.dig(Dialogue::AnswerContext::KEY, "subject")
          end
        end

        test "deadline-only agricultural record does not prove the call is open" do
          with_agricultural_snapshot(items: [synthetic_public_call(opens_on: nil, temporal_status: "deadline_only")]) do
            text = ask("Da li je otvoren javni poziv za poljoprivredu?", architecture: "agricultural_call_timing")
            assert_includes text, "Početak podnošenja zahtjeva nije potvrđen"
            assert_includes text, "sam budući rok ne potvrđuje da je poziv otvoren"
            assert_not_includes text, "Današnji datum je unutar"
          end
        end

        test "agricultural deadline and form follow-up rereads the source without claiming approval" do
          with_agricultural_snapshot do |store|
            ask("Da li je otvoren javni poziv za poljoprivredu?", architecture: "agricultural_call_timing")
            store.row.check_payload.fetch("items").first["closes_on"] = "2040-09-15"
            text = ask("Koji su rok i obrazac za taj poziv?", architecture: "agricultural_call_deadlines")
            assert_includes text, "2040-09-15"
            assert_includes text, "Objavljeni rok ovog poziva je prošao"
            assert_includes text, "community.example.invalid/forms/authored-application.pdf"
            assert_includes text, "community.example.invalid/calls/application"
            assert_includes text, "Preuzimanje obrasca nije predaja zahtjeva, odobrenje ili potvrda isplate"
            assert_includes text, "Ne šalji lične dokumente"
            assert_equal 2, store.requested_keys.size
          end
          @store.reset(@context)
          seed_public_subject("agricultural_2026_call")
          with_agricultural_snapshot do
            text = ask("Koji su rok i obrazac za taj poziv?", architecture: "agricultural_call_deadlines")
            assert_includes text, "2040-10-02"
            assert_not_includes text, "2026"
          end
        end

        test "missing stale and disabled agricultural sources never fall back to inherited dates" do
          with_agricultural_snapshot do |store|
            store.row.check_payload["checked_at"] = (@context.now - 1.year).iso8601
            text = ask("Da li je otvoren javni poziv za poljoprivredu?", architecture: "agricultural_call_timing")
            assert_includes text, "ne mogu pouzdano navesti rokove"
            assert_not_includes text, "2040-10-02"
            @store.reset(@context)
            store.row = nil
            text = ask("Da li je otvoren javni poziv za poljoprivredu?", architecture: "agricultural_call_timing")
            assert_includes text, "ne mogu pouzdano navesti rokove"
            assert_not_includes text, "2026"
            @store.reset(@context)
            store.define_singleton_method(:snapshot) { |**| raise "disabled source must not read snapshots" }
            CityServiceSources.stub(:enabled?, false) do
              text = ask("Da li je otvoren javni poziv za poljoprivredu?", architecture: "agricultural_call_timing")
              assert_includes text, "ne mogu pouzdano navesti rokove"
              assert_not_includes text, "gradbijeljina.org"
            end
          end
        end

        test "agricultural typed bridge retains organization actor read deadline and Cyrillic boundaries" do
          with_agricultural_snapshot do
            reader = ReadPort.new(organization: @organization)
            [@context.with(organization_id: @organization.id + 1),
             @context.with(actor_id: Decidim::User.maximum(:id).to_i + 1)].each do |context|
              assert_raises(Dialogue::Contracts::Invalid) { reader.agricultural_call_timing(context:) }
            end
            assert_raises(Dialogue::Contracts::Invalid) { reader.agricultural_call_timing(context: @context, locale: "invalid") }
            [@context.with(capabilities: []),
             @context.with(deadline: Process.clock_gettime(Process::CLOCK_MONOTONIC) - 1)].each do |context|
              result = reader.agricultural_call_timing(context:)
              assert_includes %w(not_authorized unavailable), result.status
              assert_empty result.facts
            end
            result = reader.agricultural_call_timing(context: @context, locale: "sr-Cyrl")
            assert_equal "ok", result.status
            assert_match(/\p{Cyrillic}/, result.facts.first.fetch("text"))
            assert_equal "https://community.example.invalid/calls/authored-agriculture", result.facts.first.fetch("source_url")
          end
        end

        test "association question without any source registry answers without reading stored calls or a model" do
          checker = Object.new
          checker.define_singleton_method(:snapshot) { |**| raise "unconfigured source must not read stored calls" }
          CityServiceSources.stub(:all, []) do
            CityServiceSourceCheckStore.stub(:new, checker) do
              text = ask("Postoji li javni poziv za udruženja?", architecture: "association_public_call")
              assert_includes text, "ne mogu pouzdano potvrditi"
              assert_includes text, "službena stranica poziva trenutno nije dostupna za ovu zajednicu"
              assert_not_includes text, "gradbijeljina.org"
              assert_not_includes text, "community.example.invalid/calls"
            end
          end
        end

        test "association selection uses own community and remains visible after unrelated calls exceed the limit" do
          items = 8.times.map do |i|
            synthetic_public_call(id: "unrelated-#{i}", title: "NEPOVEZANA IZMIŠLJENA DJELATNOST", closes_on: "2040-09-20")
          end
          items << synthetic_public_call(id: "association", title: "IZMIŠLJENI javni poziv za udruženja",
                                          source_url: "https://community.example.invalid/calls/authored-association")
          with_agricultural_snapshot(items:) do |store|
            text = ask("Postoji li javni poziv za udruženja?", architecture: "association_public_call")
            assert_includes text, "IZMIŠLJENI javni poziv za udruženja"
            assert_includes text, "2040-10-02"
            assert_includes text, "community.example.invalid/calls/authored-association"
            assert_includes text, "nije potpun popis svih poziva"
            assert_includes text, "niti potvrda vaše prihvatljivosti, predaje ili odobrenja"
            assert_not_includes text, "NEPOVEZANA"
            assert_not_includes text, "Bijeljina"
            assert_equal ["public_calls:#{@organization.id}"], store.requested_keys
          end
        end

        test "association eligibility follow-up rereads a now closed call instead of retaining old availability" do
          item = synthetic_public_call(title: "IZMIŠLJENI javni poziv za udruženja",
                                       source_url: "https://community.example.invalid/calls/authored-association")
          with_agricultural_snapshot(items: [item]) do |store|
            ask("Postoji li javni poziv za udruženja?", architecture: "association_public_call")
            store.row.check_payload.fetch("items").first["closes_on"] = "2040-09-15"
            text = ask("Znači li to da naše udruženje ispunjava uslove?", architecture: "association_public_call")
            assert_includes text, "Objava poziva sama ne potvrđuje"
            assert_includes text, "nisam našla potvrđen otvoren poziv"
            assert_not_includes text, "2040-10-02"
            assert_not_includes text, "calls/authored-association"
            assert_equal 2, store.requested_keys.size
          end
        end

        test "association deadline-only record cannot establish an opening date" do
          item = synthetic_public_call(title: "IZMIŠLJENI javni poziv za udruženja", opens_on: nil, temporal_status: "deadline_only")
          with_agricultural_snapshot(items: [item]) do
            text = ask("Postoji li javni poziv za udruženja?", architecture: "association_public_call")
            assert_includes text, "Početak podnošenja nije potvrđen"
            assert_includes text, "budući rok sam ne dokazuje da je poziv otvoren"
            assert_includes text, "2040-10-02"
          end
        end

        test "stale unreviewed and wrong-tenant association snapshots do not expose call records" do
          item = synthetic_public_call(title: "IZMIŠLJENI javni poziv za udruženja")
          with_agricultural_snapshot(items: [item]) do |store|
            original = store.row.check_payload.dup
            [{ "checked_at" => (@context.now - 1.year).iso8601 }, { "status" => "unreviewed" },
             { "organization_id" => @organization.id + 1 }].each do |changes|
              @store.reset(@context)
              store.row.check_payload = original.merge(changes)
              text = ask("Postoji li javni poziv za udruženja?", architecture: "association_public_call")
              assert_includes text, "ne mogu pouzdano potvrditi"
              assert_not_includes text, "IZMIŠLJENI javni poziv za udruženja"
              assert_not_includes text, "2040-10-02"
            end
          end
        end

        test "association follow-up without public read capability cannot expose stored calls or listing" do
          item = synthetic_public_call(title: "IZMIŠLJENI javni poziv za udruženja")
          with_agricultural_snapshot(items: [item]) do |store|
            @context = @context.with(capabilities: [])
            @store.reset(@context)
            seed_public_subject("association_public_call")
            store.define_singleton_method(:snapshot) { |**| raise "public read denied must not read calls" }
            text = ask("Da li naše udruženje ispunjava uslove?", architecture: "association_public_call")
            assert_includes text, "Objava poziva sama ne potvrđuje"
            assert_includes text, "ne mogu pouzdano potvrditi"
            assert_not_includes text, "community.example.invalid/calls"
            assert_empty store.requested_keys
          end
        end

        def with_birth_extract_cards
          install_synthetic_procedures(organization_host: @organization.host)
          @procedure_keys = []
          @procedure_payload = nil
          owner = self
          checker = Object.new
          checker.define_singleton_method(:snapshot) do |source_key:|
            owner.instance_variable_get(:@procedure_keys) << source_key
            payload = owner.instance_variable_get(:@procedure_payload)
            payload && Struct.new(:check_payload).new(payload)
          end
          CityServiceSourceCheckStore.stub(:new, checker) { yield }
        ensure
          restore_synthetic_procedures
        end

        def with_municipal_case_card
          with_birth_extract_cards do
            rows = ServiceProcedures.all.map do |card|
              next card unless card[:key] == "pracenje_predmeta"

              card.merge(document_kind: "municipal_case_status", channel: "online", organization_host: @organization.host,
                         title: "IZMIŠLJENO PRAĆENJE GRADSKOG PREDMETA",
                         steps: ["IZMIŠLJENI KORAK PREGLEDA UPUTSTVA.", "Podatke predmeta unosite samo u pregledani službeni kanal."],
                         form_download_url: "https://community.example.invalid/forms/authored-case.pdf")
            end
            ServiceProcedures.instance_variable_set(:@all, rows.freeze)
            yield
          end
        end

        def rewrite_municipal_case_card(**changes)
          rows = ServiceProcedures.all.map { |card| card[:key] == "pracenje_predmeta" ? card.merge(changes) : card }
          ServiceProcedures.instance_variable_set(:@all, rows.freeze)
        end

        test "municipal case guidance uses own reviewed procedure form and date without a personal case lookup" do
          with_municipal_case_card do
            text = ask("Kako pratim status zahtjeva predatog gradskoj upravi?", architecture: "city_case_status_guidance")
            assert_includes text, "IZMIŠLJENI KORAK PREGLEDA UPUTSTVA"
            assert_includes text, "community.example.invalid/procedures/pracenje_predmeta"
            assert_includes text, "community.example.invalid/forms/authored-case.pdf"
            assert_includes text, "Pregledano 2040-09-09"
            assert_includes text, "Nemam pristup gradskoj evidenciji"
            assert_includes text, "nije poslao upit upravi"
            assert_not_includes text, "gradbijeljina.org"
            assert_not_includes text, "nema posebno polje"
          end
        end

        test "municipal case number followup rereads the instruction without inventing form fields" do
          with_municipal_case_card do
            ask("Kako pratim status zahtjeva predatog gradskoj upravi?", architecture: "city_case_status_guidance")
            rewrite_municipal_case_card(steps: ["NOVO IZMIŠLJENO UPUTSTVO, NE STARA POLJA."])
            text = ask("Gdje upisujem broj svog predmeta?", architecture: "city_case_status_guidance")
            assert_includes text, "NOVO IZMIŠLJENO UPUTSTVO"
            assert_not_includes text, "IZMIŠLJENI KORAK PREGLEDA UPUTSTVA"
            assert_includes text, "ne pretpostavljam posebno polje za broj predmeta"
            assert_includes text, "ne šalji u ovaj chat"
            assert_equal ["reference:procedure:pracenje_predmeta"] * 2, @procedure_keys
          end
        end

        test "municipal case procedure requires explicit purpose online channel and matching organization" do
          with_municipal_case_card do
            original = ServiceProcedures.all
            [nil, { document_kind: nil }, { document_kind: "birth_extract" }, { channel: "counter" },
             { organization_host: nil }, { organization_host: "other.example.invalid" }, { review_status: "pending" }].each do |changes|
              @store.reset(@context)
              rows = original.filter_map do |card|
                next card unless card[:key] == "pracenje_predmeta"
                next if changes.nil?

                card.merge(changes)
              end
              ServiceProcedures.instance_variable_set(:@all, rows.freeze)
              text = ask("Kako pratim status zahtjeva predatog gradskoj upravi?", architecture: "city_case_status_guidance")
              assert_includes text, "Nemam dostupno pregledano uputstvo ove zajednice"
              assert_not_includes text, "authored-case.pdf"
              assert_not_includes text, "gradbijeljina.org"
            end
          end
        end

        test "two municipal case procedure cards remain ambiguous without reading either source" do
          with_municipal_case_card do
            card = ServiceProcedures.find("pracenje_predmeta")
            ServiceProcedures.instance_variable_set(:@all, [card, card.merge(key: "another_case_status")].freeze)
            result = ReadPort.new(organization: @organization).municipal_case_status_procedure(context: @context)
            assert_equal "ambiguous", result.status
            assert_empty result.facts
            assert_empty @procedure_keys
          end
        end

        test "municipal case origin review date effective window and hash gates cannot be bypassed" do
          with_municipal_case_card do
            original = ServiceProcedures.find("pracenje_predmeta")
            [{ source_url: "https://unreviewed.example.invalid/case" }, { source_checked_on: "2030-09-09" },
             { source_checked_on: "2040-09-17" }, { effective_until: "2040-09-15" },
             { reviewed_content_hash: "not-a-revision" }].each do |changes|
              ServiceProcedures.instance_variable_set(:@all, [original.merge(changes)].freeze)
              result = ReadPort.new(organization: @organization).municipal_case_status_procedure(context: @context)
              assert_includes %w(unavailable stale unreviewed), result.status
              assert_empty result.facts
            end
          end
        end

        test "municipal case typed bridge retains tenant actor capability deadline and all locale boundaries" do
          with_municipal_case_card do
            reader = ReadPort.new(organization: @organization)
            [@context.with(organization_id: @organization.id + 1),
             @context.with(actor_id: Decidim::User.maximum(:id).to_i + 1)].each do |context|
              assert_raises(Dialogue::Contracts::Invalid) { reader.municipal_case_status_procedure(context:) }
            end
            assert_raises(Dialogue::Contracts::Invalid) { reader.municipal_case_status_procedure(context: @context, locale: "invalid") }
            [@context.with(capabilities: []), @context.with(deadline: Process.clock_gettime(Process::CLOCK_MONOTONIC) - 1)].each do |context|
              result = reader.municipal_case_status_procedure(context:)
              assert_includes %w(not_authorized unavailable), result.status
              assert_empty result.facts
            end
            %w(sr sr-Cyrl bs hr).each do |locale|
              result = reader.municipal_case_status_procedure(context: @context, locale:)
              assert_equal "ok", result.status
              row = result.facts.fetch(0)
              assert_equal "municipal_case_status", row.fetch("document_kind")
              assert_equal @organization.id, row.fetch("coverage").fetch("organization_id")
              assert_equal false, result.validity.fetch("personal_case_access")
              assert_equal false, result.validity.fetch("request_submitted")
              assert_equal "https://community.example.invalid/forms/authored-case.pdf", row.fetch("form_download_url")
              assert_match(/\p{Cyrillic}/, row.fetch("text")) if locale == "sr-Cyrl"
            end
          end
        end

        test "municipal case followup with changed source review withholds the old instruction" do
          with_municipal_case_card do
            ask("Kako pratim status zahtjeva predatog gradskoj upravi?", architecture: "city_case_status_guidance")
            card = ServiceProcedures.find("pracenje_predmeta")
            @procedure_payload = { "status" => "unavailable", "review_required_for_hash" => card.fetch(:reviewed_content_hash),
                                   "source_url" => card.fetch(:source_url) }
            text = ask("Gdje upisujem broj svog predmeta?", architecture: "city_case_status_guidance")
            assert_includes text, "Nemam dostupno pregledano uputstvo ove zajednice"
            assert_not_includes text, "authored-case.pdf"
            assert_not_includes text, "IZMIŠLJENI KORAK PREGLEDA UPUTSTVA"
          end
        end

        test "municipal case identifier supplied in chat is never sent to a status service or echoed as a result" do
          with_municipal_case_card do
            ask("Kako pratim status zahtjeva predatog gradskoj upravi?", architecture: "city_case_status_guidance")
            text = ask("Gdje ide broj svog predmeta TEST-PRIVATE-ID?", architecture: "city_case_status_guidance")
            assert_not_includes text, "TEST-PRIVATE-ID"
            assert_includes text, "niti mogu vidjeti tvoj lični predmet"
            assert_equal ["reference:procedure:pracenje_predmeta"] * 2, @procedure_keys
          end
        end

        def with_identity_card_guidance
          with_birth_extract_cards do
            template = ServiceProcedures.find("e_registar")
            cards = %w(application status).map do |focus|
              template.merge(key: "identity_card_#{focus}", document_kind: "identity_card_#{focus}",
                channel: focus == "status" ? "online" : "counter", organization_host: @organization.host,
                title: "IZMIŠLJENO UPUTSTVO LIČNE KARTE #{focus}",
                source_url: "https://community.example.invalid/procedures/identity-card-#{focus}",
                reviewed_content_hash: Digest::SHA256.hexdigest("authored-identity-card-#{focus}"), source_aliases: [],
                steps: [focus == "status" ? "IZMIŠLJENI PREDUSLOV TESTNOG STATUSA." : "IZMIŠLJENI KORAK IZDAVANJA DOKUMENTA."],
                form_download_url: focus == "application" ? "https://community.example.invalid/forms/authored-identity-card.pdf" : nil)
            end
            ServiceProcedures.instance_variable_set(:@all, [*ServiceProcedures.all, *cards].freeze)
            yield
          end
        end

        def rewrite_identity_card(focus:, **changes)
          rows = ServiceProcedures.all.map { |card| card[:key] == "identity_card_#{focus}" ? card.merge(changes) : card }
          ServiceProcedures.instance_variable_set(:@all, rows.freeze)
        end

        test "identity application guidance uses own authority source and form without fixed jurisdiction" do
          with_identity_card_guidance do
            text = ask("Koji dokumenti trebaju za novu ličnu kartu?", architecture: "police_identity_card")
            assert_includes text, "IZMIŠLJENI KORAK IZDAVANJA DOKUMENTA"
            assert_includes text, "community.example.invalid/procedures/identity-card-application"
            assert_includes text, "authored-identity-card.pdf"
            assert_includes text, "Pregledano 2040-09-09"
            assert_includes text, "nisam podnijela zahtjev"
            assert_not_includes text, "mup.vladars.rs"
            assert_not_includes text, "PU Bijeljina"
            assert_not_includes text, "TESTNOG STATUSA"
          end
        end

        test "identity status followup uses separate reviewed status prerequisites without a personal lookup" do
          with_identity_card_guidance do
            ask("Koji dokumenti trebaju za novu ličnu kartu?", architecture: "police_identity_card")
            text = ask("Možeš li vidjeti da li je gotova?", architecture: "police_identity_card")
            assert_includes text, "Ne mogu vidjeti da li je tvoja lična karta gotova"
            assert_includes text, "IZMIŠLJENI PREDUSLOV TESTNOG STATUSA"
            assert_includes text, "community.example.invalid/procedures/identity-card-status"
            assert_includes text, "JMB i druge lične podatke ne šalji"
            assert_not_includes text, "identity-card-application"
            assert_not_includes text, "broj telefona mora biti prethodno prijavljen"
            assert_equal ["reference:procedure:identity_card_application", "reference:procedure:identity_card_status"], @procedure_keys
          end
        end

        test "explicit new identity application after a status question selects application guidance again" do
          with_identity_card_guidance do
            ask("Da li je lična karta gotova?", architecture: "police_identity_card")
            text = ask("Treba mi nova lična karta, koji dokumenti?", architecture: "police_identity_card")
            assert_includes text, "IZMIŠLJENI KORAK IZDAVANJA DOKUMENTA"
            assert_not_includes text, "IZMIŠLJENI PREDUSLOV TESTNOG STATUSA"
            assert_not_includes text, "identity-card-status"
          end
        end

        test "missing identity status guidance cannot borrow application procedure or invent SMS rules" do
          with_identity_card_guidance do
            rows = ServiceProcedures.all.reject { |card| card[:document_kind] == "identity_card_status" }
            ServiceProcedures.instance_variable_set(:@all, rows.freeze)
            ask("Treba mi nova lična karta, koji dokumenti?", architecture: "police_identity_card")
            text = ask("Možeš li vidjeti da li je gotova?", architecture: "police_identity_card")
            assert_includes text, "Nemam dostupno pregledano uputstvo ove zajednice za provjeru statusa"
            assert_not_includes text, "identity-card-application"
            assert_not_includes text, "SMS"
            assert_not_includes text, "mup.vladars.rs"
          end
        end

        test "identity purpose host channel and duplicate guards cannot select another community card" do
          with_identity_card_guidance do
            original = ServiceProcedures.all
            [{ document_kind: "birth_extract" }, { organization_host: "other.example.invalid" },
             { channel: nil }, { review_status: "pending" }].each do |changes|
              ServiceProcedures.instance_variable_set(:@all, original.freeze)
              rewrite_identity_card(focus: "application", **changes)
              result = ReadPort.new(organization: @organization).identity_card_procedure(context: @context)
              assert_includes %w(empty unreviewed unavailable), result.status
              assert_empty result.facts
            end
            card = original.find { |row| row[:key] == "identity_card_application" }
            ServiceProcedures.instance_variable_set(:@all, [*original, card.merge(key: "duplicate_application")].freeze)
            result = ReadPort.new(organization: @organization).identity_card_procedure(context: @context)
            assert_equal "ambiguous", result.status
            assert_empty result.facts
          end
        end

        test "identity status source revision and review policy withhold changed or invalid instructions" do
          with_identity_card_guidance do
            original = ServiceProcedures.find("identity_card_status")
            [{ source_checked_on: "2030-09-09" }, { source_checked_on: "2040-09-17" },
             { effective_until: "2040-09-15" }, { source_url: "https://unreviewed.example.invalid/status" },
             { reviewed_content_hash: "invalid" }].each do |changes|
              ServiceProcedures.instance_variable_set(:@all, [original.merge(changes)].freeze)
              result = ReadPort.new(organization: @organization).identity_card_procedure(context: @context, focus: "status")
              assert_includes %w(stale unavailable unreviewed), result.status
              assert_empty result.facts
            end
            ServiceProcedures.instance_variable_set(:@all, [original].freeze)
            @procedure_payload = { "status" => "unavailable", "review_required_for_hash" => original.fetch(:reviewed_content_hash),
                                   "source_url" => original.fetch(:source_url) }
            text = ask("Da li je lična karta gotova?", architecture: "police_identity_card")
            assert_includes text, "Nemam dostupno pregledano uputstvo"
            assert_not_includes text, "IZMIŠLJENI PREDUSLOV TESTNOG STATUSA"
          end
        end

        test "identity typed bridge retains actor tenant capability deadline focus and locale boundaries" do
          with_identity_card_guidance do
            reader = ReadPort.new(organization: @organization)
            [@context.with(organization_id: @organization.id + 1),
             @context.with(actor_id: Decidim::User.maximum(:id).to_i + 1)].each do |context|
              assert_raises(Dialogue::Contracts::Invalid) { reader.identity_card_procedure(context:) }
            end
            assert_raises(Dialogue::Contracts::Invalid) { reader.identity_card_procedure(context: @context, focus: "private_case") }
            assert_raises(Dialogue::Contracts::Invalid) { reader.identity_card_procedure(context: @context, locale: "invalid") }
            [@context.with(capabilities: []), @context.with(deadline: Process.clock_gettime(Process::CLOCK_MONOTONIC) - 1)].each do |context|
              result = reader.identity_card_procedure(context:)
              assert_includes %w(not_authorized unavailable), result.status
              assert_empty result.facts
            end
            %w(application status).product(%w(sr sr-Cyrl bs hr)).each do |focus, locale|
              result = reader.identity_card_procedure(context: @context, locale:, focus:)
              assert_equal "ok", result.status
              row = result.facts.fetch(0)
              assert_equal "identity_card_#{focus}", row.fetch("document_kind")
              assert_equal false, result.validity.fetch("personal_document_access")
              assert_equal false, result.validity.fetch("request_submitted")
              assert_equal @organization.id, row.fetch("coverage").fetch("organization_id")
              assert_match(/\p{Cyrillic}/, row.fetch("text")) if locale == "sr-Cyrl"
            end
          end
        end

        test "identity status without any matching instruction cannot claim a personal document result" do
          with_identity_card_guidance do
            ServiceProcedures.instance_variable_set(:@all, [].freeze)
            text = ask("Da li je lična karta gotova?", architecture: "police_identity_card")
            assert_includes text, "Ne mogu vidjeti da li je tvoja lična karta gotova"
            assert_includes text, "Nemam dostupno pregledano uputstvo"
            assert_includes text, "nisam podnijela zahtjev niti provjerila ili potvrdila"
            assert_not_includes text, "mup.vladars.rs"
          end
        end

        def with_reviewed_weather
          install_synthetic_weather_region
          write_synthetic_weather_region(organization_host: @organization.host)
          source = { key: "weather_warnings", enabled: true, source_url: SyntheticWeatherRegion::SOURCE_URL,
                     provider: "Autorski weather pružalac", label: "Autorski weather izvor", location_granularity: "source_declared_region",
                     delivery_modes: ["on_demand"], scrape_cadence: "hourly" }.freeze
          swap_service_constant(CityServiceSources, :SOURCES, [source].freeze)
          @weather_review = WeatherRegionConfiguration.load(day: @context.now.in_time_zone("Europe/Sarajevo").to_date)
          @weather_status = :ok
          @weather_requests = []
          @weather_notices = [synthetic_weather_notice]
          owner = self
          checker = Object.new
          checker.define_singleton_method(:check) do |keys:, **|
            owner.instance_variable_get(:@weather_requests).concat(keys)
            [CityServiceNoticeCollector::SourceCheckResult.new(source_key: "weather_warnings",
              status: owner.instance_variable_get(:@weather_status), notices: owner.instance_variable_get(:@weather_notices),
              checked_at: owner.instance_variable_get(:@weather_status) == :unavailable ? nil : owner.instance_variable_get(:@context).now)]
          end
          CityServiceSourceCheckStore.stub(:new, checker) { yield }
        ensure
          restore_synthetic_weather_region
        end

        def synthetic_weather_notice(starts_at: @context.now - 1.hour, ends_at: @context.now + 1.hour, event: "IZMIŠLJENO ŽUTO UPOZORENJE")
          metadata = { "kind" => "official_warning", "provider_severity" => "Moderate", "provider_event" => event,
                       "affected_area_text" => "Autorski provider region", "starts_at" => starts_at.iso8601, "ends_at" => ends_at.iso8601,
                       "effective_at" => (@context.now - 2.hours).iso8601, "source_published_at" => (@context.now - 2.hours).iso8601,
                       "review_required" => true, "geographic_status" => "source_declared_region" }.merge(@weather_review.metadata)
          CityServiceNoticeCollector::Notice.new(source_key: "weather_warnings", title: "IZMIŠLJENA NAJAVA", body: "AUTORSKI TESTNI IZVOR.",
            url: SyntheticWeatherRegion::SOURCE_URL, fingerprint: "authored-weather-a", metadata:)
        end

        test "weather region explains own reviewed scope separately from unavailable current warning evidence" do
          with_reviewed_weather do
            @weather_status = :unavailable
            @weather_notices = []
            text = ask("Šta znači naziv regiona u vremenskom upozorenju?", architecture: "weather_region_scope")
            assert_includes text, "Izmišljena pregledana regija"
            assert_includes text, "Izmišljena zajednica"
            assert_includes text, "TEST-REGION-A"
            assert_includes text, "review.example.invalid/authored-region#feature-a"
            assert_includes text, "nije potvrda da trenutno važi upozorenje"
            assert_not_includes text, "Bijeljina"
            assert_not_includes text, "BA002"
          end
        end

        test "weather region followup rereads changed review without inheriting the earlier local label" do
          with_reviewed_weather do
            ask("Šta znači naziv regiona u vremenskom upozorenju?", architecture: "weather_region_scope")
            write_synthetic_weather_region(organization_host: @organization.host, region_label: "Nova autorska regija")
            text = ask("A odnosi li se taj region i ovdje?", architecture: "weather_region_scope")
            assert_includes text, "Nova autorska regija"
            assert_not_includes text, "Izmišljena pregledana regija"
            assert_includes text, "nije potvrda da trenutno važi upozorenje"
          end
        end

        test "missing weather review cannot expose an inherited region source or city" do
          with_reviewed_weather do
            ENV.delete("MI_WEATHER_REGION_CONFIG_PATH")
            text = ask("Šta znači naziv regiona u vremenskom upozorenju?", architecture: "weather_region_scope", resolution: "source_unavailable")
            assert_includes text, "Nemam dostupan važeći pregled"
            assert_not_includes text, "meteoalarm.org"
            assert_not_includes text, "weather.example.invalid"
            assert_empty @weather_requests
          end
        end

        test "yellow weather answer uses own prepared event period source and locality limitation" do
          with_reviewed_weather do
            text = ask("Ima li žuto vremensko upozorenje?", architecture: "yellow_weather_source")
            assert_includes text, "IZMIŠLJENO ŽUTO UPOZORENJE"
            assert_includes text, "Period iz izvora"
            assert_includes text, "Europe/Sarajevo"
            assert_includes text, "https://weather.example.invalid/feed"
            assert_includes text, "nije potvrda stanja u tvojoj ulici"
            assert_not_includes text, "Bijeljina"
          end
        end

        test "upcoming yellow period is not presented as a currently established hazard" do
          with_reviewed_weather do
            @weather_notices = [synthetic_weather_notice(starts_at: @context.now + 3.hours, ends_at: @context.now + 6.hours)]
            text = ask("Ima li žuto vremensko upozorenje?", architecture: "yellow_weather_source")
            assert_includes text, "Objavljeni period tek predstoji"
            assert_includes text, "ne potvrđuje opasnost sada"
            assert_not_includes text, "Izvorni period obuhvata trenutak pregleda"
          end
        end

        test "unreviewed yellow source remains explicitly unconfirmed rather than becoming a confirmed warning" do
          with_reviewed_weather do
            @weather_status = :unreviewed
            text = ask("Ima li žuto vremensko upozorenje?", architecture: "yellow_weather_source", resolution: "source_unavailable")
            assert_includes text, "označen je kao nepotvrđen"
            assert_includes text, "ne mogu potvrditi aktuelno upozorenje"
            assert_includes text, "IZMIŠLJENO ŽUTO UPOZORENJE"
            assert_not_includes text, "Izvorni period obuhvata trenutak pregleda"
          end
        end

        test "empty prepared weather check is unknown instead of absence of danger" do
          with_reviewed_weather do
            @weather_status = :empty
            @weather_notices = []
            text = ask("Ima li žuto vremensko upozorenje?", architecture: "yellow_weather_source", resolution: "source_unavailable")
            assert_includes text, "nemam potvrđen pripremljeni žuti zapis"
            assert_includes text, "nije tvrdnja da upozorenja nema"
            assert_includes text, "nivo opasnosti nula"
            assert_not_includes text, "IZMIŠLJENO ŽUTO UPOZORENJE"
          end
        end

        test "changed review with old retained yellow data cannot repeat the earlier warning" do
          with_reviewed_weather do
            ask("Ima li žuto vremensko upozorenje?", architecture: "yellow_weather_source")
            write_synthetic_weather_region(organization_host: @organization.host, region_label: "Nova autorska regija")
            text = ask("Ima li žuto vremensko upozorenje?", architecture: "yellow_weather_source", resolution: "source_unavailable")
            assert_includes text, "nemam potvrđen pripremljeni žuti zapis"
            assert_not_includes text, "IZMIŠLJENO ŽUTO UPOZORENJE"
          end
        end

        test "yellow board explanation uses actual severity policy without claiming a publication" do
          with_reviewed_weather do
            ask("Ima li žuto vremensko upozorenje?", architecture: "yellow_weather_source")
            text = ask("Zašto ga nema na gradskoj tabli?", architecture: "yellow_weather_board_boundary")
            assert_includes text, "nije među nivoima"
            assert_includes text, "Severe, Extreme"
            assert_includes text, "ne potvrđuje konkretnu objavu"
            assert_includes text, "ne dokazuje da izvor nije izdao upozorenje"
            swap_service_constant(CityServiceWeatherParser, :BOARD_SEVERITIES, %w(Moderate Severe Extreme).freeze)
            @store.reset(@context)
            text = ask("Zašto na gradskoj tabli nema žutog vremenskog upozorenja?", architecture: "yellow_weather_board_boundary")
            assert_includes text, "može ući među kandidate"
            assert_not_includes text, "nije među nivoima"
          end
        end

        test "warning validity explanation is conditional and links only own reviewed source" do
          with_reviewed_weather do
            text = ask("Ako upozorenje počinje večeras, je li opasnost sada?", architecture: "weather_warning_validity_boundary")
            assert_includes text, "Vrijeme objave i početak važenja nisu isto"
            assert_includes text, "nije dokaz da je sada sigurno ili bez rizika"
            assert_includes text, "https://weather.example.invalid/feed"
            assert_not_includes text, "meteoalarm.org"
          end
        end

        test "hourly street forecast boundary does not substitute a warning source or inherited regional forecast service" do
          text = ask("Hoće li sutra u mojoj ulici padati kiša u 10 sati?", architecture: "hourly_street_forecast_boundary")
          assert_includes text, "Nemam pregledanu prognozu po satu"
          assert_includes text, "Izvor regionalnih upozorenja nije satna prognoza"
          assert_not_includes text, "rhmzrs.com"
          assert_not_includes text, "meteoalarm.org"
        end

        test "denied public weather read cannot expose source review or event data through a direct answer" do
          with_reviewed_weather do
            @context = @context.with(capabilities: [])
            @store.reset(@context)
            text = ask("Ima li žuto vremensko upozorenje?", architecture: "yellow_weather_source", resolution: "source_unavailable")
            assert_includes text, "nemam potvrđen pripremljeni žuti zapis"
            assert_not_includes text, "weather.example.invalid"
            assert_not_includes text, "IZMIŠLJENO ŽUTO UPOZORENJE"
            assert_empty @weather_requests
          end
        end

        test "direct weather rendering preserves source and structured time across four locales" do
          with_reviewed_weather do
            %w(sr sr-Cyrl bs hr).each do |locale|
              @store.reset(@context)
              context = @context.with(deadline: Dialogue::TurnBudget.new(timeout: 9))
              message = Decidim::Bih::Concierge::WebMessage.new("Ima li žuto vremensko upozorenje?", trusted_context: context)
              result = @coordinator.send(:direct_yellow_weather, message:, state: @store.state, context:, locale:)
              assert_equal "answered", result.resolution
              assert_includes result.reply.text, "https://weather.example.invalid/feed"
              assert_includes result.reply.text, "16.09.2040."
              assert_includes Decidim::Bih::Text.fold(result.reply.text), "izmisljeno zuto upozorenje"
              assert_match(/\p{Cyrillic}/, result.reply.text) if locale == "sr-Cyrl"
            end
          end
        end

        test "yellow date followup reads requested day instead of repeating todays prepared warning" do
          with_reviewed_weather do
            ask("Ima li žuto vremensko upozorenje?", architecture: "yellow_weather_source")
            text = ask("A sutra?", architecture: "yellow_weather_source", resolution: "source_unavailable")
            assert_not_includes text, "IZMIŠLJENO ŽUTO UPOZORENJE"
            @weather_notices = [synthetic_weather_notice(starts_at: @context.now + 1.day, ends_at: @context.now + 2.days, event: "IZMIŠLJENA SUTRAŠNJA NAJAVA")]
            text = ask("A sutra?", architecture: "yellow_weather_source")
            assert_includes text, "IZMIŠLJENA SUTRAŠNJA NAJAVA"
            assert_includes text, "Objavljeni period tek predstoji"
          end
        end

        def rewrite_birth_card(**changes)
          rows = ServiceProcedures.all.map { |card| card[:key] == "maticar" ? card.merge(changes) : card }
          ServiceProcedures.instance_variable_set(:@all, rows.freeze)
        end

        def add_counter_birth_card
          online = ServiceProcedures.find("maticar")
          card = online.merge(key: "birth_extract_counter", title: "IZMIŠLJENI ŠALTERSKI POSTUPAK", channel: "counter",
                              source_url: "https://community.example.invalid/procedures/birth-extract-counter",
                              reviewed_content_hash: Digest::SHA256.hexdigest("authored-counter-source"), aliases: [], source_aliases: [],
                              steps: ["IZMIŠLJENI KORAK NA ŠALTERU."], required_documents: ["IZMIŠLJENI DOKUMENT ZA ŠALTER"],
                              fee: { administrative_fee_bam: 7.5, delivery_cost: "none", postage_amount_bam: nil },
                              delivery: { document_method: "counter", instructions_method: "counter" })
          ServiceProcedures.instance_variable_set(:@all, [*ServiceProcedures.all, card].freeze)
        end

        test "birth extract fee keeps own zero fee separate from unknown postage and unavailable counter data" do
          with_birth_extract_cards do
            text = ask("Koliko košta izvod iz matične knjige rođenih?", architecture: "birth_extract_fee_scope")
            assert_includes text, "Administrativna taksa: 0 KM"
            assert_includes text, "Iznos poštarine nije potvrđen"
            assert_includes text, "Za kanale šalter nemam dostupno pregledano uputstvo"
            assert_includes text, "community.example.invalid/procedures/maticar"
            assert_not_includes text, "Poštarina: 0"
            assert_not_includes text, "gradbijeljina.org"
          end
        end

        test "explicit counter question uses its own fee and does not borrow online zero" do
          with_birth_extract_cards do
            add_counter_birth_card
            text = ask("Koliko košta izvod iz matične knjige rođenih na šalteru?", architecture: "birth_extract_fee_scope")
            assert_includes text, "Predaja na šalteru"
            assert_includes text, "Administrativna taksa: 7.5 KM"
            assert_includes text, "ovaj kanal nema trošak dostave"
            assert_not_includes text, "Administrativna taksa: 0 KM"
            assert_not_includes text, "Online podnošenje"
          end
        end

        test "explicit channel correction changes online to counter and retains the correction in later followups" do
          with_birth_extract_cards do
            add_counter_birth_card
            ask("Koliko košta izvod iz matične knjige rođenih online?", architecture: "birth_extract_fee_scope")
            text = ask("Koliko košta izvod rođenih, ne online nego na šalteru?", architecture: "birth_extract_fee_scope")
            assert_includes text, "Administrativna taksa: 7.5 KM"
            assert_not_includes text, "Administrativna taksa: 0 KM"
            text = ask("Postoji li oslobađanje od takse?", architecture: "birth_extract_fee_exemption_scope")
            assert_includes text, "Predaja na šalteru"
            assert_includes text, "Administrativna taksa: 7.5 KM"
            assert_not_includes text, "Online podnošenje"
          end
        end

        test "unspecified birth extract channel lists separately reviewed online and counter procedures" do
          with_birth_extract_cards do
            add_counter_birth_card
            text = ask("Koliko košta izvod iz matične knjige rođenih?", architecture: "birth_extract_fee_scope")
            assert_includes text, "Online podnošenje"
            assert_includes text, "Predaja na šalteru"
            assert_includes text, "Administrativna taksa: 0 KM"
            assert_includes text, "Administrativna taksa: 7.5 KM"
            assert_includes text, "/procedures/birth-extract-counter"
            assert_not_includes text, "Ukupna cijena"
          end
        end

        test "birth extract exemption followups retain online channel and reread changed fees" do
          with_birth_extract_cards do
            add_counter_birth_card
            question = "Koliko košta izvod iz matične knjige rođenih online?"
            ask(question, architecture: "birth_extract_fee_scope")
            text = ask("Postoji li oslobađanje od takse?", architecture: "birth_extract_fee_exemption_scope")
            assert_includes text, "Pravila oslobađanja od takse nisu potvrđena"
            assert_includes text, "Nulta taksa sama ne potvrđuje"
            assert_not_includes text, "7.5 KM"
            rewrite_birth_card(fee: { administrative_fee_bam: 5, delivery_cost: "postage", postage_amount_bam: nil },
                               fee_exemptions: "IZMIŠLJENO PRAVILO OSLOBAĐANJA SAMO ONLINE")
            text = ask("A oslobađanje od takse?", architecture: "birth_extract_fee_exemption_scope")
            assert_includes text, "Administrativna taksa: 5 KM"
            assert_includes text, "IZMIŠLJENO PRAVILO OSLOBAĐANJA SAMO ONLINE"
            assert_not_includes text, "Administrativna taksa: 0 KM"
            assert_not_includes text, "7.5 KM"
            assert_equal question, @store.state.dig(Dialogue::AnswerContext::KEY, "anchor")
            assert_equal 3, @procedure_keys.size
          end
        end

        test "birth extract instructions keep own steps documents form and delivery without a counter assumption" do
          with_birth_extract_cards do
            rewrite_birth_card(required_documents: ["IZMIŠLJENI DOKUMENT A"],
                               form_download_url: "https://community.example.invalid/forms/authored-birth-request")
            text = ask("Kako da naručim izvod rođenih preko e-matičara?", architecture: "birth_extract_procedure_boundary")
            assert_includes text, "Korak 1: Izmišljeni online zahtjev"
            assert_includes text, "IZMIŠLJENI DOKUMENT A"
            assert_includes text, "/forms/authored-birth-request"
            assert_includes text, "dostave dokumenta: poštom"
            assert_includes text, "dostave uputstva: elektronskom poštom"
            assert_includes text, "ne potvrda trenutnog statusa, predaje, odobrenja ili dostave"
            assert_includes text, "ne u ovaj chat"
          end
        end

        test "email followup distinguishes emailed instructions from the document itself" do
          with_birth_extract_cards do
            ask("Kolika je taksa za e-matičar?", architecture: "ematricar_delivery")
            text = ask("Dokument stiže e-poštom?", architecture: "ematricar_delivery")
            assert_includes text, "dostave dokumenta: poštom"
            assert_includes text, "dostave uputstva: elektronskom poštom"
            assert_includes text, "samo po sebi ne znači da se i dokument dostavlja e-poštom"
            assert_equal 2, @procedure_keys.size
          end
        end

        test "reviewed electronic delivery is retained without inventing postal or email delivery" do
          with_birth_extract_cards do
            rewrite_birth_card(delivery: { document_method: "electronic", instructions_method: "portal" })
            seed_public_subject("ematricar_delivery")
            text = ask("Dokument stiže e-poštom?", architecture: "ematricar_delivery")
            assert_includes text, "dostave dokumenta: elektronski"
            assert_includes text, "dostave uputstva: na portalu"
            assert_not_includes text, "dostave dokumenta: poštom"
            assert_includes text, "samo po sebi ne znači"
          end
        end

        test "reviewed timing text is preserved without promising a delivery day" do
          with_birth_extract_cards do
            rewrite_birth_card(delivery: { document_method: "postal", instructions_method: "email", delivery_time_text: "IZMIŠLJENI OKVIR OBRADE" })
            seed_public_subject("ematricar_delivery")
            text = ask("Možeš li garantovati dan isporuke?", architecture: "ematricar_delivery")
            assert_includes text, "IZMIŠLJENI OKVIR OBRADE"
            assert_includes text, "To nije potvrda završetka ili stvarnog dolaska"
            assert_includes text, "Ne mogu obećati dan dolaska"
          end
        end

        test "generic unbound wrong-community or unreviewed registrar cards cannot supply birth facts" do
          with_birth_extract_cards do
            original = ServiceProcedures.all
            [[], original.map { |card| card.merge(document_kind: nil) }, original.map { |card| card.merge(channel: nil) },
             original.map { |card| card.merge(organization_host: nil) }, original.map { |card| card.merge(organization_host: "other.example.invalid") },
             original.map { |card| card.merge(review_status: "pending") }].each do |rows|
              @store.reset(@context)
              ServiceProcedures.instance_variable_set(:@all, rows.freeze)
              text = ask("Koliko košta izvod iz matične knjige rođenih?", architecture: "birth_extract_fee_scope")
              assert_includes text, "Nemam dostupno pregledano uputstvo"
              assert_not_includes text, "Administrativna taksa: 0 KM"
              assert_not_includes text, "community.example.invalid/procedures"
            end
          end
        end

        test "ambiguous online cards are not selected arbitrarily and do not suppress a valid counter card" do
          with_birth_extract_cards do
            duplicate = ServiceProcedures.find("maticar").merge(key: "second_online_birth")
            ServiceProcedures.instance_variable_set(:@all, [*ServiceProcedures.all, duplicate].freeze)
            reader = ReadPort.new(organization: @organization)
            result = reader.birth_extract_procedures(context: @context, channel: "online")
            assert_equal "ambiguous", result.status
            assert_empty result.facts
            add_counter_birth_card
            result = reader.birth_extract_procedures(context: @context)
            assert_equal "ok", result.status
            assert_equal ["counter"], result.coverage.fetch("available_channels")
            assert_equal ["online"], result.coverage.fetch("unavailable_channels")
            assert_equal "counter", result.facts.first.fetch("channel")
          end
        end

        test "birth extract source review barriers and effective expiry prevent retained fee replay" do
          with_birth_extract_cards do
            ask("Koliko košta izvod iz matične knjige rođenih online?", architecture: "birth_extract_fee_scope")
            card = ServiceProcedures.find("maticar")
            @procedure_payload = { "status" => "unavailable", "review_required_for_hash" => card.fetch(:reviewed_content_hash), "source_url" => card.fetch(:source_url) }
            text = ask("Postoji li oslobađanje od takse?", architecture: "birth_extract_fee_exemption_scope")
            assert_includes text, "Nemam dostupno pregledano uputstvo"
            assert_not_includes text, "Administrativna taksa: 0 KM"
            @procedure_payload = nil
            rewrite_birth_card(effective_until: "2040-09-15")
            text = ask("A oslobađanje od takse?", architecture: "birth_extract_fee_exemption_scope")
            assert_includes text, "Nemam dostupno pregledano uputstvo"
            assert_not_includes text, "Administrativna taksa: 0 KM"
          end
        end

        test "birth extract typed read keeps trusted tenant actor capability deadline channel and locale guards" do
          with_birth_extract_cards do
            reader = ReadPort.new(organization: @organization)
            [@context.with(organization_id: @organization.id + 1), @context.with(actor_id: Decidim::User.maximum(:id).to_i + 1)].each do |context|
              assert_raises(Dialogue::Contracts::Invalid) { reader.birth_extract_procedures(context:) }
            end
            assert_raises(Dialogue::Contracts::Invalid) { reader.birth_extract_procedures(context: @context, channel: "private") }
            assert_raises(Dialogue::Contracts::Invalid) { reader.birth_extract_procedures(context: @context, locale: "invalid") }
            [@context.with(capabilities: []), @context.with(deadline: Process.clock_gettime(Process::CLOCK_MONOTONIC) - 1)].each do |context|
              result = reader.birth_extract_procedures(context:)
              assert_includes %w(not_authorized unavailable), result.status
              assert_empty result.facts
            end
            %w(sr sr-Cyrl bs hr).each do |locale|
              result = reader.birth_extract_procedures(context: @context, locale:)
              assert_equal "ok", result.status
              assert_equal @organization.id, result.facts.first.dig("coverage", "organization_id")
              assert_equal @organization.host, result.facts.first.dig("coverage", "organization_host")
              assert_equal "online", result.facts.first.fetch("channel")
              assert_equal false, result.validity.fetch("live_status")
              assert_equal "https://community.example.invalid/procedures/maticar", result.facts.first.fetch("source_url")
              assert_match(/\p{Cyrillic}/, result.facts.first.fetch("text")) if locale == "sr-Cyrl"
            end
          end
        end

        test "water bill guidance can still include an explicitly reviewed role contact" do
          text = ask("Račun za vodu je pogrešan, kako da uložim reklamaciju?", architecture: "water_bill_contact_boundary")
          assert_includes text, "IZMIŠLJENI TELEFON SLUŽBE"
          assert_includes text, "/civic/water_service/phone"
          assert_includes text, "IZMIŠLJENI JAVNI E-MAIL SLUŽBE"
          assert_includes text, "ne mogu pregledati tvoj račun niti poslati reklamaciju"
          assert_not_includes text, "WRONG ROLE"
        end

        test "bulky waste contact follow-up does not invent a current collection date" do
          seed_public_subject("bulky_waste")
          text = ask("Koji je kontakt za termin odvoza?", architecture: "bulky_waste_contact_followup")
          assert_includes text, "IZMIŠLJENI TELEFON SLUŽBE"
          assert_includes text, "ne potvrđuje aktuelnu akciju odvoza ili novi termin"
          assert_not_includes text, "2026"
        end

        test "recycling location follow-up does not infer container locations from ordinary collection" do
          seed_public_subject("waste_recycling")
          text = ask("Gdje su najbliže posude kod parka?", architecture: "recycling_park_location_boundary")
          assert_includes text, "IZMIŠLJENI TELEFON SLUŽBE"
          assert_includes text, "ne mogu potvrditi najbližu"
          assert_includes text, "Redovni raspored miješanog otpada ne određuje lokaciju reciklažne posude"
        end

        test "parking payment instructions never become structured contact details" do
          reader = ReadPort.new(organization: @organization, directory: CityDirectory.for(@organization))
          result = reader.service_follow_up(source_id: "city_services:parking", focus: "website",
                                            details: %w(phone), context: @context, locale: "sr")
          assert_equal "ok", result.status
          assert_empty result.facts.select { |row| row["detail_field"] }
          assert_not_includes result.facts.to_s, "TEST-W"
        end

        test "new permit office keeps phone address and form facts without borrowing another department" do
          text = ask("Gdje da tražim novu građevinsku dozvolu?", architecture: "building_permit_office")
          assert_includes text, "IZMIŠLJENI TELEFON SLUŽBE"
          assert_includes text, "IZMIŠLJENA ADRESA SLUŽBE"
          assert_includes text, "IZMIŠLJENI OBRAZAC"
          assert_includes text, "/civic/building_permit_office/phone"
          assert_not_includes text, "WRONG ROLE"
          followup = ask("Gdje su obrazac i taksa u registru?", architecture: "building_permit_registry")
          assert_includes followup, "ne potvrđuje iznos takse"
          assert_includes followup, "IZMIŠLJENI OBRAZAC"
        end

        test "social office hours retain contact details but never promise an appointment or approval" do
          text = ask("Koje je radno vrijeme centra za socijalni rad?", architecture: "social_work_office_hours")
          assert_includes text, "IZMIŠLJENO RADNO VRIJEME"
          assert_includes text, "IZMIŠLJENA ADRESA SLUŽBE"
          assert_includes text, "nije potvrda da je termin za tvoj predmet slobodan"
          followup = ask("Znači li dolazak da je pomoć odobrena isti dan?", architecture: "social_help_approval_boundary")
          assert_includes followup, "ne znači da je pomoć odobrena"
          assert_includes followup, "ne u ovom chatu"
        end

        test "damaged public container keeps report guidance without claiming submission" do
          text = ask("Javni kontejner je oštećen, kome da prijavim?", architecture: "damaged_public_container_guidance")
          assert_includes text, "IZMIŠLJENI TELEFON SLUŽBE"
          assert_includes text, "/prijave/new"
          assert_includes text, "ako je kontejner privatnog"
          assert_includes text, "Ovdje nisam poslala prijavu"
        end

        test "named reference waste-service contact and website follow-up use this community's evidence" do
          text = ask("Koji je kontakt komunalnih usluga Komunalca?", architecture: "komunalac_service_contact")
          assert_includes text, "IZMIŠLJENI TELEFON SLUŽBE"
          assert_not_includes text, "WRONG ROLE"
          followup = ask("Koja je njihova web stranica?", architecture: "komunalac_service_contact")
          assert_includes followup, "community.example.invalid"
          assert_not_includes followup, "IZMIŠLJENI TELEFON"
        end

        test "no configured directory entry cannot inherit an office phone address or opening hours" do
          swap_service_constant(CityServicesData, :ENTRIES, [].freeze)
          CityDirectory.instance_variable_set(:@directory, Decidim::Bih::City::ServiceDirectory.new([]))
          %w(gradjevinske_dozvole_legalizacija socijalna_zastita otpad).each do |key|
            text = guidance(key, details: %w(phone address hours))
            assert_includes text, "trenutno nisu dostupni"
            assert_no_match(/https?:|\+387|0(?:55|65|66)[ \/-]/, text)
          end
        end

        test "partial facts remain useful without claiming a missing address" do
          rewrite_synthetic_civic_contacts do |data|
            data.fetch("socijalna_zastita").reject! { |row| row["predicate"] == "address" }
          end
          text = guidance("socijalna_zastita", details: %w(phone address hours))
          assert_includes text, "IZMIŠLJENI TELEFON"
          assert_includes text, "IZMIŠLJENO RADNO VRIJEME"
          assert_not_includes text, "IZMIŠLJENA ADRESA"
          assert_includes text, "Nisu dostupni svi pregledani kontaktni detalji"
        end

        test "unreviewed future and expired role facts are never presented" do
          [ { "review_state" => "unreviewed" }, { "source_checked_on" => "2041-01-01" },
            { "effective_until" => "2040-09-15" } ].each do |change|
            rewrite_synthetic_civic_contacts do |data|
              row = data.fetch("otpad").find { |value| value["subject_id"] == "waste_service" }
              row.replace(synthetic_civic_contact_fact(role: "waste_service", field: "phone").merge(change))
            end
            text = guidance("otpad", details: %w(phone))
            assert_not_includes text, "IZMIŠLJENI TELEFON"
            assert_not_includes text, "WRONG ROLE"
            assert_includes text, "Pregledana službena stranica"
          end
        end

        test "an approved administrator card never inherits shipped contact details" do
          entry = CityDirectory.for(@organization).find(:socijalna_zastita).merge(content_origin: "admin_override")
          directory = Object.new
          directory.define_singleton_method(:find) { |_| entry }
          CityDirectory.stub(:for, ->(_) { directory }) do
            text = guidance("socijalna_zastita", details: %w(phone address hours))
            assert_includes text, "Pregledana službena stranica"
            assert_not_includes text, "IZMIŠLJENI TELEFON"
            assert_not_includes text, "IZMIŠLJENA ADRESA"
            assert_not_includes text, "IZMIŠLJENO RADNO VRIJEME"
          end
        end

        test "details retain actual source citations and never assert live contact availability" do
          reader = ReadPort.new(organization: @organization, directory: CityDirectory.for(@organization))
          result = reader.service_follow_up(source_id: "city_services:socijalna_zastita", focus: "website",
                                            details: %w(phone address hours), context: @context, locale: "sr")
          assert_equal "ok", result.status
          rows = result.facts.select { |row| row["detail_field"] }
          assert_equal %w(address hours phone), rows.map { |row| row.fetch("detail_field") }.sort
          assert rows.all? { |row| row.fetch("subject_id") == "social_work_office" }
          assert rows.all? { |row| row.fetch("source_url").include?("/civic/social_work_office/") && row.fetch("provenance").any? }
          assert_equal false, result.validity.fetch("live_status")
        end

        test "an over-limit detail group is omitted whole rather than partially asserted" do
          rewrite_synthetic_civic_contacts do |data|
            data["otpad"] = 8.times.map do |i|
              synthetic_civic_contact_fact(role: "waste_service", field: "phone").merge("id" => "synthetic-phone-#{i}")
            end
          end
          text = guidance("otpad", details: %w(phone))
          assert_not_includes text, "IZMIŠLJENI TELEFON"
          assert_includes text, "Nisu dostupni svi pregledani kontaktni detalji"
        end

        test "unsupported details and other subjects cannot expose arbitrary data" do
          reader = ReadPort.new(organization: @organization, directory: CityDirectory.for(@organization))
          result = reader.service_follow_up(source_id: "city_services:socijalna_zastita", focus: "website",
                                            details: ["payment"], context: @context, locale: "sr")
          assert_equal "unavailable", result.status
          assert_empty result.facts
          text = guidance("socijalna_zastita", details: %w(phone))
          assert_not_includes text, "WRONG ROLE"
        end

        test "organization capabilities and expired deadlines still guard the actual typed read" do
          assert_raises(Dialogue::Contracts::Invalid) do
            guidance("otpad", details: %w(phone), context: @context.with(organization_id: @organization.id + 1))
          end
          [@context.with(capabilities: %w(report_guidance)),
           @context.with(deadline: Process.clock_gettime(Process::CLOCK_MONOTONIC) - 1)].each do |context|
            text = guidance("otpad", details: %w(phone), context:)
            assert_includes text, "trenutno nisu dostupni"
            assert_not_includes text, "IZMIŠLJENI TELEFON"
          end
        end
      end
    end
  end
end
