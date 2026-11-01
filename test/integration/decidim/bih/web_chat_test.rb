# frozen_string_literal: true

require "test_helper"
require "capybara"
require_relative "../../../support/native_milica_provider"
require_relative "../../../support/synthetic_web_chat_data"

module Decidim
  module Bih
    module Concierge
      # HTTP coverage for the floating "MI bot" web-chat endpoint
      # (POST /biceriseno/chat). The controller renders JSON only (no Decidim
      # layout / Shakapacker), and is wired to the live Bijeljina web concierge
      # via Decidim::Bih.concierge_resolver, so these tests exercise a real
      # round-trip through the concierge brain.
      class WebChatTest < ActionDispatch::IntegrationTest
        include ::Devise::Test::IntegrationHelpers
        include NativeMilicaProvider
        include SyntheticWebChatData

        # The widget is a same-origin fetch; the controller requires this header.
        XHR = { "X-Requested-With" => "XMLHttpRequest" }.freeze

        setup do
          travel_to(Time.utc(2040, 9, 16, 12))
          install_synthetic_web_chat_data
          @organization = create_organization
          host! @organization.host
          @previous_concierge_org_host = ENV.fetch("DECIDIM_CONCIERGE_ORG_HOST", nil)
          ENV["DECIDIM_CONCIERGE_ORG_HOST"] = @organization.host
          @previous_gemini_env = %w(GEMINI_API_KEY GEMINI_MODEL GEMINI_BASE_URL).index_with { |key| ENV.fetch(key, nil) }
          @previous_gemini_env.each_key { |key| ENV.delete(key) }
          Decidim::Bih::Config.reset!
          # Both concierge wirings memoize a responder bound to an organization;
          # reset so this test's freshly-created org is the one in use.
          DecidimApp::Bijeljina::WebConcierge.reset!
          DecidimApp::Bijeljina::Concierge.reset!
          Rails.cache.clear
          install_native_provider
        end

        teardown do
          uninstall_native_provider
          restore_synthetic_web_chat_data
          travel_back
          DecidimApp::Bijeljina::WebConcierge.reset!
          DecidimApp::Bijeljina::Concierge.reset!
          @previous_concierge_org_host.nil? ? ENV.delete("DECIDIM_CONCIERGE_ORG_HOST") : ENV["DECIDIM_CONCIERGE_ORG_HOST"] = @previous_concierge_org_host
          @previous_gemini_env&.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
          Decidim::Bih::Config.reset!
        end

        test "a native waste read crosses HTTP and metadata boundaries without raw event text" do
          @native_provider.queue_public("read_waste_schedule", { query: "Izmišljeno selo" })
          events = capture_web_chat_events { post_milica("kad se odvozi smeće Izmišljeno selo") }
          body = response.parsed_body
          assert_feedback_contract body.fetch("feedback")
          assert_equal "service", events.first[:answer_intent]
          assert_equal 2, @native_provider.calls.size
          assert_includes JSON.generate(native_evidence), "Izmišljeno selo"
          assert_payload_has_no_raw_text(events.first, "kad se odvozi smeće Izmišljeno selo")
          assert_payload_has_no_raw_text(events.first, body.fetch("reply"))
        end

        test "native MZ geometry read crosses HTTP with its public map and no membership write" do
          area = Decidim::Bih::LocalArea.create!(organization: @organization, kind: "mz", slug: "mz-mirna", name: { "sr" => "Mirna" },
                                                 boundary: { "type" => "Polygon", "coordinates" => [[[19.0, 44.5], [19.01, 44.5], [19.01, 44.51], [19.0, 44.5]]] })
          before = Decidim::Bih::CitizenProfile.count
          @native_provider.queue_public("read_area", { area_query: "Mirna", place_kind: "mz" }) do |envelope|
            fact = envelope.fetch("evidence").first.fetch("facts").fetch("source_fact")
            assert_equal "mz", fact.fetch("area_kind")
            assert_equal area.slug, fact.fetch("area_slug")
            "Javna mapa MZ: #{fact.fetch("destination")}"
          end
          post_milica("Gdje su javne granice MZ Mirna?")
          assert_response :success
          assert_includes response.parsed_body.fetch("reply"), "/mjesne-zajednice/mz-mirna"
          assert_equal before, Decidim::Bih::CitizenProfile.count
          assert_equal 2, @native_provider.calls.size
        end

        test "a served answer cites each source once and carries no internal slug" do
          @native_provider.queue_public("read_platform_guidance", { subject: "feedback" }) do |envelope|
            "Ocjena je dobrovoljna. Izvor: #{envelope.fetch("evidence").first.fetch("source_url")}"
          end
          post_milica("Šta znači ocjena odgovora?")
          answer = response.parsed_body.fetch("reply")
          assert_equal 1, answer.scan("Izvor:").size
          assert_no_match(/\br_[a-f0-9]{24}\b/, answer)
          assert_operator answer.length, :<, 900
          assert_equal 2, @native_provider.calls.size
        end

        test "location memory status follows persisted outcome and is unknown on a failed share or forget" do
          slot_key = Dialogue::ConversationSlots::KEY
          point = { "kind" => "exact", "ciphertext" => "opaque-token", "at" => Time.current.to_f,
                    "expires_at" => 20.minutes.from_now.to_f }
          active = { slot_key => Dialogue::ConversationSlots.empty.merge("location" => point) }
          with_brain(typed_brain(resolution: "answered", topic: "transport", state: active)) { post_milica("odavde") }
          assert_equal "active", response.parsed_body.fetch("location_memory_state")

          unavailable = Object.new
          unavailable.define_singleton_method(:respond) { |_| raise "Redis unavailable" }
          with_brain(unavailable) { post_milica("zaboravi moju lokaciju") }
          assert_equal "unknown", response.parsed_body.fetch("location_memory_state"), "failed forget must not assert deletion"

          inactive = { slot_key => Dialogue::ConversationSlots.empty }
          with_brain(typed_brain(resolution: "answered", topic: "transport", state: inactive)) { post_milica("zaboravi moju lokaciju") }
          assert_equal "inactive", response.parsed_body.fetch("location_memory_state")

          with_brain(unavailable) { post_milica("odavde") }
          assert_equal "unknown", response.parsed_body.fetch("location_memory_state"), "failed share must not assert retention"
        end

        test "a signed-in user from another organization is anonymous in chat instrumentation" do
          other_organization = create_organization
          outsider = FactoryBot.create(:user, :confirmed, organization: other_organization)

          sign_in outsider

          events = capture_web_chat_events do
            post "/biceriseno/chat",
                 params: { message: "hej" }.to_json,
                 headers: XHR.merge("Content-Type" => "application/json")
          end

          assert_response :ok
          assert response.parsed_body["reply"].present?
          assert_feedback_contract response.parsed_body.fetch("feedback")
          assert_equal 1, events.size
          assert_equal @organization.id, events.first[:organization_id]
          assert_nil events.first[:user_id]
        end

        test "an empty message returns 200 with the fallback help reply" do
          post "/biceriseno/chat",
               params: { message: "  " }.to_json,
               headers: XHR.merge("Content-Type" => "application/json")

          assert_response :ok
          assert response.parsed_body["reply"].present?
        end

        test "ordinary help uses native structured clarification without inferred action chips" do
          @native_provider.queue_final(text: "Mogu pomoći s javnim podacima i postojećim postupcima. Šta želiš provjeriti?")
          post_milica("help")
          assert_includes response.parsed_body.fetch("reply"), "Šta želiš provjeriti"
          assert_empty response.parsed_body.fetch("quick_replies")
          assert_equal 1, @native_provider.calls.size
        end

        test "english native courtesy preserves composed language" do
          @native_provider.queue_final(text: "Hello. What would you like to check?")
          post_milica("hello")
          assert_equal "Hello. What would you like to check?", response.parsed_body.fetch("reply")
          assert_empty response.parsed_body.fetch("quick_replies")
          assert_equal 1, @native_provider.calls.size
        end

        test "a local casual greeting uses the reviewed greeting without a model call" do
          @native_provider.queue_final(text: "Zdravo. Šta želiš provjeriti?")
          post_milica("zdravo")
          assert_equal "Ćao! Tu sam. Šta te zanima?", response.parsed_body.fetch("reply")
          assert_empty @native_provider.calls
          assert_empty response.parsed_body.fetch("quick_replies")
        end

        test "a waste answer stays chip-free" do
          post "/biceriseno/chat",
               params: { message: "kad se odvozi smeće Izmišljeno selo" }.to_json,
               headers: XHR.merge("Content-Type" => "application/json")

          assert_response :ok
          assert_empty response.parsed_body["quick_replies"], "waste answers already give the direct result"
        end

        test "setup questions return account setup guidance and setup metadata" do
          @native_provider.queue_protected("account_action", { action: "registration" })
          assert_no_difference -> { Decidim::User.count } do
            post_milica("Kako da se registrujem?")
          end
          assert_includes response.parsed_body.fetch("reply"), Decidim::Bih.registration_path
          assert_equal 1, @native_provider.calls.size
          assert_not_includes JSON.generate(@native_provider.calls), "user_id"
        end

        test "public platform read returns current evidence through native tool protocol" do
          @native_provider.queue_public("read_platform_guidance", { subject: "platform" })
          post_milica("Šta je MI platforma?")
          assert_equal 2, @native_provider.calls.size
          assert_includes JSON.generate(native_evidence), "platform"
          assert_feedback_contract response.parsed_body.fetch("feedback")
        end

        test "feedback meaning questions explain voluntary review without account linkage" do
          @native_provider.queue_public("read_platform_guidance", { subject: "feedback" }) do |envelope|
            policy = envelope.fetch("evidence").first.dig("facts", "source_fact", "policy")
            assert_equal true, policy.fetch("voluntary")
            assert_includes policy.fetch("identity_scope"), "not account linked"
            "Korisno i Nije korisno su dobrovoljna ocjena ovog odgovora, bez povezivanja s nalogom."
          end
          post_milica("Šta znači Korisno?")
          assert_includes response.parsed_body.fetch("reply"), "dobrovoljna"
          assert_equal 2, @native_provider.calls.size
        end

        test "expanded service-directory topics are available through web chat" do
          @native_provider.queue_public("read_directory", { query: "policija" })
          post_milica("Službeni kontakt policije?")
          assert_equal "ok", native_evidence.fetch("status")
          assert_not_empty native_evidence.fetch("evidence")
          assert_equal 2, @native_provider.calls.size
          assert_includes JSON.generate(native_evidence), "directory"
          assert_not_includes response.parsed_body.fetch("reply"), "r_"
        end

        test "procedure native read preserves reviewed availability boundary without submitting forms" do
          @native_provider.queue_public("read_procedure", { key: "synthetic-permit" })
          assert_no_difference -> { Decidim::Bih::Report.count } do
            post_milica("Koji su koraci izmišljenog zahtjeva?")
          end
          assert_equal 2, @native_provider.calls.size
          assert_equal "ok", native_evidence.fetch("status")
          assert_not_empty native_evidence.fetch("evidence")
          assert_includes JSON.generate(@native_provider.calls.first[:tools]), "read_procedure"
          assert_feedback_contract response.parsed_body.fetch("feedback")
        end

        test "transport directory evidence retains published-source limitations" do
          @native_provider.queue_public("read_directory", { key: "javni_prevoz" })
          post_milica("Kolika je cijena autobuske karte?")
          assert_equal 2, @native_provider.calls.size
          assert_equal "ok", native_evidence.fetch("status")
          assert_includes JSON.generate(native_evidence.fetch("evidence")), "2,37 KM"
          assert native_evidence.fetch("warnings").include?("reviewed_directory_not_live_status")
          assert_feedback_contract response.parsed_body.fetch("feedback")
        end

        test "native journey from Primjervrt (CSP) to Primjerpolje (centar) uses current reviewed tuples through HTTP" do
          with_reviewed_transport do
            @native_provider.queue_public("resolve_and_plan_journey",
                                          { origin_query: "Primjervrt (CSP)", destination_query: "Primjerpolje (centar)", date: "2026-09-16", after_time: "06:00" })
            assert_no_difference [-> { Decidim::Bih::Report.count }, -> { Decidim::User.count }] do
              post_milica("Od Primjervrt (CSP) do Primjerpolje (centar) 16.9.2026. poslije 06:00")
            end
            assert_equal 2, @native_provider.calls.size
            envelope = native_evidence
            assert_equal "ok", envelope.fetch("status"), envelope.fetch("warnings").inspect
            facts = envelope.fetch("evidence").map { |record| record.fetch("facts") }
            legs = facts.select { |fact| fact["departure_at"] && fact["arrival_at"] }
            assert_operator legs.size, :>=, 2, "Izmišljeno selo to Janja needs a reviewed transfer"
            assert_match(/Primjervrt \(CSP\)/, legs.first.fetch("origin_label"))
            assert_match(/Primjerpolje \(centar\)/, legs.last.fetch("destination_label"))
            assert_equal legs.first.fetch("destination_label"), legs.last.fetch("origin_label"), "transfer must use the same reviewed stop"
            assert(legs.all? { |fact| Time.iso8601(fact.fetch("departure_at")).to_date == Date.new(2026, 9, 16) })
            assert(legs.all? { |fact| Time.iso8601(fact.fetch("arrival_at")) >= Time.iso8601(fact.fetch("departure_at")) })
            assert_feedback_contract response.parsed_body.fetch("feedback")
          end
        end

        test "consented nearest-stop HTTP request uses transient coordinates in direct reader without model retention" do
          with_reviewed_transport do
            observed_locations = []
            timetable_class = DecidimApp::Bijeljina::PublicTransportTimetable
            original_new = timetable_class.method(:new)
            instrumented_reader = lambda do |**options|
              reader = original_new.call(**options)
              original_nearest_stop = reader.method(:nearest_stop)
              reader.define_singleton_method(:nearest_stop) do |**arguments|
                observed_locations << arguments.fetch(:location)
                original_nearest_stop.call(**arguments)
              end
              reader
            end
            timetable_class.stub(:new, instrumented_reader) do
              events = capture_web_chat_events do
                post_milica("Najbliže autobusko stajalište na mojoj lokaciji?",
                            location: { latitude: 0.5001, longitude: 0.5001, purpose: "current_location", consent: true,
                                        provenance: "browser_geolocation" })
              end
              assert observed_locations.any?, "direct and validation reads must reach the reviewed timetable"
              assert observed_locations.all? { |location| location == { latitude: 0.5001, longitude: 0.5001 } },
                     "every replay must use the same consented coordinates"
              assert_empty @native_provider.calls, "direct reviewed stop read must not call the model"
              assert_includes response.parsed_body.fetch("reply"), "Najbliže pregledano autobusko stajalište"
              assert_feedback_contract response.parsed_body.fetch("feedback")
              assert_payload_has_no_raw_text(events.first, "0.5001")

              @native_provider.queue_final(text: "Koji drugi podatak želiš provjeriti?")
              post_milica("A drugi javni podaci?")
              assert_equal 1, @native_provider.calls.size
              assert_not_includes JSON.generate(@native_provider.calls.last), "0.5001"
              assert_not_includes response.parsed_body.fetch("reply"), "0.5001"
            end
          end
        end

        test "native journey from Bijeljina (NAS) to Primjerpark uses current reviewed tuples through HTTP" do
          with_reviewed_transport do
            @native_provider.queue_public("resolve_and_plan_journey", { origin_query: "Bijeljina (NAS)", destination_query: "Primjerpark", date: "2026-09-16", after_time: "06:00" })
            assert_no_difference [-> { Decidim::Bih::Report.count }, -> { Decidim::User.count }] do
              post_milica("Od Bijeljina (NAS) do Primjerpark 16.9.2026. poslije 06:00")
            end
            assert_equal 2, @native_provider.calls.size
            envelope = native_evidence
            assert_equal "ok", envelope.fetch("status"), envelope.fetch("warnings").inspect
            facts = envelope.fetch("evidence").map { |record| record.fetch("facts") }
            assert_includes facts.map { |fact| fact["route_code"] }, "G1"
            legs = facts.select { |fact| fact["departure_at"] && fact["arrival_at"] }
            assert legs.any?
            assert(legs.all? { |fact| Time.iso8601(fact.fetch("departure_at")).to_date == Date.new(2026, 9, 16) })
            assert(legs.all? { |fact| Time.iso8601(fact.fetch("arrival_at")) >= Time.iso8601(fact.fetch("departure_at")) })
            assert_feedback_contract response.parsed_body.fetch("feedback")
          end
        end

        test "native journey from Bijeljina (NAS) to Primjerpolje (škola) uses current reviewed tuples through HTTP" do
          with_reviewed_transport do
            @native_provider.queue_public("resolve_and_plan_journey",
                                          { origin_query: "Bijeljina (NAS)", destination_query: "Primjerpolje (škola)", date: "2026-09-16", after_time: "06:00" })
            assert_no_difference [-> { Decidim::Bih::Report.count }, -> { Decidim::User.count }] do
              post_milica("Od Bijeljina (NAS) do Primjerpolje (škola) 16.9.2026. poslije 06:00")
            end
            assert_equal 2, @native_provider.calls.size
            envelope = native_evidence
            assert_equal "ok", envelope.fetch("status"), envelope.fetch("warnings").inspect
            facts = envelope.fetch("evidence").map { |record| record.fetch("facts") }
            legs = facts.select { |fact| fact["departure_at"] && fact["arrival_at"] }
            assert legs.any?
            assert_match(/Bijeljina \(NAS\)/, legs.first.fetch("origin_label"))
            assert_match(/Primjerpolje \(škola\)/, legs.last.fetch("destination_label"))
            assert legs.all? { |fact| %w(P2 P12 P13).include?(fact.fetch("route_code")) }, "use a reviewed Janja line"
            assert(legs.all? { |fact| Time.iso8601(fact.fetch("departure_at")).to_date == Date.new(2026, 9, 16) })
            assert(legs.all? { |fact| Time.iso8601(fact.fetch("arrival_at")) >= Time.iso8601(fact.fetch("departure_at")) })
            assert_feedback_contract response.parsed_body.fetch("feedback")
          end
        end

        test "native journey from Primjerpark to Bijeljina (NAS) uses current reviewed tuples through HTTP" do
          with_reviewed_transport do
            @native_provider.queue_public("resolve_and_plan_journey", { origin_query: "Primjerpark", destination_query: "Bijeljina (NAS)", date: "2026-09-16", after_time: "06:00" })
            assert_no_difference [-> { Decidim::Bih::Report.count }, -> { Decidim::User.count }] do
              post_milica("Od Primjerpark do Bijeljina (NAS) 16.9.2026. poslije 06:00")
            end
            assert_equal 2, @native_provider.calls.size
            envelope = native_evidence
            assert_equal "ok", envelope.fetch("status"), envelope.fetch("warnings").inspect
            facts = envelope.fetch("evidence").map { |record| record.fetch("facts") }
            assert_includes facts.map { |fact| fact["route_code"] }, "G1"
            legs = facts.select { |fact| fact["departure_at"] && fact["arrival_at"] }
            assert legs.any?
            assert(legs.all? { |fact| Time.iso8601(fact.fetch("departure_at")).to_date == Date.new(2026, 9, 16) })
            assert(legs.all? { |fact| Time.iso8601(fact.fetch("arrival_at")) >= Time.iso8601(fact.fetch("departure_at")) })
            assert_feedback_contract response.parsed_body.fetch("feedback")
          end
        end

        test "parking street questions use the structured street-zone overview" do
          @native_provider.queue_public("read_parking", { query: "Izmišljeni javor" })
          events = capture_web_chat_events do
            post "/biceriseno/chat",
                 params: { message: "kako da platim parking za ulicu izmišljeni javor?" }.to_json,
                 headers: XHR.merge("Content-Type" => "application/json")
          end

          assert_response :ok
          body = response.parsed_body
          assert_includes body.fetch("reply"), "Izmišljeni javor"
          assert_includes body.fetch("reply"), "plava / II zona"
          assert_includes body.fetch("reply"), "TEST-B"
          assert_includes body.fetch("reply"), "0,95 KM/h"
          assert_empty body.fetch("quick_replies")
          assert_equal "service", events.first[:answer_intent]
        end

        test "parking zone questions resolve Izmišljena breza to red zone" do
          @native_provider.queue_public("read_parking", { query: "Izmišljena breza" })
          post "/biceriseno/chat",
               params: { message: "koja je parking zovna u ulici izmišljena breza?" }.to_json,
               headers: XHR.merge("Content-Type" => "application/json")

          assert_response :ok
          body = response.parsed_body
          assert_includes body.fetch("reply"), "Izmišljena breza"
          assert_includes body.fetch("reply"), "crvena / I zona"
          assert_includes body.fetch("reply"), "TEST-R"
          assert_includes body.fetch("reply"), "1,85 KM/h"
        end

        test "parking location questions ask for a street instead of guessing a zone" do
          @native_provider.queue_public("read_parking", {}) do |envelope|
            assert_includes envelope.fetch("warnings"), "parking_street_or_lot_required"
            "Ne mogu pouzdano odrediti parking zonu samo iz koordinata. Pošalji naziv ulice."
          end
          events = capture_web_chat_events do
            post "/biceriseno/chat",
                 params: {
                   message: "kako da platim parking za ovu lokaciju?",
                   location: { latitude: 44.7561, longitude: 19.2144 }
                 }.to_json,
                 headers: XHR.merge("Content-Type" => "application/json")
          end

          assert_response :ok
          body = response.parsed_body
          assert_includes body.fetch("reply"), "Orijentir ne određuje tačan parking segment"
          assert_includes body.fetch("reply"), "Napiši ulicu parking-mjesta"
          assert_empty body.fetch("quick_replies")
          assert_equal "service", events.first[:answer_intent]
          assert_equal true, events.first[:location_present]
        end

        test "current parking zone questions ask for a street instead of guessing a zone" do
          @native_provider.queue_public("read_parking", {}) do |envelope|
            assert_includes envelope.fetch("warnings"), "parking_street_or_lot_required"
            "Ne mogu pouzdano odrediti parking zonu samo iz koordinata. Pošalji naziv ulice."
          end
          events = capture_web_chat_events do
            post "/biceriseno/chat",
                 params: {
                   message: "U kojoj sam parking zoni?",
                   location: { latitude: 44.7561, longitude: 19.2144 }
                 }.to_json,
                 headers: XHR.merge("Content-Type" => "application/json")
          end

          assert_response :ok
          body = response.parsed_body
          assert_includes body.fetch("reply"), "Orijentir ne određuje tačan parking segment"
          assert_includes body.fetch("reply"), "Napiši ulicu parking-mjesta"
          assert_not_includes body.fetch("reply"), "Imam strukturirani pregled parking zona"
          assert_empty body.fetch("quick_replies")
          assert_equal "service", events.first[:answer_intent]
          assert_equal true, events.first[:location_present]
        end

        test "location report guidance creates no report and uses the official handoff" do
          @native_provider.queue_protected("prepare_report", { description: "Problem na ovoj lokaciji" })
          events = nil

          assert_no_difference -> { Decidim::Bih::Report.count } do
            events = capture_web_chat_events do
              post "/biceriseno/chat",
                   params: {
                     message: "hoću da prijavim problem na ovoj lokaciji",
                     location: { latitude: 44.7561, longitude: 19.2144 }
                   }.to_json,
                   headers: XHR.merge("Content-Type" => "application/json")
            end
          end

          assert_response :ok
          body = response.parsed_body
          assert_includes body.fetch("reply"), "/biceriseno/prijave/new"
          assert_includes body.fetch("reply"), "razgovor ih ne prenosi automatski"
          assert_empty body.fetch("quick_replies")
          assert_equal "report_guidance", events.first[:answer_intent]
          assert_equal true, events.first[:location_present]
        end

        test "location can identify the local MZ and Komsiluk without storing coordinates" do
          @native_provider.queue_public("read_area", {})
          concierge_organization = DecidimApp::Bijeljina::Concierge.organization
          isolated_lat = 1.2345
          isolated_lon = 2.3456

          Decidim::Bih::LocalArea.create!(
            organization: concierge_organization,
            kind: "mz",
            slug: "mz-centar-lokacija",
            name: { "sr" => "MZ Centar" },
            boundary: square_boundary(lat: isolated_lat, lon: isolated_lon)
          )
          Decidim::Bih::LocalArea.create!(
            organization: concierge_organization,
            kind: "komsiluk",
            slug: "komsiluk-centar-lokacija",
            name: { "sr" => "Centar Sjever" },
            boundary: square_boundary(lat: isolated_lat, lon: isolated_lon)
          )

          assert_no_difference -> { Decidim::Bih::Report.count } do
            post "/biceriseno/chat",
                 params: {
                   message: "koji je moj komšiluk na ovoj lokaciji?",
                   location: { latitude: isolated_lat, longitude: isolated_lon, consent: true, purpose: "current_location", provenance: "browser_geolocation" }
                 }.to_json,
                 headers: XHR.merge("Content-Type" => "application/json")
          end

          assert_response :ok
          body = response.parsed_body
          assert_includes body.fetch("reply"), "Centar Sjever"
          assert_includes body.fetch("reply"), "MZ Centar"
          @native_provider.queue_final(text: "Koji drugi podatak želiš provjeriti?")
          post_milica("A drugi javni podaci?")
          assert_not_includes JSON.generate(@native_provider.calls.last), isolated_lat.to_s
          assert_empty body.fetch("quick_replies")
        end

        test "follow-up questions use the previous service turn as short-lived context" do
          2.times { @native_provider.queue_public("read_parking_tariffs", { zone: "white" }) }
          first_events = capture_web_chat_events do
            post "/biceriseno/chat",
                 params: { message: "parking" }.to_json,
                 headers: XHR.merge("Content-Type" => "application/json")
          end
          assert_response :ok
          assert_equal "service", first_events.first[:answer_intent]

          events = capture_web_chat_events do
            post "/biceriseno/chat",
                 params: { message: "koliko košta?" }.to_json,
                 headers: XHR.merge("Content-Type" => "application/json")
          end

          assert_response :ok
          response.parsed_body
          assert_includes JSON.generate(native_evidence), "parking"
          assert_includes JSON.generate(@native_provider.calls[2][:contents]), "parking"
          assert_includes JSON.generate(native_evidence), "TEST-W"
          assert_equal "service", events.first[:answer_intent]
          assert_equal 1, events.first[:conversation_turns]
        end

        test "route-code transport follow-ups are answered through web chat" do
          @native_provider.queue_public("service_calendar", { line: "P2" })
          post_milica("Koji dani su objavljeni za P2?")
          @native_provider.queue_public("service_calendar", { line: "P2", date: "2026-09-16" })
          post_milica("A za 16.9.2026?")
          assert_equal 4, @native_provider.calls.size
          assert_includes JSON.generate(@native_provider.calls[2][:contents]), "P2"
          assert_feedback_contract response.parsed_body.fetch("feedback")
        end

        test "a blank message emits a blank outcome event" do
          events = capture_web_chat_events do
            post "/biceriseno/chat",
                 params: { message: "  " }.to_json,
                 headers: XHR.merge("Content-Type" => "application/json")
          end

          assert_response :ok
          assert_equal "blank", events.first[:outcome]
          assert_equal "fallback", events.first[:answer_intent]
          assert_equal 0, events.first[:message_length]
          assert_operator events.first[:reply_length], :>, 0
        end

        test "native report proposal prepares guidance without implicit submission" do
          @native_provider.queue_protected("prepare_report", { description: "Pokvarena ulična lampa", area_query: "Izmišljeno selo" })
          assert_no_difference -> { Decidim::Bih::Report.count } do
            post_milica("Želim prijaviti pokvarenu lampu u Izmišljenom selu")
          end
          assert_includes response.parsed_body.fetch("reply"), "/biceriseno/prijave/new"
          assert_equal 1, @native_provider.calls.size
          contract = assert_feedback_contract(response.parsed_body.fetch("feedback"))
          assert_difference -> { Decidim::Bih::ConciergeFeedback.count }, 1 do
            post_feedback(contract, "not_helpful")
          end
          row = Decidim::Bih::ConciergeFeedback.order(:created_at).last
          assert_equal "Želim prijaviti pokvarenu lampu u Izmišljenom selu", row.citizen_message
          assert_payload_has_no_raw_text(row.metadata, row.citizen_message)
        end

        test "a request without the same-origin header is forbidden" do
          post "/biceriseno/chat",
               params: { message: "zdravo" }.to_json,
               headers: { "Content-Type" => "application/json" }

          assert_response :forbidden
        end

        test "answer feedback stores the rated exchange anonymously and keeps events metadata-only" do
          @native_provider.queue_public("read_waste_schedule", { area_query: "Izmišljeno selo" })
          post "/biceriseno/chat",
               params: { message: "kad se odvozi smeće Izmišljeno selo" }.to_json,
               headers: XHR.merge("Content-Type" => "application/json")
          chat_body = response.parsed_body
          feedback_contract = assert_feedback_contract(chat_body.fetch("feedback"))

          events = capture_feedback_events do
            assert_difference -> { Decidim::Bih::ConciergeFeedback.count }, 1 do
              post "/biceriseno/chat/feedback",
                   params: {
                     reply_id: feedback_contract.fetch("id"),
                     token: feedback_contract.fetch("token"),
                     value: "helpful"
                   }.to_json,
                   headers: XHR.merge("Content-Type" => "application/json")
            end
          end

          assert_response :ok
          assert_equal "ok", response.parsed_body["status"]

          record = Decidim::Bih::ConciergeFeedback.order(:created_at).last
          assert_equal @organization, record.organization
          assert_nil record.user
          assert_equal feedback_contract.fetch("id"), record.reply_id
          assert_equal "helpful", record.value
          assert_equal I18n.locale.to_s, record.locale
          assert_equal "web_chat", record.metadata["source"]
          assert_equal "success", record.metadata["outcome"]
          assert_equal "service", record.metadata["answer_intent"]
          assert_operator record.metadata["reply_length"], :>, 0
          assert_equal "kad se odvozi smeće Izmišljeno selo", record.citizen_message
          assert_equal chat_body.fetch("reply"), record.bot_reply_text
          assert_payload_has_no_raw_text(record.metadata, "kad se odvozi smeće Izmišljeno selo")
          assert_payload_has_no_raw_text(record.metadata, chat_body.fetch("reply"))

          assert_equal 1, events.size
          payload = events.first
          assert_equal "ok", payload[:outcome]
          assert_equal "helpful", payload[:value]
          assert_equal @organization.id, payload[:organization_id]
          assert_nil payload[:user_id]
          assert_equal true, payload[:reply_id_present]
          assert_payload_has_no_raw_text(payload, feedback_contract.fetch("id"))
          assert_payload_has_no_raw_text(payload, feedback_contract.fetch("token"))
          assert_payload_has_no_raw_text(payload, chat_body.fetch("reply"))
        end

        test "signed-in answer feedback is not attached to the user account" do
          citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
          sign_in citizen

          post "/biceriseno/chat",
               params: { message: "zdravo" }.to_json,
               headers: XHR.merge("Content-Type" => "application/json")
          chat_body = response.parsed_body
          feedback_contract = assert_feedback_contract(chat_body.fetch("feedback"))

          assert_difference -> { Decidim::Bih::ConciergeFeedback.count }, 1 do
            post_feedback(feedback_contract, "not_helpful")
          end

          assert_response :ok
          record = Decidim::Bih::ConciergeFeedback.order(:created_at).last
          assert_nil record.user
          assert_equal "not_helpful", record.value
          assert_equal "zdravo", record.citizen_message
          assert_equal chat_body.fetch("reply"), record.bot_reply_text
        end

        test "answer boundary counts blank turns without entering the brain or ReadPort" do
          custom_brain = Object.new
          custom_brain.define_singleton_method(:respond) { |_| raise "Blank turn reached the brain" }
          original = Decidim::Bih.concierge_resolver
          Decidim::Bih.concierge_resolver = custom_brain
          events = []
          callback = ->(*arguments) { events << arguments.last }
          ActiveSupport::Notifications.subscribed(callback, "milica.answer_outcome") { post_milica("") }

          assert_equal [{ topic: "unknown", outcome: "blank" }], events
        ensure
          Decidim::Bih.concierge_resolver = original
        end

        test "typed unavailable reply preserves only allowlisted topic in outcome counters and signed feedback" do
          reply = Responder::Reply.new(text: "Podatak nije dostupan.", report: nil, answer_intent: "service")
          result = Dialogue::ProcedureRunner::Result.new(state: { "topic" => "air_quality" }, reply:, resolution: "source_unavailable",
                                                         fact_ids: [], handoff_offered: false, handoff_completed: false)
          reply.define_singleton_method(:dialogue_outcome) { result }
          custom_brain = Object.new
          custom_brain.define_singleton_method(:respond) { |_| reply }
          original = Decidim::Bih.concierge_resolver
          Decidim::Bih.concierge_resolver = custom_brain
          events = []
          callback = ->(*arguments) { events << arguments.last }
          ActiveSupport::Notifications.subscribed(callback, "milica.answer_outcome") { post_milica("Kakav je vazduh?") }
          feedback = response.parsed_body.fetch("feedback")
          post_feedback(feedback, "not_helpful")

          assert_response :ok
          assert_equal [{ topic: "air_quality", outcome: "source_unavailable" }], events
          assert_equal "air_quality", Decidim::Bih::ConciergeFeedback.find_by!(reply_id: feedback.fetch("id")).metadata["topic"]
        ensure
          Decidim::Bih.concierge_resolver = original
        end

        test "answer intent metadata is enum bounded before signing and persistence" do
          custom_brain = Object.new
          def custom_brain.respond(_message)
            Decidim::Bih::Concierge::Responder::Reply.new(
              text: "custom reply",
              report: nil,
              answer_intent: "=cmd"
            )
          end

          original = Decidim::Bih.concierge_resolver
          Decidim::Bih.concierge_resolver = custom_brain
          begin
            events = capture_web_chat_events do
              post "/biceriseno/chat",
                   params: { message: "custom" }.to_json,
                   headers: XHR.merge("Content-Type" => "application/json")
            end
            feedback_contract = assert_feedback_contract(response.parsed_body.fetch("feedback"))

            assert_difference -> { Decidim::Bih::ConciergeFeedback.count }, 1 do
              post_feedback(feedback_contract, "helpful")
            end
          ensure
            Decidim::Bih.concierge_resolver = original
          end

          assert_response :ok
          assert_equal "unknown", events.first[:answer_intent]
          assert_equal "unknown", Decidim::Bih::ConciergeFeedback.order(:created_at).last.metadata["answer_intent"]
        end

        test "persona gestures expose animated reduced-motion and semantic media fields" do
          custom_brain = Object.new
          def custom_brain.respond(_message)
            Decidim::Bih::Concierge::Responder::Reply.new(
              text: "Provjeren odgovor.",
              report: nil,
              answer_intent: "service",
              sticker: :milica_map
            )
          end

          original = Decidim::Bih.concierge_resolver
          Decidim::Bih.concierge_resolver = custom_brain
          begin
            post "/biceriseno/chat",
                 params: { message: "pokaži mapu" }.to_json,
                 headers: XHR.merge("Content-Type" => "application/json")
          ensure
            Decidim::Bih.concierge_resolver = original
          end

          assert_response :ok
          body = response.parsed_body
          assert_equal "https://#{@organization.host}/mi/milica/map.gif", body.fetch("sticker_url")
          assert_equal "https://#{@organization.host}/mi/milica/map.jpg", body.fetch("sticker_static_url")
          assert_equal I18n.t("decidim.bih.concierge.media.milica_map.alt"), body.fetch("sticker_alt")
        end

        test "unanswered-question capture requires the eligibility in the signed reply token" do
          reply = Responder::Reply.new(text: "Za ovo nemam podržan postupak.", report: nil, answer_intent: "service")
          result = Dialogue::ProcedureRunner::Result.new(state: nil, reply:, resolution: "unsupported", fact_ids: [],
                                                         handoff_offered: false, handoff_completed: false)
          reply.define_singleton_method(:dialogue_outcome) { result }
          brain = Object.new
          brain.define_singleton_method(:respond) { |_| reply }
          original = Decidim::Bih.concierge_resolver
          Decidim::Bih.concierge_resolver = brain
          post_milica("Sintetičko pitanje za pregled")
          body = response.parsed_body
          assert_equal true, body.fetch("offer_capture")
          contract = body.fetch("feedback")
          payload = Rails.application.message_verifier(:decidim_bih_web_chat_feedback).verify(contract.fetch("token"))
          assert_equal true, payload.fetch("offer_capture")
          assert_difference -> { Decidim::Bih::ConciergeFeedback.count }, 1 do
            post_feedback(contract, "share_question")
          end
          assert_response :ok
          assert_equal "ok", response.parsed_body.fetch("status")
          row = Decidim::Bih::ConciergeFeedback.find_by!(reply_id: contract.fetch("id"))
          assert_equal "share_question", row.value
          assert_nil row.user
          assert_equal "Sintetičko pitanje za pregled", row.citizen_message
        ensure
          Decidim::Bih.concierge_resolver = original
        end

        test "unbound pre-upgrade tokens are rejected while current ordinary tokens still rate" do
          post_milica("Hvala")
          contract = response.parsed_body.fetch("feedback")
          assert_equal false, response.parsed_body.fetch("offer_capture")
          verifier = Rails.application.message_verifier(:decidim_bih_web_chat_feedback)
          payload = verifier.verify(contract.fetch("token"))
          assert_equal false, payload.fetch("offer_capture")
          old_contract = contract.merge("token" => verifier.generate(payload.except("offer_capture", "session_digest")))
          [contract, old_contract].each do |token|
            assert_no_difference -> { Decidim::Bih::ConciergeFeedback.count } do
              post_feedback(token, "share_question")
            end
            assert_response :unprocessable_entity
            assert_equal "invalid", response.parsed_body.fetch("status")
          end
          assert_no_difference -> { Decidim::Bih::ConciergeFeedback.count } do
            post_feedback(old_contract, "helpful")
          end
          assert_response :unprocessable_entity
          assert_equal "feedback_unavailable", response.parsed_body.fetch("reason")
          assert_difference -> { Decidim::Bih::ConciergeFeedback.count }, 1 do
            post_feedback(contract, "helpful")
          end
          assert_response :ok
          assert_no_difference -> { Decidim::Bih::ConciergeFeedback.count } do
            post_feedback(contract, "not_helpful")
          end
          assert_response :ok
          assert_equal "not_helpful", Decidim::Bih::ConciergeFeedback.find_by!(reply_id: contract.fetch("id")).value
        end

        test "a feedback token cannot be reused by another browser session" do
          post_milica("Hvala")
          contract = response.parsed_body.fetch("feedback")
          foreign = open_session
          foreign.host! @organization.host
          assert_no_difference -> { Decidim::Bih::ConciergeFeedback.count } do
            foreign.post "/biceriseno/chat/feedback",
                         params: { reply_id: contract.fetch("id"), token: contract.fetch("token"), value: "helpful" }.to_json,
                         headers: XHR.merge("Content-Type" => "application/json")
          end
          assert_equal 422, foreign.response.status
          assert_equal "feedback_unavailable", foreign.response.parsed_body.fetch("reason")
          assert_difference -> { Decidim::Bih::ConciergeFeedback.count }, 1 do
            post_feedback(contract, "helpful")
          end
          assert_response :ok
        end

        test "feedback expires after 24 hours and cannot mutate the existing rating" do
          issued_at = Time.current.change(usec: 0)
          contract = nil
          travel_to(issued_at) do
            post_milica("Hvala")
            contract = response.parsed_body.fetch("feedback")
          end
          travel_to(issued_at + 24.hours - 1.second) do
            assert_difference -> { Decidim::Bih::ConciergeFeedback.count }, 1 do
              post_feedback(contract, "helpful")
            end
            assert_response :ok
          end
          travel_to(issued_at + 24.hours) do
            assert_no_difference -> { Decidim::Bih::ConciergeFeedback.count } do
              post_feedback(contract, "not_helpful")
            end
            assert_response :unprocessable_entity
            assert_equal "feedback_unavailable", response.parsed_body.fetch("reason")
          end
          assert_equal "helpful", Decidim::Bih::ConciergeFeedback.find_by!(reply_id: contract.fetch("id")).value
        end

        test "answer feedback updates a prior vote from the same browser session" do
          post "/biceriseno/chat",
               params: { message: "zdravo" }.to_json,
               headers: XHR.merge("Content-Type" => "application/json")
          feedback_contract = response.parsed_body.fetch("feedback")

          assert_difference -> { Decidim::Bih::ConciergeFeedback.count }, 1 do
            post_feedback(feedback_contract, "helpful")
          end
          assert_response :ok

          assert_no_difference -> { Decidim::Bih::ConciergeFeedback.count } do
            post_feedback(feedback_contract, "not_helpful")
          end
          assert_response :ok

          record = Decidim::Bih::ConciergeFeedback.find_by!(reply_id: feedback_contract.fetch("id"))
          assert_equal "not_helpful", record.value
          assert_no_difference -> { Decidim::Bih::ConciergeFeedback.count } do
            post_feedback(feedback_contract, "not_helpful")
          end
          assert_response :ok
          assert_equal "not_helpful", record.reload.value
        end

        test "answer feedback rejects invalid values and tampered tokens" do
          post "/biceriseno/chat",
               params: { message: "zdravo" }.to_json,
               headers: XHR.merge("Content-Type" => "application/json")
          feedback_contract = response.parsed_body.fetch("feedback")

          assert_no_difference -> { Decidim::Bih::ConciergeFeedback.count } do
            post_feedback(feedback_contract, "maybe")
          end
          assert_response :unprocessable_entity

          tampered = feedback_contract.merge("token" => "#{feedback_contract.fetch("token")}tampered")
          assert_no_difference -> { Decidim::Bih::ConciergeFeedback.count } do
            post_feedback(tampered, "helpful")
          end
          assert_response :unprocessable_entity
        end

        test "answer feedback token cannot be replayed on another organization host" do
          post "/biceriseno/chat",
               params: { message: "kad se odvozi smeće Izmišljeno selo" }.to_json,
               headers: XHR.merge("Content-Type" => "application/json")
          feedback_contract = assert_feedback_contract(response.parsed_body.fetch("feedback"))
          other_organization = create_organization

          host! other_organization.host
          DecidimApp::Bijeljina::WebConcierge.reset!

          assert_no_difference -> { Decidim::Bih::ConciergeFeedback.count } do
            post "/biceriseno/chat/feedback",
                 params: {
                   reply_id: feedback_contract.fetch("id"),
                   token: feedback_contract.fetch("token"),
                   value: "helpful"
                 }.to_json,
                 headers: XHR.merge("Content-Type" => "application/json")
          end

          assert_response :unprocessable_entity
          assert_equal "invalid", response.parsed_body["status"]
        end

        test "answer feedback requires the same-origin header" do
          post "/biceriseno/chat",
               params: { message: "zdravo" }.to_json,
               headers: XHR.merge("Content-Type" => "application/json")
          feedback_contract = response.parsed_body.fetch("feedback")

          post "/biceriseno/chat/feedback",
               params: {
                 reply_id: feedback_contract.fetch("id"),
                 token: feedback_contract.fetch("token"),
                 value: "helpful"
               }.to_json,
               headers: { "Content-Type" => "application/json" }

          assert_response :forbidden
        end

        test "same-origin JSON chat accepts a valid CSRF token when forgery protection is enabled" do
          with_forgery_protection do
            get "/biceriseno/mi-bot"
            token = css_select("meta[name='csrf-token']").first["content"]

            post "/biceriseno/chat",
                 params: { message: "zdravo" }.to_json,
                 headers: XHR.merge("Content-Type" => "application/json", "X-CSRF-Token" => token)

            assert_response :ok
            assert response.parsed_body["reply"].present?
          end
        end

        test "same-origin JSON feedback accepts a valid CSRF token when forgery protection is enabled" do
          with_forgery_protection do
            get "/biceriseno/mi-bot"
            token = css_select("meta[name='csrf-token']").first["content"]

            post "/biceriseno/chat",
                 params: { message: "zdravo" }.to_json,
                 headers: XHR.merge("Content-Type" => "application/json", "X-CSRF-Token" => token)
            feedback_contract = response.parsed_body.fetch("feedback")

            post "/biceriseno/chat/feedback",
                 params: {
                   reply_id: feedback_contract.fetch("id"),
                   token: feedback_contract.fetch("token"),
                   value: "helpful"
                 }.to_json,
                 headers: XHR.merge("Content-Type" => "application/json", "X-CSRF-Token" => token)

            assert_response :ok
            assert_equal "ok", response.parsed_body["status"]
          end
        end

        test "same-origin JSON feedback rejects a missing CSRF token when forgery protection is enabled" do
          with_forgery_protection do
            get "/biceriseno/mi-bot"
            token = css_select("meta[name='csrf-token']").first["content"]

            post "/biceriseno/chat",
                 params: { message: "zdravo" }.to_json,
                 headers: XHR.merge("Content-Type" => "application/json", "X-CSRF-Token" => token)
            feedback_contract = response.parsed_body.fetch("feedback")

            assert_no_difference -> { Decidim::Bih::ConciergeFeedback.count } do
              post "/biceriseno/chat/feedback",
                   params: {
                     reply_id: feedback_contract.fetch("id"),
                     token: feedback_contract.fetch("token"),
                     value: "helpful"
                   }.to_json,
                   headers: XHR.merge("Content-Type" => "application/json")
            end

            assert_response :unprocessable_entity
          end
        end

        test "same-origin JSON chat rejects a missing CSRF token when forgery protection is enabled" do
          with_forgery_protection do
            get "/biceriseno/mi-bot"

            assert_no_difference -> { Decidim::Bih::Report.count } do
              post "/biceriseno/chat",
                   params: { message: "zdravo" }.to_json,
                   headers: XHR.merge("Content-Type" => "application/json")
            end

            assert_response :unprocessable_entity
          end
        end

        # The real production surface for an emergency: the widget's own HTTP
        # endpoint, with the dialogue and report intake switched on exactly as
        # the deployment has them, and a provider client that RAISES if it is
        # reached. Fresh session per scenario; the 20-trial matrix for the same
        # cases lives at the service boundary (report_conversation_test), which
        # can guarantee fresh state per trial without 20 HTTP round-trips.
        test "an emergency and its follow-up are answered over HTTP with no provider call and no report" do
          provider = Object.new
          def provider.configured? = true

          def provider.generate_content(**) = raise("the provider was reached on a safety turn")

          with_production_dialogue_flags do
            Decidim::Bih::Ai::GeminiClient.stub(:new, provider) do
              assert_no_difference -> { Decidim::Bih::Report.count } do
                post_milica("Пожар у подруму зграде, шири се дим!")
                opener = response.parsed_body.fetch("reply")

                assert_equal I18n.t("decidim.bih.dialogue.emergency_fire", locale: :"sr-Cyrl"), opener.lines.first.strip,
                             "a Cyrillic emergency is answered in Cyrillic, leading with the fire brigade"
                assert_includes opener, I18n.t("decidim.bih.dialogue.emergency_disclaimer", locale: :"sr-Cyrl")

                post_milica("Кога да зовем одмах?")
                follow_up = response.parsed_body.fetch("reply")

                assert_includes follow_up, "123", "the follow-up is answered from the bounded safety context"
                assert_not_includes follow_up, "PS BIJELjINA", "and never with the police-station directory"
              end
            end
          end
        end

        test "an ordinary question after an emergency is not answered as one" do
          with_production_dialogue_flags do
            post_milica("Gori kontejner ispred zgrade!")

            assert_includes response.parsed_body.fetch("reply"), "123"

            # No provider is configured in this environment, so the ordinary
            # turn ends in the provider-unavailable reply. That is exactly the
            # point: the emergency context did not capture it, and the answer
            # names no emergency service.
            post_milica("Kad se odvozi smeće u Izmišljenom selu?")
            later = response.parsed_body.fetch("reply")

            assert_not_includes later, I18n.t("decidim.bih.dialogue.emergency_fire", locale: :sr)
            assert_no_match(/\b12[234]\b/, later)
          end
        end

        test "the brain-down fallback still surfaces civic shortcut chips" do
          raising = Object.new
          def raising.respond(_message) = raise("boom")

          original = Decidim::Bih.concierge_resolver
          Decidim::Bih.concierge_resolver = raising
          begin
            post "/biceriseno/chat",
                 params: { message: "zdravo" }.to_json,
                 headers: XHR.merge("Content-Type" => "application/json")
          ensure
            Decidim::Bih.concierge_resolver = original
          end

          assert_response :ok
          chips = response.parsed_body["quick_replies"]
          assert chips.any?, "even when the brain is down the help reply offers shortcuts"
          assert(chips.all? { |chip| chip["url"].present? || chip["send"].present? })
        end

        test "a request that blows up the brain still returns a friendly 200" do
          # Point the resolver at a brain that raises; the controller must catch
          # it and answer with the fallback reply rather than 500.
          raising = Object.new
          def raising.respond(_message) = raise("boom")

          original = Decidim::Bih.concierge_resolver
          Decidim::Bih.concierge_resolver = raising
          events = []
          begin
            events = capture_web_chat_events do
              post "/biceriseno/chat",
                   params: { message: "zdravo" }.to_json,
                   headers: XHR.merge("Content-Type" => "application/json")
            end
          ensure
            Decidim::Bih.concierge_resolver = original
          end

          assert_response :ok
          assert response.parsed_body["reply"].present?
          assert_equal "error", events.first[:outcome], "a rescued exception is an error, not a fallback"
          assert_equal "fallback", events.first[:answer_intent]
          assert_equal "RuntimeError", events.first[:exception_class]
          assert_equal 6, events.first[:message_length]
          assert_payload_has_no_raw_text(events.first, "zdravo")
        end

        test "credential turns never reach the brain later history or feedback transcript" do
          with_capturing_concierge do |messages|
            post_milica("Moj kod je 123456")
            feedback = response.parsed_body.fetch("feedback")
            payload = Rails.application.message_verifier(:decidim_bih_web_chat_feedback).verify(feedback.fetch("token"))
            assert_nil payload[:citizen_message]
            assert_empty messages
            post_feedback(feedback, "not_helpful")
            assert_nil Decidim::Bih::ConciergeFeedback.order(:id).last.citizen_message

            post_milica("A kako se registrujem?")
            assert_equal 1, messages.size
            assert_empty messages.last.conversation_context
          end
        end

        test "cached legacy goodwill answers are summarized before the next brain turn" do
          actor = FactoryBot.create(:user, :confirmed, organization: @organization)
          points = 137
          Decidim::Bih::Goodwill::Ledger.new.award(actor, points, reason: "volunteer_hour")
          sign_in actor

          # Keep the first turn on the real feature-off (legacy) route, then
          # capture the next request. This proves the controller's cached
          # transcript boundary rather than only testing a hand-built message.
          previous_dialogue_enabled = ENV.fetch("MILICA_DIALOGUE_ENABLED", nil)
          ENV["MILICA_DIALOGUE_ENABLED"] = "true"
          previous = Decidim::Bih.concierge_resolver
          messages = []
          first_turn = true
          brain = Object.new
          brain.define_singleton_method(:respond) do |message|
            if first_turn
              first_turn = false
              DecidimApp::Bijeljina::WebConcierge.respond(message)
            else
              messages << message
              Decidim::Bih::Concierge::Responder::Reply.new(
                text: "Nastavak", report: nil, answer_intent: "service", tone: "core"
              )
            end
          end
          Decidim::Bih.concierge_resolver = brain

          begin
            @native_provider.queue_protected("read_own_information", { kind: "balance" })
            post_milica("Koliko imam bodova?")
            assert_includes response.parsed_body.fetch("reply"), points.to_s

            post_milica("A parking?")
          ensure
            Decidim::Bih.concierge_resolver = previous
            previous_dialogue_enabled.nil? ? ENV.delete("MILICA_DIALOGUE_ENABLED") : ENV["MILICA_DIALOGUE_ENABLED"] = previous_dialogue_enabled
          end

          assert_equal 1, messages.size
          history = messages.last.conversation_context
          assert_equal 1, history.size
          assert_equal "goodwill", history.first.fetch("answer_intent")
          assert_equal I18n.t("decidim.bih.dialogue.factual_history_summary"), history.first.fetch("bot")
          assert_not_includes JSON.generate(history.map { |turn| turn.except("at") }), points.to_s
        end

        test "raw goodwill history cached before the guard is neutralized on read" do
          with_capturing_concierge do |messages|
            post_milica("Prvo pitanje")
            old_turn = { "user" => "Moji bodovi", "bot" => "Privatni saldo 137", "answer_intent" => "goodwill", "at" => Time.current.to_i }
            Rails.cache.stub(:read, [old_turn]) { post_milica("A parking?") }

            history = messages.last.conversation_context
            assert_equal 1, history.size
            assert_equal I18n.t("decidim.bih.dialogue.factual_history_summary"), history.first.fetch("bot")
            assert_not_includes JSON.generate(history), "Privatni saldo 137"
          end
        end

        test "credential plus cancellation sends only the sanitized cancellation to the brain" do
          previous = Decidim::Bih.concierge_resolver
          messages = []
          brain = Object.new
          brain.define_singleton_method(:respond) do |message|
            messages << message
            Decidim::Bih::Concierge::Responder::Reply.new(
              text: "Razumijem, odustajemo.", report: nil, answer_intent: "help", tone: "core"
            )
          end
          Decidim::Bih.concierge_resolver = brain

          begin
            post_milica("Odustajem, moj kod je 987654")
          ensure
            Decidim::Bih.concierge_resolver = previous
          end

          assert_equal 1, messages.size
          assert_equal "odustani", messages.first.text
          assert_not_includes messages.first.text, "987654"
          body = response.parsed_body
          assert_includes body.fetch("reply"), I18n.t("decidim.bih.dialogue.credentials")
          assert_not_includes JSON.generate(body), "987654"
          feedback = body.fetch("feedback")
          payload = Rails.application.message_verifier(:decidim_bih_web_chat_feedback).verify(feedback.fetch("token"))
          assert_nil payload[:citizen_message]
        end

        test "cache and session history prune each turn at exact expiry" do
          started = Time.utc(2026, 9, 5, 12)
          with_capturing_concierge do |messages|
            travel_to(started) { post_milica("Prvo pitanje") }
            travel_to(started + 1799) { post_milica("Drugo pitanje") }
            assert_equal ["Prvo pitanje"], messages.last.conversation_context.pluck("user")
            travel_to(started + 1800) do
              Rails.cache.stub(:read, nil) { post_milica("Treće pitanje") }
            end
            assert_equal ["Drugo pitanje"], messages.last.conversation_context.pluck("user")
          end
        end

        test "clear rotates conversation scope even when cache deletion fails" do
          with_capturing_concierge do |messages|
            post_milica("Pitanje prije brisanja")
            previous_scope = messages.last.trusted_context.conversation_key
            Rails.cache.stub(:delete, ->(*) { raise IOError, "cache unavailable" }) { post_milica("/clear") }
            assert_equal I18n.t("decidim.bih.dialogue.cleared"), response.parsed_body.fetch("reply")

            post_milica("Novo pitanje")
            assert_empty messages.last.conversation_context
            assert_not_equal previous_scope, messages.last.trusted_context.conversation_key
          end
        end

        test "account changes do not inherit another actors conversation" do
          first = FactoryBot.create(:user, :confirmed, organization: @organization)
          second = FactoryBot.create(:user, :confirmed, organization: @organization)
          with_capturing_concierge do |messages|
            sign_in first
            post_milica("Moje prethodne prijave")
            assert_equal first.id, messages.last.trusted_context.actor_id
            sign_out first
            sign_in second
            post_milica("Šta je bilo sa prijavom?")
            assert_equal second.id, messages.last.trusted_context.actor_id
            assert_empty messages.last.conversation_context
          end
        end

        test "purpose accuracy and consent survive the complete location boundary" do
          with_capturing_concierge do |messages|
            location = { latitude: 44.7, longitude: 19.2, accuracy: 12, purpose: "current_location",
                         consent: true, provenance: "browser_geolocation" }
            post_milica("Na ovoj lokaciji", location:)
            assert_equal location, messages.last.dialogue_location
            post_milica("status prijave", location:)
            assert_equal location, messages.last.dialogue_location, "fresh consent is not discarded by a topic keyword"
            post_milica("A sada?")
            assert_nil messages.last.dialogue_location, "the previous turn location is never reused"
            post_milica("Na ovoj lokaciji", location: location.merge(consent: false))
            assert_nil messages.last.dialogue_location
            post_milica("Na ovoj lokaciji", location: location.merge(accuracy: "NaN"))
            assert_nil messages.last.dialogue_location
          end
        end

        test "cache failure preserves bounded user and assistant pairs in session fallback" do
          with_capturing_concierge do |messages|
            Rails.cache.stub(:write, ->(*) { raise IOError, "cache unavailable" }) { post_milica("Voda u Izmišljenom selu") }
            Rails.cache.stub(:read, ->(*) { raise IOError, "cache unavailable" }) { post_milica("A sutra?") }
            previous = messages.last.conversation_context.last
            assert_equal "Voda u Izmišljenom selu", previous.fetch("user")
            assert_equal "Koje naselje?", previous.fetch("bot")
            assert previous.fetch("at").positive?
          end
        end

        test "session fallback has a byte bound for long Cyrillic pairs" do
          controller = WebChatController.new
          turns = 6.times.map do
            { "user" => "Питање " * 100, "bot" => "Одговор " * 100, "at" => Time.current.to_i, "tone" => "core" }
          end
          bounded = controller.send(:bounded_session_turns, turns)
          assert bounded.any?
          assert_operator JSON.generate(bounded).bytesize, :<=, WebChatController::MAX_SESSION_CONTEXT_BYTES
          assert(bounded.all? { |turn| turn.fetch("user").present? && turn.fetch("bot").present? })
        end

        test "account switching clears the previous actors actual semantic state scope" do
          first = FactoryBot.create(:user, :confirmed, organization: @organization)
          second = FactoryBot.create(:user, :confirmed, organization: @organization)
          cleared = []
          store = Object.new
          store.define_singleton_method(:clear) { |context:| cleared << context }
          Dialogue::StateStore.stub(:new, store) do
            with_capturing_concierge do |messages|
              sign_in first
              post_milica("Moje prijave")
              prior = messages.last.trusted_context
              sign_out first
              sign_in second
              post_milica("Moj komšiluk")
              assert_equal first.id, cleared.last.actor_id
              assert_equal prior.conversation_key, cleared.last.conversation_key
              assert_equal @organization.id, cleared.last.organization_id
              assert_equal second.id, messages.last.trusted_context.actor_id
              assert_not_equal prior.conversation_key, messages.last.trusted_context.conversation_key
            end
          end
        end

        # --- own-state answers (package G) ------------------------------------

        test "a signed-in citizen with a reserved invitation is told their own reservation number only" do
          @native_provider.queue_protected("read_own_information", { kind: "invitation" })
          create_launch_reward
          citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
          neighbour = FactoryBot.create(:user, :confirmed, organization: @organization)
          mine = create_invitation(citizen, code: "MI-AAAAA-22222")
          theirs = create_invitation(neighbour, code: "MI-BBBBB-33333")
          sign_in citizen

          events = nil
          assert_no_difference own_state_write_counters do
            events = capture_web_chat_events { post_milica("Imam li pozivnicu?") }
          end

          reply = response.parsed_body.fetch("reply")
          assert_includes reply, "MI-AAAAA-22222"
          assert_not_includes reply, "MI-BBBBB-33333"
          assert_includes reply, Decidim::Bih::Engine.routes.url_helpers.community_hub_path
          assert_includes reply, "istorijski zapis, ne nova ponuda"
          assert_equal "goodwill", events.first[:answer_intent]
          assert_equal "success", events.first[:outcome]
          assert_equal "reserved", mine.reload.status
          assert_equal "reserved", theirs.reload.status
        end

        test "a confirmed invitation and a Cyrillic question are answered in kind with the Latin number kept" do
          @native_provider.queue_protected("read_own_information", { kind: "invitation" })
          create_launch_reward
          citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
          create_invitation(citizen, code: "MI-CCCCC-44444", confirmed_at: Time.current)
          sign_in citizen

          post_milica("Имам ли позивницу?")

          reply = response.parsed_body.fetch("reply")
          assert_includes reply, "потврда доласка"
          assert_includes reply, "није доказ уласка"
          assert_includes reply, "MI-CCCCC-44444"
        end

        test "the reservation number never enters the cached transcript" do
          create_launch_reward
          citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
          create_invitation(citizen, code: "MI-AAAAA-22222")
          sign_in citizen

          messages = []
          first_turn = true
          brain = Object.new
          brain.define_singleton_method(:respond) do |message|
            if first_turn
              first_turn = false
              DecidimApp::Bijeljina::WebConcierge.respond(message)
            else
              messages << message
              Responder::Reply.new(text: "Nastavak", report: nil, answer_intent: "service", tone: "core")
            end
          end
          with_brain(brain) do
            @native_provider.queue_protected("read_own_information", { kind: "invitation" })
            post_milica("Imam li pozivnicu?")
            assert_includes response.parsed_body.fetch("reply"), "MI-AAAAA-22222"
            post_milica("A parking?")
          end

          history = messages.last.conversation_context
          assert_equal 1, history.size
          assert_equal "goodwill", history.first.fetch("answer_intent")
          assert_equal I18n.t("decidim.bih.dialogue.factual_history_summary"), history.first.fetch("bot")
          assert_not_includes JSON.generate(history), "MI-AAAAA-22222"
        end

        test "an anonymous visitor asking about the invitation is offered sign-in and sees no reservation number" do
          @native_provider.queue_protected("read_own_information", { kind: "invitation" })
          create_launch_reward
          citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
          create_invitation(citizen, code: "MI-AAAAA-22222")

          post_milica("Jesam li pozvan na 17.9?")

          reply = response.parsed_body.fetch("reply")
          assert_not_includes reply, "MI-AAAAA-22222"
          assert_includes reply, I18n.t("decidim.bih.dialogue.handoff_sign_in", locale: :sr, url: "/users/sign_in")
          assert_equal 1, @native_provider.calls.size
        end

        test "without an invitation the threshold comes from the catalogue and the gap from the ledger" do
          @native_provider.queue_protected("read_own_information", { kind: "invitation" })
          create_launch_reward(cost: 20)
          citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
          Decidim::Bih::Goodwill::Ledger.new.award(citizen, 12, reason: "volunteer_hour")
          sign_in citizen

          assert_no_difference own_state_write_counters do
            post_milica("Da li sam dobio pozivnicu?")
          end

          reply = response.parsed_body.fetch("reply")
          assert_includes reply, "Prag je 20 bodova"
          assert_includes reply, "imaš 12 bodova"
          assert_includes reply, "još 8 bodova"
          assert_includes reply, Decidim::Bih.public_path("zajednistvo?tab=kako")
          assert_includes reply, Decidim::Bih::Engine.routes.url_helpers.verification_explainer_path
          assert_not_includes reply, "MI-"
        end

        test "a signed-in citizen is told their chosen komsiluk with its MZ and where to change it" do
          @native_provider.queue_protected("read_own_information", { kind: "area" })
          area = create_local_area(kind: "komsiluk", slug: "komsiluk-synthetic-village", name: "Izmišljeno selo")
          mz = create_local_area(kind: "mz", slug: "mz-synthetic-village", name: "MZ Izmišljeno selo")
          citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
          profile = Decidim::Bih::CitizenProfile.create!(organization: @organization, user: citizen)
          profile.assign_komsiluk!(area, source: "dropdown", resolved_mz: mz)
          before = profile.reload.attributes
          sign_in citizen

          post_milica("Koji je moj komšiluk?")

          reply = response.parsed_body.fetch("reply")
          assert_includes reply, "Tvoj komšiluk je Izmišljeno selo (MZ Izmišljeno selo)"
          assert_includes reply, Decidim::Bih::Engine.routes.url_helpers.edit_komsiluk_path
          assert_includes reply, Decidim::Bih::Engine.routes.url_helpers.komsiluk_board_index_path
          assert_equal before, profile.reload.attributes
        end

        test "no chosen komsiluk gets the choose-area hand-off and an anonymous visitor the sign-in one" do
          @native_provider.queue_protected("read_own_information", { kind: "area" })
          post_milica("u kom sam komšiluku")
          anonymous = response.parsed_body.fetch("reply")
          assert_includes anonymous, I18n.t("decidim.bih.dialogue.handoff_sign_in", locale: :sr, url: "/users/sign_in")

          citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
          sign_in citizen
          assert_no_difference -> { Decidim::Bih::CitizenProfile.count } do
            @native_provider.queue_protected("read_own_information", { kind: "area" })
            post_milica("Gdje sam prijavljen?")
          end
          reply = response.parsed_body.fetch("reply")
          assert_includes reply, I18n.t("decidim.bih.dialogue.handoff_choose_area", locale: :sr,
                                                                                    url: Decidim::Bih::Engine.routes.url_helpers.edit_komsiluk_path)
        end

        test "a message whose trusted scope names another actor is refused without data" do
          create_launch_reward
          citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
          other = FactoryBot.create(:user, :confirmed, organization: @organization)
          create_invitation(citizen, code: "MI-AAAAA-22222")
          create_invitation(other, code: "MI-BBBBB-33333")
          switched = Dialogue::Contracts::TrustedContext.new(
            organization_id: @organization.id, conversation_key: "b" * 64, actor_id: other.id,
            account_state: "registered", capabilities: %w(public_reads own_report_reads)
          )
          message = Decidim::Bih::Concierge::WebMessage.new("Imam li pozivnicu?", user: citizen, trusted_context: switched)

          reply = DecidimApp::Bijeljina::WebConcierge.respond(message)

          assert_not_includes reply.text, "MI-AAAAA-22222"
          assert_not_includes reply.text, "MI-BBBBB-33333"
          assert_includes reply.text, "ništa nisam poslala"
          assert_empty @native_provider.calls
        end

        # --- honest outcomes, consent offer, turn log (package D) ------------

        test "an unsupported dialogue resolution is recorded as a fallback and offers to keep the question" do
          brain = typed_brain(resolution: "unsupported", topic: "unknown",
                              state: { "active_task" => "ask_information", "entities" => { "query" => "parking na Marsu" } })
          with_brain(brain) do
            assert_difference -> { Decidim::Bih::ConciergeUsageAggregate.where(outcome: "fallback").sum(:requests_count) }, 1 do
              post_milica("Koliko košta parking na Marsu?")
            end
          end

          assert_equal true, response.parsed_body.fetch("offer_capture")
          aggregate = Decidim::Bih::ConciergeUsageAggregate.order(:created_at).last
          assert_equal "fallback", aggregate.outcome
          assert_equal 1, aggregate.resolution_unsupported_count
        end

        test "provider_unavailable and busy resolutions are fallbacks and never raise without a counter column" do
          %w(provider_unavailable busy).each do |resolution|
            outcomes = []
            callback = ->(*arguments) { outcomes << arguments.last }
            with_brain(typed_brain(resolution:, topic: "waste")) do
              assert_difference -> { Decidim::Bih::ConciergeUsageAggregate.where(outcome: "fallback").sum(:requests_count) }, 1 do
                ActiveSupport::Notifications.subscribed(callback, "milica.answer_outcome") { post_milica("kad se odvozi smeće") }
              end
            end

            # The Redis/answer-outcome event keeps the exact resolution as its
            # label; only the daily aggregate collapses it to "fallback".
            assert_equal [{ topic: "waste", outcome: resolution }], outcomes, resolution
            assert_equal(resolution == "provider_unavailable", response.parsed_body.fetch("offer_capture"), resolution)
            aggregate = Decidim::Bih::ConciergeUsageAggregate.order(:created_at).last
            assert_not aggregate.has_attribute?("resolution_#{resolution}_count")
            assert_equal 0, aggregate.resolution_unsupported_count
          end
        end

        test "an answered turn stays a success and does not offer capture" do
          with_brain(typed_brain(resolution: "answered", topic: "waste")) { post_milica("kad se odvozi smeće") }

          assert_equal false, response.parsed_body.fetch("offer_capture")
          assert_equal "success", Decidim::Bih::ConciergeUsageAggregate.order(:created_at).last.outcome
        end

        test "capture is offered on the second clarification in a row, not the first" do
          with_brain(typed_brain(resolution: "clarification", topic: "parking", state: { "clarification_count" => 1 })) { post_milica("parking") }
          assert_equal false, response.parsed_body.fetch("offer_capture")

          with_brain(typed_brain(resolution: "clarification", topic: "parking", state: { "clarification_count" => 2 })) { post_milica("parking") }
          assert_equal true, response.parsed_body.fetch("offer_capture")
          assert_equal "success", Decidim::Bih::ConciergeUsageAggregate.order(:created_at).last.outcome
        end

        test "a brain that raises records an error outcome row" do
          raising = Object.new
          def raising.respond(_message) = raise("boom")

          with_brain(raising) do
            assert_difference -> { Decidim::Bih::ConciergeUsageAggregate.where(outcome: "error").sum(:requests_count) }, 1 do
              post_milica("zdravo")
            end
          end

          assert_equal false, response.parsed_body.fetch("offer_capture")
        end

        test "every turn writes one structured log line without citizen text" do
          brain = typed_brain(resolution: "clarification", topic: "parking",
                              state: { "active_task" => "ask_information", "pending_slot" => "area_query", "clarification_count" => 1,
                                       "entities" => { "query" => "Ulica Kralja Petra" } })
          log = capture_rails_log { with_brain(brain) { post_milica("Koja je zona za Ulicu Kralja Petra?") } }

          line = log.lines.find { |entry| entry.include?("[MilicaTurn]") }
          assert line, "expected a [MilicaTurn] line in:\n#{log}"
          expected = "[MilicaTurn] channel=web_chat action=ask_information topic=parking operation=unknown needs_clarification=true " \
                     "resolution=clarification intent=service outcome=success ms=%d pending_slot=area_query clarification_count=1 entity_keys=query"
          assert_match(/#{Regexp.escape(expected).sub("%d", '\d+')}$/, line.strip)
          assert_not_includes line, "Kralja"
          assert_not_includes line, "Ulica"
        end

        test "a rescued exception is logged as an error turn with the class name only" do
          raising = Object.new
          def raising.respond(_message) = raise("boom with secret 38765")

          log = capture_rails_log { with_brain(raising) { post_milica("zdravo") } }

          line = log.lines.find { |entry| entry.include?("[MilicaTurn]") }
          assert line
          assert_match(/outcome=error ms=\d+ pending_slot=unknown clarification_count=0 entity_keys=none error=RuntimeError$/, line.strip)
          assert_not_includes line, "38765"
        end

        test "the consent button stores the exchange like a rating" do
          with_brain(typed_brain(resolution: "unsupported", topic: "unknown")) { post_milica("Koliko košta parking na Marsu?") }
          chat_body = response.parsed_body
          contract = assert_feedback_contract(chat_body.fetch("feedback"))

          assert_difference -> { Decidim::Bih::ConciergeFeedback.count }, 1 do
            post_feedback(contract, "share_question")
          end

          assert_response :ok
          assert_equal "ok", response.parsed_body["status"]
          record = Decidim::Bih::ConciergeFeedback.order(:created_at).last
          assert_equal "share_question", record.value
          assert_nil record.user
          assert_equal "Koliko košta parking na Marsu?", record.citizen_message
          assert_equal chat_body.fetch("reply"), record.bot_reply_text
          assert_equal "fallback", record.metadata["outcome"]
          assert_equal "web_chat", record.metadata["source"]
        end

        test "the consent button never keeps a credential-shaped exchange" do
          with_brain(typed_brain(resolution: "unsupported", topic: "unknown")) { post_milica("moja lozinka je Tajna123!") }
          contract = assert_feedback_contract(response.parsed_body.fetch("feedback"))

          assert_equal false, response.parsed_body.fetch("offer_capture")
          assert_no_difference -> { Decidim::Bih::ConciergeFeedback.count } do
            post_feedback(contract, "share_question")
          end
          assert_response :unprocessable_entity

          post_feedback(contract, "not_helpful")
          assert_response :ok
          record = Decidim::Bih::ConciergeFeedback.order(:created_at).last
          assert_equal "not_helpful", record.value
          assert_nil record.citizen_message
          assert_not_includes record.bot_reply_text, "Tajna123!"
          assert_includes record.bot_reply_text, "nemoj slati kodove"
        end

        # == Task 5: the web hand-off when the return ticket is gone
        #
        # /milica/prijava works when it is opened by the session that created
        # it — that path is covered end to end by
        # test/contracts/milica_registration_handoff_test.rb. These cover the
        # OTHER case, which is the ordinary one: the citizen came back later,
        # opened the link in another browser, or the conversation moved on.
        # None of them may walk an existing citizen through new-account
        # registration.

        test "a hand-off with no ticket offers an anonymous visitor sign-in and saves the conversation to return to" do
          get "/milica/prijava"

          assert_redirected_to "/users/sign_in"
          assert_equal Decidim::Bih.public_path("mi-bot"), session["user_return_to"]
          assert_not_equal Decidim::Bih.registration_path, response.location
        end

        test "a hand-off with no ticket continues a signed-in citizen's own onboarding step" do
          citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
          sign_in citizen

          get "/milica/prijava"

          assert_redirected_to Decidim::Bih::Onboarding::NextStep.for(citizen, organization: @organization)
          assert_not_includes response.location.to_s, Decidim::Bih.registration_path
        end

        test "a verified citizen with no komsiluk is sent to the picker, never back to registration" do
          citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
          Decidim::Authorization.create!(user: citizen, name: "sms", unique_id: "sms-#{SecureRandom.hex(6)}", granted_at: Time.current)
          sign_in citizen

          get "/milica/prijava"

          assert_redirected_to "#{Decidim::Bih.public_path("komsiluk")}?setup=1"
        end

        test "a blocked account recovers to the conversation and discloses nothing" do
          citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
          sign_in citizen
          citizen.update!(blocked: true, blocked_at: Time.current, extended_data: { "user_name" => "x" })

          get "/milica/prijava"

          assert_response :redirect
          assert_not_includes response.location.to_s, Decidim::Bih.registration_path
        end

        test "the recovery destination is read-only and bounded to known local steps" do
          port = DecidimApp::Bijeljina::Milica::RegistrationPort.new(organization: @organization)
          citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
          outsider = FactoryBot.create(:user, :confirmed, organization: create_organization)

          assert_equal "/users/sign_in", port.recovery_destination(nil)
          assert_nil port.recovery_destination(outsider), "another organization's citizen is not resolved here"
          assert_no_difference [-> { Decidim::Authorization.count }, -> { Decidim::Bih::CitizenProfile.count }] do
            assert port.recovery_allowed?(port.recovery_destination(citizen))
          end

          ["https://evil.example/users/sign_in", "//evil.example", "/admin", "/users/sign_up", nil, ""].each do |candidate|
            assert_not port.recovery_allowed?(candidate), candidate.inspect
          end
        end

        private

        # A brain whose reply carries a typed dialogue outcome, the way the host
        # WebConcierge attaches ProcedureRunner::Result to its replies.
        def create_launch_reward(cost: 20)
          Decidim::Bih::Goodwill::Reward.create!(
            organization: @organization, key: Decidim::Bih.launch_invitation_reward_key,
            title: { "sr" => "Pozivnica za lansiranje 17.9." }, cost:, stock: 310,
            deducts_points: false, auto_issue_at_threshold: true, expires_at: 1.week.from_now
          )
        end

        def create_invitation(user, code:, status: "reserved", confirmed_at: nil)
          Decidim::Bih::Goodwill::RewardFulfillment.create!(
            organization: @organization, user:, ledger_transaction: nil,
            reward_key: Decidim::Bih.launch_invitation_reward_key, cost: 20, status:, auto_issued: true,
            entry_code: code, issued_at: Time.current, confirmation_deadline_at: 72.hours.from_now,
            attendance_confirmed_at: confirmed_at
          )
        end

        def create_local_area(kind:, slug:, name:)
          Decidim::Bih::LocalArea.create!(organization: @organization, kind:, slug:, name: { "sr" => name }, boundary: {})
        end

        # Asking about your own state must never issue, confirm, assign or award anything.
        def own_state_write_counters
          [
            -> { Decidim::Bih::Goodwill::RewardFulfillment.count },
            -> { Decidim::Bih::Goodwill::RewardFulfillmentEvent.count },
            -> { Decidim::Bih::Goodwill::Transaction.count },
            -> { Decidim::Bih::CitizenProfile.count }
          ]
        end

        def typed_brain(resolution:, topic:, state: {}, text: "Odgovor bota.", answer_intent: "service")
          reply = Responder::Reply.new(text:, report: nil, answer_intent:)
          result = Dialogue::ProcedureRunner::Result.new(
            state: { "topic" => topic, "clarification_count" => 0, "entities" => {} }.merge(state), reply:, resolution:,
            fact_ids: [], handoff_offered: false, handoff_completed: false
          )
          reply.define_singleton_method(:dialogue_outcome) { result }
          brain = Object.new
          brain.define_singleton_method(:respond) { |_| reply }
          brain
        end

        def with_brain(brain)
          original = Decidim::Bih.concierge_resolver
          Decidim::Bih.concierge_resolver = brain
          yield
        ensure
          Decidim::Bih.concierge_resolver = original
        end

        def capture_rails_log
          io = StringIO.new
          logger = ActiveSupport::Logger.new(io)
          if Rails.logger.respond_to?(:broadcast_to)
            Rails.logger.broadcast_to(logger)
            begin
              yield
            ensure
              Rails.logger.stop_broadcasting_to(logger)
            end
          else
            previous = Rails.logger
            Rails.logger = logger
            begin
              yield
            ensure
              Rails.logger = previous
            end
          end
          io.string
        end

        def with_capturing_concierge
          previous = Decidim::Bih.concierge_resolver
          messages = []
          brain = Object.new
          brain.define_singleton_method(:respond) do |message|
            messages << message
            Responder::Reply.new(text: "Koje naselje?", report: nil, answer_intent: "service", tone: "core")
          end
          Decidim::Bih.concierge_resolver = brain
          yield messages
        ensure
          Decidim::Bih.concierge_resolver = previous
        end

        # The flags the deployment actually runs with: the v1 dialogue open to
        # the public and report intake enabled, so the chat turn takes the same
        # path a citizen's does.
        def with_production_dialogue_flags
          keys = %w(MILICA_DIALOGUE_ENABLED MILICA_DIALOGUE_AUDIENCE MILICA_DIALOGUE_COHORT_USER_IDS
                    MILICA_COMPOSITION_ENABLED MILICA_CONVERSATIONAL_WRITES_ENABLED
                    MILICA_REPORT_CHAT_SUBMISSION_ENABLED MILICA_CONVERSATION_MODEL)
          previous = keys.index_with { |key| ENV.fetch(key, nil) }
          ENV["MILICA_DIALOGUE_ENABLED"] = "true"
          ENV["MILICA_DIALOGUE_AUDIENCE"] = "public"
          ENV["MILICA_DIALOGUE_COHORT_USER_IDS"] = ""
          ENV["MILICA_COMPOSITION_ENABLED"] = "false"
          ENV["MILICA_CONVERSATION_ARCHITECTURE"] = "model_led"
          ENV["MILICA_CONVERSATIONAL_WRITES_ENABLED"] = "false"
          ENV["MILICA_REPORT_CHAT_SUBMISSION_ENABLED"] = "true"
          ENV.delete("MILICA_CONVERSATION_MODEL")
          DecidimApp::Bijeljina::WebConcierge.reset!
          yield
        ensure
          previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
          DecidimApp::Bijeljina::WebConcierge.reset!
        end

        # Materialize the authored toy transport rows in the isolated test DB.
        # The citizen request still uses real source checks/eligibility and never
        # invokes a collector, network fetcher, PDF parser or provider.
        def with_reviewed_transport
          host = DecidimApp::Bijeljina
          reviewed = host::ReviewedTransportTimetables
          now = Time.utc(2026, 9, 16, 6)
          travel_to(now) do
            store = host::CityServiceSourceCheckStore.new
            reader = host::PublicTransportTimetable.new(snapshot_store: store, prepared_only: true)
            notices = reviewed.manifest.fetch("routes").map do |entry|
              notice = city_service_notice(source_key: "public_transport", title: entry.fetch("title"), url: entry.dig("timetable", "url"))
              data = reviewed.data_for(entry)
              directions = data.fetch("directions").map do |direction|
                stops = direction.fetch("stops").each_with_index.map do |row, index|
                  point = reviewed.stop_location_for(entry.fetch("code"), direction.fetch("name"), row.fetch("label"))
                  { "label" => row.fetch("label"), "normalized_label" => reader.send(:normalized_text, row.fetch("label")), "times" => row.fetch("times"), "index" => index,
                    "latitude" => point.fetch("latitude"), "longitude" => point.fetch("longitude"), "coordinates_source" => point.fetch("image_url"),
                    "coordinates_accuracy" => point.fetch("accuracy") }
                end
                { "name" => direction.fetch("name"), "calendar" => reviewed.calendar_metadata(direction, entry), "stops" => stops }
              end
              payload = { "status" => "ok", "checked_at" => now.iso8601, "content_hash" => entry.dig("timetable", "sha256"), "source_url" => notice.url,
                          "directions" => directions, "calendars" => directions.map { |direction| direction.fetch("calendar") }.uniq { |calendar| calendar.fetch("kind") } }
              store.promote(source_key: reader.send(:document_key, notice), source_version: reader.send(:document_version, notice), payload:, success: true, attempted_at: now,
                            checked_at: now)
              notice
            end
            check = host::CityServiceNoticeCollector::SourceCheckResult.new(source_key: "public_transport", status: :ok, notices:, checked_at: now, error_code: nil)
            store.record(check:, attempted_at: now)
            host::CityServiceNoticeCollector.stub(:check, ->(**) { flunk "Citizen path must not collect upstream" }) { yield }
          end
        end

        def native_evidence
          @native_provider.calls.last.fetch(:contents).last.fetch("parts").first.fetch("functionResponse").fetch("response")
        end

        def post_milica(message, **extra)
          post "/biceriseno/chat", params: { message:, **extra }.to_json,
                                   headers: XHR.merge("Content-Type" => "application/json")
          assert_response :ok
        end

        def capture_web_chat_events
          events = []
          callback = lambda do |_name, _started, _finished, _id, payload|
            events << payload
          end

          ActiveSupport::Notifications.subscribed(callback, Decidim::Bih::Concierge::WebChatController::NOTIFICATION_EVENT) do
            yield
          end
          events
        end

        def capture_feedback_events
          events = []
          callback = lambda do |_name, _started, _finished, _id, payload|
            events << payload
          end

          ActiveSupport::Notifications.subscribed(callback, Decidim::Bih::Concierge::WebChatController::FEEDBACK_EVENT) do
            yield
          end
          events
        end

        def assert_feedback_contract(feedback)
          assert_kind_of Hash, feedback
          assert_match Decidim::Bih::ConciergeFeedback::REPLY_ID_FORMAT, feedback.fetch("id")
          assert_equal "/biceriseno/chat/feedback", feedback.fetch("url")
          assert feedback.fetch("token").present?, "expected a signed feedback token"
          feedback
        end

        def assert_report_chip(chips, url: Decidim::Bih::Engine.routes.url_helpers.new_report_path)
          assert_kind_of Array, chips
          label = I18n.t("decidim.bih.concierge.widget.quick.report", locale: "sr")
          chip = chips.find { |entry| entry.fetch("label") == label }

          assert_not_nil chip, "expected a report quick-reply chip"
          assert_equal url, chip.fetch("url")
        end

        def assert_walking_maps_chip(chips, origin:, destination:)
          assert_kind_of Array, chips
          chip = chips.find { |entry| entry.fetch("label") == "Pješke do stajališta" }

          assert_not_nil chip, "expected a walking directions quick-reply chip"
          uri = URI.parse(chip.fetch("url"))
          assert_equal "www.google.com", uri.host
          assert_equal "/maps/dir/", uri.path

          query = URI.decode_www_form(uri.query).to_h
          assert_equal "1", query.fetch("api")
          assert_equal origin, query.fetch("origin")
          assert_equal destination, query.fetch("destination")
          assert_equal "walking", query.fetch("travelmode")
        end

        def post_feedback(feedback_contract, value)
          post "/biceriseno/chat/feedback",
               params: {
                 reply_id: feedback_contract.fetch("id"),
                 token: feedback_contract.fetch("token"),
                 value:
               }.to_json,
               headers: XHR.merge("Content-Type" => "application/json")
        end

        def assert_payload_has_no_raw_text(payload, text)
          payload.values.compact.each do |value|
            assert_not_equal text, value
          end
        end

        def city_service_notice(source_key:, title:, body: "", provider: "Grad Bijeljina", url: "https://source.example")
          DecidimApp::Bijeljina::CityServiceNoticeCollector::Notice.new(
            source_key:,
            source_label: source_key,
            provider:,
            title:,
            body:,
            url:,
            fingerprint: "abc123",
            fetched_at: Time.current
          )
        end

        def square_boundary(lat:, lon:, delta: 0.01)
          {
            "type" => "Polygon",
            "coordinates" => [
              [
                [lon - delta, lat - delta],
                [lon + delta, lat - delta],
                [lon + delta, lat + delta],
                [lon - delta, lat + delta],
                [lon - delta, lat - delta]
              ]
            ]
          }
        end

        def with_forgery_protection
          previous = ActionController::Base.allow_forgery_protection
          ActionController::Base.allow_forgery_protection = true
          yield
        ensure
          ActionController::Base.allow_forgery_protection = previous
        end
      end
    end
  end
end
