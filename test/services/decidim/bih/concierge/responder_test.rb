# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module Concierge
      class ResponderTest < ActiveSupport::TestCase
        # Minimal stand-in for an inbound message (Viber or otherwise).
        Message = Struct.new(:text, :image_url, :latitude, :longitude, keyword_init: true) do
          def initialize(text: nil, image_url: nil, latitude: nil, longitude: nil)
            super
          end
        end

        # Stub content services so each intent can be exercised in isolation.
        class FakeDirectory
          def initialize(hits) = (@hits = hits)

          def search(_query, limit: 1) = @hits.first(limit)
        end

        class FakeWaste
          def initialize(days, partial_gap: nil)
            @days = days
            @partial_gap = partial_gap
          end

          def collection_days_for(_query) = @days

          def partial_coverage_gap_for(_query) = @partial_gap
        end

        # Stub budget service: returns +amount+ for the +known+ category only.
        class FakeBudget
          def initialize(known:, amount:, year: 2040)
            @known = known
            @amount = amount
            @year = year
          end

          attr_reader :year

          def amount_for(query)
            query.to_s.downcase.include?(@known) ? @amount : nil
          end
        end

        # Stub gazette service: returns a canned hit for every search.
        class FakeGazette
          def initialize(hits) = (@hits = hits)

          def search(_query, limit: 1) = @hits.first(limit)
        end

        # Stub donations provider: a fixed cached "total raised" + donate link,
        # mirroring DecidimApp::Bijeljina::Donations' contract.
        class FakeDonations
          Totals = Struct.new(:total, :count, :currency, :as_of, keyword_init: true) # rubocop:disable Lint/StructNewOverride

          def initialize(total:, count:, url: "https://community.example.invalid/donate", currency_label: "KM")
            @total = total
            @count = count
            @url = url
            @currency_label = currency_label
          end

          attr_reader :currency_label

          def totals = Totals.new(total: BigDecimal(@total.to_s), count: @count, currency: "BAM", as_of: Time.current)

          def donate_url = @url
        end

        class FakeCityEvents
          attr_reader :queries

          def initialize(answer)
            @answer = answer
            @queries = []
          end

          def answer(text:, locale:)
            @queries << { text:, locale: }
            @answer
          end
        end

        class FakeLiveServiceAnswers
          attr_reader :queries

          def initialize(answer)
            @answer = answer
            @queries = []
          end

          def answer(text:, locale:)
            @queries << { text:, locale: }
            @answer
          end

          def match?(text:)
            text.to_s.present? && @answer.present?
          end
        end

        class FailingLiveServiceAnswers
          def answer(text:, locale:)
            raise "live source unavailable for #{text}/#{locale}"
          end
        end

        class FakeDataStatus
          attr_reader :locales

          def initialize(answer = "MI! data status")
            @answer = answer
            @locales = []
          end

          def answer(locale:)
            @locales << locale
            @answer
          end
        end

        # Stub LLM classifier: always "configured" and forces a fixed intent,
        # so we can prove the predicted intent selects the handler even when no
        # keyword is present (and that a photo still overrides it).
        class FakeClassifier
          def initialize(intent:, query: nil)
            @result = Decidim::Bih::Concierge::IntentClassifier::Result.new(intent: intent, query: query)
          end

          def configured? = true

          def classify(_text) = @result
        end

        # Records calls so guidance-only report tests can prove that an image is
        # never fetched merely because a citizen attached it.
        class FakeImageFetcher
          attr_reader :calls

          def initialize = (@calls = [])

          def call(url)
            @calls << url
            raise "guidance-only responder must not fetch #{url}"
          end
        end

        setup do
          @organization = create_organization
          @prior_flagship_slug = Decidim::Bih.flagship_process_slug
          Decidim::Bih.flagship_process_slug = "synthetic-process"
        end
        teardown { Decidim::Bih.flagship_process_slug = @prior_flagship_slug }

        def build_responder(directory: FakeDirectory.new([]), waste: FakeWaste.new(nil), # rubocop:disable Metrics/ParameterLists
                            intake: Decidim::Bih::ReportIntake.new, budget: nil, gazette: nil,
                            donations: nil, city_events: nil, live_service_answers: nil, data_status: nil,
                            classifier: nil, image_fetcher: nil,
                            allow_classifier_text_report: false)
          Responder.new(
            organization: @organization,
            directory: directory,
            waste_schedule: waste,
            report_intake: intake,
            budget: budget,
            gazette: gazette,
            donations: donations,
            city_events: city_events,
            live_service_answers: live_service_answers,
            data_status: data_status,
            classifier: classifier,
            image_fetcher: image_fetcher,
            allow_classifier_text_report: allow_classifier_text_report
          )
        end

        test "a photo whose caption mentions waste gets report-form guidance without intake" do
          responder = build_responder(waste: FakeWaste.new(%w(ponedjeljak)))
          reply = nil
          assert_no_difference -> { Decidim::Bih::Report.count } do
            reply = responder.respond(
              Message.new(text: "Prepun kontejner, slika u prilogu", image_url: "https://images.example.invalid/img.jpg")
            )
          end

          assert_nil reply.report
          assert_equal "report_guidance", reply.answer_intent
          assert_includes reply.text, Decidim::Bih::Engine.routes.url_helpers.new_report_path
        end

        test "REPORT GUIDANCE: an inbound photo never invokes the image fetcher" do
          fetcher = FakeImageFetcher.new
          responder = build_responder(image_fetcher: fetcher)
          reply = responder.respond(
            Message.new(text: "Prepun kontejner", image_url: "https://images.example.invalid/img.png")
          )

          assert_nil reply.report
          assert_empty fetcher.calls
          assert_includes reply.text, Decidim::Bih::Engine.routes.url_helpers.new_report_path
        end

        test "REPORT GUIDANCE: a bare image is evidence only and never files" do
          nil_fetcher = Object.new.tap { |o| o.define_singleton_method(:call) { |_url| nil } }
          responder = build_responder(image_fetcher: nil_fetcher)
          reply = nil
          assert_no_difference -> { Decidim::Bih::Report.count } do
            reply = responder.respond(Message.new(image_url: "https://images.example.invalid/img.png"))
          end

          assert_nil reply.report
          assert_nil reply.sticker
          assert_equal "report_guidance", reply.answer_intent
        end

        test "STATUS: returns the localized status when the report exists" do
          report = Decidim::Bih::ReportIntake.new.call(organization: @organization, description: "Test prijava")
          report.update!(status: "u_obradi")
          reply = build_responder.respond(Message.new(text: "Status za #{report.reference}?"))

          assert_equal report.id, reply.report.id
          assert_equal "status", reply.answer_intent
          assert_includes reply.text, report.reference
          assert_includes reply.text, "U obradi"
        end

        test "STATUS: not-found message for an unknown reference" do
          reply = build_responder.respond(Message.new(text: "BR-2099-9999"))

          assert_nil reply.report
          assert_equal "status", reply.answer_intent
          assert_includes reply.text, "Nisam pronašla"
          assert_includes reply.text, "BR-2099-9999"
        end

        test "CITY EVENT: answers current service questions before report fallback" do
          city_events = FakeCityEvents.new("Primjervrt: planirano isključenje struje od 09:00 do 12:00.")
          reply = build_responder(city_events:).respond(Message.new(text: "Ima li struje danas u Primjervrtu?"))

          assert_nil reply.report
          assert_equal "city_event", reply.answer_intent
          assert_includes reply.text, "Primjervrt"
          assert_equal "Ima li struje danas u Primjervrtu?", city_events.queries.first.fetch(:text)
          assert_report_quick_reply reply
        end

        test "DATA STATUS: explains available data and integrations without creating a report" do
          data_status = FakeDataStatus.new("MI! koristim budžet, otpad, izvore i integracije.")
          reply = build_responder(data_status: data_status).respond(
            Message.new(text: "Koje podatke i integracije ima MI bot?")
          )

          assert_nil reply.report
          assert_equal "data_status", reply.answer_intent
          assert_includes reply.text, "budžet"
          assert_includes reply.text, "integracije"
          assert_equal ["sr"], data_status.locales
        end

        test "DATA STATUS: classifier-promoted source questions reach the provider" do
          data_status = FakeDataStatus.new("Izvori su pregledani.")
          responder = build_responder(data_status: data_status, classifier: FakeClassifier.new(intent: :data_status))

          reply = responder.respond(Message.new(text: "what do you know"))

          assert_nil reply.report
          assert_equal "data_status", reply.answer_intent
          assert_includes reply.text, "Izvori"
        end

        test "FEEDBACK HELP: explains Nije korisno without creating a report" do
          reply = build_responder.respond(
            Message.new(text: "Šta znači ako odgovor označim kao Nije korisno?")
          )

          assert_nil reply.report
          assert_equal "help", reply.answer_intent
          assert_includes reply.text, "dobrovoljnu ocjenu"
          assert_includes reply.text, "bez povezivanja s tvojim nalogom"
          assert_includes reply.text, "ne objavljuje javno"
          assert_includes reply.text, "Korisno"
        end

        test "LIVE SERVICE: previous service turn can ground a prethodno follow-up" do
          live_service_answers = FakeLiveServiceAnswers.new("Cijene parkiranja po zoni.")
          message = Message.new(text: "prethodno koliko košta?")
          message.define_singleton_method(:conversation_context) do
            [{ "user" => "parking", "answer_intent" => "service" }]
          end

          reply = build_responder(live_service_answers:).respond(message)

          assert_nil reply.report
          assert_equal "service", reply.answer_intent
          assert_includes reply.text, "Cijene parkiranja"
          assert_equal "parking prethodno koliko košta?", live_service_answers.queries.first.fetch(:text)
        end

        # ── CYRILLIC REPLIES (reply in the script the citizen wrote in) ────────

        test "REPLY SCRIPT: a Cyrillic waste query gets a Cyrillic reply with transliterated days" do
          responder = build_responder(waste: FakeWaste.new(%w(ponedjeljak)))
          reply = responder.respond(Message.new(text: "Када је одвоз смећа у насељу Примјерврт?"))

          assert_match(/\p{Cyrillic}/, reply.text, "a Cyrillic message must get a Cyrillic reply")
          # Day names are stored Latin in the schedule; a Cyrillic reply transliterates them.
          assert_includes reply.text, Decidim::Bih::Transliterator.call("ponedjeljak")
          assert_not_includes reply.text, "ponedjeljak"
        end

        test "REPLY SCRIPT: a Latin waste query keeps a Latin reply (regression)" do
          responder = build_responder(waste: FakeWaste.new(%w(ponedjeljak)))
          reply = responder.respond(Message.new(text: "Kada je odvoz smeća u naselju Primjervrt?"))

          assert_includes reply.text, "ponedjeljak"
          assert_no_match(/\p{Cyrillic}/, reply.text)
        end

        test "REPLY SCRIPT: a Cyrillic status query replies in Cyrillic but keeps the Latin reference" do
          report = Decidim::Bih::ReportIntake.new.call(organization: @organization, description: "Тест пријава")
          report.update!(status: "u_obradi")

          reply = build_responder.respond(Message.new(text: "Статус за #{report.reference}?"))

          assert_equal report.id, reply.report.id
          assert_includes reply.text, report.reference, "the BR-… reference must stay Latin"
          assert_includes reply.text, I18n.t("decidim.bih.reports.public_statuses.in_progress", locale: "sr-Cyrl")
        end

        test "WASTE: answers with the collection days on a hit" do
          responder = build_responder(waste: FakeWaste.new(%w(ponedjeljak četvrtak)))
          reply = responder.respond(Message.new(text: "Kada je odvoz smeća u naselju Primjervrt?"))

          assert_nil reply.report
          assert_equal "waste", reply.answer_intent
          assert_includes reply.text, "ponedjeljak"
          assert_includes reply.text, "Primjervrt"
        end

        test "WASTE: app-provided source metadata is cited when available" do
          sourced_waste = Class.new(FakeWaste) do
            def source_provider = "IZMIŠLJENA SLUŽBA OTPADA"

            def source_kind = "Program odvoza otpada za 2040. godinu, lokalni snimak PDF-a"

            def source_checked_at = Date.new(2040, 9, 14)

            def source_url = "https://komunalac.example/program.pdf"
          end.new(%w(utorak))

          reply = build_responder(waste: sourced_waste).respond(
            Message.new(text: "kada se vozi smeće iz ulice primjerave")
          )

          assert_nil reply.report
          assert_equal "waste", reply.answer_intent
          assert_includes reply.text, "Odvoz otpada za „primjerave“: utorak"
          assert_includes reply.text, "Izvor: IZMIŠLJENA SLUŽBA OTPADA"
          assert_includes reply.text, "lokalni snimak PDF-a"
          assert_includes reply.text, "provjereno 14.09.2040."
          assert_includes reply.text, "https://komunalac.example/program.pdf"
        end

        test "WASTE: Cyrillic (sr-Cyrl) message still triggers the waste intent" do
          # sr-Cyrl is a first-class enabled locale; a citizen writing in Cyrillic
          # must reach the same intents as a Latin writer. "смеће" -> "smece".
          responder = build_responder(waste: FakeWaste.new(%w(ponedjeljak)))
          reply = responder.respond(Message.new(text: "Када је одвоз смећа у насељу Примјерврт?"))

          assert_nil reply.report
          # Routed to waste (not the report catch-all); the reply is now Cyrillic,
          # so the day name is the transliterated form.
          assert_includes reply.text, Decidim::Bih::Transliterator.call("ponedjeljak")
        end

        test "WASTE: couldn't-find message when the street is unknown" do
          responder = build_responder(waste: FakeWaste.new(nil))
          reply = responder.respond(Message.new(text: "odvoz smeća Nepostojeća ulica"))

          assert_nil reply.report
          assert_includes reply.text.downcase, "nisam pronašla"
        end

        test "WASTE: known partial coverage gap is disclosed instead of generic miss" do
          partial_gap = {
            districts: ["Rejon 2", "Rejon 3", "Rejon 4"],
            source_url: "https://komunalac.example/program.pdf"
          }
          waste = FakeWaste.new(nil, partial_gap:)
          reply = build_responder(waste: waste).respond(Message.new(text: "odvoz smeća Rejon 2"))

          assert_nil reply.report
          assert_equal "waste", reply.answer_intent
          assert_includes reply.text, "nepokriveni"
          assert_includes reply.text, "Rejon 2"
          assert_includes reply.text, "https://komunalac.example/program.pdf"
        end

        # Round 28 R2 (shared Text.fold): a waste keyword carrying trailing
        # punctuation ("smeće?") is now folded to "smece" and correctly stripped
        # from the area lookup, instead of leaking into it as it did before the
        # shared folder normalized punctuation. Locks that improvement in.
        test "WASTE: a punctuated keyword is stripped from the area query, not leaked" do
          captured = nil
          recording_waste = Class.new do
            define_method(:collection_days_for) do |query|
              captured = query
              %w(ponedjeljak)
            end
          end.new

          responder = build_responder(waste: recording_waste)
          responder.respond(Message.new(text: "raspored za smeće? Primjervrt"))

          assert_not_nil captured, "the waste service must be consulted"
          assert_not_includes captured.downcase, "sme",
                              "the waste keyword must not leak into the area query"
          assert_includes captured.downcase, "primjervrt", "the real area must remain"
        end

        test "SERVICE: returns the directory answer + source for a question" do
          directory = FakeDirectory.new([{ answer: "Izvod tražite online.", source_url: "https://community.example.invalid/maticar" }])
          reply = build_responder(directory: directory).respond(Message.new(text: "Gdje vadim izvod iz matične?"))

          assert_nil reply.report
          assert_equal "service", reply.answer_intent
          assert_includes reply.text, "Izvod tražite online."
          assert_includes reply.text, "https://community.example.invalid/maticar"
          assert_includes reply.text, "napiši konkretnije"
          assert_report_quick_reply reply
        end

        test "SERVICE: live source answers win over static directory links" do
          directory = FakeDirectory.new([{ answer: "Statičan odgovor sa linkom.", source_url: "https://community.example.invalid/link" }])
          live = FakeLiveServiceAnswers.new("Trenutno očitanje: IZMIŠLJENI SENZOR PM2.5 23 µg/m³.")
          reply = build_responder(directory: directory, live_service_answers: live).respond(
            Message.new(text: "kakav je kvalitet vazduha u Bijeljini?")
          )

          assert_nil reply.report
          assert_equal "service", reply.answer_intent
          assert_includes reply.text, "PM2.5 23"
          assert_not_includes reply.text, "https://community.example.invalid/link"
          assert_equal "kakav je kvalitet vazduha u Bijeljini?", live.queries.first.fetch(:text)
          assert_equal "sr", live.queries.first.fetch(:locale)
          assert_report_quick_reply reply
        end

        test "SERVICE: classifier-promoted help yields to live service signals" do
          live = FakeLiveServiceAnswers.new("P2 Izmišljeni testni trg u 13:23.")
          responder = build_responder(live_service_answers: live, classifier: FakeClassifier.new(intent: :help))

          reply = responder.respond(Message.new(text: "P2 sljeddeći autobus iz centra"))

          assert_nil reply.report
          assert_equal "service", reply.answer_intent
          assert_includes reply.text, "13:23"
        end

        test "SERVICE: live source failures fall through to static directory answers" do
          directory = FakeDirectory.new([{ answer: "Izvod tražite online.", source_url: "https://community.example.invalid/maticar" }])
          warnings = []
          reply = Rails.logger.stub(:warn, ->(message) { warnings << message }) do
            build_responder(directory: directory, live_service_answers: FailingLiveServiceAnswers.new).respond(
              Message.new(text: "Gdje vadim izvod iz matične?")
            )
          end

          assert_nil reply.report
          assert_equal "service", reply.answer_intent
          assert_includes reply.text, "Izvod tražite online."
          assert_includes reply.text, "https://community.example.invalid/maticar"
          assert_report_quick_reply reply
          assert_equal ["[Concierge] live_service_answer_failed error_class=RuntimeError"], warnings
          assert_not_includes warnings.first, "Gdje vadim izvod"
        end

        test "SERVICE: generic phone questions are not stolen by MZ contact guidance" do
          directory = FakeDirectory.new([{ answer: "Vodovod: TEST-WATER-CONTACT.", source_url: "https://community.example.invalid/vodovod" }])
          reply = build_responder(directory: directory).respond(Message.new(text: "telefon vodovoda"))

          assert_nil reply.report
          assert_equal "service", reply.answer_intent
          assert_includes reply.text, "Vodovod"
        end

        test "BUDGET: answers with the thousands-formatted amount for a known category" do
          budget = FakeBudget.new(known: "socijalni rad", amount: 123_456, year: 2040)
          reply = build_responder(budget: budget).respond(
            Message.new(text: "koliko je izdvojeno za socijalni rad")
          )

          assert_nil reply.report
          assert_equal "budget", reply.answer_intent
          assert_includes reply.text, "123.456"
          assert_includes reply.text, "socijalni rad"
          assert_includes reply.text, "2040"
        end

        test "BUDGET: not-found message for a budget keyword with no matching category" do
          budget = FakeBudget.new(known: "socijalni rad", amount: 123_456)
          reply = build_responder(budget: budget).respond(
            Message.new(text: "koliko je izdvojeno za svemirski program")
          )

          assert_nil reply.report
          assert_includes reply.text, "svemirski program"
          assert_includes reply.text.downcase, "nisam pronašla"
        end

        test "BUDGET: intent is skipped (falls through) when no budget service is wired" do
          # No budget dep + no gazette/service hit + short text => fallback help.
          reply = build_responder.respond(Message.new(text: "budžet"))

          assert_nil reply.report
          assert_includes reply.text, "Ne treba ti naziv odjeljenja"
        end

        test "BUDGET: a photo with a budget keyword yields report guidance without a write" do
          budget = FakeBudget.new(known: "socijalni rad", amount: 123_456)
          responder = build_responder(budget: budget)
          reply = nil
          assert_no_difference -> { Decidim::Bih::Report.count } do
            reply = responder.respond(
              Message.new(text: "koliko je izdvojeno za socijalni rad", image_url: "https://images.example.invalid/3.jpg")
            )
          end

          assert_nil reply.report
          assert_equal "report_guidance", reply.answer_intent
          assert_includes reply.text, Decidim::Bih::Engine.routes.url_helpers.new_report_path
        end

        test "GAZETTE: answers with the issue number + url for a decision question" do
          gazette = FakeGazette.new([{ number: "12/2040", date: "2040-05-10",
                                       url: "https://gazette.example.invalid/12-2040.pdf", summary: "Odluka o parkingu" }])
          reply = build_responder(gazette: gazette).respond(Message.new(text: "odluka o parkingu"))

          assert_nil reply.report
          assert_equal "gazette", reply.answer_intent
          assert_includes reply.text, "12/2040"
          assert_includes reply.text, "https://gazette.example.invalid/12-2040.pdf"
        end

        test "GAZETTE: renders cleanly with no dangling label when the summary is nil" do
          gazette = FakeGazette.new([{ number: "3/2040", date: "2040-02-01",
                                       url: "https://gazette.example.invalid/3-2040.pdf", summary: nil }])
          reply = build_responder(gazette: gazette).respond(Message.new(text: "odluka o budžetu skupštine"))

          assert_includes reply.text, "https://gazette.example.invalid/3-2040.pdf"
          assert_not reply.text.end_with?(" "), "no trailing space when the summary is nil"
        end

        test "GAZETTE: intent is skipped (falls through) when no gazette service is wired" do
          reply = build_responder.respond(Message.new(text: "glasnik"))

          assert_nil reply.report
          assert_includes reply.text, "Ne treba ti naziv odjeljenja"
        end

        test "GAZETTE wins over BUDGET when both are wired and it is a decision question" do
          budget = FakeBudget.new(known: "nepostojeci", amount: 1)
          gazette = FakeGazette.new([{ number: "5/2040", date: "2040-04-07",
                                       url: "https://gazette.example.invalid/5.pdf", summary: nil }])
          reply = build_responder(budget: budget, gazette: gazette).respond(
            Message.new(text: "Šta je skupština odlučila o budžetu?")
          )

          assert_includes reply.text, "5/2040"
          assert_includes reply.text, "https://gazette.example.invalid/5.pdf"
        end

        test "GAZETTE: not-found when a decision keyword has no matching issue" do
          gazette = FakeGazette.new([])
          reply = build_responder(gazette: gazette).respond(Message.new(text: "odluka o necemu nepostojecem"))

          assert_nil reply.report
          assert_includes reply.text.downcase, "nisam pronašla rezultat"
        end

        test "BUDGET strips declined keyword forms (budžeta) from the category" do
          budget = FakeBudget.new(known: "sport", amount: 500_000)
          reply = build_responder(budget: budget).respond(
            Message.new(text: "koliko je budžeta izdvojeno za sport")
          )

          assert_includes reply.text, "500.000"
        end

        test "DONATION: answers with the raised amount, count and donate link" do
          donations = FakeDonations.new(total: 1250, count: 28)
          reply = build_responder(donations: donations).respond(
            Message.new(text: "Koliko je do sada prikupljeno?")
          )

          assert_nil reply.report
          assert_equal "donation", reply.answer_intent
          assert_includes reply.text, "1.250"
          assert_includes reply.text, "KM"
          assert_includes reply.text, "28"
          assert_includes reply.text, "https://community.example.invalid/donate"
        end

        test "DONATION: a donacije keyword also triggers the donation intent" do
          donations = FakeDonations.new(total: 500, count: 10)
          reply = build_responder(donations: donations).respond(
            Message.new(text: "Gdje mogu da vidim donacije?")
          )

          assert_includes reply.text, "500"
          assert_includes reply.text, "https://community.example.invalid/donate"
        end

        test "DONATION: intent is skipped (falls through) when no donations provider is wired" do
          # Short, non-substantive text so it can't become a report; with no
          # donations dep it must fall through to the help menu.
          reply = build_responder.respond(Message.new(text: "prikupljeno"))

          assert_nil reply.report
          assert_includes reply.text, "Ne treba ti naziv odjeljenja"
        end

        test "DONATION: a photo with a donation keyword yields report guidance without a write" do
          donations = FakeDonations.new(total: 100, count: 2)
          responder = build_responder(donations: donations)
          reply = nil
          assert_no_difference -> { Decidim::Bih::Report.count } do
            reply = responder.respond(
              Message.new(text: "koliko je prikupljeno", image_url: "https://images.example.invalid/d.jpg")
            )
          end

          assert_nil reply.report
          assert_equal "report_guidance", reply.answer_intent
        end

        test "DONATION: a classifier :donation intent is wired and serves the donation reply" do
          # Mirrors the budget/waste intents: the handler still keyword self-gates
          # (so a misclassification falls through), but the intent IS promotable.
          donations = FakeDonations.new(total: 777, count: 9)
          responder = build_responder(donations: donations, classifier: FakeClassifier.new(intent: :donation))

          reply = responder.respond(Message.new(text: "ima li donacija u fondu"))

          assert_includes reply.text, "777"
          assert_includes reply.text, "https://community.example.invalid/donate"
        end

        test "UNKNOWN: substantive text alone clarifies through the help menu without filing" do
          responder = build_responder
          reply = nil
          assert_no_difference -> { Decidim::Bih::Report.count } do
            reply = responder.respond(Message.new(text: "Komšije bučno renoviraju stan cijelu noć svaku noć"))
          end

          assert_nil reply.report
          assert_equal "help", reply.answer_intent
          assert_includes reply.text, "Ne treba ti naziv odjeljenja"
          assert_nil reply.sticker, "guidance must not claim a completed submission"
        end

        test "non-report replies carry no sticker" do
          # The help/fallback menu is not a sticker-worthy event.
          reply = build_responder.respond(Message.new(text: "hej"))
          assert_nil reply.sticker
        end

        test "REPORT GUIDANCE: a photo without text never files a report" do
          responder = build_responder
          reply = nil
          assert_no_difference -> { Decidim::Bih::Report.count } do
            reply = responder.respond(Message.new(image_url: "https://images.example.invalid/1.jpg"))
          end

          assert_nil reply.report
          assert_includes reply.text, Decidim::Bih::Engine.routes.url_helpers.new_report_path
        end

        test "REPORT GUIDANCE: a photo and GPS skip service but never auto-submit" do
          directory = FakeDirectory.new([{ answer: "x", source_url: "y" }])
          responder = build_responder(directory: directory)
          reply = nil
          assert_no_difference -> { Decidim::Bih::Report.count } do
            reply = responder.respond(Message.new(text: "rupa", image_url: "https://images.example.invalid/2.jpg",
                                                  latitude: 0.5, longitude: 0.5))
          end

          assert_nil reply.report
          assert_equal "report_guidance", reply.answer_intent
          assert_includes reply.text, Decidim::Bih::Engine.routes.url_helpers.new_report_path
        end

        test "FALLBACK: short, non-actionable text gets the help menu" do
          reply = build_responder.respond(Message.new(text: "hej"))

          assert_nil reply.report
          assert_equal "help", reply.answer_intent
          assert_includes reply.text, "Ne treba ti naziv odjeljenja"
        end

        test "SETUP: registration and verification questions return setup guidance" do
          reply = build_responder.respond(Message.new(text: "kako da se registrujem i verifikujem nalog pismom"))

          assert_nil reply.report
          assert_equal "setup", reply.answer_intent
          assert_includes reply.text, "/registracija"
          assert_includes reply.text, "/biceriseno/moj-nalog"
          assert_includes reply.text, "/biceriseno/verifikacija"
          assert_includes reply.text, "/biceriseno/komsiluk"
          assert_includes reply.text, "/notifications_settings"
        end

        test "SETUP: classifier-promoted setup can answer a keyword-light onboarding question" do
          responder = build_responder(classifier: FakeClassifier.new(intent: :setup))

          reply = responder.respond(Message.new(text: "where do I start"))

          assert_nil reply.report
          assert_equal "setup", reply.answer_intent
          assert_includes reply.text, "/biceriseno/moj-nalog"
        end

        test "REPORT GUIDANCE: how-to report questions stay read-only" do
          reply = nil

          assert_no_difference -> { Decidim::Bih::Report.count } do
            reply = build_responder.respond(Message.new(text: "kako da prijavim rupu u putu"))
          end

          assert_nil reply.report
          assert_equal "report_guidance", reply.answer_intent
          assert_includes reply.text, Decidim::Bih::Engine.routes.url_helpers.new_report_path
          assert_report_quick_reply reply
        end

        test "UNKNOWN: a plain problem description stays read-only and gets the safe menu" do
          reply = nil

          assert_no_difference -> { Decidim::Bih::Report.count } do
            reply = build_responder.respond(Message.new(text: "Velika rupa na putu kod škole"))
          end

          assert_nil reply.report
          assert_equal "help", reply.answer_intent
          assert_includes reply.text, "Ne treba ti naziv odjeljenja"
        end

        test "PARTICIPATION GUIDANCE: classifier-promoted questions link to the process" do
          responder = build_responder(classifier: FakeClassifier.new(intent: :participation_guidance))

          reply = responder.respond(Message.new(text: "where can citizens join"))

          assert_nil reply.report
          assert_equal "participation_guidance", reply.answer_intent
          assert_includes reply.text, "/processes/"
        end

        test "VOLUNTEER GUIDANCE: volunteer questions link to volunteer actions" do
          reply = build_responder.respond(Message.new(text: "hoću da volontiram i upišem sate"))

          assert_nil reply.report
          assert_equal "volunteer_guidance", reply.answer_intent
          assert_includes reply.text, Decidim::Bih::Engine.routes.url_helpers.volunteer_path
        end

        test "LOCAL AREA GUIDANCE: public MZ contact by name" do
          Decidim::Bih::LocalArea.create!(
            organization: @organization,
            kind: "mz",
            slug: "primjervrt",
            name: { "sr" => "Primjervrt", "en" => "Primjervrt" },
            predsjednik: "IZMIŠLJENI PREDSTAVNIK",
            telefon: "TEST-PHONE"
          )

          reply = build_responder.respond(Message.new(text: "ko je predsjednik MZ Primjervrt"))

          assert_nil reply.report
          assert_equal "local_area_guidance", reply.answer_intent
          assert_includes reply.text, "Primjervrt"
          assert_includes reply.text, "IZMIŠLJENI PREDSTAVNIK"
          assert_includes reply.text, "TEST-PHONE"
          assert_includes reply.text, Decidim::Bih::Engine.routes.url_helpers.mz_area_path(slug: "primjervrt")
        end

        # --- quick-reply civic shortcut chips -------------------------------

        test "FALLBACK: the help reply carries civic shortcut quick replies" do
          reply = build_responder.respond(Message.new(text: "hej"))

          chips = reply.quick_replies
          assert_kind_of Array, chips
          assert chips.any?, "the help/fallback reply must offer civic shortcuts"

          labels = chips.map { |chip| chip[:label] }
          assert_includes labels, I18n.t("decidim.bih.concierge.widget.quick.report_describe", locale: "sr")
          assert_includes labels, I18n.t("decidim.bih.concierge.widget.quick.report_form", locale: "sr")
          assert_includes labels, I18n.t("decidim.bih.concierge.widget.quick.idea", locale: "sr")
          assert_includes labels, I18n.t("decidim.bih.concierge.widget.quick.budget", locale: "sr")
          assert_includes labels, I18n.t("decidim.bih.concierge.widget.quick.donate", locale: "sr")

          # Every chip carries exactly one action: a navigable target or a canned message.
          assert chips.all? { |chip| chip.slice(:url, :send).compact.size == 1 }, "each chip must carry a url or a send"

          describe_chip = chips.find { |chip| chip[:label] == I18n.t("decidim.bih.concierge.widget.quick.report_describe", locale: "sr") }
          assert_equal I18n.t("decidim.bih.concierge.widget.quick.report_describe_send", locale: "sr"), describe_chip[:send]

          report_chip = chips.find { |chip| chip[:label] == I18n.t("decidim.bih.concierge.widget.quick.report_form", locale: "sr") }
          assert_equal Decidim::Bih::Engine.routes.url_helpers.new_report_path, report_chip[:url]

          donate_chip = chips.find { |chip| chip[:label] == I18n.t("decidim.bih.concierge.widget.quick.donate", locale: "sr") }
          assert_equal Decidim::Bih::Engine.routes.url_helpers.community_projects_path, donate_chip[:url]
        end

        test "HELP: capability questions use the help reply even without the classifier" do
          directory = FakeDirectory.new([{ answer: "Wrong service answer.", source_url: "https://community.example.invalid/wrong" }])
          reply = build_responder(directory: directory).respond(Message.new(text: "sta sve mozes da uradis"))

          assert_nil reply.report
          assert_equal "help", reply.answer_intent
          assert_not_includes reply.text, "Wrong service answer."
          assert_not_empty reply.quick_replies
        end

        test "FALLBACK: chip labels follow the reply script (Cyrillic message → Cyrillic labels)" do
          reply = build_responder.respond(Message.new(text: "ћао"))

          labels = reply.quick_replies.map { |chip| chip[:label] }
          assert_includes labels, I18n.t("decidim.bih.concierge.widget.quick.report_form", locale: "sr-Cyrl")
          assert_includes labels, I18n.t("decidim.bih.concierge.widget.quick.report_describe", locale: "sr-Cyrl")
        end

        test "a substantive (status) reply carries NO quick replies" do
          report = Decidim::Bih::ReportIntake.new.call(organization: @organization, description: "Test prijava")
          reply = build_responder.respond(Message.new(text: "Status za #{report.reference}?"))

          assert_empty reply.quick_replies, "substantive answers must not show civic chips"
        end

        test "a substantive (waste) reply carries NO quick replies" do
          responder = build_responder(waste: FakeWaste.new(%w(ponedjeljak)))
          reply = responder.respond(Message.new(text: "Kada je odvoz smeća u naselju Primjervrt?"))

          assert_empty reply.quick_replies
        end

        test "WASTE: street filler words and case forms are stripped from the area" do
          captured = nil
          recording_waste = Class.new do
            define_method(:collection_days_for) do |query|
              captured = query
              %w(utorak)
            end
          end.new
          responder = build_responder(waste: recording_waste)

          reply = responder.respond(Message.new(text: "kada se vozi smeće iz ulice primjerave"))

          assert_nil reply.report
          assert_equal "waste", reply.answer_intent
          assert_equal "primjerave", captured
          assert_includes reply.text, "primjerave"
          assert_not_includes reply.text, "ulice primjerave"
        end

        test "unknown substantive text returns help choices without filing a report" do
          reply = build_responder.respond(Message.new(text: "Komšije bučno renoviraju stan cijelu noć svaku noć"))

          assert_nil reply.report
          assert_equal "help", reply.answer_intent
          assert_report_quick_reply reply
        end

        # Substantive answers carry the single "Prijavi problem" form chip; the
        # help menu carries the split "Obrazac sa fotografijom" chip. Both
        # navigate to the report intake form.
        def assert_report_quick_reply(reply)
          report_labels = [
            I18n.t("decidim.bih.concierge.widget.quick.report", locale: "sr"),
            I18n.t("decidim.bih.concierge.widget.quick.report_form", locale: "sr")
          ]
          report_chip = reply.quick_replies.find { |chip| report_labels.include?(chip[:label]) }

          assert_not_nil report_chip, "expected a report quick-reply chip"
          assert_equal Decidim::Bih::Engine.routes.url_helpers.new_report_path, report_chip[:url]
        end

        # --- LLM intent routing (with a stub, key-less classifier) ----------

        test "LLM intent routes a keyword-less question to the SERVICE handler" do
          directory = FakeDirectory.new([{ answer: "Porez se plaća online.", source_url: "https://community.example.invalid/porez" }])
          responder = build_responder(directory: directory, classifier: FakeClassifier.new(intent: :service))

          # No service keyword present; only the classifier promotes service.
          reply = responder.respond(Message.new(text: "gdje da platim porez"))

          assert_nil reply.report
          assert_includes reply.text, "Porez se plaća online."
          assert_includes reply.text, "https://community.example.invalid/porez"
        end

        test "LLM help intent answers a keywordless capability question before service overmatching" do
          directory = FakeDirectory.new([{ answer: "Ne treba biti izabrano.", source_url: "https://community.example.invalid/wrong" }])
          responder = build_responder(directory: directory, classifier: FakeClassifier.new(intent: :help))

          reply = responder.respond(Message.new(text: "sta sve mozes da uradis"))

          assert_nil reply.report
          assert_equal "help", reply.answer_intent
          assert_includes reply.text, I18n.t("decidim.bih.concierge.help", locale: "sr").lines.first.strip
          assert_not_includes reply.text, "Ne treba biti izabrano."
          assert_not_empty reply.quick_replies
        end

        test "LLM query routes a keyword-less question to the WASTE lookup" do
          captured = nil
          recording_waste = Class.new do
            define_method(:collection_days_for) do |query|
              captured = query
              %w(ponedjeljak)
            end
          end.new
          responder = build_responder(
            waste: recording_waste,
            classifier: FakeClassifier.new(intent: :waste, query: "Primjervrt")
          )

          reply = responder.respond(Message.new(text: "when is pickup"))

          assert_nil reply.report
          assert_equal "waste", reply.answer_intent
          assert_equal "Primjervrt", captured
          assert_includes reply.text, "ponedjeljak"
        end

        test "LLM waste query slots are normalized before lookup" do
          captured = nil
          recording_waste = Class.new do
            define_method(:collection_days_for) do |query|
              captured = query
              %w(utorak)
            end
          end.new
          responder = build_responder(
            waste: recording_waste,
            classifier: FakeClassifier.new(intent: :waste, query: "ulice primjerave")
          )

          reply = responder.respond(Message.new(text: "kada se vozi smeće iz ulice primjerave"))

          assert_nil reply.report
          assert_equal "waste", reply.answer_intent
          assert_equal "primjerave", captured
          assert_not_includes reply.text, "ulice primjerave"
        end

        test "LLM waste misclassification yields to explicit live-service signals" do
          waste = Class.new do
            def collection_days_for(_query) = raise("waste should not run for autobus")
          end.new
          live = FakeLiveServiceAnswers.new("Sljedeći polazak: P1 Bijeljina - Primjervrt u 13:19.")
          responder = build_responder(
            waste: waste,
            live_service_answers: live,
            classifier: FakeClassifier.new(intent: :waste, query: "primjervrtu")
          )

          reply = responder.respond(Message.new(text: "kada je sljedeći autobus iz centra za primjervrtu"))

          assert_nil reply.report
          assert_equal "service", reply.answer_intent
          assert_includes reply.text, "P1"
          assert_equal "kada je sljedeći autobus iz centra za primjervrtu", live.queries.first.fetch(:text)
        end

        test "LLM query routes a keyword-less question to the BUDGET lookup" do
          budget = FakeBudget.new(known: "sport", amount: 500_000, year: 2040)
          responder = build_responder(
            budget: budget,
            classifier: FakeClassifier.new(intent: :budget, query: "sport")
          )

          reply = responder.respond(Message.new(text: "what about sports funding"))

          assert_nil reply.report
          assert_equal "budget", reply.answer_intent
          assert_includes reply.text, "500.000"
          assert_includes reply.text, "2040"
        end

        test "LLM city_event intent is promotable and records city_event metadata" do
          city_events = FakeCityEvents.new("Primjervrt: planirano isključenje struje od 09:00 do 12:00.")
          responder = build_responder(
            city_events: city_events,
            classifier: FakeClassifier.new(intent: :city_event, query: "Primjervrt")
          )

          reply = responder.respond(Message.new(text: "anything planned today?"))

          assert_nil reply.report
          assert_equal "city_event", reply.answer_intent
          assert_includes reply.text, "Primjervrt"
          assert_includes city_events.queries.first.fetch(:text), "Primjervrt"
        end

        test "a photo stays guidance-only even when the classifier says :service" do
          directory = FakeDirectory.new([{ answer: "x", source_url: "y" }])
          responder = build_responder(directory: directory, classifier: FakeClassifier.new(intent: :service))
          reply = nil
          assert_no_difference -> { Decidim::Bih::Report.count } do
            reply = responder.respond(Message.new(text: "neko pitanje", image_url: "https://images.example.invalid/9.jpg"))
          end

          assert_nil reply.report
          assert_equal "report_guidance", reply.answer_intent
          assert_includes reply.text, Decidim::Bih::Engine.routes.url_helpers.new_report_path
        end

        test "a misclassification degrades to keyword routing (handler self-gates and falls through)" do
          # Classifier wrongly says :waste, but there is no waste service hit and
          # no waste keyword, so it falls through; a real budget keyword wins.
          budget = FakeBudget.new(known: "sport", amount: 500_000, year: 2040)
          responder = build_responder(budget: budget, classifier: FakeClassifier.new(intent: :waste))

          reply = responder.respond(Message.new(text: "koliko je izdvojeno za sport"))

          assert_nil reply.report
          assert_includes reply.text, "500.000"
        end

        test ":help intent leaves explicit deterministic keyword answers untouched" do
          gazette = FakeGazette.new([{ number: "9/2041", date: "2041-01-01",
                                       url: "https://gazette.example.invalid/9.pdf", summary: nil }])
          responder = build_responder(gazette: gazette, classifier: FakeClassifier.new(intent: :help))

          reply = responder.respond(Message.new(text: "odluka o parkingu"))

          assert_includes reply.text, "9/2041"
        end

        test ":unknown intent leaves the keyword order untouched" do
          gazette = FakeGazette.new([{ number: "9/2041", date: "2041-01-01",
                                       url: "https://gazette.example.invalid/9.pdf", summary: nil }])
          responder = build_responder(gazette: gazette, classifier: FakeClassifier.new(intent: :unknown))

          reply = responder.respond(Message.new(text: "odluka o parkingu"))

          assert_includes reply.text, "9/2041"
        end

        test "classifier :report does NOT hijack an answerable question (no spurious report)" do
          # :report is deliberately not promotable — an LLM misclassification or
          # prompt injection must not file a report instead of answering.
          budget = FakeBudget.new(known: "socijalni rad", amount: 123_456)
          responder = build_responder(budget: budget, classifier: FakeClassifier.new(intent: :report))

          reply = nil
          assert_no_difference -> { Decidim::Bih::Report.count } do
            reply = responder.respond(Message.new(text: "koliko je izdvojeno za socijalni rad"))
          end

          assert_includes reply.text, "123.456"
          assert_nil reply.report
        end

        test "classifier :report can be enabled for non-persisting web guidance only" do
          guidance_intake = Object.new
          guidance_intake.define_singleton_method(:call) { |**| raise "guidance intake must not be invoked" }
          directory = FakeDirectory.new([{ answer: "Wrong service answer.", source_url: "https://community.example.invalid/wrong" }])
          responder = build_responder(
            directory: directory,
            intake: guidance_intake,
            classifier: FakeClassifier.new(intent: :report, query: "rupa kod škole"),
            allow_classifier_text_report: true
          )

          reply = responder.respond(Message.new(text: "imam rupu na putu kod skole sta da radim"))

          assert_equal "report_guidance", reply.answer_intent
          assert_nil reply.report
          assert_includes reply.text, Decidim::Bih::Engine.routes.url_helpers.new_report_path
          assert_not_includes reply.text, "Wrong service answer."
        end

        test "a threat routes to immediate safety guidance and never creates a report" do
          responder = build_responder(classifier: FakeClassifier.new(intent: :report))
          reply = nil

          assert_no_difference -> { Decidim::Bih::Report.count } do
            reply = responder.respond(
              Message.new(text: "Neko mi prijeti", image_url: "https://cdn.example/threat.jpg")
            )
          end

          assert_equal "safety", reply.answer_intent
          assert_equal "core", reply.tone
          assert_includes reply.text, "122"
          assert_nil reply.report
        end

        test "a message containing a personal identifier routes to privacy guidance" do
          responder = build_responder(classifier: FakeClassifier.new(intent: :report))
          reply = nil

          assert_no_difference -> { Decidim::Bih::Report.count } do
            reply = responder.respond(Message.new(text: "Moj JMBG je 0000000000000"))
          end

          assert_equal "privacy", reply.answer_intent
          assert_equal "core", reply.tone
          assert_includes reply.text, "JMBG"
          assert_nil reply.report
        end

        test "a corruption allegation stays guidance-only and never creates a report" do
          responder = build_responder(classifier: FakeClassifier.new(intent: :report))
          reply = nil

          assert_no_difference -> { Decidim::Bih::Report.count } do
            reply = responder.respond(Message.new(text: "Ovaj službenik prima mito i korumpiran je"))
          end

          assert_equal "moderation", reply.answer_intent
          assert_equal "core", reply.tone
          assert_nil reply.report
        end
        test "unconfigured participation uses the public hub without inventing a process URL" do
          Decidim::Bih.flagship_process_slug = nil
          reply = build_responder(classifier: FakeClassifier.new(intent: :participation_guidance)).respond(
            Message.new(text: "where can citizens join")
          )
          assert_equal "participation_guidance", reply.answer_intent
          assert_includes reply.text, Decidim::Bih.public_path
          assert_not_includes reply.text, "/processes/"
          assert_nil reply.report
        end

      end
    end
  end
end
