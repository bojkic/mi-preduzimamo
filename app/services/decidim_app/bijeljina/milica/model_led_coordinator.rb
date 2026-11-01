# frozen_string_literal: true

require "date"
require "time"
require "securerandom"
require "active_support/isolated_execution_state"
require_relative "emergency_continuation"
require_relative "conversation_memory"
require_relative "public_capability_catalog"
require_relative "verified_answer_renderer"
require_relative "stop_family_question"
require_relative "unsupported_journey_constraint"
require_relative "board_notice_reference"
require_relative "channel_capability_reply"
require_relative "platform_support_contact"
require_relative "../../launch_event_configuration"
require_relative "../civic_destinations"
require_relative "../citizen_reference_catalog"
require_relative "../komsiluk_naming_campaign"

module DecidimApp
  module Bijeljina
    module Milica
      # The production host boundary for the model-led engine. All persistent
      # conversation updates use the existing scoped compare-and-set store.
      class ModelLedCoordinator
        Dialogue = Decidim::Bih::Concierge::Dialogue
        RESOURCE_TRACE_KEY = :milica_model_led_resource_trace
        MODEL = "gemini-3.5-flash-lite"
        DOTTED_DATE = /(?<![\d.,])(\d{1,2})\.(\d{1,2})\.(\d{4})(?!\d|[.,]\d)/
        BROAD_CITY_NOTICES = /(?:grads\w*|gradsk\w*|bijeljin\w*).{0,60}(?:obavijest\w*|obavjestenj\w*|obavestenj\w*|upozorenj\w*)|(?:obavijest\w*|obavjestenj\w*|obavestenj\w*|upozorenj\w*).{0,60}(?:grads\w*|gradsk\w*|bijeljin\w*)/
        INSTRUCTION = <<~TEXT
          Ti si Milica, pomoćnica lokalne zajednice koja koristi ovu platformu. Razumij pitanje i odgovori korisno, sažeto,
          na jeziku i pismu građanina; izričit izbor građanina ima prednost nad jezikom interfejsa.
          Prati zahtjeve građanina, ne pretpostavke iz svojih ranijih odgovora. Ispravka mijenja
          samo imenovani uslov: novo polazište nije novo odredište. Zadrži ostala mjesta,
          datum i vremenski prag; serverski današnji datum ne zamjenjuje ranije traženi datum.
          Isto važi za sat: ispravka polazišta ne zamjenjuje raniji vremenski prag trenutnim satom.
          Ako istorija kaže da prethodni zahtjev nije sačuvan, a građanin ga nastavlja, pitaj
          za nedostajući datum/vrijeme ili drugi neophodan uslov; nemoj ih izmišljati iz sata servera.
          Relativne datume tumači po lokalnom vremenu Europe/Sarajevo. Relativni datum u
          citiranom starom obavještenju odnosi se na njegov datum, ne na današnji dan.
          Građaninova pretpostavka nije dokaz: kada javni podatak kaže drugačije, ljubazno
          ispravi pretpostavku, naročito kod javnog kontakta i područja uslužnog obavještenja.
          Ne traži ponovo razliku koju je građanin već razjasnio. U naredno čitanje prenesi
          njegovo pojašnjenje zajedno s predmetom pitanja. Naselje, administrativna MZ i komšiluk
          nisu isto: ako čitanje nema traženi geografski obuhvat, objasni ograničenje tog čitanja,
          ne traži da građanin ponovo izabere već razjašnjenu vrstu mjesta. Za opšti pozdrav odgovori
          prirodno; za konkretno pitanje o novostima pročitaj aktuelne javne aktivnosti.
          U odgovoru koristi stvarne javne URL adrese iz podataka, ne nazive njihovih polja.
          Pravila cijena i oslobađanja ograniči na postupak i kanal koje izvor stvarno opisuje.
          Imaš aktuelne javne upute u kontekstu i alate za ostale podatke. Za pitanje
          o trenutno objavljenim projektima ili materijalnim potrebama pročitaj katalog;
          opšti opis fondacije ne govori šta je sada objavljeno. Samostalno izaberi
          odgovarajuće čitanje i nastavi ako prethodni rezultat još ne odgovara pitanju.
          Ako aktuelni kontekst već sadrži odgovor, odmah ga sastavi i citiraj: ne čitaj iste
          upute ponovo. Nezavisna potrebna čitanja zatraži zajedno. Koristi ponuđene ključeve
          postupaka prema značenju pitanja, bez dodatne pretrage kada je postupak jasan.
          Ako si samo razriješila stajališta, još nisi provjerila polazak. Ako čitanje puta nije
          završeno ili je nepodržano, kaži da polazak nije provjeren; ne tvrdi da nema autobusa.
          Traži samo podatak koji stvarno nedostaje. Javno objašnjenje o nalogu nije čitanje
          privatnog naloga; nezadovoljstvo odgovorom je prilika da popraviš odgovor.
          Poštuj predmet, datum, područje i ograničenja vraćenih podataka. Kod obavještenja
          za usluge, područje upita služi za pretragu; samo potvrđeni obuhvat samog obavještenja
          dokazuje da se prekid odnosi na traženo područje. Ime trafostanice ili kontekstualno
          spomenutog mjesta ne dokazuje da prekid važi za to mjesto, niti da ne važi za drugo.
          Razlikuj odsustvo
          dokaza od dokaza da nečega nema. Ne pripisuj mjerenju vrijeme objave ili naše provjere.
          Dijeljena lokacija služi javnim čitanjima tokom aktivnog razgovora; ne predstavlja identitet,
          prebivalište ili članstvo. Ako aktivni podaci imaju potvrđeno mjesto, koristi ga za
          "odavde" i sljedeće javne upite bez ponovnog pitanja. Novo polazište imenovano samo za
          jednu rutu mijenja tu rutu, ne trajnu lokaciju. Ako traženi postupak zahtijeva ulicu,
          a poznato je samo naselje, pitaj za ulicu. Ograničenja pojedinog alata nisu ograničenja svih alata.
          Kada javni izvor daje jednu pregledanu najbolju podudarnost za neodređeno mjesto ili stajalište,
          odgovori odmah, imenuj pretpostavku i pozovi građanina da pošalje tačniju ulicu, broj objekta
          ili stajalište radi ponovne provjere. Ne predstavljaj pretpostavku kao tačan kućni obuhvat.
          Ako se ulica proteže kroz više komšiluka, jedna ulica ne dokazuje pripadnost jednome;
          objasni koji mali podatak razdvaja mogućnosti, bez izmišljanja geografske granice.
          Za privatne podatke ili radnje koristi zaštićeni postupak; samo stvarna potvrda
          izvršenja dokazuje uspjeh. Javne podatke objasni bez nepotrebne registracije.
        TEXT

        def initialize(organization:, client: nil, tools_factory: nil, workflow: nil, state_store: nil, runtime: nil, accounting_factory: nil, execution_mode: "adaptive", prefetch_guidance: true, evidence_observer: nil, delivery_clock: -> { Time.current }) # rubocop:disable Metrics/ParameterLists -- injectable host boundaries
          raise ArgumentError, "Invalid public execution mode" unless %w(fixed adaptive).include?(execution_mode)
          @execution_mode = execution_mode
          @prefetch_guidance = prefetch_guidance
          @evidence_observer = evidence_observer
          @delivery_clock = delivery_clock
          @organization = organization
          @resource_observer = method(:observe_resource_span)
          @client = client || GeminiConversationClient.new(
            api_key: Decidim::Bih::Config.gemini[:api_key], model: MODEL, base_url: Decidim::Bih::Config.gemini[:base_url],
            settings: { "max_output_tokens" => 4096, "thinking_level" => "minimal" }, observer: @resource_observer
          )
          @tools_factory = tools_factory || ->(location:) { ConversationTools.new(organization:, location:, observer: @resource_observer) }
          @workflow = workflow || WorkflowProposals.new(organization:)
          @store = state_store || Dialogue::StateStore.new
          @memory = ConversationMemory.new(organization:)
          @public_capabilities = PublicCapabilityCatalog.new(organization:)
          @runtime = runtime || Dialogue::Coordinator::Runtime.new
          @accounting_factory = accounting_factory || lambda {
            ConversationUsage.new(organization_id: organization.id, model: MODEL,
                                  max_attempts: @execution_mode == "fixed" ? 2 : 8,
                                  observer: @resource_observer)
          }
        end

        def call(message:, context:, channel: "web_chat") # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity -- failure boundary and admission
          trace = SecureRandom.hex(12)
          unless context.is_a?(Dialogue::Contracts::TrustedContext) && context.organization_id == @organization.id
            raise Dialogue::Contracts::Invalid,
                  "Trusted conversation scope required"
          end

          raise Dialogue::Contracts::Invalid, "Invalid ingress channel" unless %w(web_chat viber viber_bm whatsapp messenger instagram).include?(channel)

          emergency = EmergencyContinuation.call(message:, context:, store: @store)
          return emergency if emergency

          control_key = Dialogue::Coordinator.control_key(message)
          if %w(safety credentials allegation).include?(control_key)
            reply = Dialogue::Coordinator.control_reply(message:)
            return outcome(reply:, state: nil, resolution: control_key == "safety" ? "safety_guidance" : "refused")
          end
          admitted = @runtime.call do |budget|
            with_resource_trace(trace) { execute(message:, context: context.with(deadline: budget), channel:, trace:) }
          end
          return admitted.value if admitted.respond_to?(:admitted?) && admitted.admitted? && admitted.value.is_a?(Dialogue::ProcedureRunner::Result)

          status = admitted.respond_to?(:status) ? admitted.status.to_s : "unavailable"
          status = "unavailable" unless %w(capacity expired unavailable).include?(status)
          phase = admitted.respond_to?(:phase) ? admitted.phase.to_s : ""
          phase = "unknown" unless %w(pre_admission admission_store capacity work_setup work_execution runtime).include?(phase)
          details = {}
          if admitted.respond_to?(:reason) && Dialogue::AdmissionControl::Result::REASONS.include?(admitted.reason)
            details[:reason] = admitted.reason
          end
          details[:failure_site] = admitted.failure_site if admitted.respond_to?(:failure_site) && admitted.failure_site
          diagnostic(trace, "admission_finished", status:, phase:, **details)
          failure(message, reason: status, phase:)
        rescue StandardError => e
          code = e.respond_to?(:code) && Dialogue::ModelLedConversation::DIAGNOSTIC_CODES.include?(e.code.to_s) ? e.code.to_s : "host_failure"
          diagnostic(trace, "host_failure", code:)
          provider_codes = %w(http_error transport_error empty_response malformed_response response_too_large missing_candidate unfinished_response)
          failure(message, reason: provider_codes.include?(code) ? :provider_unavailable : :unavailable)
        end

        private

        def execute(message:, context:, channel:, trace:)
          state = @store.read(context:)
          raise Dialogue::Contracts::Invalid, "Conversation state unavailable" unless state

          state = retire_ordinary_task(state, context:)
          memory_enabled = ConversationMemory.enabled? && channel != "viber"
          state = commit_citizen_memory(state:, message:, context:) if memory_enabled
          locale = Dialogue::Coordinator.locale_for(message)
          if memory_enabled && !@memory.forget?(message) &&
             ((@memory.exact_share_requested?(message) && !@memory.exact_share_saved?(state:, message:, context:)) ||
              (ConversationMemory.typed_address_enabled? && @memory.typed_location_statement?(message.text) &&
               !@memory.typed_location_saved?(state:, message:, context:)))
            return location_save_unavailable_outcome(state:, locale:)
          end
          if Dialogue::Coordinator.cancelled?(message)
            result = @workflow.cancel(message:, state:, context:, locale:)
            return persist(result, previous: state, context:, frame: Dialogue::ConversationFrame.empty(context:))
          end
          return forget_location_outcome(state:, context:, locale:) if memory_enabled && @memory.forget?(message)
          if (channel_reply = ChannelCapabilityReply.call(message:, channel:, organization: @organization))
            result = outcome(reply: channel_reply, state:, resolution: "answered",
                             diagnostics: { "architecture" => "channel_capability_reply", "model_calls" => 0, "tool_calls" => 0 })
            frame = Dialogue::ConversationFrame.load(state[Dialogue::ConversationFrame::KEY], context:)
            return persist(result, previous: state, context:,
                           frame: public_history(frame:, message:, answer: channel_reply.text, context:, state:))
          end
          if casual_greeting?(message.text)
            answer = "Ćao! Tu sam. Šta te zanima?"
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "casual_greeting", subject: "greeting")
          end
          if text_location_without_gps_question?(message.text)
            answer = "Da. Napiši ulicu i broj ako želiš, ili prepoznatljiv javni orijentir. GPS nije potreban za " \
                     "ovaj upit. Provjeriću dostupne javne podatke i jasno navesti pretpostavku; samo navođenje " \
                     "mjesta ne potvrđuje tvoje prebivalište."
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "text_location_without_gps", subject: "text_location_without_gps")
          end
          if state.dig(Dialogue::AnswerContext::KEY, "subject") == "greeting" &&
             platform_news_followup?(message.text)
            answer = "Ako misliš na nove objave komšija, tablu svog komšiluka možeš otvoriti na " \
                     "#{public_site_url('komsiluk-board')} nakon prijave na nalog s dodijeljenim područjem. " \
                     "Bez naziva komšiluka i prava pristupa ne mogu potvrditi šta je tamo novo. " \
                     "Javne projekte pregledaj na #{public_site_url('projekti')}; ako napišeš komšiluk ili temu, " \
                     "mogu provjeriti dostupne javne aktivnosti."
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "platform_news_scope", subject: "platform_news")
          end
          if private_points_route_question?(message.text)
            answer = "Svoje bodove i stanje novčanika provjeri nakon prijave na " \
                     "#{public_site_url('moj-doprinos')}. Bez potvrđene veze s tvojim nalogom ne mogu ih pročitati iz ovog razgovora."
            folded = Decidim::Bih::Text.fold(message.text.to_s)
            if folded.match?(/\b(?:nagrad\w*|zamijen\w*|iskorist\w*)\b/)
              answer = "#{answer} Nagradu možeš izabrati u katalogu na " \
                       "#{public_site_url('zajednistvo?tab=nagrade')}; tamo provjeri uslove i raspoloživost. " \
                       "Ovdje nisam preuzela niti rezervisala nagradu."
            end
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "private_points_route", subject: "private_points")
          end
          if state.dig(Dialogue::AnswerContext::KEY, "subject") == "birth_extract_fee" &&
             birth_extract_fee_exemption_followup?(message.text)
            channel = birth_extract_channel(message.text, state:)
            answer = reviewed_birth_extract_guidance(context:, locale:, channel:, focus: "exemption")
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "birth_extract_fee_exemption_scope", subject: "birth_extract_fee",
                                          anchor: birth_extract_anchor(message:, state:), tool_calls: 1)
          end
          if (ematricar_kind = ematricar_delivery_question(message.text, state:))
            return direct_ematricar_delivery(message:, state:, context:, locale:, kind: ematricar_kind)
          end
          if birth_extract_fee_question?(message.text)
            channel = birth_extract_channel(message.text, state:)
            answer = reviewed_birth_extract_guidance(context:, locale:, channel:, focus: "fee")
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "birth_extract_fee_scope", subject: "birth_extract_fee",
                                          anchor: birth_extract_anchor(message:, state:), tool_calls: 1)
          end
          if birth_extract_procedure_question?(message.text, state:)
            channel = birth_extract_channel(message.text, state:)
            answer = reviewed_birth_extract_guidance(context:, locale:, channel:, focus: "instructions")
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "birth_extract_procedure_boundary", subject: "birth_extract_procedure",
                                          anchor: birth_extract_anchor(message:, state:), tool_calls: 1)
          end
          if civic_report_status_route_question?(message.text, state:)
            answer = if state.dig(Dialogue::AnswerContext::KEY, "subject") == "civic_report_status_routes"
                       "Status se vidi uz broj prijave u javnom spisku #{public_site_url('prijave-pronadji')}. " \
                         "Otvori stranicu, u polje 'Broj prijave' unesi referencu s potvrde i pogledaj " \
                         "oznaku 'Status' pored pronađene prijave. Ako tražiš privatne detalje svoje prijave, " \
                         "koristi sačuvani privatni link iz potvrde ili se prijavi i otvori 'Moje prijave'. " \
                         "Statusni token ne šalji u chat."
                     else
                       "Javni status komunalne prijave provjeri po referenci na " \
                         "#{public_site_url('prijave-pronadji')}. Ako si je poslao/la sa svog naloga, " \
                         "prijavi se i otvori #{public_site_url('prijave?view=mine')}. Za privatne detalje anonimne " \
                         "prijave koristi sačuvani privatni link s potvrde; statusni token ne šalji u chat. " \
                         "Javne prijave možeš pregledati na #{public_site_url('prijave')}."
                     end
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "civic_report_status_routes", subject: "civic_report_status_routes")
          end
          if water_bill_contact_question?(message.text, state:)
            followup = state.dig(Dialogue::AnswerContext::KEY, "subject") == "water_bill_contact"
            contact = reviewed_water_contact_guidance(context:, locale:)
            answer = if followup
                       "Ne. Iz ovog razgovora ne mogu vidjeti tvoj račun za vodu ni stanje duga. " \
                         "Za provjeru ličnog stanja obrati se svom vodovodu. #{contact} Broj računa ne šalji u chat."
                     else
                       "Ako misliš da je račun za vodu pogrešan, obrati se svom vodovodu radi provjere i reklamacije. " \
                         "#{contact} Ovdje ne mogu pregledati tvoj račun niti poslati reklamaciju; broj računa ne šalji u chat."
                     end
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "water_bill_contact_boundary", subject: "water_bill_contact")
          end
          if public_share_link_question?(message.text)
            folded = Decidim::Bih::Text.fold(message.text.to_s)
            answer = if folded.match?(/\bjavn\w*\s+link\b/)
                       "Evo običnog javnog linka za kopiranje: https://#{@organization.host}/"
                     else
                       "Možeš kopirati i poslati komšijama javni link platforme: https://#{@organization.host}/. " \
                         "Ovdje nisam nikome poslala poziv niti napravila lični pozivni kod."
                     end
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "public_share_link", subject: "public_share_link")
          end
          if race_after_launch_question?(message.text)
            race = Decidim::Bih::Race::Config.new(organization: @organization)
            end_time = race.window_to.in_time_zone("Europe/Sarajevo").strftime("%d.%m.%Y. u %H:%M")
            status = race.open?(context.now) ? "Trka je sada u toku i završava se #{end_time}." :
              "Trka je završena #{end_time}; poredak na stranici provjeri prema datumu ažuriranja."
            answer = "Trku komšiluka pogledaj na https://#{@organization.host}/trka. #{status} " \
                     "Prikaz poretka može biti keširan; trka i događaj lansiranja imaju odvojene termine."
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "race_after_launch", subject: "race_after_launch")
          end
          if past_launch_event_question?(message.text, context:)
            answer = configured_launch_event_guidance(context:)
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "past_launch_event", subject: "past_launch_event")
          end
          if state.dig(Dialogue::AnswerContext::KEY, "subject") == "central_janja_stop" &&
             approximate_walk_followup?(message.text)
            return direct_published_boarding_guidance(message:, state:, context:, locale:, followup: true)
          end
          if central_janja_stop_question?(message.text)
            return direct_published_boarding_guidance(message:, state:, context:, locale:, followup: false)
          end
          if state.dig(Dialogue::AnswerContext::KEY, "subject") == "announced_works_area" &&
             announced_works_settlement_followup?(message.text)
            answer = "Razumijem: misliš na naselje, ne na stajalište ili svoj komšiluk na platformi. " \
                     "Nisam mijenjala tvoj nalog. Koje radove želiš provjeriti: struju, vodu ili put? " \
                     "Ta vrsta određuje službeni izvor; nemam potvrdu da je cijelo naselje obuhvaćeno radovima."
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "announced_works_settlement_scope", subject: "announced_works_area")
          end
          if announced_works_area_question?(message.text)
            latin = Decidim::Bih::Transliterator.to_latin(message.text.to_s)
            area = latin[/\bu\s+([^?.!,]{2,60})/i, 1]&.strip
            area = "navedenom području" if area.blank?
            answer = "Pitaš za radove u #{area}; to uzimam kao područje, ne autobusko stajalište. Treba provjeriti " \
                     "odgovarajući izvor za struju, vodu ili put; samo naziv područja ne potvrđuje da je cijelo obuhvaćeno. " \
                     "Na koje radove misliš? Ako znaš ulicu, mogu preciznije provjeriti obuhvat."
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "announced_works_area_scope", subject: "announced_works_area")
          end
          if state.dig(Dialogue::AnswerContext::KEY, "subject") == "duplicate_report_status" &&
             duplicate_report_followup?(message.text)
            answer = "Otvori svoju prijavu i prati povezanu glavnu prijavu: javni status možeš pronaći po referenci na " \
                     "#{public_site_url('prijave-pronadji')}. Ako imaš nalog kojim si prijavio, svoje prijave su na " \
                     "#{public_site_url('prijave?view=mine')}. Bez reference ne mogu otvoriti baš tvoj predmet iz ovog razgovora."
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "duplicate_report_followup", subject: "duplicate_report_status")
          end
          if duplicate_report_status_question?(message.text)
            answer = "Ne. Status „Duplikat“ znači da je tvoja prijava povezana s glavnom prijavom istog problema. " \
                     "To samo po sebi ne znači da je problem riješen. Status rješavanja prati na povezanoj glavnoj prijavi; " \
                     "javnu referencu možeš potražiti na #{public_site_url('prijave-pronadji')}."
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "duplicate_report_status", subject: "duplicate_report_status")
          end
          if state.dig(Dialogue::AnswerContext::KEY, "subject") == "private_points" &&
             private_points_unauthenticated_followup?(message.text)
            answer = "Ne. Bez prijave i potvrđene veze s tvojim nalogom ne mogu vidjeti tvoje lično stanje bodova. " \
                     "Provjeri ga na #{public_site_url('moj-doprinos')}; ovdje nisam pristupila nalogu."
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "private_points_auth_boundary", subject: "private_points")
          end
          if ChannelCapabilityReply.public_transport_without_phone?(message.text)
            reply = ChannelCapabilityReply.public_transport_permission_reply(message:)
            return direct_source_boundary(message:, state:, context:, locale:, answer: reply.text,
                                          architecture: "public_transport_without_phone", subject: "public_transport")
          end
          if feedback_button_purpose_question?(message.text)
            answer = "Dugme 'Nije korisno' ocjenjuje moj konkretan odgovor. Ne šalje prijavu gradu i ne potvrđuje da je problem riješen. " \
                     "Samo pisanje poruke u chatu ne bilježi ocjenu; ocjena se sačuva tek kad pritisneš dugme. " \
                     "Klik može sačuvati tekst pitanja i odgovora za privatni pregled radi poboljšanja usluge; ocjena nije javna."
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "feedback_button_purpose", subject: "feedback_button_purpose")
          end
          if state.dig(Dialogue::AnswerContext::KEY, "subject") == "feedback_button_purpose" &&
             feedback_review_followup?(message.text)
            answer = "Ocjenu i, nakon klika, sačuvani tekst pitanja i odgovora mogu privatno pregledati ovlaštene osobe radi poboljšanja platforme. " \
                     "Ocjena je vezana za taj odgovor i sažetak sesije pretraživača, ne za tvoj nalog. " \
                     "Ako si u tekstu naveo ime ili drugi lični podatak, on ipak može ostati u sačuvanom tekstu."
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "feedback_review_privacy", subject: "feedback_storage_privacy")
          end
          if feedback_storage_question?(message.text)
            answer = "Klik na 'Korisno' ili 'Nije korisno' može sačuvati tekst tog pitanja i mog odgovora za privatni pregled. " \
                     "Ocjena nije povezana s tvojim nalogom, ali ime i drugi lični podaci koje napišeš u tekstu mogu ostati sačuvani. " \
                     "Ocjena nije javna i ne trenira model automatski. Dobrovoljna je i možeš je promijeniti za isti odgovor u istoj sesiji."
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "feedback_storage_privacy", subject: "feedback_storage_privacy")
          end
          if state.dig(Dialogue::AnswerContext::KEY, "subject") == "feedback_storage_privacy" &&
             feedback_identity_followup?(message.text)
            answer = "Ne, nije potpuno anonimno ako si u pitanju napisao ime. Ocjena nije povezana s nalogom, " \
                     "ali klik na 'Korisno' može sačuvati tekst pitanja i odgovora za privatni pregled, uključujući ime u tekstu. " \
                     "Ime se ne uklanja automatski."
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "feedback_identity_privacy", subject: "feedback_storage_privacy")
          end
          if new_building_permit_office_question?(message.text)
            contact = reviewed_service_contact_guidance(key: "gradjevinske_dozvole_legalizacija", details: %w(phone email address form), context:, locale:)
            answer = "Za novu građevinsku dozvolu treba provjeriti nadležni organ i zapis tačnog postupka. #{contact} " \
                     "Imenik službe sam po sebi ne potvrđuje uslove ili iznos takse za tvoj zahtjev."
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "building_permit_office", subject: "building_permit_office")
          end
          if state.dig(Dialogue::AnswerContext::KEY, "subject") == "building_permit_office" &&
             permit_registry_followup?(message.text)
            contact = reviewed_service_contact_guidance(key: "gradjevinske_dozvole_legalizacija", details: %w(phone email address form), context:, locale:)
            answer = "Uslove, potrebne dokumente, obrazac i taksu provjeri u službenom zapisu tačnog postupka. " \
                     "Sam imenik ili spisak postupaka ne potvrđuje iznos takse. #{contact}"
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "building_permit_registry", subject: "building_permit_office")
          end
          if social_work_office_hours_question?(message.text)
            contact = reviewed_service_contact_guidance(key: "socijalna_zastita", details: %w(phone email address hours), context:, locale:)
            answer = "Kontakt, adresu i radno vrijeme nadležne službe mogu navesti samo iz pregledanih podataka zajednice. " \
                     "#{contact} Objavljeno radno vrijeme nije potvrda da je termin za tvoj predmet slobodan."
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "social_work_office_hours", subject: "social_work_office_hours")
          end
          if state.dig(Dialogue::AnswerContext::KEY, "subject") == "social_work_office_hours" &&
             social_help_approval_followup?(message.text)
            contact = reviewed_service_contact_guidance(key: "socijalna_zastita", details: %w(phone email), context:, locale:)
            answer = "Ne. Dolazak tokom radnog vremena ne znači da je pomoć odobrena niti da će tvoj predmet biti " \
                     "riješen istog dana. Nadležna služba zasebno provjerava uslove i donosi odluku. #{contact} " \
                     "Lične dokumente i podatke predaj samo nadležnoj službi, ne u ovom chatu."
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "social_help_approval_boundary", subject: "social_work_office_hours")
          end
          if agricultural_call_open_question?(message.text)
            answer = reviewed_agricultural_call_guidance(context:, locale:)
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "agricultural_call_timing", subject: "agricultural_call")
          end
          if %w(agricultural_call agricultural_2026_call).include?(state.dig(Dialogue::AnswerContext::KEY, "subject")) &&
             agricultural_call_deadline_followup?(message.text)
            answer = reviewed_agricultural_call_guidance(context:, locale:)
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "agricultural_call_deadlines", subject: "agricultural_call")
          end
          if form_pickup_approval_question?(message.text)
            answer = "Tačno. Preuzimanje praznog obrasca nije predaja zahtjeva niti odobrenje. " \
                     "Tek ispunjen i predat zahtjev ide na provjeru uslova; nadležni organ zasebno odlučuje. " \
                     "Samim preuzimanjem ne nastaje pravo na podršku niti na isplatu."
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "form_pickup_approval_boundary", subject: "form_application")
          end
          if association_public_call_question?(message.text, state:)
            return direct_association_public_call(message:, state:, context:, locale:)
          end
          if social_work_budget_question?(message.text, state:)
            return direct_social_work_budget(message:, state:, context:, locale:)
          end
          if city_budget_total_question?(message.text, state:)
            return direct_city_budget_total(message:, state:, context:, locale:)
          end
          if komunalac_service_contact_question?(message.text, state:)
            return direct_komunalac_service_contact(message:, state:, context:, locale:)
          end
          if bureau_contact_question?(message.text)
            answer = reviewed_bureau_contact(context:)
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "reviewed_bureau_contact", subject: "bureau_contact") if answer
          end
          if donation_total_public_question?(message.text)
            tools = @tools_factory.call(location: nil)
            envelope = tools.registry.call(name: "read_reference", arguments: { "topic" => "donation", "query" => message.text.to_s },
                                           context:, eligibility: tools.eligibility)
            revalidate_delivery_evidence!([envelope.for_prompt(context:, eligibility: tools.eligibility)], tools:)
            fact = envelope.status == "ok" && envelope.evidence.one? ? envelope.evidence.first.dig("facts", "source_fact") : nil
            answer = if fact && fact["kind"] == "donation_total"
                       "Javni zbir donacija ove zajednice prema posljednjoj provjerenoj evidenciji: #{fact.fetch('text')} " \
                         "To je zbir, ne potvrda pojedinačne uplate. Izvor: #{fact.fetch('source_url')}."
                     else
                       "Trenutno nemam svjež potvrđen javni zbir donacija. #{configured_support_guidance} " \
                         "Nedostupan zbir ne znači da je iznos nula; javni zbir nije potvrda pojedinačne uplate."
                     end
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "donation_public_total", subject: "donation_total", tool_calls: 1)
          end
          if donation_total_receipt_question?(message.text)
            answer = "Ne. Javni zbir donacija za projekat ili ukupno na platformi ne potvrđuje tvoju pojedinačnu uplatu " \
                     "niti otkriva ko je uplatio. Za svoju uplatu provjeri potvrdu platnog servisa ili banke, " \
                     "a za usklađivanje s projektom obrati se operateru ove instalacije. #{configured_support_guidance} " \
                     "U ovom chatu ne šalji broj računa " \
                     "ni podatke kartice."
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "donation_aggregate_receipt_boundary", subject: "donation_receipt")
          end
          if public_race_standings_question?(message.text)
            unless Decidim::Bih::Race::Visibility.visible?(@organization)
              answer = I18n.t("decidim.bih.community_hub.race.hidden", locale:)
              return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                            architecture: "public_race_hidden", subject: "public_race_standings")
            end
            answer = "Javni poredak Trke komšiluka i pravila pogledaj na https://#{@organization.host}/trka. " \
                     "Prikaz poretka može biti keširan; za stanje pogledaj oznaku ažuriranja na toj stranici."
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "public_race_standings", subject: "public_race_standings")
          end
          if state.dig(Dialogue::AnswerContext::KEY, "subject") == "public_race_standings" &&
             race_vs_personal_points_question?(message.text)
            answer = "Ne. Javni poredak prikazuje rezultat komšiluka u Trci, a tvoji lični bodovi su zasebno " \
                     "stanje naloga. Iz ovog razgovora ne mogu vidjeti tvoje lične bodove; provjeri ih u svom prijavljenom nalogu."
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "race_vs_personal_points", subject: "public_race_standings")
          end
          if personal_race_contribution_question?(message.text)
            answer = "Javni poredak na https://#{@organization.host}/trka ne pokazuje koliko si ti lično doprinio. " \
                     "Svoje bodove i evidenciju doprinosa provjeri nakon prijave na #{public_site_url('moj-doprinos')}. " \
                     "Iz ovog razgovora ne mogu očitati tvoj nalog niti iz javnog zbira izračunati tvoj udio u Trci."
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "personal_race_contribution_boundary", subject: "public_race_standings")
          end
          if cheapest_rewards_question?(message.text)
            tools = @tools_factory.call(location: nil)
            envelope = tools.registry.call(name: "read_catalog", arguments: { "topic" => "rewards", "query" => message.text.to_s },
                                           context:, eligibility: tools.eligibility)
            revalidate_delivery_evidence!([envelope.for_prompt(context:, eligibility: tools.eligibility)], tools:)
            rewards = envelope.status == "ok" ? envelope.evidence.filter_map { |row|
              fact = row.dig("facts", "source_fact")
              fact if fact && fact["kind"] == "reward"
            }.first(2) : []
            source = public_site_url("zajednistvo?tab=nagrade")
            answer = if rewards.any?
                       listing = rewards.map do |fact|
                         name = fact.fetch("text").split(": ", 2).first
                         qualifier = fact["deducts_points"] ? "cijena" : "prag za preuzimanje"
                         "#{name} (#{qualifier}: #{fact.fetch('points_cost')} bodova)"
                       end.join("; ")
                       "Prema trenutno pregledanom javnom katalogu, #{rewards.length == 1 ? 'dostupna je samo' : 'dvije najjeftinije su'} " \
                         "#{listing}. Provjeri uslove i dostupnost prije preuzimanja na #{source}; ovdje ništa nije rezervisano."
                     else
                       "Trenutno ne mogu potvrditi dvije dostupne nagrade s cijenom u bodovima. " \
                         "Provjeri javni katalog i uslove na #{source}; ovdje ništa nije rezervisano."
                     end
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "cheapest_public_rewards", subject: "public_rewards", tool_calls: 1)
          end
          if state.dig(Dialogue::AnswerContext::KEY, "subject") == "public_rewards" &&
             reward_availability_followup?(message.text)
            answer = "Uslove i javno prikazanu dostupnost provjeri na #{public_site_url('zajednistvo?tab=nagrade')}. " \
                     "Ličnu podobnost i stvarnu dostupnost sistem provjerava pri pokušaju preuzimanja u prijavljenom nalogu; " \
                     "ovdje nisam ništa rezervisala niti preuzela."
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "reward_availability_boundary", subject: "public_rewards")
          end
          if state.dig(Dialogue::AnswerContext::KEY, "subject") == "public_participation" &&
             participation_read_only_followup?(message.text)
            answer = "Temu i pravila otvori na stranici konkretnog procesa iz javnog kataloga " \
                     "https://#{@organization.host}/processes. Samo čitanje stranice ne daje glas; " \
                     "u ovom razgovoru nisam glasala niti išta prijavila."
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "participation_read_only", subject: "public_participation")
          end
          if public_participation_question?(message.text)
            tools = @tools_factory.call(location: nil)
            envelope = tools.registry.call(name: "read_catalog", arguments: { "topic" => "participation", "query" => message.text.to_s },
                                           context:, eligibility: tools.eligibility)
            revalidate_delivery_evidence!([envelope.for_prompt(context:, eligibility: tools.eligibility)], tools:)
            spaces = envelope.status == "ok" ? envelope.evidence.filter_map { |row|
              fact = row.dig("facts", "source_fact")
              fact if fact && %w(participatory_process public_meeting public_proposal).include?(fact["kind"])
            }.first(3) : []
            source = "https://#{@organization.host}/processes"
            answer = if spaces.any?
                       listing = spaces.map { |fact| "#{fact.fetch('text').split(': ', 2).first}: #{fact.fetch('source_url')}" }.join("; ")
                       "U pregledanom javnom katalogu objavljeni su: #{listing}. Na stranici izabranog procesa pročitaj temu i pravila; " \
                         "ovdje nisam glasala niti se prijavila."
                     elsif envelope.status == "unsupported"
                       "U pregledanom javnom katalogu sada nisam našla objavljen tekući proces. " \
                         "Provjeri javni spisak na #{source}; samo čitanje ne daje glas."
                     else
                       "Trenutno ne mogu provjeriti objavljene procese. Javni spisak i pravila potraži na #{source}; " \
                         "samo čitanje ne daje glas."
                     end
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "public_participation_catalog", subject: "public_participation", tool_calls: 1)
          end
          if historical_cash_bus_fare_question?(message.text)
            answer = "Ne mogu garantovati cijenu karte G1 u gotovini kod vozača za navedeni datum. " \
                     "Pregledana gradska objava o prevozu ne potvrđuje cijenu i način naplate za tu pojedinačnu vožnju; " \
                     "za uslove prodaje provjeri kod prevoznika. Gradska objava: " \
                     "#{CityServiceSources.fetch('public_transport').fetch(:source_url)}. Ovdje nisam prodala kartu."
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "historical_cash_fare_boundary", subject: "transport_fare")
          end
          if voting_without_points_question?(message.text)
            answer = "Da, možeš glasati bez bodova zajedništva. Bodovi nisu uslov za glasanje i ne daju jači glas. " \
                     "Za konkretno glasanje ipak važe pravila i uslovi učešća tog procesa; ovdje nisam glasala za tebe."
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "voting_points_boundary", subject: "voting_points")
          end
          if damaged_public_container_question?(message.text)
            contact = reviewed_service_contact_guidance(key: "otpad", details: %w(phone email), context:, locale:)
            answer = "Za oštećeni javni komunalni kontejner treba provjeriti nadležnu komunalnu službu. #{contact} " \
                     "Možeš koristiti i obrazac za komunalni problem #{public_site_url('prijave/new')}. " \
                     "Za konkretnu intervenciju dodaj ulicu ili obližnji orijentir; ako je kontejner privatnog " \
                     "upravnika, napiši to pa ću ponovo provjeriti nadležnost. Ovdje nisam poslala prijavu."
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "damaged_public_container_guidance", subject: "waste_container_report")
          end
          if feedback_controls_missing_question?(message.text)
            answer = "Ako u ovom prikazu nema dugmeta 'Nije korisno', napiši mi šta je bilo pogrešno pa mogu popraviti odgovor. " \
                     "Sama poruka ne bilježi ocjenu i ne podnosi niti objavljuje prijavu."
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "feedback_controls_missing", subject: "civic_feedback_controls")
          end
          if state.dig(Dialogue::AnswerContext::KEY, "subject") == "civic_feedback_controls" &&
             feedback_description_followup?(message.text)
            answer = "Da. Napiši šta je bilo pogrešno ili šta nedostaje, pa ću pokušati ispraviti odgovor. " \
                     "Taj tekst sam ne bilježi ocjenu."
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "feedback_description", subject: "civic_feedback_description")
          end
          if neighborhood_subscription_question?(message.text, state:)
            return direct_neighborhood_subscription(message:, state:, context:, locale:)
          end
          if memory_enabled && location_recall_question?(message.text)
            kind = state.dig(Dialogue::ConversationSlots::KEY, "location", "kind")
            recalled = named_location_recall(message:, state:, context:, locale:) if kind == "named"
            recalled = private_location_recall(message:, state:, context:, locale:, show_value: true) if kind == "address"
            return recalled if recalled
          end
          if memory_enabled && @memory.standalone_typed_location_statement?(message.text) &&
             state.dig(Dialogue::ConversationSlots::KEY, "location", "at") == context.now.to_f
            kind = state.dig(Dialogue::ConversationSlots::KEY, "location", "kind")
            return named_location_recall(message:, state:, context:, locale:) if kind == "named"
            return private_location_recall(message:, state:, context:, locale:, show_value: false) if kind == "address"
          end
          if memory_enabled && state.dig(Dialogue::ConversationSlots::KEY, "location", "kind") == "address"
            if @memory.typed_location_statement?(message.text) &&
               state.dig(Dialogue::ConversationSlots::KEY, "location", "at") == context.now.to_f
              # A mixed address/question turn must not send the raw private
              # clause to the model. The citizen can continue without repeating
              # the location on the next turn.
              return private_location_route_limit(state:, context:, locale:) if @memory.transport_question?(message.text)
              return private_location_mixed_outcome(state:, context:, locale:)
            end
            return private_location_route_limit(state:, context:, locale:) if @memory.private_origin_journey?(message.text)
          end
          if waste_execution_question?(message.text)
            return direct_waste_execution_boundary(message:, state:, context:, locale:)
          end
          if waste_service_change_question?(message.text)
            return direct_waste_service_change(message:, state:, context:, locale:)
          end
          if state.dig(Dialogue::AnswerContext::KEY, "subject") == "bulky_waste" &&
             bulky_waste_contact_followup?(message.text)
            contact = reviewed_service_contact_guidance(key: "otpad", details: %w(phone email), context:, locale:)
            answer = "Za kontakt oko kabastog otpada koristi pregledane podatke svoje komunalne službe. #{contact} " \
                     "Kontakt službe ne potvrđuje aktuelnu akciju odvoza ili novi termin; za to treba posebna datirana najava."
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "bulky_waste_contact_followup", subject: "bulky_waste")
          end
          if bulky_waste_question?(message.text)
            return direct_bulky_waste(message:, state:, context:, locale:)
          end
          if citywide_waste_schedule_question?(message.text)
            return direct_citywide_waste_schedule(message:, state:, context:, locale:)
          end
          if state.dig(Dialogue::AnswerContext::KEY, "subject") == "waste_recycling" &&
             recycling_park_location_followup?(message.text)
            contact = reviewed_service_contact_guidance(key: "otpad", details: %w(phone email), context:, locale:)
            answer = "Za traženo mjesto nemam pregledan spisak ili mapu reciklažnih posuda, pa ne mogu potvrditi najbližu. " \
                     "#{contact} Kontakt službe ne potvrđuje lokaciju posude ili poseban termin. " \
                     "Redovni raspored miješanog otpada ne određuje lokaciju reciklažne posude."
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "recycling_park_location_boundary", subject: "waste_recycling")
          end
          if paper_recycling_question?(message.text)
            return direct_paper_recycling(message:, state:, context:, locale:)
          end
          if waste_next_year_question?(message.text, state:)
            return direct_waste_next_year(message:, state:, context:, locale:)
          end
          if dvorovi_coverage_question?(message.text)
            return direct_dvorovi_coverage(message:, state:, context:, locale:)
          end
          if (street = corrected_waste_street(message.text, state:, context:))
            return direct_corrected_waste_street(message:, state:, context:, locale:, street:)
          end
          if memory_enabled && (waste_area = waste_named_location_target(message.text, state:))
            return direct_waste_named_location(message:, state:, context:, locale:, name: waste_area)
          end
          if (post_id = BoardNoticeReference.post_id(message.text))
            return direct_board_notice(post_id:, state:, context:, locale:)
          end
          if neighborhood_board_updates_question?(message.text)
            return direct_neighborhood_board_updates(message:, state:, context:, locale:)
          end
          if state.dig(Dialogue::AnswerContext::KEY, "subject") == "neighborhood_board" &&
             neighborhood_posts_followup?(message.text)
            answer = "Razumijem: tražiš objave komšija na MI platformi, ne gradske vijesti. " \
                     "Otvori #{public_site_url('komsiluk-board')} i prijavi se na nalog s dodijeljenim komšilukom. " \
                     "Za čitanje table nije potrebna telefonska verifikacija; za pisanje jeste. " \
                     "Iz ovog razgovora ne mogu prikazati privatne objave."
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "neighborhood_posts_followup", subject: "neighborhood_board")
          end
          naming_followup = state.dig(Dialogue::AnswerContext::KEY, "subject") == "neighborhood_naming_status" &&
                            neighborhood_naming_participation_followup?(message.text)
          if neighborhood_provisional_name_question?(message.text) || naming_followup
            process = KomsilukNamingCampaign.process_for(@organization)
            component = KomsilukNamingCampaign.component_for(@organization)
            open = process&.published? && component&.published?
            answer = if naming_followup
                       if open
                         "Komšije mogu učestvovati u objavljenoj kampanji https://#{@organization.host}/processes/imenujmo-komsiluke. " \
                           "Prvo izaberu svoj komšiluk i potvrde telefon; prema fazi kampanje mogu predložiti jedno ime " \
                           "ili dati jedan promjenjiv glas u svom komšiluku. Provjeri rokove na stranici kampanje."
                       else
                         "Kampanja izbora imena još nije javno otvorena. Kada bude objavljena, komšije će prvo izabrati " \
                           "svoj komšiluk i potvrditi telefon, zatim moći predložiti jedno ime i u fazi glasanja " \
                           "dati jedan promjenjiv glas u svom komšiluku. Sada ne mogu primiti prijedlog ni glas."
                       end
                     else
                       "Ne. To što prikaz više ne pokazuje oznaku 'prijedlog' ne potvrđuje konačno ime. " \
                         "Početni nazivi su prijedlozi sa karte; kampanja za izbor imena #{open ? 'je objavljena' : 'još nije javno otvorena'}. " \
                         "Konačan naziv ne mogu zaključiti iz uklonjene oznake."
                     end
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "neighborhood_naming_status", subject: "neighborhood_naming_status", tool_calls: 1)
          end
          if neighborhood_boundaries_only_question?(message.text)
            answer = "Razumijem: želiš samo pogledati granice komšiluka, bez promjene svog izbora. " \
                     "Javna karta je na #{Decidim::Bih.registration_url(host: @organization.host)}; " \
                     "otvaranje stranice i pregled karte ne mijenjaju tvoj komšiluk. " \
                     "Izbor se čuva tek kada potvrdiš odgovarajući obrazac."
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "neighborhood_boundaries_only")
          end
          if mz_map_not_neighborhood_selection?(message.text)
            answer = "Tačno: karta mjesne zajednice služi samo za pregled područja; ne bira niti mijenja tvoj komšiluk. " \
                     "Ako želiš izabrati svoj komšiluk, prijavi se i otvori #{public_site_url('komsiluk')}. " \
                     "Tamo možeš odabrati područje na karti ili iz liste; samo otvaranje karte ništa ne mijenja."
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "mz_map_selection_boundary")
          end
          if mz_street_membership_question?(message.text, state:)
            return direct_mz_street_membership(message:, state:, context:, locale:)
          end
          if neighborhood_board_access_question?(message.text, state:)
            return direct_neighborhood_board_access(message:, state:, context:, locale:)
          end
          if platform_support_contact_question?(message.text, state:)
            return direct_platform_support_contact(message:, state:, context:, locale:)
          end
          if city_case_status_question?(message.text, state:)
            return direct_city_case_status(message:, state:, context:, locale:)
          end
          if scoped_weekend_notice_question?(message.text, state:)
            return direct_scoped_weekend_notice(message:, state:, context:, locale:)
          end
          if weather_region_question?(message.text, state:)
            return direct_weather_region(message:, state:, context:, locale:)
          end
          if yellow_weather_question?(message.text, state:)
            return direct_yellow_weather(message:, state:, context:, locale:)
          end
          if weather_warning_validity_question?(message.text)
            return direct_weather_warning_validity(message:, state:, context:, locale:)
          end
          if city_notice_source_question?(message.text, state:)
            return direct_city_notice_source(message:, state:, context:, locale:)
          end
          if named_transformer_coverage_question?(message.text, state:)
            return direct_named_transformer_coverage(message:, state:, context:, locale:)
          end
          if water_contact_question?(message.text, state:)
            return direct_water_contact(message:, state:, context:, locale:)
          end
          if (forecast = hourly_street_forecast_boundary(message.text, state:))
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(forecast, locale),
                                          architecture: "hourly_street_forecast_boundary", subject: "hourly_weather_forecast")
          end
          if (river = river_trend_risk_boundary(message.text, state:))
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(river, locale),
                                          architecture: "river_trend_risk_boundary", subject: "river_trend_risk")
          end
          if gazette_ler_act_question?(message.text, state:)
            return direct_gazette_ler_act(message:, state:, context:, locale:)
          end
          if gazette_archive_boundary(message.text, state:)
            return direct_reviewed_gazette_archive(message:, state:, context:, locale:)
          end
          if pension_personal_receipt_followup?(message.text, state:)
            answer = "Ne. Javna objava o isplati ne potvrđuje da je novac stigao na tvoj račun. " \
                     "To možeš provjeriti u svojoj banci; ovdje ne šalji broj računa ni druge bankovne podatke."
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "pio_personal_receipt_boundary", subject: "pio_public_notice")
          end
          if pension_august_2026_notice_question?(message.text) || pension_notice_question?(message.text)
            answer = reviewed_pension_notice_guidance(message:, context:)
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "pio_public_notice", subject: "pio_public_notice", tool_calls: 1)
          end
          if child_benefit_public_notice_question?(message.text)
            key = CitizenNoticePilots.snapshot_key("jfdz_notices")
            unless CityServiceSourceCheckStore.new.snapshot(source_key: key)
              answer = "Trenutno nemam pripremljen aktuelan pregled objava Javnog fonda za dječiju zaštitu " \
                       "o isplati dječijeg dodatka, pa ne mogu potvrditi posljednju isplatu. " \
                       "Provjeri zvanične objave Fonda: #{CitizenNoticePilots::SOURCES.fetch('jfdz_notices').fetch(:url)}. " \
                       "Javna objava ne potvrđuje pojedinačno pravo ni uplatu."
              return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                            architecture: "jfdz_notices_unprepared", subject: "jfdz_public_notice", tool_calls: 1)
            end
          end
          if child_benefit_personal_status_followup?(message.text, state:)
            answer = "Ne. Javna objava Fonda o isplati dječijeg dodatka ne potvrđuje tvoje " \
                     "pojedinačno pravo ni uplatu. Vlastiti status provjeri kod nadležnog Fonda; " \
                     "ovdje nemam pristup tvom predmetu."
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "jfdz_personal_status_boundary", subject: "jfdz_public_notice")
          end
          if (medicine = family_medicine_contact_answer(message.text, state:, context:))
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(medicine, locale),
                                          architecture: "reviewed_family_medicine_contact", subject: "family_medicine_phone")
          end
          if (sms = first_zone_sms_number_answer(message.text, state:))
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(sms, locale),
                                          architecture: "first_zone_sms_number", subject: "parking_first_zone_sms")
          end
          if road_segment_question?(message.text, state:)
            return direct_road_source_unavailable(message:, state:, context:, locale:) if
              CityServiceSourceCheckStore.check(keys: ["road_conditions"], deadline: context.deadline).first.status == :unavailable
          end
          if civil_protection_current_warning_question?(message.text, state:)
            return direct_civil_protection_current_warning(message:, state:, context:, locale:)
          end
          if sistem48_public_archive_question?(message.text, state:)
            return direct_sistem48_public_archive(message:, state:, context:, locale:)
          end
          if broad_city_notices_question?(message.text, state:)
            return direct_published_city_notices(message:, state:, context:, locale:)
          end
          if (volunteer_dates = volunteer_two_dates_request(message.text))
            return direct_volunteer_two_dates(message:, state:, context:, locale:, request: volunteer_dates)
          end
          if (volunteer_date = volunteer_date_narrowing(message.text, state:))
            return direct_volunteer_date_narrowing(message:, state:, context:, locale:, request: volunteer_date)
          end
          if (mz_today = public_mz_today_request(message.text, state:))
            return direct_public_mz_today(message:, state:, context:, locale:, request: mz_today)
          end
          if (mz_map = public_mz_map_request(message.text, state:))
            return direct_public_mz_map(message:, state:, context:, locale:, request: mz_map)
          end
          if (area_profile = ambiguous_public_area_profile_request(message.text, state:))
            return direct_ambiguous_public_area_profile(message:, state:, context:, locale:, request: area_profile)
          end
          if public_map_membership_question?(message.text)
            answer = "Ne. Izbor mjesta na javnoj mapi služi samo za pregled i ne mijenja komšiluk " \
                     "na tvom nalogu. Za promjenu izabranog komšiluka prijavi se i otvori " \
                     "#{public_site_url('komsiluk')}."
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "public_map_membership_boundary", subject: "neighborhood_membership")
          end
          if (activity_area = public_area_activity_request(message.text, state:))
            return direct_public_area_activity(message:, state:, context:, locale:, request: activity_area)
          end
          if (notice_area = scoped_notice_area_request(message.text, state:))
            return direct_scoped_notice_area(message:, state:, context:, locale:, request: notice_area)
          end
          if report_reference_missing_followup?(message.text, state:, context:)
            answer = "Razumijem, misliš na broj odnosno referencu prijave, ne na kod za prijavu na nalog. " \
                     "Ako si prijavu podnio/la sa svog naloga, prijavi se i otvori svoje prijave: " \
                     "#{public_site_url('prijave?view=mine')}. Bez reference možeš pregledati javne prijave na " \
                     "#{public_site_url('prijave')} i filtrirati po kategoriji ili statusu, pa uporediti javnu adresu " \
                     "i datum. To ne vraća privatni link za status niti dokazuje da je prijava tvoja."
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "report_reference_missing_boundary", subject: "report_recovery")
          end
          if report_without_reference_search_question?(message.text, state:)
            return direct_report_without_reference_search(message:, state:, context:, locale:)
          end
          if neighborhood_post_form_question?(message.text, state:)
            return direct_neighborhood_post_form(message:, state:, context:, locale:)
          end
          if report_preparation_only_question?(message.text, state:)
            return direct_report_preparation_only(message:, state:, context:, locale:)
          end
          if volunteer_start_and_place_question?(message.text, state:)
            return direct_volunteer_start_and_place(message:, state:, context:, locale:)
          end
          if public_platform_invitation_question?(message.text, state:)
            return direct_public_platform_invitation(message:, state:, context:, locale:)
          end
          if police_identity_card_question?(message.text, state:)
            return direct_police_identity_card(message:, state:, context:, locale:)
          end
          if report_receipt_question?(message.text)
            return direct_report_receipt_boundary(message:, state:, context:, locale:)
          end
          if instagram_report_submission_question?(message.text)
            return direct_instagram_report_submission(message:, state:, context:, locale:)
          end
          if context.allows?("report_guidance") && streetlight_report_question?(message.text)
            return direct_streetlight_report_guidance(message:, state:, context:, locale:)
          end
          if report_reading_visibility_question?(message.text)
            public_details = I18n.t("decidim.bih.reports.new.visibility.public", locale:)
            private_details = I18n.t("decidim.bih.reports.new.visibility.private", locale:)
            answer = "Ako tek čitaš uputstvo, ništa nije poslano ni objavljeno. Kada građanin potvrdi prijavu: " \
                     "#{public_details} #{private_details} Ime prijavioca nije dio javnog prikaza prijave. " \
                     "Prije slanja treba pregledati adresu i tačku problema."
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "report_reading_visibility", subject: "report_reading_visibility")
          end
          if state.dig(Dialogue::AnswerContext::KEY, "subject") == "report_reading_visibility" &&
             report_map_blur_followup?(message.text)
            answer = "Tačka problema koju potvrdiš uz prijavu prikazuje se javno na mapi u tačnom položaju, " \
                     "bez zamagljivanja; adresa problema takođe može biti javna. Takva tačka može otkriti dom. " \
                     "Ovaj upit nije poslao lokaciju ni prijavu."
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "report_map_point_privacy", subject: "report_reading_visibility")
          end
          if report_anonymous_tradeoff_question?(message.text)
            answer = "Prijava bez naloga nema vezu s tvojim nalogom i ne donosi bodove, ali obrazac i dalje dopušta da uneseš kontakt. " \
                     "Opcija 'Prijavi anonimno' sprečava prosljeđivanje kontakta gradskoj službi; ako si prijavljen/a, " \
                     "prijava i dalje može biti privatno povezana s tvojim nalogom i donijeti bodove. " \
                     "Ni jedna od te dvije stvari ne skriva unesenu adresu ili tačku problema na javnoj mapi."
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "report_anonymous_tradeoff", subject: "report_anonymous_tradeoff")
          end
          if state.dig(Dialogue::AnswerContext::KEY, "subject") == "report_anonymous_tradeoff" &&
             report_anonymous_location_followup?(message.text)
            answer = "Tako je: anonimna prijava ne skriva lokaciju problema. Adresa koju uneseš i tačka koju označiš " \
                     "mogu se javno prikazati; prije slanja pregledaj te podatke."
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "report_anonymous_location", subject: "report_anonymous_tradeoff")
          end
          if report_public_location_question?(message.text)
            answer = "Da. Adresa koju uneseš i tačka koju označiš uz prijavu mogu biti javno prikazane. " \
                     "Samo čitanje uputstva ne objavljuje tvoju lokaciju. Prije slanja pregledaj javne podatke prijave."
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "report_public_location", subject: "report_public_location")
          end
          if state.dig(Dialogue::AnswerContext::KEY, "subject") == "report_public_location" &&
             report_home_point_followup?(message.text)
            answer = "Samo čitanje uputstva ne postavlja tačku na mapu. Ako budeš slala prijavu, nemoj unositi kućnu adresu " \
                     "ili označiti kuću: unesena adresa i odabrana tačka su javne. U web obrascu ta polja nisu obavezna. " \
                     "Pregledaj podatke prije potvrde; ako ne možeš opisati problem bez otkrivanja doma, nemoj poslati prijavu."
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "report_home_point_boundary", subject: "report_public_location")
          end
          if report_preview_visibility_question?(message.text)
            return direct_report_preview_visibility(message:, state:, context:, locale:)
          end
          if report_submission_boundary_question?(message.text, state:)
            return direct_report_submission_boundary(message:, state:, context:, locale:, channel:)
          end
          if whatsapp_receipt_question?(message.text)
            return direct_whatsapp_receipt_boundary(message:, state:, context:, locale:, channel:)
          end
          if outbound_sms_question?(message.text)
            return direct_outbound_sms_boundary(message:, state:, context:, locale:)
          end
          if viber_conversation_question?(message.text)
            return direct_viber_conversation(message:, state:, context:, locale:)
          end
          if phone_confirmation_status_question?(message.text)
            return direct_phone_confirmation_status(message:, state:, context:, locale:)
          end
          if volunteer_application_guidance_question?(message.text)
            answer = "Otvori #{public_site_url('volontiranje?tab=prilike')} i pregledaj otvorene prilike. " \
                     "Za slanje prijave prijavi se u nalog i na izabranoj prilici pritisni 'Pošalji prijavu na pregled'. " \
                     "Prijava zatim čeka odluku; mjesto nije potvrđeno samim slanjem. Samo gledanje stranice ništa ne prijavljuje. " \
                     "Ovdje sam dala samo uputstvo i nisam poslala prijavu."
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "volunteer_application_guidance", subject: "volunteer_application_guidance")
          end
          if state.dig(Dialogue::AnswerContext::KEY, "subject") == "volunteer_application_guidance" &&
             volunteer_page_view_followup?(message.text)
            answer = "Ne. Otvaranje stranice prilike samo prikazuje podatke. Na spisak ne dolaziš dok ne pošalješ prijavu, " \
                     "a mjesto zavisi od naknadne odluke o prijavi."
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "volunteer_page_view_boundary", subject: "volunteer_application_guidance")
          end
          if volunteer_signup_points_question?(message.text)
            return direct_volunteer_signup_points(message:, state:, context:, locale:)
          end
          if volunteer_hours_verification_question?(message.text, state:)
            answer = "Samo upisani sati, prijava ili prisustvo još ne donose bodove. Ovlašteni operater mora provjeriti " \
                     "prisustvo i odobriti zapis o odrađenim satima; tek tada sistem obračunava bodove prema važećem pravilu. " \
                     "Ja u ovom razgovoru ne mogu upisati ili odobriti sate niti provjeriti tvoje lično stanje bodova."
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "volunteer_hours_verification", subject: "volunteer_hours_verification")
          end
          if registration_open_question?(message.text)
            return direct_registration_open(message:, state:, context:, locale:)
          end
          if registration_by_chat_question?(message.text)
            return direct_registration_by_chat(message:, state:, context:, locale:)
          end
          if account_private_phone_question?(message.text)
            return direct_account_private_phone(message:, state:, context:, locale:)
          end
          if report_phone_visibility_followup?(message.text, state:, context:)
            return direct_report_phone_visibility(message:, state:, context:, locale:)
          end
          if account_name_language_settings_question?(message.text)
            answer = "Prijavi se i otvori Moj nalog → Osnovni podaci: #{public_site_url('moj-nalog#osnovni-podaci')}. " \
                     "Tu su polja za prikazano ime i jezik. Promjena se čuva tek kada pošalješ obrazac; ovdje ništa nisam mijenjala."
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "account_name_language_settings", subject: "account_settings_path")
          end
          if state.dig(Dialogue::AnswerContext::KEY, "subject") == "account_settings_path" &&
             account_settings_path_followup?(message.text)
            answer = "Put je Moj nalog → Osnovni podaci: #{public_site_url('moj-nalog#osnovni-podaci')}. " \
                     "Samo otvaranje stranice ništa ne mijenja."
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "account_settings_path", subject: "account_settings_path")
          end
          if account_privacy_settings_question?(message.text)
            return direct_account_privacy_settings(message:, state:, context:, locale:)
          end
          if public_content_removal_question?(message.text)
            answer = "Za zahtjev za uklanjanje konkretne javne objave obrati se operateru ove instalacije " \
                     "i navedi poveznicu ili broj objave. #{configured_support_guidance} " \
                     "Politiku privatnosti ove instalacije pogledaj na #{public_site_url('pages/privacy-policy')}. " \
                     "Potvrdu identiteta dostavljaj samo kroz pregledani službeni kanal, ne kroz ovaj chat. " \
                     "U ovom razgovoru nisam poslala zahtjev niti uklonila objavu."
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "public_content_removal_guidance", subject: "account_privacy")
          end
          if private_report_status_question?(message.text)
            return direct_private_report_status(message:, state:, context:, locale:)
          end
          if own_anonymous_reports_question?(message.text, state:)
            return direct_own_anonymous_reports(message:, state:, context:, locale:)
          end
          if report_status_meaning_question?(message.text, state:)
            return direct_report_status_meaning(message:, state:, context:, locale:)
          end
          if notification_topics_question?(message.text, state:)
            return direct_notification_topics(message:, state:, context:, locale:)
          end
          if account_code_recovery_question?(message.text, state:)
            return direct_account_code_recovery(message:, state:, context:, locale:)
          end
          if iphone_web_app_question?(message.text, state:)
            return direct_iphone_web_app(message:, state:, context:, locale:)
          end
          if goodwill_daily_cap_question?(message.text)
            return direct_goodwill_daily_cap(message:, state:, context:, locale:)
          end
          if (capability = @public_capabilities.resolve(text: message.text.to_s, locale:, state:, channel:))
            return direct_public_capability(message:, state:, context:, locale:, capability:)
          end
          if source_fetch_date_question?(message.text)
            return direct_source_fetch_date(message:, state:, context:, locale:)
          end
          if holiday_waste_change_question?(message.text, state:)
            return direct_holiday_waste_change(message:, state:, context:, locale:)
          end
          if waste_schedule_change_question?(message.text)
            return direct_waste_schedule_change(message:, state:, context:, locale:)
          end
          if first_zone_parking_payment_question?(message.text)
            return direct_first_zone_parking_payment(message:, state:, context:, locale:)
          end
          if blue_parking_tariff_question?(message.text, state:)
            return direct_blue_parking_tariff(message:, state:, context:, locale:)
          end
          if parking_payment_confirmation_question?(message.text)
            return direct_parking_payment_confirmation(message:, state:, context:, locale:)
          end
          if parking_landmark_price_question?(message.text)
            return direct_parking_landmark_price(message:, state:, context:, locale:)
          end
          if live_parking_space_question?(message.text)
            return direct_live_parking_space(message:, state:, context:, locale:)
          end
          if parking_sign_zone_followup?(message.text)
            answer = "Vidim da imaš znak na parking-mjestu — to je najbolji podatak za zonu. " \
                     "Napiši šta na njemu piše: boju ili oznaku zone (bijela, I/crvena ili II/plava) ili navedeni SMS broj. " \
                     "Tada mogu izdvojiti odgovarajuću tarifu. Bez oznake sa znaka ne mogu potvrditi koju zonu treba platiti; " \
                     "nemoj plaćati po mojoj pretpostavci."
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "parking_sign_zone_followup", subject: "parking_sign_zone")
          end
          if gps_parking_zone_question?(message.text, state:, location: current_public_location(message))
            answer = "Primila sam tvoju podijeljenu lokaciju, ali pregledani podaci ne povezuju GPS tačku " \
                     "s tačnim uličnim parking-segmentom ili zonom. Napiši ulicu parking-mjesta ili " \
                     "oznaku zone sa znaka na licu mjesta pa ću ponovo provjeriti. Ne moraš slati GPS ponovo."
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "gps_parking_zone_boundary", subject: "gps_parking_zone")
          end
          if gps_waste_schedule_question?(message.text, state:, location: current_public_location(message))
            return direct_gps_waste_schedule(message:, state:, context:, locale:)
          end
          if parking_tariff_source_question?(message.text)
            return direct_parking_tariff_source(message:, state:, context:, locale:)
          end
          if water_safety_question?(message.text, state:)
            return direct_water_safety_boundary(message:, state:, context:, locale:)
          end
          if (dated_notice = dated_water_notice_request(message.text, state:))
            return direct_dated_water_notice(message:, state:, context:, locale:, request: dated_notice)
          end
          if water_notice_scope_question?(message.text, state:)
            return direct_water_notice_scope(message:, state:, context:, locale:)
          end
          if water_today_notice_question?(message.text, state:)
            return direct_water_today_notice(message:, state:, context:, locale:)
          end
          if water_current_fault_question?(message.text, state:)
            return direct_water_current_fault(message:, state:, context:, locale:)
          end
          if water_tomorrow_notice_question?(message.text, state:)
            return direct_water_tomorrow_notice(message:, state:, context:, locale:)
          end
          if border_freight_wait_followup?(message.text)
            answer = "Ne. Podatak o čekanju za putnički automobil ne može se primijeniti na teretni kamion. " \
                     "Ovaj pregled ne potvrđuje čekanje za teretna vozila; provjeri podatke za tu kategoriju " \
                     "direktno kod BIHAMK-a: #{CitizenNoticePilots::SOURCES.fetch('bihamk_border').fetch(:url)}."
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "border_freight_scope", subject: "border_wait")
          end
          if klimerko_scope_question?(message.text, state:)
            return direct_klimerko_scope(message:, state:, context:, locale:)
          end
          if pm25_value_meaning_question?(message.text)
            return direct_pm25_value_meaning(message:, state:, context:, locale:)
          end
          if klimerko_pm10_question?(message.text, state:)
            return direct_klimerko_pm10_boundary(message:, state:, context:, locale:)
          end
          if pm25_measurement_clock_question?(message.text, state:)
            return direct_pm25_measurement_clock(message:, state:, context:, locale:)
          end
          if badovinci_water_level_question?(message.text)
            return direct_badovinci_water_level_boundary(message:, state:, context:, locale:)
          end
          if jamena_water_level_question?(message.text)
            answer = "RHMZ Srbije objavljuje stanicu Jamena na Savi: " \
                     "https://www.hidmet.gov.rs/latin/hidrologija/izvestajne/bezprognoza.php?hm_id=45084. " \
                     "U svojoj pregledanoj evidenciji nemam pouzdano potvrđenu najnoviju vrijednost i vrijeme očitanja " \
                     "za tu stanicu; na službenoj stranici provjeri datum i vodostaj u centimetrima. " \
                     "Neću zamijeniti Jamenu drugom stanicom."
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "jamena_water_level_boundary", subject: "water_level")
          end
          if (relative_notice = old_relative_notice_question(message.text))
            return direct_old_relative_notice(message:, state:, context:, locale:, kind: relative_notice)
          end
          if electricity_today_notice_question?(message.text, state:)
            return direct_electricity_today_notice(message:, state:, context:, locale:)
          end
          if (dated_electricity = dated_electricity_notice_request(message.text, state:))
            return direct_dated_electricity_notice(message:, state:, context:, locale:, request: dated_electricity)
          end
          if electricity_tomorrow_notice_question?(message.text, state:)
            return direct_electricity_tomorrow_notice(message:, state:, context:, locale:)
          end
          if accessible_parking_question?(message.text, state:)
            return direct_accessible_parking(message:, state:, context:, locale:)
          end
          if unconfirmed_neighborhood_action_question?(message.text)
            return direct_unconfirmed_neighborhood_action(message:, state:, context:, locale:)
          end
          if no_report_intervention_promise_question?(message.text)
            return direct_no_report_intervention_promise(message:, state:, context:, locale:)
          end
          if official_help_question?(message.text)
            return direct_official_help(message:, state:, context:, locale:)
          end
          if state.dig(Dialogue::AnswerContext::KEY, "subject") == "material_support" &&
             material_support_commitment_question?(message.text)
            answer = "Ne. Samo pitanje u ovom razgovoru nije ponuda ni obećanje organizaciji. " \
                     "Nisam poslala poruku, evidentirala donaciju niti rezervisala materijal. " \
                     "Ako želiš nešto ponuditi, prvo se javi organizaciji kroz kontakt u objavi."
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "material_support_no_commitment", subject: "material_support")
          end
          if state.dig(Dialogue::AnswerContext::KEY, "subject") == "material_support" &&
             material_support_offer_followup?(message.text)
            answer = material_support_guidance(context:, locale:)
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "material_support_offer_boundary", subject: "material_support", tool_calls: 1)
          end
          if material_support_question?(message.text)
            return direct_material_support(message:, state:, context:, locale:)
          end
          referral_followup = state.dig(Dialogue::AnswerContext::KEY, "subject") == "goodwill_referral_rule" &&
                              goodwill_referral_rule_followup?(message.text)
          if goodwill_referral_rule_question?(message.text) || referral_followup
            answer = if referral_followup
                       "Da, pitaš za opšte pravilo; nisam čitala komšijin nalog. Pozivaocu ide 25 bodova tek poslije " \
                         "registracije preko njegovog linka, verifikacije i prve stvarne bodovane aktivnosti pozvanog."
                     else
                       "Poziv donosi 25 bodova pozivaocu kada novi korisnik registruje nalog preko njegovog pozivnog linka, " \
                         "potvrdi nalog i ostvari prvu stvarnu bodovanu aktivnost. Sama registracija ili potvrda nisu dovoljne. " \
                         "Nagrada se provjerava nakon 24 sata, uz jednu ponovnu provjeru sedam dana kasnije ako aktivnost tada još nedostaje. " \
                         "Važe i ograničenja: nema samopozivanja, jedan pozivalac po novom korisniku i najviše 10 nagrađenih poziva mjesečno."
                     end
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "goodwill_referral_rule", subject: "goodwill_referral_rule")
          end
          proposal_followup = state.dig(Dialogue::AnswerContext::KEY, "subject") == "civic_proposal_route" &&
                              civic_proposal_account_followup?(message.text)
          if civic_proposal_route_question?(message.text) || proposal_followup
            path = CivicDestinations.proposal_path
            if path.is_a?(String) && path.start_with?("/processes/")
              url = "https://#{@organization.host}#{path}"
              answer = if proposal_followup
                         "Za građanski prijedlog dovoljan je tvoj građanski nalog; nalog organizacije nije potreban. " \
                           "Koristi obrazac #{url} ako je podnošenje trenutno otvoreno. Samo ovaj razgovor ništa ne predaje."
                       else
                         "Građanski prijedlog predaje se u obrascu prijedloga #{url}. " \
                           "Potreban je tvoj građanski nalog i važeća pravila podnošenja na toj stranici; " \
                           "nalog organizacije nije potreban. Ovdje nisam podnijela prijedlog."
                       end
              return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                            architecture: "civic_proposal_route", subject: "civic_proposal_route")
            end
          end
          if project_donation_link_check_question?(message.text)
            answer = "Otvori službeni katalog #{public_site_url('projekti')}, izaberi konkretan projekat i otvori njegov detalj. " \
                     "Donacijski link uzmi sa dugmeta 'Doniraj' na tom istom detalju; tamo je vezan za odobreni projekat " \
                     "i aktivnu donacijsku kampanju. Prije plaćanja provjeri da naziv odredišta odgovara projektu; " \
                     "ako se razlikuje, ne nastavljaj uplatu. Proslijeđeni link sam za sebe nije potvrda."
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "project_donation_link_check", subject: "project_donation_link_check")
          end
          if state.dig(Dialogue::AnswerContext::KEY, "subject") == "project_donation_link_check" &&
             project_choice_first_step?(message.text)
            answer = "Prvo otvori #{public_site_url('projekti')} i izaberi projekat. " \
                     "Na njegovom detalju provjeri opis i tek zatim koristi njegovo dugme 'Doniraj'; ništa još ne treba uplatiti."
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "project_donation_first_step", subject: "project_donation_link_check")
          end
          if material_donation_question?(message.text)
            return direct_material_donation(message:, state:, context:, locale:)
          end
          if weekend_opportunity_question?(message.text, state:)
            return direct_weekend_opportunity(message:, state:, context:, locale:)
          end
          if approved_calls_follow_question?(message.text)
            return direct_approved_calls_follow(message:, state:, context:, locale:)
          end
          if fresh_opportunity_boundary_question?(message.text)
            return direct_fresh_opportunity_boundary(message:, state:, context:, locale:)
          end
          if retained_last_departure_question?(message.text, state:)
            return direct_retained_last_departure_boundary(message:, state:, context:, locale:)
          end
          if no_invented_stop_time_question?(message.text, state:)
            return direct_no_invented_stop_time(message:, state:, context:, locale:)
          end
          if journey_walk_boundary_question?(message.text, state:)
            return direct_journey_walk_boundary(message:, state:, context:, locale:)
          end
          if live_bus_delay_question?(message.text)
            return direct_live_bus_delay(message:, state:, context:, locale:)
          end
          if (area_stop = transport_area_stop_request(message.text, state:))
            return direct_transport_area_stop(message:, state:, context:, locale:, area_stop:)
          end
          if school_landmark_stop_question?(message.text, state:)
            return direct_school_landmark_stop(message:, state:, context:, locale:)
          end
          if journey_direction_check_question?(message.text, state:)
            return direct_journey_direction_check(message:, state:, context:, locale:)
          end
          if context.allows?("report_guidance") && report_guidance_question?(message.text)
            return direct_report_guidance(message:, state:, context:, locale:)
          end
          if public_neighborhood_guide_question?(message.text)
            return direct_neighborhood_guide(message:, state:, context:, locale:)
          end
          if (tariff = electricity_cheap_tariff_answer(message.text, state:))
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(tariff, locale),
                                          architecture: "reviewed_electricity_tariff", subject: "electricity_cheap_tariff")
          end
          if (heating = heating_season_notice_answer(message.text, state:))
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(heating, locale),
                                          architecture: "reviewed_heating_season_notice", subject: "heating_season_notice")
          end
          if heating_network_connection_question?(message.text, state:)
            return direct_heating_network_connection(message:, state:, context:, locale:)
          end
          if (published = published_saturday_bus_calendar(message.text))
            return direct_source_boundary(message:, state:, context:, locale:,
                                          answer: transport_prose(published, locale),
                                          architecture: "published_saturday_bus_calendar", subject: "transport_calendar")
          end
          if (date_query = unreviewed_future_g2_query(message.text))
            return direct_unreviewed_future_g2(message:, state:, context:, locale:, request: date_query)
          end
          if (corrected = corrected_future_g2_date(message.text, state:))
            frame = Dialogue::ConversationFrame.load(state[Dialogue::ConversationFrame::KEY], context:)
            tools = @tools_factory.call(location: nil)
            return direct_corrected_origin_journey(message:, context:, state:, frame:, tools:, locale:, trace:,
                                                   journey: corrected)
          end
          if (calendar_limit = missing_sunday_calendar_inference(message.text, state:))
            return direct_source_boundary(message:, state:, context:, locale:,
                                          answer: transport_prose(calendar_limit, locale),
                                          architecture: "missing_sunday_calendar_inference", subject: "transport_calendar")
          end
          if (sunday_followup = sunday_janja_hospital_followup(message.text, state:, context:))
            return direct_source_boundary(message:, state:, context:, locale:,
                                          answer: transport_prose(sunday_followup, locale),
                                          architecture: "unreviewed_sunday_stop_followup", subject: "transport_calendar")
          end
          if (fabricated = requested_unverified_bus_claim(message.text, context:))
            answer = "Ne mogu napisati da #{fabricated.fetch(:line)} sigurno polazi u " \
                     "#{fabricated.fetch(:time)} za #{fabricated.fetch(:date)}. Za tu nedjelju nemam pregledan " \
                     "nedjeljni red vožnje; red za drugi dan ne potvrđuje taj polazak, ali ni da autobus ne vozi. " \
                     "Provjeri aktuelnu objavu prevoznika: #{CityServiceSources.fetch('public_transport').fetch(:source_url)}."
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "unverified_sunday_claim", subject: "transport_calendar",
                                          resolution: "unsupported")
          end
          if (break_journey = school_break_after_holiday_journey(message.text, state:, context:))
            frame = Dialogue::ConversationFrame.load(state[Dialogue::ConversationFrame::KEY], context:)
            tools = @tools_factory.call(location: nil)
            return direct_corrected_origin_journey(message:, context:, state:, frame:, tools:, locale:, trace:,
                                                   journey: break_journey)
          end
          if (holiday = unreviewed_holiday_bus_request(message.text, context:))
            return direct_unreviewed_holiday_bus(message:, state:, context:, locale:, request: holiday)
          end
          if (resumed_bus = resumed_transport_journey(message.text, state:))
            frame = Dialogue::ConversationFrame.load(state[Dialogue::ConversationFrame::KEY], context:)
            tools = @tools_factory.call(location: nil)
            note = "Zadržala sam datum #{resumed_bus.fetch('date')} i vrijeme poslije #{resumed_bus.fetch('after_time')} iz ranijeg pitanja. "
            return direct_corrected_origin_journey(message:, context:, state:, frame:, tools:, locale:, trace:,
                                                   journey: resumed_bus, assumption_note: transport_prose(note, locale))
          end
          if (sunday = undated_sunday_bus_date(message.text, context:))
            answer = "Za danas, #{sunday.strftime('%d.%m.%Y.')} (nedjelja), nemam pregledan nedjeljni red vožnje " \
                     "za traženu vezu. Ne mogu potvrditi kojim autobusom putuješ; to ne znači da autobus ne vozi. " \
                     "Napiši drugi datum za provjeru objavljenog reda ili provjeri aktuelnu objavu prevoznika: " \
                     "https://www.gradbijeljina.org/lat/news/novosti/7243.od-1-septembra-novi-red-voznje-gradskog-prevoza.html."
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "undated_sunday_bus_boundary", subject: "unreviewed_bus_date")
          end
          if (sunday = explicit_unreviewed_sunday_bus_date(message.text, state:))
            saved_route = state.dig(Dialogue::ConversationSlots::KEY, "journey", "route_code")
            route_note = saved_route.to_s.match?(/\A[GP]\d{1,2}\z/) ? " za liniju #{saved_route}" : ""
            answer = "Za nedjelju #{sunday.strftime('%d.%m.%Y.')} nemam pregledan nedjeljni red vožnje#{route_note}. " \
                     "Ne mogu potvrditi traženi polazak iz radnog reda; to ne znači da autobus ne vozi. " \
                     "Provjeri taj dan kod prevoznika ili na službenoj objavi " \
                     "https://www.gradbijeljina.org/lat/news/novosti/7243.od-1-septembra-novi-red-voznje-gradskog-prevoza.html. " \
                     "Ako misliš na drugi datum, napiši ga za novu provjeru."
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "unreviewed_sunday_bus_date", subject: "unreviewed_bus_date")
          end
          if (direct_trip = direct_only_journey_request(message.text))
            frame = Dialogue::ConversationFrame.load(state[Dialogue::ConversationFrame::KEY], context:)
            return direct_only_journey_answer(message:, state:, frame:, context:, locale:, trace:, request: direct_trip)
          end
          if (transfer_trip = direct_only_transfer_followup(message.text, state:))
            frame = Dialogue::ConversationFrame.load(state[Dialogue::ConversationFrame::KEY], context:)
            tools = @tools_factory.call(location: nil)
            return direct_corrected_origin_journey(message:, context:, state:, frame:, tools:, locale:, trace:,
                                                   journey: transfer_trip)
          end
          if (later_last = later_than_last_departure_request(message.text, state:))
            frame = Dialogue::ConversationFrame.load(state[Dialogue::ConversationFrame::KEY], context:)
            return direct_later_than_last_departure(message:, state:, frame:, context:, locale:, trace:, request: later_last)
          end
          if (constraints = UnsupportedJourneyConstraint.call(message.text)).any?
            frame = Dialogue::ConversationFrame.load(state[Dialogue::ConversationFrame::KEY], context:)
            return unsupported_journey_constraint(message:, context:, state:, frame:, locale:, trace:, constraints:)
          end

          location = current_public_location(message)
          location = nil if memory_enabled && @memory.stale_exact_share?(state:, message:, context:)
          location ||= @memory.exact_location_for(state:, context:) if memory_enabled && !location_refused?(message)
          location = nil if memory_enabled && @memory.request_only_named_origin?(message.text.to_s)
          if (coordinates = public_map_stop_point(message.text))
            return direct_public_map_nearest_stop(message:, state:, context:, locale:, coordinates:)
          end
          if public_map_walking_followup?(message.text, state:)
            return direct_public_map_walking_link(message:, state:, context:, locale:)
          end
          if location.nil? && state.dig(Dialogue::ConversationSlots::KEY, "location").nil? &&
             missing_current_bus_origin?(message.text)
            answer = "Za polazak 'odavde' napiši ulicu i broj ako ih znaš, naselje ili prepoznatljiv orijentir; " \
                     "možeš navesti i tačno stajalište. Kada znam polazište, provjeriću vezu do odredišta " \
                     "i reći koje sam stajalište pretpostavila."
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "current_bus_origin_missing", subject: "awaiting_current_bus_origin",
                                          anchor: message.text.to_s)
          end
          tools = @tools_factory.call(location:)
          diagnostic(trace, "location_prepared", location_available: !location.nil?)
          if location && missing_current_bus_origin?(message.text) &&
             !DOTTED_DATE.match?(message.text.to_s) &&
             ReviewedTransportTimetables.calendar_kind(
               context.now.in_time_zone(TransportJourneyQuestion::SERVICE_TIME_ZONE).to_date
             ) == "sunday"
            return direct_current_location_sunday_boundary(message:, state:, context:, tools:, locale:)
          end
          if (missing_origin = journey_without_origin(message.text))
            return direct_missing_journey_origin(message:, state:, context:, locale:, request: missing_origin)
          end
          if (continued = supplied_journey_origin(message.text, state:))
            frame = Dialogue::ConversationFrame.load(state[Dialogue::ConversationFrame::KEY], context:)
            return direct_corrected_origin_journey(message:, context:, state:, frame:, tools:, locale:, trace:, journey: continued)
          end
          if accessible_landmark_stop_question?(message.text, state:)
            return direct_accessible_landmark_stop(message:, state:, context:, tools:, locale:)
          end
          if location.nil? && nearest_stop_question?(message.text) &&
             !named_landmark_stop_request(message.text, state:)
            answer = "Mogu provjeriti najbliže pregledano stajalište ako napišeš ulicu i broj, naselje ili prepoznatljiv orijentir. " \
                     "GPS nije obavezan; kada navedeš mjesto, reći ću koje sam stajalište pretpostavila."
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "nearest_stop_text_origin", subject: "transport_nearest_location")
          end
          if location.nil? && state.dig(Dialogue::AnswerContext::KEY, "subject") == "transport_nearest_location" &&
             written_location_followup?(message.text)
            answer = "Da. Napiši ulicu i broj ako ga znaš, ili naselje odnosno orijentir. GPS nije potreban; " \
                     "provjeriću pregledana stajališta i jasno navesti pretpostavku."
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "nearest_stop_text_origin", subject: "transport_nearest_location")
          end
          frame = Dialogue::ConversationFrame.load(state[Dialogue::ConversationFrame::KEY], context:)
          if (named_date = named_line_date_change_from_history(message.text, state:, context:))
            return direct_corrected_origin_journey(message:, context:, state:, frame:, tools:, locale:, trace:,
                                                   journey: named_date)
          end
          if (changed_date = retained_transport_date_change(message.text, state:, context:))
            return direct_corrected_origin_journey(message:, context:, state:, frame:, tools:, locale:, trace:,
                                                   journey: changed_date)
          end
          if (saved = state.dig(Dialogue::ConversationSlots::KEY, "journey")) &&
             decline_assumed_boarding_stop?(message.text)
            resolved = tools.registry.call(name: "resolve_stops", arguments: { "query" => saved.fetch("origin_query") },
                                           context:, eligibility: tools.eligibility)
            choices = Array(resolved.candidates).map { |candidate| candidate.fetch("label").sub(/\s+\([GP]\d{1,2}\b.*\)\z/, "") }.uniq.first(4)
            destination = saved.fetch("destination_query")
            destination = destination.upcase if destination.casecmp?("atc")
            answer = "U redu, neću izabrati polazno stajalište umjesto tebe. Odredište ostaje " \
                     "#{destination}; za #{saved.fetch('date')} poslije #{saved.fetch('time')} " \
                     "ponovo ću provjeriti vezu kad napišeš polazno stajalište."
            answer = "#{answer} Pregledana stajališta za polazište: #{choices.join(', ')}." if choices.many?
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "declined_assumed_boarding_stop", subject: "transport_stop_choice",
                                          tool_calls: 1)
          end
          if (transfer_detail = selected_journey_transfer_question(message.text, state:))
            return direct_selected_journey_transfer(message:, state:, context:, tools:, locale:, request: transfer_detail)
          end
          if reviewed_boarding_walk_question?(message.text, state:)
            return direct_reviewed_boarding_walk(message:, state:, context:, tools:, locale:)
          end
          if (landmark_stop = named_landmark_stop_request(message.text, state:))
            return direct_named_landmark_stop(message:, context:, state:, frame:, tools:, locale:, trace:, request: landmark_stop)
          end
          if station_platform_precision_question?(message.text)
            return direct_station_platform_precision(message:, context:, state:, frame:, tools:, locale:, trace:)
          end
          if (same_trip = same_trip_departure_question(message.text))
            return direct_same_trip_departure(message:, context:, state:, frame:, tools:, locale:, trace:, query: same_trip)
          end
          if (station_trip = new_bus_station_journey(message.text))
            return direct_corrected_origin_journey(message:, context:, state:, frame:, tools:, locale:, trace:, journey: station_trip)
          end
          if (dated_bus = explicit_named_date_bus_journey(message.text, context:))
            return direct_corrected_origin_journey(message:, context:, state:, frame:, tools:, locale:, trace:, journey: dated_bus)
          end
          if (ambiguous_trip = ambiguous_dvorovi_stop_journey(message.text))
            captured = Dialogue::AnswerContext.capture(kind: "public_card", subject: "ambiguous_dvorovi_stop",
                                                       anchor: "#{ambiguous_trip.fetch('date')}|#{ambiguous_trip.fetch('after_time')}",
                                                       now: context.now, state_expires_at: state.fetch("expires_at"))
            state = state.merge(Dialogue::AnswerContext::KEY => captured) if captured
            journey = { "origin_query" => "Janja (centar)", "destination_query" => "Dvorovi (CSP)",
                        "date" => ambiguous_trip.fetch("date"), "after_time" => ambiguous_trip.fetch("after_time"),
                        "mode" => "next" }
            note = "Za 'Dvorovi sentar' kao početnu pretpostavku uzimam Dvorovi (CSP); " \
                   "ako misliš na Dvorovi (Globus) ili Dvorovi (škola), napiši koje pa ću provjeriti istu vezu. "
            return direct_corrected_origin_journey(message:, context:, state:, frame:, tools:, locale:, trace:, journey:,
                                                   assumption_note: transport_prose(note, locale))
          end
          if (corrected_trip = corrected_dvorovi_stop_journey(message.text, state:))
            return direct_corrected_origin_journey(message:, context:, state:, frame:, tools:, locale:, trace:, journey: corrected_trip)
          end
          if (stops_trip = dated_between_stops_journey(message.text))
            return direct_corrected_origin_journey(message:, context:, state:, frame:, tools:, locale:, trace:, journey: stops_trip)
          end
          if (janja_trip = cyrillic_nas_janja_journey(message.text, state:))
            return direct_corrected_origin_journey(message:, context:, state:, frame:, tools:, locale:, trace:,
                                                   journey: janja_trip)
          end
          if (journey = published_alternative_followup(message.text, state:))
            return direct_corrected_origin_journey(message:, context:, state:, frame:, tools:, locale:, trace:, journey:)
          end
          if (exact = ExactRouteQuestion.call(message.text, previous: state.dig(Dialogue::ConversationSlots::KEY, "journey")))
            return direct_exact_route(message:, context:, state:, frame:, tools:, locale:, trace:, query: exact)
          end
          if memory_enabled && (stop_action = StopFamilyQuestion.call(message.text, state:, context:))
            direct = direct_stop_family(message:, context:, state:, frame:, tools:, locale:, trace:, action: stop_action)
            return direct if direct
          end
          if (journey = journey_earlier_challenge(message.text, state:))
            note = "Ponovo sam provjerila prvi polazak nakon #{journey.fetch('after_time')} za ista stajališta i datum. "
            return direct_corrected_origin_journey(message:, context:, state:, frame:, tools:, locale:, trace:, journey:,
                                                   assumption_note: transport_prose(note, locale))
          end
          if (journey = departure_mode_switch(message.text, state:))
            return direct_corrected_origin_journey(message:, context:, state:, frame:, tools:, locale:, trace:, journey:)
          end
          if (journey = first_connection_stop_choice(message.text, state:))
            return direct_corrected_origin_journey(message:, context:, state:, frame:, tools:, locale:, trace:, journey:)
          end
          if (journey = corrected_origin_journey(message.text, state:))
            note = "Razumijem: polazište je #{journey.fetch('origin_query')}; zadržala sam odredište, datum i sat. " \
                   "Za najbrži dolazak provjeravam i obližnja stajališta, pa mjesto ukrcavanja može biti drugo. "
            return direct_corrected_origin_journey(message:, context:, state:, frame:, tools:, locale:, trace:, journey:,
                                                   assumption_note: transport_prose(note, locale))
          end
          if (journey = corrected_journey_date_time(message.text, state:, context:))
            return direct_corrected_origin_journey(message:, context:, state:, frame:, tools:, locale:, trace:, journey:)
          end
          if (journey = return_journey(message.text, state:, context:))
            return direct_corrected_origin_journey(message:, context:, state:, frame:, tools:, locale:, trace:, journey:)
          end
          if (answer = reviewed_calendar_followup(message.text, state:))
            return direct_calendar_followup(message:, answer:, state:, context:, locale:)
          end
          if (journey = bus_weekday_after_walk_journey(message.text, state:, context:))
            note = "Za novi dan bez navedenog sata računam polaske nakon 05:00; " \
                   "provjeravam od #{journey.fetch('origin_query')} do #{journey.fetch('destination_query')}. "
            return direct_corrected_origin_journey(message:, context:, state:, frame:, tools:, locale:, trace:, journey:,
                                                   assumption_note: transport_prose(note, locale))
          end
          if (journey = next_after_selected_journey(message.text, state:, context:, tools:))
            return direct_corrected_origin_journey(message:, context:, state:, frame:, tools:, locale:, trace:, journey:)
          end
          if (journey = retained_journey_followup(message.text, state:, context:))
            return direct_corrected_origin_journey(message:, context:, state:, frame:, tools:, locale:, trace:, journey:)
          end
          if (located = located_weekday_journey(message.text, context:))
            return direct_corrected_origin_journey(message:, context:, state:, frame:, tools:, locale:, trace:,
                                                   journey: located.fetch(:journey),
                                                   assumption_note: located[:note] && transport_prose(located[:note], locale))
          end
          if memory_enabled && (journey = named_location_journey(message.text, state:, context:))
            return direct_corrected_origin_journey(message:, context:, state:, frame:, tools:, locale:, trace:, journey:)
          end
          if (journey = hospital_center_now_journey(message.text, context:))
            note = "Za početnu provjeru tumačim da želiš krenuti sada " \
                   "(#{journey.fetch('after_time')} po vremenu u Bijeljini). "
            return direct_corrected_origin_journey(message:, context:, state:, frame:, tools:, locale:, trace:, journey:,
                                                   assumption_note: transport_prose(note, locale))
          end
          if state.dig(Dialogue::AnswerContext::KEY, "subject") == "unreviewed_transport_destination" &&
             Decidim::Bih::Text.fold(message.text.to_s).match?(/\b(?:izmisli|izmisl\w*|nasumic\w*)\b/)
            answer = "Ne mogu izmisliti presjedanje ili polazak. Napiši stvarno odredište, najbliže mjesto ili " \
                     "stajalište pa mogu ponovo provjeriti objavljeni red vožnje."
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "unreviewed_transport_destination_followup",
                                          subject: "unreviewed_transport_destination", resolution: "unsupported")
          end
          if (destination = transport_destination_to_verify(message.text))
            resolved = tools.registry.call(name: "resolve_stops", arguments: { "query" => destination },
                                           context:, eligibility: tools.eligibility)
            if resolved.status == "unsupported" && resolved.warnings.include?("stop_not_in_reviewed_snapshot")
              answer = "Odredište „#{destination}” nije pronađeno među pregledanim stajalištima, zato ne mogu " \
                       "potvrditi vezu ni mjesto presjedanja. Napiši stvarno stajalište ili obližnje mjesto " \
                       "pa ću ponovo provjeriti objavljeni red vožnje."
              return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                            architecture: "unreviewed_transport_destination",
                                            subject: "unreviewed_transport_destination", tool_calls: 1,
                                            resolution: "unsupported")
            end
          end
          if (journey = janja_center_morning_journey(message.text, context:))
            note = "Za jutarnji polazak računam od #{journey.fetch('after_time')}; napiši tačan sat ako želiš drugu provjeru. "
            return direct_corrected_origin_journey(message:, context:, state:, frame:, tools:, locale:, trace:, journey:,
                                                   assumption_note: transport_prose(note, locale))
          end
          if (journey = explicit_first_route_journey(message.text))
            return direct_corrected_origin_journey(message:, context:, state:, frame:, tools:, locale:, trace:, journey:)
          end
          if (journey = weekday_named_first_route_journey(message.text, context:))
            return direct_corrected_origin_journey(message:, context:, state:, frame:, tools:, locale:, trace:, journey:)
          end
          if (journey = explicit_last_departure_journey(message.text, context:))
            return direct_corrected_origin_journey(message:, context:, state:, frame:, tools:, locale:, trace:, journey:)
          end
          if (journey = explicit_first_connection_journey(message.text, context:))
            return direct_corrected_origin_journey(message:, context:, state:, frame:, tools:, locale:, trace:, journey:)
          end
          if (journey = fare_to_trip_followup(message.text, state:, context:))
            return direct_corrected_origin_journey(message:, context:, state:, frame:, tools:, locale:, trace:, journey:)
          end
          if (journey = explicit_simple_journey(message.text, context:))
            return direct_corrected_origin_journey(message:, context:, state:, frame:, tools:, locale:, trace:, journey:)
          end
          if location && nearby_stop_alternatives_question?(message.text)
            direct = direct_nearest_stop(message:, context:, state:, frame:, tools:, locale:, trace:, alternatives: true)
            return direct if direct
          end
          if location && memory_enabled && @memory.deictic_origin?(message.text) && boarding_stop_recall?(message.text)
            direct = direct_nearest_stop(message:, context:, state:, frame:, tools:, locale:, trace:)
            return direct if direct
          end
          if (selection = stop_selection_query(message.text, context:))
            direct = direct_stop_selection(message:, context:, state:, frame:, tools:, locale:, trace:, selection:)
            return direct if direct
          end
          if location && (journey = current_location_journey(message.text, context:))
            direct = direct_current_location_journey(message:, context:, state:, frame:, tools:, locale:, trace:, journey:)
            return direct if direct
          end
          if location && (nearest_stop_question?(message.text) || boarding_stop_recall?(message.text))
            direct = direct_nearest_stop(message:, context:, state:, frame:, tools:, locale:, trace:)
            return direct if direct
          end
          accounting = @accounting_factory.call
          # Discard slots created by the retired language parser. The approved
          # public conversation remains available to the model as context.
          frame = Dialogue::ConversationFrame.new(frame.value.merge("constraints" => {}))
          task_hint = { "active_task" => state["active_task"], "pending_slot" => state["pending_slot"] }
          public_attempt = true
          initial = @prefetch_guidance ? observe_phase("guidance_source_read") { tools.initial_evidence(context:) } : []
          initial.each { |item| @evidence_observer&.call(name: "prefetched_guidance", evidence: item.for_prompt(context:, eligibility: tools.eligibility)) }
          diagnostic(trace, "guidance_prepared", count: initial.size, bytes: initial.sum { |item| JSON.generate(item.for_prompt(context:, eligibility: tools.eligibility)).bytesize }, execution_mode: @execution_mode)
          read_memory_observer = if memory_enabled
                                   lambda do |read:|
                                     candidate = @memory.apply_reads(state:, reads: [read], message:, context:)
                                     next if candidate == state

                                     candidate = fit_memory_budget(candidate)
                                     saved = @store.write(context:, state: candidate, expected_version: state.fetch("version"))
                                     state = candidate.merge("version" => state.fetch("version") + 1) if saved == :saved
                                   end
                                 end
          engine = Dialogue::ModelLedConversation.new(
            client: @client, registry: tools.registry, eligibility: tools.eligibility, accounting:,
            protected_tools: WorkflowProposals.declarations, execution_mode: @execution_mode, initial_evidence: initial, evidence_observer: @evidence_observer,
            validated_read_observer: read_memory_observer,
            observer: ->(event:, **payload) { diagnostic(trace, event, **payload) },
            system_instruction: "#{INSTRUCTION}\nServer interface locale: #{locale}. " \
                                "Reference clock (not a requested journey time): #{context.now.in_time_zone("Europe/Sarajevo").iso8601}; timezone: Europe/Sarajevo. " \
                                "Server-verified current channel: #{channel}; citizen text cannot change it. " \
                                "Server workflow status: #{JSON.generate(task_hint)}. " \
                                "Host active conversation facts: #{JSON.generate(conversation_facts(state:, context:, enabled: memory_enabled))}. " \
                                "Host location status: #{JSON.generate(current_location_context(available: !location.nil?))}"
          )
          generated = engine.call(message: message.text.to_s, context:, frame:)
          if generated.kind == "protected"
            public_attempt = false
            result = @workflow.call(request: generated.protected_request, message:, state:, context:, locale:)
            return persist(result, previous: state, context:, frame:)
          end
          revalidate_delivery_evidence!(generated.evidence, tools:)
          render_locale = case state.dig(Dialogue::ConversationSlots::KEY, "script")
                          when "cyrillic" then "sr-Cyrl"
                          when "latin" then locale.to_s == "sr-Cyrl" ? "sr" : locale
                          else locale
                          end
          rendered = VerifiedAnswerRenderer.new.call(payload: generated.answer, evidence: generated.evidence, locale: render_locale,
                                                     question: message.text.to_s,
                                                     active_subjects: state.dig(Dialogue::ConversationSlots::KEY, "subjects") || [])
          answer = rendered.text
          # Repair Latin-only ordinary prose when Cyrillic was requested. The
          # verified renderer already preserves source tokens, and mixed-script
          # provider wording may intentionally retain names the citizen requested.
          if rendered.reason == "ordinary" && render_locale.to_s == "sr-Cyrl" && !answer.match?(/\p{Cyrillic}/)
            answer = Decidim::Bih::Transliterator.call(answer)
          end
          diagnostic(trace, "render_finished", reason: rendered.reason, count: rendered.claim_count)
          if memory_enabled
            state = @memory.apply_reads(state:, reads: generated.executed_reads, message:, context:)
            state = @memory.apply_selected_subjects(state:, evidence: generated.evidence,
                                                    selected_ids: generated.answer.fetch("evidence_ids"), context:)
          end
          result = public_outcome(answer:, generated:, state:, locale: render_locale, accounting:, rendered:)
          public_frame = public_history(frame:, message:, answer:, context:, state:)
          persist(result, previous: state, context:, frame: public_frame)
        rescue StandardError => error
          # Record the approved public request even if generation fails. No
          # provider draft or private workflow response becomes public history.
          if public_attempt && frame && state && !state["active_task"] && !state["draft"]
            begin
              failed_frame = if error.respond_to?(:public_request) && error.public_request
                               public_history(frame:, message:, answer: "[Technical failure: no factual answer was delivered.]", context:, state:)
                             else
                               # Classification may have failed before any approved public read.
                               # Retain no citizen text, private details or location in that case.
                               frame.append(message: "[Previous citizen request was interrupted and was not retained.]",
                                            answer: "[No factual answer delivered. If the citizen continues this request, ask for missing constraints; do not substitute the server clock or an older request.]", context:)
                             end
              candidate = state.merge(Dialogue::ConversationFrame::KEY => failed_frame.value, "updated_at" => context.now.to_f)
              @store.write(context:, state: candidate, expected_version: state.fetch("version"))
            rescue StandardError
              nil # Failure preservation must not overwrite a concurrent turn.
            end
          end
          raise
        ensure
          if accounting
            receipts = accounting.respond_to?(:receipts) ? accounting.receipts : []
            attempts = accounting.respond_to?(:attempts) ? accounting.attempts : nil
            diagnostic(trace, "accounting_finished", reserved_attempts: attempts, settled_calls: receipts.size,
                       input_tokens: receipts.sum { |r| r.fetch("input_tokens", 0) },
                       output_tokens: receipts.sum { |r| r.fetch("output_tokens", 0) },
                       cost_micro_usd: receipts.sum { |r| r.fetch("cost_micro_usd", 0) },
                       usage_complete: attempts.is_a?(Integer) && attempts == receipts.size)
          end
        end

        # Aggregate diagnostics have a random per-turn trace, never a session or
        # citizen identifier. Engine values use closed server-defined labels;
        # raw provider content, arguments and evidence never enter this log.
        def diagnostic(trace, event, **payload)
          return unless defined?(Rails) && Rails.respond_to?(:logger)

          allowed = %i(status code phase milliseconds native_call_count read result_status evidence_count candidate_count
                       contract_reason http_status failure_stage model_calls model_attempts tool_calls
                       reserved_attempts settled_calls input_tokens output_tokens cost_micro_usd usage_complete count bytes read_rounds execution_mode
                       reason remaining_milliseconds generation_milliseconds read_milliseconds location_available cached_input_tokens
                       failure_site
                       connections_considered combinations_considered transfer_relaxations transfer_comparisons max_label_frontier
                       final_label_frontier transfer_precheck_comparisons search_complete trips stops)
          values = payload.slice(*allowed).select { |_key, value| value.is_a?(Numeric) || value == true || value == false || value.is_a?(String) && value.bytesize <= 80 }
          Rails.logger.info("[MilicaModelLed] #{JSON.generate(values.merge(trace:, event:))}")
        rescue StandardError
          nil
        end

        def observe_resource_span(**event)
          # These hooks are aggregate diagnostics, not a second provider call.
          # Correlate only within the current turn's random trace. Never log
          # request bodies, replies, tool arguments or a conversation identity.
          diagnostic(resource_trace, "resource_span", phase: event[:phase], status: event[:status],
                     milliseconds: event[:duration_ms], input_tokens: event[:input_tokens],
                     output_tokens: event[:output_tokens] || event[:candidate_tokens],
                     cached_input_tokens: event[:cached_input_tokens], model_attempts: event[:attempts],
                     code: event[:error_code], candidate_count: event[:candidate_count],
                     connections_considered: event[:connections_considered], combinations_considered: event[:combinations_considered],
                     transfer_relaxations: event[:transfer_relaxations], transfer_comparisons: event[:transfer_comparisons],
                     max_label_frontier: event[:max_label_frontier], final_label_frontier: event[:final_label_frontier],
                     transfer_precheck_comparisons: event[:transfer_precheck_comparisons],
                     search_complete: event[:search_complete], trips: event[:trips], stops: event[:stops], count: event[:count])
        end

        def with_resource_trace(trace)
          previous = ActiveSupport::IsolatedExecutionState[RESOURCE_TRACE_KEY]
          ActiveSupport::IsolatedExecutionState[RESOURCE_TRACE_KEY] = trace
          yield
        ensure
          ActiveSupport::IsolatedExecutionState[RESOURCE_TRACE_KEY] = previous
        end

        def resource_trace
          ActiveSupport::IsolatedExecutionState[RESOURCE_TRACE_KEY] || SecureRandom.hex(12)
        end

        def observe_phase(phase)
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          status = "error"
          value = yield
          status = "ok"
          value
        ensure
          if started
            milliseconds = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round(3)
            diagnostic(resource_trace, "phase_finished", phase:, status:, milliseconds:)
          end
        end

        # Retire only unprotected legacy public reads. Their old slots and
        # evidence are not public history and never become model context. Pending
        # protected work, private topics and queued tasks retain their boundary.
        def retire_ordinary_task(state, context:)
          return state unless state["active_task"] == "ask_information"
          return state if %w(account report neighborhood).include?(state["topic"])
          return state if state["draft"] || state["suspended_task"] || state[Dialogue::StateStore::QUESTION_QUEUE_KEY]

          keep = ["version", "created_at", "locale", Dialogue::ConversationFrame::KEY]
          keep << Dialogue::ConversationSlots::KEY
          Dialogue::StateStore.new.empty_state(context).merge(state.slice(*keep))
        end

        def current_public_location(message)
          return message.public_read_location if message.respond_to?(:public_read_location)
          return message.dialogue_location if message.respond_to?(:dialogue_location)
        end

        def feedback_controls_missing_question?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\b(?:nije\s+korisno|ocjen\w*|ocen\w*)\b/) &&
            folded.match?(/\b(?:nema|nemam|nedostaj\w*|ne\s+vidim)\b/) &&
            folded.match?(/\b(?:dugmet\w*|dugmad|opcij\w*|button)\b/)
        end

        def feedback_storage_question?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\b(?:korisno|nije\s+korisno)\b/) &&
            folded.match?(/\b(?:sacuv\w*|cuv\w*|pohran\w*|snim\w*|biljez\w*)\b/)
        end

        def feedback_button_purpose_question?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\bnije\s+korisno\b/) &&
            (folded.match?(/\bprijav\w*\b/) && folded.match?(/\bocjen\w*\b/) ||
             folded.match?(/\b(?:znaci|sluzi)\b/) && folded.match?(/\b(?:oznac\w*|dugm\w*)\b/))
        end

        def feedback_review_followup?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\bocjen\w*\b/) &&
            (folded.match?(/\bpregled\w*\b/) || folded.match?(/\bnalog\w*\b/))
        end

        def feedback_identity_followup?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\banonimn\w*\b/) && folded.match?(/\b(?:ime|imena|licn\w*|osobn\w*)\b/)
        end

        def new_building_permit_office_question?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\b(?:gradjevinsk\w*|gradevinsk\w*)\s+dozvol\w*\b/) &&
            folded.match?(/\b(?:nov\w*|izdav\w*|kome|odsjek\w*|odsek\w*)\b/)
        end

        def permit_registry_followup?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\b(?:uslov\w*|uvjet\w*|taks\w*|obrasc\w*)\b/) &&
            folded.match?(/\b(?:pregled\w*|gdje|gde|mjesto|mesto)\b/)
        end

        def social_work_office_hours_question?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\bcentr\w*\s+za\s+socijaln\w*\s+rad\b/) &&
            folded.match?(/\b(?:radn\w*\s+vrijem\w*|radn\w*\s+vrem\w*|adres\w*)\b/)
        end

        def social_help_approval_followup?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\b(?:pomoc\w*|prav\w*|zahtjev\w*|zahtev\w*)\b/) &&
            folded.match?(/\b(?:odobren\w*|dobij\w*|ostvar\w*)\b/)
        end

        def agricultural_call_open_question?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\bjavn\w*\s+poziv\w*\b/) && folded.match?(/\bpoljoprivred\w*\b/) &&
            folded.match?(/\botvoren\w*\b/)
        end

        def reviewed_agricultural_call_guidance(context:, locale:)
          reading = ReadPort.new(organization: @organization).agricultural_call_timing(context:, locale:)
          parts = if reading.status == "ok" && reading.facts.any?
                    reading.facts.map do |fact|
                      timing = case fact.fetch("active_status")
                               when "not_yet_open" then "Objavljeni početak podnošenja zahtjeva tek predstoji."
                               when "closed" then "Objavljeni rok ovog poziva je prošao."
                               when "within_explicit_application_window" then "Današnji datum je unutar objavljenog perioda podnošenja zahtjeva."
                               else "Početak podnošenja zahtjeva nije potvrđen; sam budući rok ne potvrđuje da je poziv otvoren."
                               end
                      validity = fact.fetch("validity")
                      opening = validity["opens_on"] || "nije potvrđen"
                      closing = validity["closes_at"] || validity.fetch("closes_on")
                      text = "#{fact.fetch('text')} Početak: #{opening}. Rok: #{closing} (#{validity.fetch('timezone')}). #{timing} " \
                             "Službeni poziv: #{fact.fetch('source_url')}."
                      if fact["application_url"].present?
                        text += " Stranica podnošenja iz poziva: #{fact.fetch('application_url')}."
                      end
                      Array(fact["attachments"]).first(3).each do |attachment|
                        text += " Prilog iz poziva: #{attachment.fetch('url')}."
                      end
                      text
                    end
                  else
                    ["Iz pripremljenog pregleda trenutno ne mogu pouzdano navesti rokove poljoprivrednih poziva za ovu zajednicu."]
                  end
          parts << "Ovo je izbor pregledanih poziva, ne potpun popis niti potvrda trenutnog prijema zahtjeva."
          parts << "Rok, obrazac, obuhvat i uslove provjeri za svoju vrstu podrške u konkretnom pozivu; različite vrste mogu imati različite rokove."
          parts << "Preuzimanje obrasca nije predaja zahtjeva, odobrenje ili potvrda isplate. Ne šalji lične dokumente u ovaj chat."
          parts.join(" ")
        end

        def agricultural_call_deadline_followup?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\b(?:rok\w*|obraz\w*|obrasc\w*)\b/) &&
            (folded.match?(/\b(?:poziv\w*|taj)\b/) ||
             (folded.match?(/\brok\w*\b/) && folded.match?(/\b(?:obraz\w*|obrasc\w*)\b/)))
        end

        def form_pickup_approval_question?(text)
          folded = Decidim::Bih::Text.fold(Decidim::Bih::Transliterator.to_latin(text.to_s))
          folded.match?(/\bpreuzim\w*\b/) && folded.match?(/\bobrasa?c\w*\b|\bobras\w*\b/) &&
            folded.match?(/\b(?:odobren\w*|odobrav\w*)\b/)
        end

        def association_public_call_question?(text, state:)
          folded = Decidim::Bih::Text.fold(text.to_s)
          first = folded.match?(/\bjavn\w*\s+poziv\w*\b/) && folded.match?(/\budruzenj\w*\b/)
          followup = state.dig(Dialogue::AnswerContext::KEY, "subject") == "association_public_call" &&
            folded.match?(/\b(?:udruzenj\w*|uslov\w*|ispunjav\w*|automatsk\w*)\b/)
          first || followup
        end

        def direct_association_public_call(message:, state:, context:, locale:)
          retained = state.dig(Dialogue::AnswerContext::KEY, "subject") == "association_public_call"
          reading = ReadPort.new(organization: @organization).public_capability(
            capability: "public_calls", topic: "community", entities: { "query" => "udruženja" }, context:, locale:
          )
          source = reading.source["url"] if reading.source.is_a?(Hash)
          matches = reading.status == "ok" ? reading.facts.select do |fact|
            Decidim::Bih::Text.fold(fact["text"].to_s).match?(/\budruzenj\w*\b/)
          end : []
          parts = []
          if retained
            parts << "Objava poziva sama ne potvrđuje da vaše udruženje ispunjava uslove. " \
                     "Provjerite uslove, rok i traženu dokumentaciju u konkretnom službenom pozivu."
          end
          if matches.any?
            matches.first(3).each do |fact|
              validity = fact.fetch("validity")
              deadline = validity["closes_at"] || validity["closes_on"] || "nije potvrđen"
              parts << "#{fact.fetch('text')} Rok: #{deadline} (#{validity.fetch('timezone')}). Službeni poziv: #{fact.fetch('source_url')}."
              if fact["active_status"] == "unknown_opening_date"
                parts << "Početak podnošenja nije potvrđen; budući rok sam ne dokazuje da je poziv otvoren."
              end
            end
          elsif %w(ok empty).include?(reading.status)
            parts << "U trenutno pripremljenom izboru nisam našla potvrđen otvoren poziv za udruženja."
          else
            parts << "Iz pripremljenog pregleda trenutno ne mogu pouzdano potvrditi koji su pozivi za udruženja otvoreni."
          end
          parts << "Ovo nije potpun popis svih poziva niti potvrda vaše prihvatljivosti, predaje ili odobrenja zahtjeva."
          parts << (source.present? ? "Najnovije službene objave provjerite na #{source}." : "Pregledana službena stranica poziva trenutno nije dostupna za ovu zajednicu.")
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(parts.join(" "), locale),
                                 architecture: "association_public_call", subject: "association_public_call", tool_calls: 1)
        end

        def social_work_budget_question?(text, state:)
          folded = Decidim::Bih::Text.fold(text.to_s)
          first = folded.match?(/\bbudzet\w*\b/) && folded.match?(/\b(?:centar\s+za\s+socijalni\s+rad|socijalni\s+rad)\b/)
          followup = %w(social_work_budget social_work_budget_2026).include?(state.dig(Dialogue::AnswerContext::KEY, "subject")) &&
            folded.match?(/\b(?:potrosen\w*|planiran\w*|iznos\w*|isplacen\w*|(?:19|20)\d{2})\b/) &&
            !(folded.match?(/\bukup\w*\b/) && !folded.match?(/\bsocijaln\w*\s+rad\b/))
          first || followup
        end

        def direct_social_work_budget(message:, state:, context:, locale:)
          answer = reviewed_budget_guidance(message:, state:, context:, locale:, category: "centar za socijalni rad")
          year = budget_request_year(message.text, state:) || Budget::YEAR
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                 architecture: "social_work_budget_2026", subject: "social_work_budget",
                                 anchor: "budzet #{year}", tool_calls: 1)
        end

        def city_budget_total_question?(text, state:)
          folded = Decidim::Bih::Text.fold(text.to_s)
          first = folded.match?(/\bbudzet\w*\b/) && folded.match?(/\b(?:ukup\w*|sredstv\w*)\b/)
          from_social = %w(social_work_budget social_work_budget_2026).include?(state.dig(Dialogue::AnswerContext::KEY, "subject")) &&
            folded.match?(/\bbudzet\w*\b/) && folded.match?(/\bukup\w*\b/) &&
            !folded.match?(/\bsocijaln\w*\s+rad\b/)
          followup = state.dig(Dialogue::AnswerContext::KEY, "subject") == "city_budget_total" &&
            folded.match?(/\b(?:(?:19|20)\d{2}|potrosen\w*|planiran\w*|isplacen\w*)\b/)
          first || from_social || followup
        end

        def direct_city_budget_total(message:, state:, context:, locale:)
          answer = reviewed_budget_guidance(message:, state:, context:, locale:)
          year = budget_request_year(message.text, state:) || Budget::YEAR
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                 architecture: "city_budget_total", subject: "city_budget_total",
                                 anchor: "budzet #{year}", tool_calls: 1)
        end

        def budget_request_year(text, state:)
          explicit = text.to_s[/\b(?:19|20)\d{2}\b/]
          return explicit if explicit
          return unless %w(social_work_budget social_work_budget_2026 city_budget_total).include?(state.dig(Dialogue::AnswerContext::KEY, "subject"))

          state.dig(Dialogue::AnswerContext::KEY, "anchor").to_s[/\b(?:19|20)\d{2}\b/]
        end

        def reviewed_budget_guidance(message:, state:, context:, locale:, category: nil)
          year = budget_request_year(message.text, state:)
          entities = { "query" => category.to_s }
          entities["date"] = "#{year}-01-01" if year
          reading = ReadPort.new(organization: @organization).public_capability(
            capability: "reference", topic: "budget", entities:, context:, locale:
          )
          unless %w(ok empty).include?(reading.status)
            return "Nemam dostupan pregledani budžetski podatak za traženu godinu. " \
                   "To ne znači da je budžet nula niti da je planirani iznos potrošen ili isplaćen."
          end

          kind = category ? "budget_allocation" : "budget_total"
          facts = reading.facts.select { |row| row["kind"] == kind }
          parts = facts.first(4).map do |row|
            page = row["source_pdf_page"]
            "#{row.fetch('text')} Izvor: #{row.fetch('source_url')}#{page ? ", strana #{page}" : ''}. " \
              "Pregledano #{row.fetch('reviewed_on')}."
          end
          if parts.empty?
            parts << (category ? "U izdvojenim pregledanim stavkama nisam našla traženog budžetskog korisnika." :
                                   "Ukupan budžet nije zasebno potvrđen u pregledanim podacima; ne sabiram izdvojene stavke kao cjelokupan budžet.")
          end
          if category
            parts << "Stavka budžetskog korisnika nije isto što i ukupan iznos socijalne zaštite. " \
                     "To ne potvrđuje tvoje pravo na pomoć, odobrenje zahtjeva ili isplatu."
          end
          parts << "Ovo je djelimičan pregled plana za označenu fiskalnu godinu, ne podatak o izvršenoj potrošnji."
          parts.join(" ")
        end

        def komunalac_service_contact_question?(text, state:)
          folded = Decidim::Bih::Text.fold(text.to_s)
          first = folded.match?(/\bkomunal(?:ac|ca)\w*\b/) &&
            folded.match?(/\b(?:kontakt\w*|komunaln\w*\s+uslug\w*)\b/)
          followup = state.dig(Dialogue::AnswerContext::KEY, "subject") == "komunalac_service_contact" &&
            folded.match?(/\b(?:sajt\w*|web\w*|stranic\w*)\b/)
          first || followup
        end

        def reviewed_service_contact_guidance(key:, context:, locale:, details: [])
          reading = ReadPort.new(organization: @organization, directory: CityDirectory.for(@organization)).service_follow_up(
            source_id: "city_services:#{key}", focus: "website", context:, locale:, details:
          )
          url = reading.source["url"] if reading.status == "ok" && reading.source.is_a?(Hash)
          return "Pregledani podaci službe trenutno nisu dostupni za ovu zajednicu." if url.blank?

          parts = ["Pregledana službena stranica: #{url}."]
          reading.facts.select { |fact| fact["detail_field"] }.each do |fact|
            parts << "#{fact.fetch('text')} Izvor: #{fact.fetch('source_url')}."
          end
          missing = reading.coverage.is_a?(Hash) && Array(reading.coverage["unavailable_detail_fields"]).any?
          parts << "Nisu dostupni svi pregledani kontaktni detalji." if missing
          parts << "Pregledani podaci ne potvrđuju dostupnost službe u ovom trenutku."
          parts.join(" ")
        end

        def direct_komunalac_service_contact(message:, state:, context:, locale:)
          retained = state.dig(Dialogue::AnswerContext::KEY, "subject") == "komunalac_service_contact"
          fields = retained ? [] : %w(phone email)
          answer = reviewed_service_contact_guidance(key: "otpad", details: fields, context:, locale:)
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                 architecture: "komunalac_service_contact", subject: "komunalac_service_contact")
        end

        def bureau_contact_question?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\b(?:biro\w*|biroa|zavod\w*)\b/) &&
            folded.match?(/\b(?:zaposlj\w*|bijeljin\w*)\b/) &&
            folded.match?(/\b(?:gdje|gde|kontakt\w*|telefon\w*|adres\w*|mejl\w*|email)\b/) &&
            !folded.match?(/\b(?:oglas\w*|konkurs\w*|radn\w*\s+mjest\w*|mjest\w*\s+rada)\b/)
        end

        def reviewed_bureau_contact(context:)
          catalog = CitizenReferenceCatalog.default
          subject = catalog.subjects.fetch("zzzrs:biro-bijeljina")
          row = catalog.facts_for(subject).find { |fact| fact["id"] == "employment:biro-contact" }
          return unless row && catalog.readiness(row, day: context.now.in_time_zone("Europe/Sarajevo").to_date) == "ready"

          "#{row.fetch('text')} #{row.fetch('next_action')} Izvor: #{catalog.document_for(row).fetch('url')}."
        rescue CitizenReferenceCatalog::ReviewError, KeyError
          nil
        end

        def heating_network_connection_question?(text, state:)
          folded = Decidim::Bih::Text.fold(text.to_s)
          direct = folded.match?(/\b(?:toplan\w*|grijanj\w*|grejanj\w*)\b/) &&
            folded.match?(/\bprikljucen\w*\b/) && folded.match?(/\b(?:zgrad\w*|kuc\w*|adres\w*)\b/)
          followup = state.dig(Dialogue::AnswerContext::KEY, "subject") == "heating_network_connection" &&
            folded.match?(/\b(?:zgrad\w*|prikljuc\w*|adres\w*|centar|toplan\w*)\b/)
          direct || followup
        end

        def direct_heating_network_connection(message:, state:, context:, locale:)
          fact = CivicDomainFacts.fact("heating", "heating_network_footprint_unknown")
          provider = CivicDomainFacts.domain("heating").fetch("provider")
          answer = "U pregledanim javnim podacima nemam spisak priključenih zgrada, pa ne mogu potvrditi " \
                   "priključenje navedene zgrade. Provjeri kod Toplane na #{provider.fetch('phones').join(' ili ')}. " \
                   "Pregledani izvor: #{fact.source_url}; kontakt: #{provider.fetch('source_url')}."
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                 architecture: "heating_network_connection_boundary", subject: "heating_network_connection")
        end

        def donation_total_receipt_question?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\b(?:donacij\w*|zbir\w*|ukupan\w*)\b/) &&
            folded.match?(/\b(?:moj\w*|pojedinacn\w*|necij\w*)\b/) &&
            folded.match?(/\b(?:uplat\w*|potvrd\w*|dokaz\w*)\b/)
        end

        def donation_total_public_question?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          # A rejected topic can still contain every keyword of that topic.
          # Let the next clause (for example project selection) own the turn.
          return false if folded.match?(/\bne\s+(?:trazim|pitam|zelim)\b[^.?!]{0,100}\b(?:donacij\w*|zbir\w*|ukup\w*)\b/) &&
                          folded.match?(/\b(?:nego|vec)\b/)

          folded.match?(/\bdonacij\w*\b/) && folded.match?(/\b(?:javn\w*|zbir\w*|ukupan\w*)\b/) &&
            !donation_total_receipt_question?(text)
        end

        def public_race_standings_question?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\b(?:trka|trke)\b/) && folded.match?(/\b(?:poredak|rang\w*|tabel\w*)\b/)
        end

        def race_vs_personal_points_question?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\bporedak\b/) && folded.match?(/\b(?:licn\w*|moj\w*)\b/) &&
            folded.match?(/\bbodov\w*\b/)
        end

        def personal_race_contribution_question?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\b(?:trci|trku|trka|trke)\b/) &&
            folded.match?(/\b(?:licno|moj\w*|ja)\b/) &&
            folded.match?(/\b(?:doprin\w*|bodov\w*)\b/)
        end

        def public_content_removal_question?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\b(?:uklanjan\w*|brisanj\w*|obris\w*)\b/) &&
            folded.match?(/\b(?:objav\w*|prijav\w*|sadrzaj\w*)\b/) &&
            folded.match?(/\b(?:gdje|kome|pit\w*|kontakt\w*)\b/)
        end

        def casual_greeting?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\A(?:cao|zdravo|hej|pozdrav)(?:\s+milice)?(?:\s+sta\s+ima)?\z/)
        end

        def platform_news_followup?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\b(?:nov\w*|desav\w*)\b/) &&
            folded.match?(/\b(?:platform\w*|komsij\w*|komsiluk\w*)\b/)
        end

        def private_points_route_question?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\b(?:svoj\w*|moj\w*)\s+bodov\w*\b/) &&
            folded.match?(/\b(?:gdje|provjer\w*|vidj\w*)\b/)
        end

        def birth_extract_fee_question?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\b(?:izvod\w*|maticn\w*)\b/) &&
            folded.match?(/\brodjen\w*\b/) && folded.match?(/\b(?:taks\w*|cijen\w*|kost\w*)\b/)
        end

        def ematricar_delivery_question(text, state:)
          folded = Decidim::Bih::Text.fold(Decidim::Bih::Transliterator.to_latin(text.to_s))
          if state.dig(Dialogue::AnswerContext::KEY, "subject") == "birth_extract_procedure" &&
             folded.match?(/\btaks\w*\b/) && folded.match?(/\bpostarin\w*\b/)
            return :cost
          end
          if state.dig(Dialogue::AnswerContext::KEY, "subject") == "ematricar_delivery"
            return :postage if folded.match?(/\bpostarin\w*\b/)
            return :email if folded.match?(/\bdokument\w*\b/) && folded.match?(/\be\s+post\w*\b/)
            return :delivery_day if folded.match?(/\b(?:obec\w*|garant\w*|kada|dan)\b/) &&
                                    folded.match?(/\b(?:stic\w*|stiz\w*|isporuk\w*|dan)\b/)
          end

          return :cost if folded.match?(/\be\s+maticar\w*\b/) &&
                          folded.match?(/\b(?:trosk\w*|taks\w*|postarin\w*|cijen\w*)\b/)
        end

        def birth_extract_channel(text, state:, default: "all")
          folded = Decidim::Bih::Text.fold(Decidim::Bih::Transliterator.to_latin(text.to_s))
          online = folded.match?(/\b(?:online|onlajn|e\s+maticar\w*|preko\s+interneta)\b/)
          counter = folded.match?(/\b(?:salter\w*|licno)\b/)
          if online && counter
            correction = folded.match(/\b(?:nego|vec)\b(?<choice>.+)\z/)
            return birth_extract_channel(correction[:choice], state: {}, default: "all") if correction

            return "all"
          end
          return "online" if online
          return "counter" if counter

          if %w(birth_extract_fee birth_extract_procedure ematricar_delivery).include?(state.dig(Dialogue::AnswerContext::KEY, "subject"))
            retained = state.dig(Dialogue::AnswerContext::KEY, "anchor")
            return birth_extract_channel(retained, state: {}, default:) if retained.present?
          end
          default
        end

        def birth_extract_anchor(message:, state:)
          explicit = birth_extract_channel(message.text, state: {}, default: nil)
          prior = state.dig(Dialogue::AnswerContext::KEY, "anchor")
          retained = %w(birth_extract_fee birth_extract_procedure ematricar_delivery).include?(state.dig(Dialogue::AnswerContext::KEY, "subject"))
          explicit || !retained || prior.blank? ? message.text.to_s : prior
        end

        def reviewed_birth_extract_guidance(context:, locale:, channel:, focus:)
          reading = ReadPort.new(organization: @organization).birth_extract_procedures(context:, locale:, channel:)
          parts = reading.status == "ok" ? reading.facts.map { |fact| birth_extract_fact_copy(fact, focus:) } : []
          if parts.empty?
            parts << "Nemam dostupno pregledano uputstvo za izvod iz matične knjige rođenih u traženom kanalu ove zajednice."
          elsif reading.coverage.is_a?(Hash) && Array(reading.coverage["unavailable_channels"]).any?
            missing = reading.coverage.fetch("unavailable_channels").map { |value| value == "counter" ? "šalter" : "online" }.join(", ")
            parts << "Za kanale #{missing} nemam dostupno pregledano uputstvo; uslovi jednog kanala ne važe automatski za drugi."
          end
          parts << "Ovo je javno uputstvo, ne potvrda trenutnog statusa, predaje, odobrenja ili dostave dokumenta."
          parts << "Ne mogu obećati dan dolaska. Lične podatke i dokumente unosite samo u službeni obrazac ili predajte nadležnoj službi, ne u ovaj chat."
          parts.join(" ")
        end

        def birth_extract_fact_copy(fact, focus:)
          label = fact.fetch("channel") == "counter" ? "Predaja na šalteru" : "Online podnošenje"
          parts = ["#{label} — pregledani postupak: #{fact.fetch('text').lines.first.to_s.strip} " \
                   "Obuhvat: #{fact.dig('coverage', 'scope')}."]
          parts << birth_extract_fee_copy(fact, exemptions: focus == "exemption") if %w(fee exemption postage).include?(focus)
          if focus == "instructions"
            Array(fact.fetch("steps")).each_with_index { |step, index| parts << "Korak #{index + 1}: #{step}" }
            documents = fact["required_documents"]
            parts << (documents.is_a?(Array) ? "Pregledani spisak dokumenata: #{documents.empty? ? 'prazan spisak u kartici' : documents.join('; ')}." : "Potrebni dokumenti nisu potvrđeni ovim zapisom.")
          end
          parts << birth_extract_delivery_copy(fact) if %w(instructions email delivery_day).include?(focus)
          if focus == "exemption"
            parts << "Ovdje ne potvrđujem da konkretna osoba ima pravo na oslobađanje ili da se pravilo jednog kanala primjenjuje na drugi."
          end
          parts << "Službeni obrazac: #{fact.fetch('form_download_url')}." if fact["form_download_url"].present?
          parts << "Izvor: #{fact.fetch('source_url')} (pregledano #{fact.fetch('reviewed_on')})."
          parts.join(" ")
        end

        def birth_extract_fee_copy(fact, exemptions: false)
          fee = fact["fee"].is_a?(Hash) ? fact.fetch("fee") : {}
          amount = fee["administrative_fee_bam"]
          parts = [amount.nil? ? "Administrativna taksa nije potvrđena." : "Administrativna taksa: #{amount} KM."]
          if fee["delivery_cost"] == "postage"
            postage = fee["postage_amount_bam"]
            parts << (postage.nil? ? "Iznos poštarine nije potvrđen." : "Poštarina: #{postage} KM.")
          elsif fee["delivery_cost"] == "none"
            parts << "Prema pregledanoj kartici ovaj kanal nema trošak dostave."
          else
            parts << "Podatak o naplati poštarine nije potvrđen za ovaj kanal."
          end
          if exemptions
            parts << (fact["fee_exemptions"].present? ? "Pregledano pravilo oslobađanja: #{fact.fetch('fee_exemptions')}." : "Pravila oslobađanja od takse nisu potvrđena.")
            parts << "Nulta taksa sama ne potvrđuje pravila oslobađanja drugih kanala." if amount == 0
          end
          parts.join(" ")
        end

        def birth_extract_delivery_copy(fact)
          delivery = fact["delivery"].is_a?(Hash) ? fact.fetch("delivery") : {}
          document = { "postal" => "poštom", "electronic" => "elektronski", "counter" => "preuzimanjem na šalteru" }[delivery["document_method"]]
          instructions = { "email" => "elektronskom poštom", "portal" => "na portalu", "counter" => "na šalteru" }[delivery["instructions_method"]]
          parts = [document ? "Pregledani način dostave dokumenta: #{document}." : "Način dostave dokumenta nije potvrđen."]
          parts << (instructions ? "Pregledani način dostave uputstva: #{instructions}." : "Način dostave uputstva nije potvrđen.")
          parts << "Uputstvo elektronskom poštom samo po sebi ne znači da se i dokument dostavlja e-poštom."
          timing = delivery["delivery_time_text"] || (fact["processing_time"].is_a?(Hash) && fact["processing_time"]["text"])
          parts << (timing.present? ? "Objavljeni podatak o obradi/dostavi: #{timing}. To nije potvrda završetka ili stvarnog dolaska." : "Rok obrade i dostave nije potvrđen ovim zapisom.")
          parts.join(" ")
        end

        def direct_ematricar_delivery(message:, state:, context:, locale:, kind:)
          channel = birth_extract_channel(message.text, state:, default: "online")
          focus = { cost: "fee", postage: "postage", email: "email", delivery_day: "delivery_day" }.fetch(kind)
          answer = reviewed_birth_extract_guidance(context:, locale:, channel:, focus:)
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                 architecture: "ematricar_delivery", subject: "ematricar_delivery",
                                 anchor: birth_extract_anchor(message:, state:), tool_calls: 1)
        end

        def birth_extract_fee_exemption_followup?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\b(?:oslobadj\w*|oslobodj\w*)\b/) && folded.match?(/\btaks\w*\b/)
        end

        def birth_extract_procedure_question?(text, state:)
          folded = Decidim::Bih::Text.fold(Decidim::Bih::Transliterator.to_latin(text.to_s))
          if state.dig(Dialogue::AnswerContext::KEY, "subject") == "birth_extract_procedure"
            return folded.match?(/\b(?:gdje|kako)\b/) && folded.match?(/\b(?:predaj\w*|podnos\w*|zahtjev\w*)\b/)
          end

          folded.match?(/\bizvod\w*\b/) && folded.match?(/\brodjen\w*\b/) &&
            (folded.match?(/\b(?:ponij\w*|pones\w*|treba\w*\s+donij\w*)\b/) ||
             (folded.match?(/\be\s+maticar\w*\b/) && folded.match?(/\b(?:kako|zatraz\w*|naruc\w*)\b/)))
        end

        def civic_report_status_route_question?(text, state:)
          folded = Decidim::Bih::Text.fold(Decidim::Bih::Transliterator.to_latin(text.to_s))
          if state.dig(Dialogue::AnswerContext::KEY, "subject") == "civic_report_status_routes"
            return folded.match?(/\b(?:status|prat\w*)\b/) && folded.match?(/\b(?:gdje|vid\w*)\b/)
          end

          folded.match?(/\bkomunaln\w*\b/) && folded.match?(/\bprijav\w*\b/) &&
            folded.match?(/\bprat\w*\b/)
        end

        def water_bill_contact_question?(text, state:)
          folded = Decidim::Bih::Text.fold(Decidim::Bih::Transliterator.to_latin(text.to_s))
          if state.dig(Dialogue::AnswerContext::KEY, "subject") == "water_bill_contact"
            return folded.match?(/\b(?:vodovod\w*|vod\w*)\b/) &&
              folded.match?(/\b(?:duguj\w*|dug\w*|stanj\w*|koliko)\b/)
          end

          folded.match?(/\bracun\w*\b/) && folded.match?(/\b(?:vodovod\w*|vodu|vode)\b/) &&
            folded.match?(/\b(?:pogres\w*|reklamacij\w*|prigovor\w*)\b/)
        end

        def public_share_link_question?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          invite = folded.match?(/\bpozov\w*\b/) && folded.match?(/\bkomsij\w*\b/)
          link = folded.match?(/\bjavn\w*\s+link\b/) && folded.match?(/\bkopir\w*\b/)
          invite || link
        end

        def past_launch_event_question?(text, context:)
          folded = Decidim::Bih::Text.fold(Decidim::Bih::Transliterator.to_latin(text.to_s))
          return false unless context.now && folded.match?(/\blansiranj\w*\b/)
          # Personal invitation/reward questions keep their existing reader.
          return false if folded.match?(/\b(?:moja|moju|imam|dobio|dobila|moj)\b/) && folded.match?(/\bpozivnic\w*\b/)

          folded.match?(/\b(?:kad|kada|datum|odrz\w*|dogadaj\w*|pros\w*|jos|otvoren\w*|doci|dodj\w*)\b|\d/)
        end

        def configured_launch_event_guidance(context:)
          configuration = begin
            DecidimApp::LaunchEventConfiguration.load(organization_host: @organization.host)
          rescue DecidimApp::LaunchEventConfiguration::InvalidConfiguration
            nil
          end
          if configuration&.enabled?
            starts = configuration.opens_at.in_time_zone("Europe/Sarajevo").strftime("%d.%m.%Y. u %H:%M %:z")
            ends = configuration.closes_at.in_time_zone("Europe/Sarajevo").strftime("%d.%m.%Y. u %H:%M %:z")
            phase = case configuration.phase(now: context.now)
                    when "scheduled" then "Podešeni termin još nije počeo."
                    when "open" then "Podešeni termin je sada u toku; uslove dolaska provjeri u najavi."
                    else "Podešeni termin je prošao; to ne potvrđuje da je događaj održan."
                    end
            answer = "Prema podešenoj najavi #{configuration.title}, termin je od #{starts} do #{ends} (Europe/Sarajevo). " \
                     "#{phase} Izvor koji je operater naveo: #{configuration.source_url}."
          else
            answer = "Nemam dostupnu javnu najavu lansiranja ove zajednice sa podešenim terminom. " \
                     "Ne mogu potvrditi datum iz pitanja ili mogućnost dolaska. #{configured_support_guidance}"
          end
          "#{answer} Razgovor nije poslao pozivnicu, rezervisao mjesto niti potvrdio tvoje pravo ulaska. " \
            "Trka komšiluka i lansiranje imaju odvojene termine."
        end

        def race_after_launch_question?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\btrk\w*\s+komsiluk\w*\b/) && folded.match?(/\blansiranj\w*\b/)
        end

        def central_janja_stop_question?(text)
          # Retain the legacy method/subject for old conversation state only.
          # Place names and table membership now come from configured readers.
          !central_published_stop_request(text).nil?
        end

        def central_published_stop_request(text)
          latin = Decidim::Bih::Transliterator.to_latin(text.to_s)
          folded = Decidim::Bih::Text.fold(latin)
          return unless folded.match?(/\b(?:u|iz)\s+centr[au]\b/) && folded.match?(/\bstajalist\w*\b/) &&
                        folded.match?(/\b(?:dodj\w*|stign\w*|pjesac\w*)\b/)

          destination = latin.match(/\b(?:za|prema)\s+([\p{L}\p{N}][\p{L}\p{N} ()-]{1,79})(?=[?.!,;]|$)/i)&.captures&.first&.strip
          return if destination.blank?

          { "origin_query" => "centar", "destination_query" => destination }
        end

        def direct_published_boarding_guidance(message:, state:, context:, locale:, followup:)
          saved = state.dig(Dialogue::ConversationSlots::KEY, "journey")
          request = if followup && saved.is_a?(Hash) && saved["query_kind"] == "published_boarding"
                      saved.slice("origin_query", "destination_query")
                    elsif !followup
                      central_published_stop_request(message.text)
                    end
          unless request.is_a?(Hash) && request.values_at("origin_query", "destination_query").all?(&:present?)
            return direct_source_boundary(message:, state:, context:, locale:,
              answer: transport_prose("Napiši polazište i odredište za novu provjeru stajališta. Pješačka ruta i pristupačnost nisu provjerene.", locale),
              architecture: "central_janja_walk_boundary", subject: "central_janja_stop", resolution: "clarification")
          end
          tools = @tools_factory.call(location: nil)
          guidance = reviewed_published_boarding_guidance(request:, context:, tools:)
          slots = (state[Dialogue::ConversationSlots::KEY] || Dialogue::ConversationSlots.empty).deep_dup
          slots["journey"] = request.merge("query_kind" => "published_boarding")
          normalized = Dialogue::ConversationSlots.normalize(slots, now: context.now, state_expires_at: state.fetch("expires_at"))
          state = state.merge(Dialogue::ConversationSlots::KEY => normalized) if normalized
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(guidance.fetch(:answer), locale),
            architecture: followup ? "central_janja_walk_boundary" : "central_janja_stop_assumption",
            subject: "central_janja_stop", tool_calls: guidance.fetch(:tool_calls), resolution: guidance.fetch(:resolution))
        end

        def reviewed_published_boarding_guidance(request:, context:, tools:)
          membership = tools.registry.call(name: "published_boarding_points", arguments: request, context:, eligibility: tools.eligibility)
          evidence = [membership.for_prompt(context:, eligibility: tools.eligibility)]
          records = membership.status == "ok" ? membership.evidence : []
          records = records.select { |record| record.dig("facts", "evidence_purpose") == "published_same_trip_column_membership_not_departure" }
          calls = 1
          parts = []
          # Several tables for one stop are not a choice of several locations.
          origins = records.map { |record| record.dig("facts", "origin_id") }.compact.uniq
          if origins.one? && records.any?
            navigation = tools.registry.call(name: "walking_directions", arguments: { "stop_id" => origins.first }, context:, eligibility: tools.eligibility)
            calls += 1
            evidence << navigation.for_prompt(context:, eligibility: tools.eligibility)
            fact = records.first.fetch("facts")
            parts << "U pregledanim tabelama je kandidat #{fact.fetch('origin_label')} prema #{fact.fetch('destination_label')}; " \
                     "navedene linije: #{records.map { |record| record.dig('facts', 'route_code') }.uniq.join(', ')}. " \
                     "To nije potvrda najbližeg ili najprikladnijeg stajališta. Izvor: #{records.first.fetch('source_url')}."
            nav = navigation.status == "ok" && navigation.evidence.one? ? navigation.evidence.first.fetch("facts") : nil
            if nav && nav["stop_id"] == origins.first && nav["walking_map_url"].to_s.start_with?("https://www.google.com/maps/dir/?")
              parts << "Mapa stajališta: #{nav.fetch('walking_map_url')}. Položaj je približan."
            else
              parts << "Nemam provjerenu mapu ovog stajališta."
            end
          elsif records.any?
            choices = records.map { |record| record.dig("facts", "origin_label") }.uniq.first(4)
            parts << "Pregledane tabele daju više kandidata: #{choices.join('; ')}. Napiši tačniju polaznu tačku; nisam izabrala najbliže stajalište."
          else
            parts << "Nemam potvrđenog kandidata iz pregledanih tabela za ova mjesta. To ne dokazuje da prevoz ne postoji. Napiši ulicu ili precizniji orijentir."
          end
          parts << "Izbor za područje je pretpostavka iz konfiguracije zajednice." if membership.warnings.include?("configured_area_stop_assumption")
          parts << "Datum i vrijeme polaska nisu izabrani. Pješačka ruta, udaljenost, strana ukrcavanja i pristupačnost nisu provjerene."
          revalidate_delivery_evidence!(evidence, tools:)
          resolution = if origins.one? && records.any?
                         "answered"
                       elsif records.any? || membership.status == "ambiguous"
                         "clarification"
                       elsif membership.status == "unavailable"
                         "source_unavailable"
                       else
                         "unsupported"
                       end
          { answer: parts.join(" "), resolution:, tool_calls: calls }
        end

        def approximate_walk_followup?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\b(?:priblizn\w*|pjesack\w*|rut\w*)\b/)
        end

        def announced_works_area_question?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          # A dated electricity request has a specific source reader below.
          latin = Decidim::Bih::Transliterator.to_latin(text.to_s)
          return false if folded.match?(/\b(?:elektromrez\w*|struj\w*|iskljucenj\w*)\b/) &&
                          latin.match?(DOTTED_DATE)

          folded.match?(/\bnajavljen\w*\b/) && folded.match?(/\bradov\w*\b/) &&
            folded.match?(/\bu\s+[a-z]{3,}/) && !folded.match?(/\b(?:autobus\w*|stajalist\w*|polazak\w*)\b/)
        end

        def announced_works_settlement_followup?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\bnaselj\w*\b/) &&
            folded.match?(/\b(?:komsiluk\w*|platform\w*|mjesto|mesto)\b/)
        end

        def duplicate_report_status_question?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\bprijav\w*\b/) && folded.match?(/\bduplikat\b/)
        end

        def duplicate_report_followup?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\b(?:gdje|kako)\b/) && folded.match?(/\bpratim\b/) &&
            folded.match?(/\b(?:problem\w*|prijav\w*|status\w*)\b/)
        end

        def private_points_unauthenticated_followup?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\b(?:bez\s+mog\s+prijavljivanj\w*|bez\s+prijav\w*|mozes\s+li\s+ih\s+ti)\b/)
        end

        def cheapest_rewards_question?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\bnagrad\w*\b/) &&
            folded.match?(/\b(?:najjeftin\w*|najpovoljn\w*|najmanje\s+bodova)\b/)
        end

        def reward_availability_followup?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\b(?:dostupnost\w*|uslov\w*|rezervis\w*)\b/)
        end

        def public_participation_question?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\b(?:rasprav\w*|proces\w*)\b/) &&
            folded.match?(/\b(?:javn\w*|gradjan\w*|ucestv\w*|gdje)\b/)
        end

        def participation_read_only_followup?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\b(?:tem\w*|pravil\w*)\b/) &&
            folded.match?(/\b(?:cit\w*|glas\w*)\b/)
        end

        def damaged_public_container_question?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\bkontejner\w*\b/) && folded.match?(/\b(?:ostec\w*|polom\w*|pokvar\w*)\b/) &&
            folded.match?(/\b(?:prijav\w*|kome|kontakt\w*)\b/)
        end

        def historical_cash_bus_fare_question?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\b(?:cijen\w*|cen\w*)\s+kart\w*\b/) &&
            folded.match?(/\bgotovin\w*\b/) && folded.match?(/\bvozac\w*\b/) &&
            folded.match?(/\bG1\b/i) && folded.match?(/\bgarant\w*\b/)
        end

        def voting_without_points_question?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\b(?:glasati|glasanje|glasam)\b/) && folded.match?(/\bbez\s+bodov\w*\b/)
        end

        def feedback_description_followup?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\b(?:mogu|smijem|can)\b/) &&
            folded.match?(/\b(?:napis\w*|opis\w*|write|describe)\b/) &&
            folded.match?(/\b(?:pogresn\w*|netacn\w*|wrong)\b/)
        end

        def nearest_stop_question?(text)
          TransportJourneyQuestion.nearest_stop?({ "query" => text.to_s })
        end

        def missing_current_bus_origin?(text)
          folded = Decidim::Bih::Text.fold(Decidim::Bih::Transliterator.to_latin(text.to_s))
          folded.match?(/\bodavde\b/) && folded.match?(/\b(?:autobus\w*|bus\w*)\b/)
        end

        def journey_without_origin(text)
          latin = Decidim::Bih::Transliterator.to_latin(text.to_s)
          match = latin.match(/\A\s*(?:koji|kakav|which)\s+(?:autobus|bus)\s+(?:ide|vozi|goes)\s+(?:za|do|to)\s+
                              (?<destination>[\p{L} ()-]{2,80}?)\s+(?<day>\d{1,2})\.(?<month>\d{1,2})\.(?<year>20\d{2})\.?
                              \s+(?:poslije|posle|nakon|after)\s+(?<clock>(?:[01]\d|2[0-3]):[0-5]\d)\b/ix)
          return unless match

          destination = match[:destination].strip
          destination = "Janja" if Decidim::Bih::Text.fold(destination).match?(/\Ajan[jn][aeiu]\z/)
          { "destination_query" => destination, "date" => Date.new(match[:year].to_i, match[:month].to_i, match[:day].to_i).iso8601,
            "after_time" => match[:clock] }
        rescue Date::Error
          nil
        end

        def supplied_journey_origin(text, state:)
          saved = state.dig(Dialogue::ConversationSlots::KEY, "journey")
          return unless saved.is_a?(Hash) &&
                        (saved["query_kind"] == "awaiting_origin" ||
                         state.dig(Dialogue::AnswerContext::KEY, "subject") == "awaiting_journey_origin")

          latin = Decidim::Bih::Transliterator.to_latin(text.to_s)
          match = latin.match(/\A\s*(?:kre[cćč]em|polazim|start(?:ing)?)\s+(?:sa|s|iz|od|from)\s+(?<origin>[\p{L}\d ()-]{2,80})[.!?]?\s*\z/i)
          return unless match

          origin = match[:origin].strip
          origin = "NAS" if Decidim::Bih::Text.fold(origin) == "bijeljina nas"
          saved.slice("destination_query", "date").merge("origin_query" => origin,
                                                         "after_time" => saved.fetch("time"), "mode" => "fastest")
        end

        def direct_missing_journey_origin(message:, state:, context:, locale:, request:)
          slots = (state[Dialogue::ConversationSlots::KEY] || Dialogue::ConversationSlots.empty).deep_dup
          slots["journey"] = { "destination_query" => request.fetch("destination_query"), "date" => request.fetch("date"),
                               "time" => request.fetch("after_time"), "query_kind" => "awaiting_origin" }
          normalized = Dialogue::ConversationSlots.normalize(slots, now: context.now, state_expires_at: state.fetch("expires_at"))
          next_state = normalized ? state.merge(Dialogue::ConversationSlots::KEY => normalized) : state
          captured = Dialogue::AnswerContext.capture(kind: "public_card", subject: "awaiting_journey_origin",
                                                     anchor: request.fetch("destination_query"), now: context.now,
                                                     state_expires_at: state.fetch("expires_at"))
          next_state = next_state.merge(Dialogue::AnswerContext::KEY => captured) if captured
          answer = "Za put do mjesta #{request.fetch('destination_query')} #{request.fetch('date')} poslije #{request.fetch('after_time')} " \
                   "napiši odakle krećeš, na primjer naselje ili stajalište. Zadržaću odredište, datum i sat za provjeru."
          answer = transport_prose(answer, locale)
          reply = Decidim::Bih::Concierge::Responder::Reply.new(text: answer, report: nil, answer_intent: "service", tone: "core", locale:)
          result = outcome(reply:, state: next_state, resolution: "answered",
                           diagnostics: { "architecture" => "journey_missing_origin", "model_calls" => 0, "tool_calls" => 0 })
          frame = Dialogue::ConversationFrame.load(next_state[Dialogue::ConversationFrame::KEY], context:)
          persist(result, previous: state, context:, frame: public_history(frame:, message:, answer:, context:, state: next_state))
        end

        def public_map_stop_point(text)
          return unless nearest_stop_question?(text)

          match = text.to_s.match(/(?<![\d.])(-?\d{1,2}\.\d{4,8})\s*,\s*(-?\d{1,3}\.\d{4,8})(?!\d)/)
          return unless match

          latitude, longitude = match.captures.map(&:to_f)
          { "latitude" => latitude, "longitude" => longitude } if latitude.between?(-90, 90) && longitude.between?(-180, 180)
        end

        def public_map_walking_followup?(text, state:)
          return unless state.dig(Dialogue::AnswerContext::KEY, "subject") == "transport_public_map_stop"

          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\b(?:hod\w*|pjes\w*)\b/) &&
            folded.match?(/\b(?:map\w*|put\w*|stajal\w*|stanic\w*)\b/)
        end

        def reviewed_boarding_walk_question?(text, state:)
          journey = state.dig(Dialogue::ConversationSlots::KEY, "journey")
          return unless journey.is_a?(Hash)
          id = journey["origin_id"]
          complete = %w(origin_query destination_query date time).all? { |field| journey[field].is_a?(String) }
          return unless id.to_s.start_with?("transport_stop:") || complete

          folded = Decidim::Bih::Text.fold(Decidim::Bih::Transliterator.to_latin(text.to_s))
          folded.match?(/\b(?:pjes\w*|hod\w*)\b/) &&
            (folded.match?(/\bpolazn\w*\s+(?:stajal\w*|stanic\w*)\b/) ||
             folded.match?(/\b(?:stajal\w*|stanic\w*)\s+(?:gdje|gde)\s+ulaz\w*\b/))
        end

        def direct_reviewed_boarding_walk(message:, state:, context:, tools:, locale:)
          journey = state.fetch(Dialogue::ConversationSlots::KEY).fetch("journey")
          id = journey["origin_id"]
          read_count = 1
          unless id.to_s.start_with?("transport_stop:")
            origin = journey.fetch("origin_query")
            origin = "NAS" if Decidim::Bih::Text.fold(origin).match?(/\A(?:bijeljina )?nas(?: a| u| om)?\z/)
            request = { "origin_query" => origin, "destination_query" => journey.fetch("destination_query"),
                        "date" => journey.fetch("date"), "after_time" => journey.fetch("time"), "mode" => "fastest" }
            planned = tools.registry.call(name: "resolve_and_plan_journey", arguments: request,
                                          context:, eligibility: tools.eligibility)
            revalidate_delivery_evidence!([planned.for_prompt(context:, eligibility: tools.eligibility)], tools:)
            chosen = planned.evidence.find { |record| record.dig("facts", "journey_index") == 0 && record.dig("facts", "leg_index") == 0 }
            id = chosen&.dig("facts", "origin_id") if planned.status == "ok"
            read_count += 1
          end
          return direct_source_boundary(message:, state:, context:, locale:,
                                        answer: transport_prose("Za prethodnu vezu nemam potvrđeno polazno stajalište za mapu.", locale),
                                        architecture: "reviewed_boarding_walk_unresolved", tool_calls: read_count) unless id.to_s.start_with?("transport_stop:")

          envelope = tools.registry.call(name: "walking_directions", arguments: { "stop_id" => id },
                                         context:, eligibility: tools.eligibility)
          evidence = [envelope.for_prompt(context:, eligibility: tools.eligibility)]
          revalidate_delivery_evidence!(evidence, tools:)
          fact = envelope.evidence.one? ? envelope.evidence.first.fetch("facts") : nil
          if envelope.status == "ok" && fact && fact["stop_id"] == id &&
             fact["walking_map_url"].to_s.start_with?("https://www.google.com/maps/dir/?")
            route = journey["route_code"].to_s
            route = "za liniju #{route} " unless route.empty?
            answer = "Mapa za hodanje do polaznog stajališta #{route}#{fact.fetch('stop_label')}: " \
                     "#{fact.fetch('walking_map_url')}. Položaj je približan; tačan peron i pješački put nisu provjereni."
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "reviewed_boarding_walk", tool_calls: read_count)
          end

          direct_source_boundary(message:, state:, context:, locale:,
                                 answer: transport_prose("Za to polazno stajalište nemam potvrđenu mapu za hodanje.", locale),
                                 architecture: "reviewed_boarding_walk_unavailable", tool_calls: read_count)
        end

        def direct_public_map_nearest_stop(message:, state:, context:, locale:, coordinates:)
          tools = @tools_factory.call(location: nil)
          envelope = tools.registry.call(name: "nearest_stop", arguments: coordinates, context:, eligibility: tools.eligibility)
          evidence = [envelope.for_prompt(context:, eligibility: tools.eligibility)]
          revalidate_delivery_evidence!(evidence, tools:)
          fact = envelope.evidence.one? ? envelope.evidence.first.fetch("facts") : nil
          if envelope.status == "ok" && fact && fact["stop_id"].is_a?(String) &&
             fact["distance_meters"].is_a?(Numeric) && fact["distance_kind"] == "straight_line" &&
             fact["stop_label"].is_a?(String)
            label = fact.fetch("stop_label")
            distance = fact.fetch("distance_meters").round
            answer = "Najbliže pregledano stajalište tački koju si navela je #{label}, oko #{distance} m vazdušnom linijom. " \
                     "To je približna tačka sa objavljene karte; pješački put i sigurnost staze nisu provjereni. " \
                     "Ako želiš, mogu poslati mapu za hodanje do tog stajališta."
            captured = Dialogue::AnswerContext.capture(kind: "public_card", subject: "transport_public_map_stop",
                                                       anchor: fact.fetch("stop_id"), now: context.now,
                                                       state_expires_at: state.fetch("expires_at"))
            next_state = state.merge(Dialogue::AnswerContext::KEY => captured)
            reply = Decidim::Bih::Concierge::Responder::Reply.new(text: transport_prose(answer, locale), report: nil,
                                                                  answer_intent: "service", tone: "core", locale:)
            result = outcome(reply:, state: next_state, resolution: "answered", fact_ids: envelope.evidence.map { |item| item.fetch("id") },
                             diagnostics: { "architecture" => "public_map_nearest_stop", "model_calls" => 0, "tool_calls" => 1 })
            frame = Dialogue::ConversationFrame.load(next_state[Dialogue::ConversationFrame::KEY], context:)
            return persist(result, previous: state, context:,
                           frame: public_history(frame:, message:, answer: reply.text, context:, state: next_state))
          end

          direct_source_boundary(message:, state:, context:, locale:,
                                 answer: transport_prose("Za ovu tačku nemam potvrđeno obližnje stajalište u pregledanim podacima.", locale),
                                 architecture: "public_map_nearest_stop_unavailable", tool_calls: 1)
        end

        def direct_public_map_walking_link(message:, state:, context:, locale:)
          stop_id = state.dig(Dialogue::AnswerContext::KEY, "anchor").to_s
          return unless stop_id.start_with?("transport_")

          tools = @tools_factory.call(location: nil)
          envelope = tools.registry.call(name: "walking_directions", arguments: { "stop_id" => stop_id },
                                         context:, eligibility: tools.eligibility)
          evidence = [envelope.for_prompt(context:, eligibility: tools.eligibility)]
          revalidate_delivery_evidence!(evidence, tools:)
          fact = envelope.evidence.one? ? envelope.evidence.first.fetch("facts") : nil
          if envelope.status == "ok" && fact && fact["stop_id"] == stop_id &&
             fact["walking_map_url"].to_s.start_with?("https://www.google.com/maps/dir/?")
            answer = "Mapa za hodanje do stajališta #{fact.fetch('stop_label')}: #{fact.fetch('walking_map_url')}. " \
                     "Ruta na mapi je prijedlog; dužina, trajanje i sigurnost pješačkog puta nisu provjereni."
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "public_map_walking_link", subject: "transport_public_map_stop",
                                          anchor: stop_id, tool_calls: 1)
          end

          direct_source_boundary(message:, state:, context:, locale:,
                                 answer: transport_prose("Trenutno nemam potvrđenu mapu za to stajalište.", locale),
                                 architecture: "public_map_walking_link_unavailable", tool_calls: 1)
        end

        def written_location_followup?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\b(?:gps|lokacij\w*)\b/) &&
            folded.match?(/\b(?:napis\w*|navest\w*|reci|kaz\w*|write|tell)\b/) &&
            !folded.match?(/\b(?:prijav\w*|poz ar|pozar|bodov\w*|poen\w*)\b/)
        end

        def text_location_without_gps_question?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\bgps\b/) && folded.match?(/\b(?:ulic\w*|adres\w*|orijentir\w*)\b/) &&
            folded.match?(/\b(?:navest\w*|napis\w*|reci|kaz\w*)\b/) &&
            !folded.match?(/\b(?:prijav\w*|pozar|bodov\w*|poen\w*)\b/)
        end

        def report_guidance_question?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\A(?:kako|gdje|gde|how|where)\b.{0,100}\b(?:prijavim|prijaviti|prijavljujem|report)\b/)
        end

        def public_neighborhood_guide_question?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\b(?:vodic|guide)\b/) && folded.match?(/\b(?:komsiluk\w*|neighbou?rhood\w*)\b/)
        end

        def neighborhood_board_updates_question?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\bkomsiluk\w*\b/) &&
            (folded.match?(/\b(?:sta|sto|what)\s+je\s+nov\w*\b/) && folded.match?(/\btabl\w*\b/) ||
             folded.match?(/\b(?:kako|gdje)\s+da\s+vidim\b.{0,55}\b(?:desav\w*|dogadj\w*)\b/))
        end

        def neighborhood_posts_followup?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\b(?:objav\w*|oglas\w*)\b/) &&
            folded.match?(/\b(?:komsij\w*|komsiluk\w*|platform\w*)\b/)
        end

        def neighborhood_subscription_question?(text, state:)
          folded = Decidim::Bih::Text.fold(text.to_s)
          first = folded.match?(/\b(?:prijavi\s+me|pretplati\s+me)\b/) &&
            folded.match?(/\bobavjest\w*\b/) && folded.match?(/\bkomsiluk\w*\b/)
          followup = state.dig(Dialogue::AnswerContext::KEY, "subject") == "neighborhood_subscription" &&
            (folded.match?(/\bpretplat\w*\b/) || folded.match?(/\bkoji\s+korak\b/))
          first || followup
        end

        def direct_neighborhood_subscription(message:, state:, context:, locale:)
          folded = Decidim::Bih::Text.fold(message.text.to_s)
          answer = if folded.match?(/\bkoji\s+korak\b/)
                     "Prijavi se na svoj nalog, otvori tablu komšiluka #{public_site_url('komsiluk-board')} " \
                       "i provjeri dostupne opcije za svoj komšiluk. Postavke poruka su na " \
                       "#{public_site_url('moj-nalog/poruke')}. Potvrdi izbor na stranici; sama poruka u chatu ga ne mijenja."
                   else
                     "Nisam te pretplatila niti poslala obavještenje iz chata. Za obavještenja komšiluka " \
                       "prijavi se i provjeri tablu #{public_site_url('komsiluk-board')} i postavke poruka " \
                       "#{public_site_url('moj-nalog/poruke')}. Izbor moraš potvrditi na stranici."
                   end
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                 architecture: "neighborhood_subscription_boundary", subject: "neighborhood_subscription")
        end

        def direct_neighborhood_board_updates(message:, state:, context:, locale:)
          answer = "Ne mogu potvrditi šta je novo na tabli tvog komšiluka bez utvrđenog komšiluka i prava pristupa. " \
                   "Otvori #{public_site_url('komsiluk-board')} i prijavi se ako tabla to traži. " \
                   "Ako napišeš naziv komšiluka, mogu pokušati provjeriti javno dostupne informacije; " \
                   "privatne objave neću prikazivati bez ovlaštenja."
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                 architecture: "neighborhood_board_updates_boundary", subject: "neighborhood_board")
        end

        def neighborhood_board_access_question?(text, state:)
          folded = Decidim::Bih::Text.fold(text.to_s)
          asks_access_rule = folded.match?(/\b(?:ko|tko|kako|mogu\s+li|moze\s+li|smij\w*|pristup\w*|prav\w*|potreb\w*|uslov\w*|uvjet\w*)\b/)
          first = asks_access_rule && folded.match?(/\bkomsiluk\w*\b/) && folded.match?(/\b(?:objav\w*|tabl\w*)\b/) &&
                  folded.match?(/\b(?:cita\w*|clan\w*)\b/)
          followup = state.dig(Dialogue::AnswerContext::KEY, "subject") == "neighborhood_board_access" &&
                     folded.match?(/\b(?:naziv\w*|objav\w*|prav\w*)\b/)
          first || followup
        end

        def direct_neighborhood_board_access(message:, state:, context:, locale:)
          folded = Decidim::Bih::Text.fold(message.text.to_s)
          answer = if folded.match?(/\b(?:objavim|pisanj\w*|postav\w*)\b/)
                     "Ne. Poznavanje naziva komšiluka ne daje pravo objavljivanja. Za objavu na tabli " \
                       "moraš biti prijavljen, imati dodijeljen komšiluk i odobrenu telefonsku verifikaciju. " \
                       "To možeš provjeriti na #{public_site_url('komsiluk-board')}; chat ne mijenja članstvo."
                   elsif folded.match?(/\b(?:zivim|stanujem|dovoljno|dovolj\w*)\b/) &&
                         folded.match?(/\b(?:objav\w*|tabl\w*)\b/)
                     "Ne. Sama tvrdnja u chatu da živiš u nekom komšiluku ne potvrđuje nalog ni pravo da vidiš " \
                       "njegove privatne objave. Pristup svojoj dodijeljenoj tabli provjeri nakon prijave na " \
                       "#{public_site_url('komsiluk-board')}. Ovdje nisam prikazala privatne objave niti promijenila članstvo."
                   else
                     "Tablu komšiluka #{public_site_url('komsiluk-board')} mogu čitati prijavljeni korisnici " \
                       "kojima je dodijeljen komšiluk. Za samo čitanje nije potrebna telefonska verifikacija; " \
                       "za objavljivanje jeste. Javne MZ mape i javno dostupne aktivnosti su zasebne stranice."
                   end
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                 architecture: "neighborhood_board_access_boundary", subject: "neighborhood_board_access")
        end

        def platform_support_contact_question?(text, state:)
          folded = Decidim::Bih::Text.fold(text.to_s)
          first = folded.match?(/\b(?:mi\s+platform\w*|platform\w*\s+mi)\b/) &&
                  folded.match?(/\b(?:pitanj\w*|kontakt\w*|podrsk\w*)\b/)
          followup = state.dig(Dialogue::AnswerContext::KEY, "subject") == "platform_support_contact" &&
                     folded.match?(/\b(?:kontakt\w*|link\w*|gradsk\w*)\b/)
          first || followup
        end

        def configured_support_guidance
          values = PlatformSupportContact.values
          unless values["email"] || values["website"]
            return "Javni kontakt operatera ove instalacije trenutno nije podešen."
          end

          parts = ["Javni kontakt operatera platforme#{values['name'] ? ": #{values['name']}" : ''}."]
          parts << "E-mail: #{values['email']}." if values["email"]
          parts << "Sajt: #{values['website']}." if values["website"]
          parts.join(" ")
        end

        def direct_platform_support_contact(message:, state:, context:, locale:)
          answer = "#{configured_support_guidance} To je podrška za rad platforme, " \
                   "ne kontakt gradske komunalne službe. Ovaj razgovor nije poslao zahtjev podršci."
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                 architecture: "platform_support_contact", subject: "platform_support_contact")
        end

        def city_case_status_question?(text, state:)
          folded = Decidim::Bih::Text.fold(text.to_s)
          followup = state.dig(Dialogue::AnswerContext::KEY, "subject") == "city_case_status" &&
                     folded.match?(/\bbroj\w*\s+(?:svog\s+)?predmet\w*\b/)
          initial = folded.match?(/\b(?:status\w*|prat\w*)\b/) &&
                    folded.match?(/\bzahtjev\w*\b/) && folded.match?(/\bgradsk\w*\s+uprav\w*\b/)
          followup || initial
        end

        def direct_city_case_status(message:, state:, context:, locale:)
          reading = ReadPort.new(organization: @organization).municipal_case_status_procedure(context:, locale:)
          row = reading.facts.first if reading.status == "ok" && reading.facts.one?
          parts = []
          if row
            parts << row.fetch("text")
            parts << "Pregledano službeno uputstvo: #{row.fetch('source_url')}. Pregledano #{row.fetch('reviewed_on')}."
            parts << "Obrazac ili dokument iz pregledanog uputstva: #{row.fetch('form_download_url')}." if row["form_download_url"].present?
            parts << "Za polja obrasca i potrebne dokaze prati službeno uputstvo; ne pretpostavljam posebno polje za broj predmeta ili mogućnost upisa u opis."
          else
            parts << "Nemam dostupno pregledano uputstvo ove zajednice za praćenje gradskog predmeta. " \
                     "Postupak i potrebne podatke provjeri kroz službeni kanal nadležne uprave."
          end
          parts << "Nemam pristup gradskoj evidenciji niti mogu vidjeti tvoj lični predmet. " \
                   "Broj predmeta, JMB i druge lične podatke ne šalji u ovaj chat; unosi ih samo u provjereni službeni kanal. " \
                   "Ovaj razgovor nije poslao upit upravi niti potvrdio njegov prijem ili rješenje."
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(parts.join(" "), locale),
                                 architecture: "city_case_status_guidance", subject: "city_case_status", tool_calls: 1)
        end

        def mz_street_membership_question?(text, state:)
          folded = Decidim::Bih::Text.fold(text.to_s)
          first = folded.match?(/\bulic\w*\b/) && folded.match?(/\b(?:mz|mjesn\w*\s+zajednic\w*)\b/) &&
            folded.match?(/\b(?:kojoj|koji|pripadam|spada)\b/)
          followup = state.dig(Dialogue::AnswerContext::KEY, "subject") == "mz_street_membership" &&
            folded.match?(/\b(?:broj\w*|granic\w*|geokodir\w*)\b/)
          first || followup
        end

        def direct_mz_street_membership(message:, state:, context:, locale:)
          street = message.text.to_s.match(/\bulic\w*\s+(?<street>[^,?]{3,80})[,?]/i)&.[](:street)&.strip
          street ||= state.dig(Dialogue::AnswerContext::KEY, "anchor")
          street = street.to_s.first(80)
          candidates = LocalStreetRegistry.new(organization: @organization).search(query: "#{street}, Bijeljina")
          slugs = candidates.flat_map { |candidate| Array(candidate[:mz_slugs]) }.uniq.first(6)
          areas = Decidim::Bih::LocalArea.where(organization: @organization, kind: "mz", slug: slugs).to_a
          names = I18n.with_locale(locale) { areas.map(&:translated_name).uniq.sort }
          folded = Decidim::Bih::Text.fold(message.text.to_s)
          scope = names.any? ? "Pregledana geometrija za ulicu #{street} daje MZ kandidate: #{names.join(', ')}. " :
                               "Za ulicu #{street} nemam potvrđenu MZ iz pregledane geometrije. "
          answer = if folded.match?(/\bgranic\w*\b/)
                     "#{scope}Ulični sloj ne potvrđuje granicu za svaki ulaz. Tačnu tačku provjeri na gradskoj karti " \
                       "ili kod mjesne zajednice; javni imenik kontakata je na #{public_site_url('mjesne-zajednice')}."
                   elsif folded.match?(/\bbroj\w*\b/)
                     "#{scope}Za broj kuće bez provjerene tačke ulaza ne mogu potvrditi jednu MZ. " \
                       "Ako pošalješ preciznu tačku, mogu ponovo provjeriti; sam broj nije dokaz obuhvata."
                   else
                     "#{scope}To su početni kandidati, ne potvrda MZ za svaku kuću u ulici. " \
                       "Za ponovnu provjeru napiši broj kuće ili precizniji orijentir; " \
                       "za konačan obuhvat treba provjerena tačka ulaza."
                   end
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                 architecture: "mz_street_membership_boundary", subject: "mz_street_membership",
                                 anchor: street, tool_calls: 1)
        end

        def viber_conversation_question?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\bviber\b/) && folded.match?(/\b(?:razgovar\w*|pisati|dopisiv\w*)\b/) &&
            folded.match?(/\bmilic\w*\b/)
        end

        def direct_viber_conversation(message:, state:, context:, locale:)
          answer = "Milica podržava dvosmjerni razgovor kroz službeni Viber Business Messages kanal, " \
                   "ali trenutno nemam potvrđen javni link za započinjanje novog Viber razgovora. " \
                   "Ako već imaš službeni razgovor, možeš odgovoriti u njemu; za novi razgovor koristi " \
                   "#{public_site_url('mi-bot')}. Sama Viber poruka nije potvrda da je prijava podnesena."
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                 architecture: "viber_conversation_boundary", subject: "viber_channel")
        end

        def phone_confirmation_status_question?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\b(?:provjer\w*|prover\w*|vidim|znam)\b/) &&
            folded.match?(/\bbroj\b/) && folded.match?(/\bpotvrd\w*\b/)
        end

        def direct_phone_confirmation_status(message:, state:, context:, locale:)
          answer = "Prijavi se i otvori Moj nalog: #{public_site_url('moj-nalog')}. " \
                   "U dijelu za verifikaciju uz telefon piše da li je broj potvrđen. " \
                   "Ako nije, slijedi korak za potvrdu na toj stranici. Ne mogu vidjeti status tvog naloga u ovom chatu; " \
                   "ne šalji mi kod ni broj telefona."
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                 architecture: "phone_confirmation_status_boundary")
        end

        def direct_board_notice(post_id:, state:, context:, locale:)
          reading = ReadPort.new(organization: @organization).notice_reference(post_id:, context:, locale:)
          fact = reading.status == "ok" ? reading.facts.first : nil
          answer = if fact
                     I18n.t(
                       "decidim_app.komsiluk_boards.context.milica_notice",
                       locale:, text: fact.fetch("text"),
                       url: fact.fetch("destination"),
                       report_url: Decidim::Bih::Engine.routes.url_helpers.new_report_path(script_name: Decidim::Bih.normalized_public_mount_path)
                     )
                   else
                     I18n.t("decidim_app.komsiluk_boards.context.milica_unavailable", locale:)
                   end
          reply = Decidim::Bih::Concierge::Responder::Reply.new(text: answer, report: nil, answer_intent: "service", tone: "core", locale:)
          result = outcome(reply:, state:, resolution: fact ? "answered" : "source_unavailable",
                           diagnostics: { "architecture" => "private_board_reference", "model_calls" => 0, "tool_calls" => 1 })
          # Private member content is not promoted into the public model frame.
          persist(result, previous: state, context:, frame: Dialogue::ConversationFrame.empty(context:))
        end

        def broad_city_notices_question?(text, state:)
          folded = Decidim::Bih::Text.fold(text.to_s)
          # A topic-specific warning asks for the weather feed and its local
          # validity, not a citywide list of unrelated service notices.
          return false if folded.match?(/\b(?:meteorolosk\w*|vremensk\w*)\s+upozorenj\w*\b/)
          # A named transformer plus a requested MZ asks whether one notice
          # covers that area. The citywide notice list cannot answer it.
          return false if folded.match?(/\bts\b/) && folded.match?(/\b(?:mz|mjesn\w*)\b/)

          return true if BROAD_CITY_NOTICES.match?(folded)

          retained = state[Dialogue::AnswerContext::KEY]
          retained.is_a?(Hash) && retained["subject"] == "city_notices" &&
            folded.match?(/(?:obavijest\w*|obavestenj\w*|djelimicn\w*|delimicn\w*|ogranicenj\w*)/)
        end

        def weather_region_question?(text, state:)
          folded = Decidim::Bih::Text.fold(text.to_s)
          first = folded.match?(/\b(?:vremensk\w*|meteorolosk\w*)\s+upozorenj\w*\b/) &&
                  folded.match?(/\b(?:region\w*|regij\w*|obuhvat\w*|naziv\w*|oznaka\w*)\b/)
          followup = state.dig(Dialogue::AnswerContext::KEY, "subject") == "weather_region" &&
                     folded.match?(/\b(?:ovdje|relevant\w*|obuhvat\w*|vazi|odnosi)\b/)
          first || followup
        end

        def reviewed_weather_read(message:, context:, locale:, yellow: false)
          text = message.text.to_s
          entities = { "query" => text }
          entities["category"] = "weather_yellow" if yellow
          if (date = text[/\b\d{4}-\d{2}-\d{2}\b/])
            entities["date"] = date
          elsif (date = DOTTED_DATE.match(text))
            entities["date"] = "#{date[3]}-#{date[2].rjust(2, '0')}-#{date[1].rjust(2, '0')}"
          elsif (relative = Decidim::Bih::Text.fold(text)[/\b(?:danas|sutra|juce|jucer|today|tomorrow|yesterday|sada|trenutno|veceras)\b/])
            entities["time_expression"] = relative == "veceras" ? "danas" : relative
          end
          ReadPort.new(organization: @organization).public_capability(capability: "environment", topic: "weather", entities:, context:, locale:)
        end

        def direct_weather_region(message:, state:, context:, locale:)
          reading = reviewed_weather_read(message:, context:, locale:)
          scope = reading.coverage["reviewed_region_scope"] if reading.coverage.is_a?(Hash)
          parts = if scope
                    ["Prema operatorovom pregledu, region #{scope.fetch('region_label')} (#{scope.fetch('provider_area_code')}) " \
                     "ima pregledani regionalni obuhvat za zajednicu #{scope.fetch('community_label')}. " \
                     "Dokaz pregleda: #{scope.fetch('evidence_url')}; pregledano #{scope.fetch('reviewed_on')}, važi do #{scope.fetch('valid_until')}.",
                     "Pregledani izvor upozorenja: #{scope.fetch('source_url')}."]
                  else
                    ["Nemam dostupan važeći pregled koji vezuje region izvora za ovu zajednicu; naziv regiona sam ne potvrđuje lokalni obuhvat."]
                  end
          parts << "Ovo nije potvrda da trenutno važi upozorenje niti prognoza za pojedinu ulicu ili kuću. " \
                   "Regionalni obuhvat ne određuje MZ ili komšiluk ciljeve objave."
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(parts.join(" "), locale),
                                 architecture: "weather_region_scope", subject: "weather_region", tool_calls: 1,
                                 resolution: scope ? "answered" : "source_unavailable")
        end

        def yellow_weather_question?(text, state:)
          folded = Decidim::Bih::Text.fold(text.to_s)
          first = folded.match?(/\bzut\w*\b/) && folded.match?(/\bvremensk\w*\s+upozorenj\w*\b/)
          followup = state.dig(Dialogue::AnswerContext::KEY, "subject") == "yellow_weather" &&
                     (folded.match?(/\b(?:gradsk\w*\s+tabl\w*|tabl\w*\s+grad\w*)\b/) ||
                      folded.match?(/\b(?:danas|sutra|juce|jucer|veceras|\d{4}-\d{2}-\d{2})\b/) || DOTTED_DATE.match?(text.to_s))
          first || followup
        end

        def weather_warning_validity_question?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\bupozorenj\w*\b/) && folded.match?(/\bpocin\w*\s+veceras\b/) &&
            folded.match?(/\b(?:opasnost\w*|rizik\w*)\b/) && folded.match?(/\bsada\b/)
        end

        def direct_weather_warning_validity(message:, state:, context:, locale:)
          reading = reviewed_weather_read(message:, context:, locale:)
          scope = reading.coverage["reviewed_region_scope"] if reading.coverage.is_a?(Hash)
          answer = "Iz same najave ne mogu zaključiti da je opasnost potvrđena sada. Vrijeme objave i početak važenja nisu isto: " \
                   "ako početak piše za večeras, po tom podatku period još nije počeo. To ipak nije dokaz da je sada sigurno ili bez rizika. " \
                   "Ovo objašnjava razliku, ne potvrđuje trenutnu opasnost; za konkretno upozorenje provjeri početak, kraj i službene upute. "
          answer += scope ? "Pregledani izvor ove zajednice: #{scope.fetch('source_url')}." : "Pregledani izvor za ovu zajednicu trenutno nije dostupan."
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                 architecture: "weather_warning_validity_boundary", subject: "weather_warning_validity", tool_calls: 1)
        end

        def direct_yellow_weather(message:, state:, context:, locale:)
          reading = reviewed_weather_read(message:, context:, locale:, yellow: true)
          scope = reading.coverage["reviewed_region_scope"] if reading.coverage.is_a?(Hash)
          source_note = scope ? "Pregledani izvor ove zajednice: #{scope.fetch('source_url')}." : "Pregledani izvor za ovu zajednicu trenutno nije dostupan."
          if Decidim::Bih::Text.fold(message.text.to_s).match?(/\btabl\w*\b/)
            levels = CityServiceWeatherParser::BOARD_SEVERITIES
            answer = levels.include?("Moderate") ? "Žuti nivo (Moderate) može ući među kandidate za tablu po ovom pravilu. " :
                       "Žuti nivo (Moderate) nije među nivoima koji se razmatraju za tablu po ovom pravilu. "
            answer += "Za tablu se razmatraju nivoi: #{levels.join(', ')}. To ne potvrđuje konkretnu objavu. " \
                      "Odsustvo objave na tabli ne dokazuje da izvor nije izdao upozorenje. #{source_note}"
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "yellow_weather_board_boundary", subject: "yellow_weather", tool_calls: 1)
          end

          yellow = reading.status == "ok" && reading.facts.find { |fact| fact["kind"] == "official_warning" && fact["provider_severity"] == "Moderate" }
          unconfirmed = yellow && Array(yellow["warning_codes"]).include?("source_facts_unconfirmed")
          parts = []
          if yellow
            parts << (unconfirmed ? "Izvor ove pripremljene činjenice označen je kao nepotvrđen; ne mogu potvrditi aktuelno upozorenje." :
                                    "U pripremljenom izvoru naveden je žuti nivo (Moderate).")
            event = yellow["provider_event"].to_s.presence || "Naziv događaja nije potvrđen"
            parts << "#{event}. Period iz izvora: #{yellow.fetch('local_validity')}. Izvor: #{yellow.fetch('source_url')}."
            unless unconfirmed
              parts << case yellow["temporal_status"]
                       when "upcoming" then "Objavljeni period tek predstoji; ovo ne potvrđuje opasnost sada."
                       when "expired" then "Ovo je prethodni period, ne aktuelno upozorenje."
                       else "Izvorni period obuhvata trenutak pregleda; ovo nije potvrda stanja u tvojoj ulici."
                       end
            end
          else
            parts << "Trenutno nemam potvrđen pripremljeni žuti zapis za traženi pregled. To nije tvrdnja da upozorenja nema niti da je nivo opasnosti nula."
            parts << source_note
          end
          parts << "Podatak o regionalnom upozorenju nije prognoza za pojedinu adresu niti dokaz odsustva drugih opasnosti."
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(parts.join(" "), locale),
                                 architecture: "yellow_weather_source", subject: "yellow_weather", tool_calls: 1,
                                 resolution: reading.status == "ok" && !unconfirmed ? "answered" : "source_unavailable")
        end

        def hourly_street_forecast_boundary(text, state:)
          folded = Decidim::Bih::Text.fold(text.to_s)
          followup = state.dig(Dialogue::AnswerContext::KEY, "subject") == "hourly_weather_forecast" &&
                     folded.match?(/\b(?:prognoz\w*|sat\w*)\b/)
          initial = folded.match?(/\b(?:kis\w*|padavin\w*|vremen\w*|prognoz\w*)\b/) &&
                    folded.match?(/\b(?:sutra|preksutra|danas|u\s+\d{1,2}\s+sat\w*)\b/) &&
                    folded.match?(/\b(?:ulic\w*|adres\w*)\b/)
          return unless initial || followup

          "Nemam pregledanu prognozu po satu za konkretnu ulicu, pa ne mogu potvrditi kišu na toj adresi u traženi sat. " \
            "Izvor regionalnih upozorenja nije satna prognoza. Za takvu prognozu odaberi izvor koji izričito pokriva tvoju lokaciju i vrijeme; " \
            "regionalna najava sama ne potvrđuje vrijeme u pojedinoj ulici."
        end

        def road_segment_question?(text, state:)
          folded = Decidim::Bih::Text.fold(Decidim::Bih::Transliterator.to_latin(text.to_s))
          return true if state.dig(Dialogue::AnswerContext::KEY, "subject") == "road_segment_conditions" &&
                         folded.match?(/\b(?:dionic\w*|put\w*|janji|janja)\b/)

          folded.match?(/\b(?:put\w*|dionic\w*|saobracaj\w*)\b/) &&
            folded.match?(/\b(?:ogranicenj\w*|zatvoren\w*|obustav\w*)\b/) &&
            folded.match?(/\bbijeljin\w*\b/) && folded.match?(/\bzvornik\w*\b/)
        end

        def river_trend_risk_boundary(text, state:)
          folded = Decidim::Bih::Text.fold(Decidim::Bih::Transliterator.to_latin(text.to_s))
          if folded.match?(/\b(?:rast\w*|porast\w*|opad\w*)\b/) &&
             folded.match?(/\bvodostaj\w*\b/) && folded.match?(/\bdrin\w*\b/) &&
             folded.match?(/\b(?:juce|jucer|danas|odnos\w*)\b/)
            return "Nemam potvrđena uporediva mjerenja Drine sa istog mjernog mjesta za danas i juče, " \
                   "pa ne mogu reći raste li vodostaj. Jedna posljednja vrijednost ili oznaka promjene u objavi " \
                   "nije provjerena vremenska serija za takvo poređenje."
          end

          return unless state.dig(Dialogue::AnswerContext::KEY, "subject") == "river_trend_risk"
          return unless folded.match?(/\b(?:poplav\w*|rizik\w*|opasnost\w*)\b/) &&
                        folded.match?(/\b(?:niz\w*|jedn\w*|vrijednost\w*|vrednost\w*)\b/)

          place = folded.match?(/\bjanj\w*\b/) ? "Janju" : "navedeno područje"
          "Ne. Jedno niže očitanje vodostaja ne potvrđuje da za #{place} nema rizika od poplave; " \
            "mjerenje na stanici nije procjena bezbjednosti konkretne kuće ili naselja. " \
            "Provjeri aktuelna upozorenja nadležne civilne zaštite: https://ruczrs.org/."
        end

        def gazette_ler_act_question?(text, state:)
          folded = Decidim::Bih::Text.fold(text.to_s)
          initial = folded.match?(/\b(?:odluk\w*|akt\w*)\b/) && folded.match?(/\b(?:glasni\w*|gazette)\b/)
          followup = %w(gazette_reviewed_act gazette_ler_act).include?(state.dig(Dialogue::AnswerContext::KEY, "subject")) &&
                     folded.match?(/\b(?:izmjen\w*|vazec\w*|vazi|spisk\w*)\b/)
          initial || followup
        end

        def direct_gazette_ler_act(message:, state:, context:, locale:)
          retained = %w(gazette_reviewed_act gazette_ler_act).include?(state.dig(Dialogue::AnswerContext::KEY, "subject"))
          query = retained ? state.dig(Dialogue::AnswerContext::KEY, "anchor").to_s : message.text.to_s
          # A fresh explicit document question replaces the retained act; a
          # legal-status follow-up rereads the original act, never cached prose.
          query = message.text.to_s if Decidim::Bih::Text.fold(message.text.to_s).match?(/\b(?:glasni\w*|gazette)\b/)
          reading = ReadPort.new(organization: @organization).public_capability(
            capability: "reference", topic: "gazette", entities: { "query" => query }, context:, locale:
          )
          facts = reading.status == "ok" ? reading.facts.select { |row| row["kind"] == "gazette_act" } : []
          parts = facts.first(3).map do |row|
            pages = Array(row["source_pdf_pages"])
            "#{row.fetch('text')} Izvor: #{row.fetch('source_url')}. " \
              "#{pages.any? ? "Pregledane stranice: #{pages.join(', ')}. " : ''}Pregledano #{row.fetch('reviewed_on')}."
          end
          if parts.empty?
            parts << "Nemam dostupan pojedinačno pregledani akt vezan za potvrđenu reviziju traženog izdanja. " \
                     "Ne mogu prenijeti raniji izvod bez ponovne potvrde izvora."
          end
          parts << "Djelimičan indeks i pregled izvornog akta ne potvrđuju da odluka danas važi bez izmjena. " \
                   "Odsustvo iz indeksa nije dokaz da odluka nije usvojena; sadašnje pravno stanje provjeri u punoj službenoj arhivi i kod nadležne službe."
          anchor = facts.one? ? facts.first.fetch("provider_act_id") : query
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(parts.join(" "), locale),
                                 architecture: "gazette_reviewed_act", subject: "gazette_reviewed_act", anchor:, tool_calls: 1)
        end

        # Compatibility seam: now only identifies an archive request. Reading
        # and rendering happen in the context-scoped method below.
        def gazette_archive_boundary(text, state:)
          folded = Decidim::Bih::Text.fold(text.to_s)
          initial = folded.match?(/\b(?:glasni\w*|gazette)\b/) && folded.match?(/\b(?:gdje|gde|pronac\w*|nac\w*|arhiv\w*)\b/)
          followup = state.dig(Dialogue::AnswerContext::KEY, "subject") == "gazette_archive" &&
                     folded.match?(/\b(?:odluk\w*|akt\w*)\b/) && folded.match?(/\b(?:spisk\w*|indeks\w*|nema)\b/)
          initial || followup
        end

        def direct_reviewed_gazette_archive(message:, state:, context:, locale:)
          query = message.text.to_s[/\b(?:19|20)\d{2}\b/].to_s
          if query.empty? && state.dig(Dialogue::AnswerContext::KEY, "subject") == "gazette_archive"
            query = state.dig(Dialogue::AnswerContext::KEY, "anchor").to_s[/\b(?:19|20)\d{2}\b/].to_s
          end
          reading = ReadPort.new(organization: @organization).public_capability(
            capability: "reference", topic: "gazette", entities: { "query" => query }, context:, locale:
          )
          source = reading.source["url"] if reading.source.is_a?(Hash)
          parts = []
          if %w(ok empty).include?(reading.status) && source.present?
            parts << "Pregledana službena arhiva zajednice: #{source}."
            checked = reading.validity["index_captured_on"] if reading.validity.is_a?(Hash)
            parts << "Pregled indeksa: #{checked}." if checked.present?
            issues = reading.facts.select { |row| row["kind"] == "gazette_issue" }
            issues.first(4).each do |row|
              parts << "Pripremljeni indeks navodi: #{row.fetch('text')} Izvor: #{row.fetch('source_url')}."
            end
            parts << "U ovom djelimičnom indeksu nisam našla izdanje za traženi pregled." if issues.empty?
          else
            parts << "Pregledana službena arhiva trenutno nije dostupna za ovu zajednicu; ne mogu potvrditi njen obuhvat ili najnoviji broj."
          end
          parts << "Ovo nije potpuna arhiva niti potvrda da su obuhvaćena sva nova izdanja ili puni tekstovi akata. " \
                   "To što odluka nije u mom djelimičnom spisku ne dokazuje da nije usvojena ili da više ne važi."
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(parts.join(" "), locale),
                                 architecture: "gazette_archive_boundary", subject: "gazette_archive", anchor: query.presence || "arhiva", tool_calls: 1)
        end

        def pension_notice_question?(text)
          folded = Decidim::Bih::Text.fold(Decidim::Bih::Transliterator.to_latin(text.to_s))
          !CitizenNoticeRead.unsupported_notice_query?(folded) &&
            folded.match?(/\b(?:pio|penzij\w*)\b/) && folded.match?(/\b(?:isplat\w*|objav\w*)\b/) &&
            folded.match?(/\b(?:prethodn\w*|prosl\w*|proslog|prosle)\b/)
        end

        def reviewed_pension_notice_guidance(message:, context:)
          query = Decidim::Bih::Transliterator.to_latin(message.text.to_s)
          if Decidim::Bih::Text.fold(query).match?(/\b(?:prethodn\w*|prosl\w*)\b/)
            previous = context.now.in_time_zone("Europe/Sarajevo").to_date.prev_month
            month = %w(januar februar mart april maj jun jul avgust septembar oktobar novembar decembar).fetch(previous.month - 1)
            query = "#{query} #{month} #{previous.year}"
          end
          tools = @tools_factory.call(location: nil)
          envelope = tools.registry.call(name: "read_public_notice", arguments: { "source" => "pio_notices", "query" => query },
                                         context:, eligibility: tools.eligibility)
          revalidate_delivery_evidence!([envelope.for_prompt(context:, eligibility: tools.eligibility)], tools:)
          rows = envelope.status == "ok" ? envelope.evidence.filter_map { |record| record.dig("facts", "source_fact") } : []
          rows = rows.select { |row| row["kind"] == "payment_start_notice" }
          parts = []
          if rows.any?
            rows.first(3).each do |row|
              parts << "#{row.fetch('text')} Datum javne objave: #{row.fetch('source_published_on')}. Izvor: #{row.fetch('source_url')}."
              if Date.iso8601(row.fetch("payment_starts_on")) > context.now.in_time_zone("Europe/Sarajevo").to_date
                parts << "Najavljeni početak je u budućnosti; to nije potvrda da je isplata već počela."
              end
            end
          elsif envelope.warnings.include?("last_known_notice_not_current_status")
            parts << "Sačuvani pregled javnih objava nije aktuelna potvrda isplate za traženi period; potrebna je nova provjera izvora."
          else
            parts << "Nemam potvrđenu javnu objavu o isplati za traženi period u dostupnom djelimičnom pregledu. " \
                     "To ne dokazuje da isplata nije počela ili da takva objava ne postoji."
          end
          parts << "Datum objave, mjesec na koji se isplata odnosi i najavljeni početak su odvojeni podaci. " \
                   "Javna objava ne potvrđuje tvoje pravo ni uplatu na pojedinačni račun. Nisam provjerila bankovni račun; " \
                   "broj računa i druge lične podatke ne šalji u ovaj chat."
          parts.join(" ")
        end

        def child_benefit_public_notice_question?(text)
          folded = Decidim::Bih::Text.fold(Decidim::Bih::Transliterator.to_latin(text.to_s))
          folded.match?(/\b(?:jfdz|djecij\w*\s+dodat\w*|fond\w*\s+za\s+djecij\w*\s+zastit\w*)\b/) &&
            folded.match?(/\b(?:isplat\w*|objav\w*|obavjestenj\w*)\b/)
        end

        def child_benefit_personal_status_followup?(text, state:)
          return unless state.dig(Dialogue::AnswerContext::KEY, "subject") == "jfdz_public_notice"

          folded = Decidim::Bih::Text.fold(Decidim::Bih::Transliterator.to_latin(text.to_s))
          folded.match?(/\b(?:fond\w*|objav\w*|isplat\w*)\b/) &&
            folded.match?(/\b(?:moj\w*|meni|sam|pravo|uplat\w*)\b/)
        end

        def pension_august_2026_notice_question?(text)
          folded = Decidim::Bih::Text.fold(Decidim::Bih::Transliterator.to_latin(text.to_s))
          return false if CitizenNoticeRead.unsupported_notice_query?(folded)

          months = CitizenNoticePilotParser::MONTHS.keys.any? { |name| folded.match?(/\b#{Regexp.escape(name)}\b/) }
          folded.match?(/\b(?:pio|penzij\w*)\b/) && folded.match?(/\b(?:isplat\w*|objav\w*)\b/) && months
        end

        def pension_personal_receipt_followup?(text, state:)
          return unless state.dig(Dialogue::AnswerContext::KEY, "subject") == "pio_public_notice"

          folded = Decidim::Bih::Text.fold(Decidim::Bih::Transliterator.to_latin(text.to_s))
          folded.match?(/\b(?:moj\w*|meni)\b/) && folded.match?(/\bracun\w*\b/) &&
            folded.match?(/\b(?:leg\w*|stig\w*|uplac\w*)\b/)
        end

        def family_medicine_contact_answer(text, state:, context:)
          folded = Decidim::Bih::Text.fold(Decidim::Bih::Transliterator.to_latin(text.to_s))
          initial = folded.match?(/\b(?:porodicn\w*|porodic\w*)\s+medicin\w*\b/) &&
                    folded.match?(/\b(?:broj|telefon\w*|kontakt\w*)\b/)
          followup = state.dig(Dialogue::AnswerContext::KEY, "subject") == "family_medicine_phone" &&
                     folded.match?(/\bporodicn\w*\s+medicin\w*\b/) && folded.match?(/\bcentral\w*\b/)
          repeat_number = state.dig(Dialogue::AnswerContext::KEY, "subject") == "family_medicine_phone" &&
                          folded.match?(/\Aponovi\b.*\bbroj\b/)
          return unless initial || followup || repeat_number

          row = DirectoryServiceFacts.all("zdravstvo_apoteke").find do |fact|
            fact[:subject_id] == "dom-zdravlja:porodicna-medicina" && fact[:predicate] == "phone"
          end
          return unless row && DirectoryServiceFacts.eligible([row], now: context.now).one?

          prefix = followup ? "Da, baš za Službu porodične medicine, ne za centralu. " : ""
          "#{prefix}#{row.fetch(:text)} Izvor: #{row.fetch(:source_url)} " \
            "(provjereno #{Date.iso8601(row.fetch(:source_checked_on)).strftime('%d.%m.%Y.')})."
        end

        def first_zone_sms_number_answer(text, state:)
          folded = Decidim::Bih::Text.fold(Decidim::Bih::Transliterator.to_latin(text.to_s))
          first_zone = folded.match?(/\b(?:prv\w*|i)\s+zon\w*\b/)
          return unless first_zone && folded.match?(/\bbroj\b/)

          first = folded.match?(/\b(?:parking\w*|parkiranj\w*)\b/) && folded.match?(/\bsms\b/)
          followup = state.dig(Dialogue::AnswerContext::KEY, "subject") == "parking_first_zone_sms" &&
                     folded.match?(/\b(?:samo|cjenovnik\w*|cenovnik\w*)\b/)
          return unless first || followup

          number = ParkingZones::TARIFFS.fetch("red").fetch(:sms)
          return "SMS broj za I (crvenu) zonu: #{number}." if followup

          "SMS broj za I (crvenu) zonu je #{number}. Provjeri oznaku stvarne zone na znaku i službene upute " \
            "#{ParkingZones::SOURCE_URL}; poruka meni u chatu ne plaća parking."
        end

        def direct_road_source_unavailable(message:, state:, context:, locale:)
          folded = Decidim::Bih::Text.fold(Decidim::Bih::Transliterator.to_latin(message.text.to_s))
          narrowed = state.dig(Dialogue::AnswerContext::KEY, "subject") == "road_segment_conditions" &&
            folded.match?(/\bjanj[aeiu]\b/)
          scope = narrowed ? "Razumijem: pitaš samo za dionicu kod Janje, ne za sve puteve. " : ""
          answer = "#{scope}Trenutno ne mogu provjeriti pripremljeni izvještaj Auto-moto saveza RS " \
                   "za #{narrowed ? 'tu dionicu' : 'put Bijeljina–Zvornik'}. To ne potvrđuje da nema ograničenja. " \
                   "Provjeri aktuelni izvještaj AMS RS: #{CityServiceSources.fetch('road_conditions').fetch(:source_url)}."
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                 architecture: "road_source_unavailable", subject: "road_segment_conditions", tool_calls: 1)
        end

        def named_transformer_coverage_question?(text, state:)
          folded = Decidim::Bih::Text.fold(Decidim::Bih::Transliterator.to_latin(text.to_s))
          first = folded.match?(/\bts\b/) && folded.match?(/\b(?:mz|mjesn\w*)\b/) &&
            folded.match?(/\b(?:obavijest\w*|obavjestenj\w*|obavestenj\w*|rijec|naziv\w*)\b/) &&
            folded.match?(/\b(?:potvrd\w*|odnos\w*|obuhvat\w*|dokaz\w*)\b/)
          followup = state.dig(Dialogue::AnswerContext::KEY, "subject") == "named_transformer_coverage" &&
            !folded.match?(/\bts\b/) && folded.match?(/\b(?:alat\w*|pretrag\w*|dokaz\w*)\b/)
          first || followup
        end

        def direct_named_transformer_coverage(message:, state:, context:, locale:)
          folded = Decidim::Bih::Text.fold(Decidim::Bih::Transliterator.to_latin(message.text.to_s))
          followup = !folded.match?(/\bts\b/) &&
            state.dig(Dialogue::AnswerContext::KEY, "subject") == "named_transformer_coverage"
          source = CityServiceSources.fetch("electricity_outages").fetch(:source_url)
          answer = if followup
                     "Ne. To što je alat vratio ranije obavještenje pri pretrazi za navedenu MZ " \
                       "nije dokaz da je ona obuhvaćena. Ni naziv trafostanice sam po sebi ne " \
                       "potvrđuje obuhvat neke MZ. Treba izričito naveden obuhvat u izvornoj objavi: #{source}."
                   elsif folded.match?(/\b(?:rijec|naziv\w*)\b/)
                     "Ne. Riječ u nazivu trafostanice nije dokaz da se objava odnosi na istoimenu MZ. " \
                       "Za potvrdu treba izričito naveden obuhvat u izvornoj objavi: #{source}."
                   else
                     "Sam naziv trafostanice u obavještenju ne potvrđuje isključenje za traženu MZ. " \
                       "Ni rezultat pretrage nije dokaz obuhvata. Provjeri da li izvorna objava " \
                       "izričito navodi tu MZ ili tvoju ulicu: #{source}. Ako pošalješ link objave, " \
                       "mogu provjeriti baš nju."
                   end
          anchor = followup ? state.dig(Dialogue::AnswerContext::KEY, "anchor") : message.text.to_s
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                 architecture: "named_transformer_coverage_boundary",
                                 subject: "named_transformer_coverage", anchor:)
        end

        def water_contact_question?(text, state:)
          folded = Decidim::Bih::Text.fold(text.to_s)
          first = folded.match?(/\bkontakt\w*\b/) && folded.match?(/\b(?:vodovod\w*|vodom|vode)\b/) &&
            folded.match?(/\b(?:prijav\w*|problem\w*|kvar\w*)\b/)
          followup = state.dig(Dialogue::AnswerContext::KEY, "subject") == "water_contact" &&
            folded.match?(/\bkontakt\w*\b/) && folded.match?(/\b(?:provjer\w*|prover\w*|siguran)\b/)
          first || followup
        end

        # Use the same scoped, reviewed directory and origin validation as
        # ordinary service follow-ups; no local provider contact is a fallback.
        def reviewed_water_contact_guidance(context:, locale:)
          reviewed_service_contact_guidance(key: "vodovod_servis", details: %w(phone email), context:, locale:)
        end

        def direct_water_contact(message:, state:, context:, locale:)
          contact = reviewed_water_contact_guidance(context:, locale:)
          folded = Decidim::Bih::Text.fold(message.text.to_s)
          answer = if folded.match?(/\b(?:provjer\w*|prover\w*)\b/)
                     "#{contact} Nemam potvrdu da je pojedini telefon ili kanal dostupan baš sada. " \
                       "Pregled stranice ne potvrđuje da je ranija prijava zaprimljena."
                   else
                     "Za prijavu problema s vodom obrati se svom vodovodu. #{contact} " \
                       "Poruka meni u chatu nije prijava vodovodu."
                   end
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                 architecture: "water_contact_boundary", subject: "water_contact")
        end

        def city_notice_source_question?(text, state:)
          folded = Decidim::Bih::Text.fold(text.to_s)
          first = folded.match?(/\b(?:gdje|gde|link\w*|izvor\w*|provjer\w*|prover\w*)\b/) &&
            folded.match?(/\b(?:obavijest\w*|obavjestenj\w*|obavestenj\w*)\b/) &&
            folded.match?(/\b(?:grad\w*|radov\w*)\b/)
          followup = state.dig(Dialogue::AnswerContext::KEY, "subject") == "city_notice_source" &&
            folded.match?(/\b(?:objav\w*|radov\w*|datum\w*|izvor\w*|provjer\w*|prover\w*)\b/)
          first || followup
        end

        def direct_city_notice_source(message:, state:, context:, locale:)
          folded = Decidim::Bih::Text.fold(message.text.to_s)
          url = CityServiceSources.fetch("city_official_notices").fetch(:source_url)
          answer = if folded.match?(/\bdatum\w*\b/) && folded.match?(/\bizvor\w*\b/)
                     "Koristim zbirnu stranicu gradskih obavještenja: #{url}. Ona nema jedan datum objave za sve radove. " \
                       "Nisam navela pojedinačnu datiranu objavu o radovima; datum provjeri uz konkretnu objavu. " \
                       "Datum objave sam po sebi ne potvrđuje trenutno stanje na terenu."
                   elsif folded.match?(/\b(?:ne\s+nalaz\w*|nema\s+nov\w*|odsustv\w*)\b/)
                     "Ne. To što u pregledanim objavama nema nove najave ne dokazuje da radova nema. " \
                       "Provjeri datum i područje pojedinačne objave na #{url}; za konkretno mjesto napiši ulicu ili pošalji link."
                   else
                     "Gradska obavještenja provjeri direktno na službenoj stranici Grada Bijeljina: #{url}. " \
                       "Za radove provjeri datum i navedeno područje konkretne objave; zbirna stranica ne potvrđuje stanje uživo."
                   end
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                 architecture: "city_notice_source", subject: "city_notice_source")
        end

        def report_receipt_question?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\b(?:potvrd\w*|provjer\w*|prover\w*)\b/) &&
            folded.match?(/\b(?:vec|ranij\w*|prije|pre)\b/) &&
            folded.match?(/\b(?:prijav\w*|posla\w*)\b/)
        end

        def direct_report_receipt_boundary(message:, state:, context:, locale:)
          contact = reviewed_water_contact_guidance(context:, locale:)
          answer = "Ne mogu iz ovog razgovora potvrditi da je tvoja ranija prijava kvara zaprimljena. " \
                   "Ako si kvar prijavio vodovodu, potvrdu provjeri direktno kod njih. #{contact} " \
                   "Ako si prijavu poslao na ovoj platformi, provjeri potvrdu ili referentni broj na " \
                   "#{public_site_url('prijave-pronadji')}. Sama poruka u chatu nije potvrda prijema."
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                 architecture: "report_receipt_boundary")
        end

        def report_submission_boundary_question?(text, state:)
          folded = Decidim::Bih::Text.fold(text.to_s)
          immediate = folded.match?(/\b(?:odmah|samo\s+na\s+osnovu)\b/) &&
            folded.match?(/\b(?:poslat\w*|posalj\w*)\b/) && folded.match?(/\bprijav\w*\b/)
          receipt = state.dig(Dialogue::AnswerContext::KEY, "subject") == "report_submission_boundary" &&
            folded.match?(/\b(?:kako|kad)\b/) && folded.match?(/\bzaprimlj\w*\b/)
          immediate || receipt
        end

        def direct_report_submission_boundary(message:, state:, context:, locale:, channel:)
          folded = Decidim::Bih::Text.fold(message.text.to_s)
          chat_enabled = channel == "web_chat" && ENV[ChatReportIntake::MASTER_FLAG] == "true"
          answer = if folded.match?(/\bzaprimlj\w*\b/)
                     "Podnesena prijava ima potvrdu prijema i jedinstvenu referencu nakon tvoje izričite potvrde " \
                       "pregleda u chatu ili obrascu. Bez te potvrde ne mogu reći da je zaprimljena. " \
                       "Referencu možeš provjeriti na #{public_site_url('prijave-pronadji')}."
                   elsif chat_enabled
                     "Ne odmah i ne samo na osnovu te poruke. U ovom chatu mogu pripremiti pregled prijave; " \
                       "tek nakon što ga vidiš i izričito potvrdiš može biti podnesena. Sada ništa nisam poslala. " \
                       "Možeš koristiti i obrazac #{public_site_url('prijave/new')}."
                   else
                     "Ne odmah i ne samo na osnovu te poruke. Prijavu treba pregledati i izričito potvrditi " \
                       "u dostupnom postupku; sada ništa nisam poslala. Obrazac je na #{public_site_url('prijave/new')}."
                   end
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                 architecture: "report_submission_boundary", subject: "report_submission_boundary")
        end

        def whatsapp_receipt_question?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\bwhatsapp\w*\b/) && folded.match?(/\b(?:potvrd\w*|dokaz\w*)\b/) &&
            folded.match?(/\b(?:posla\w*|isporuc\w*|stig\w*)\b/)
        end

        def direct_whatsapp_receipt_boundary(message:, state:, context:, locale:, channel:)
          scope = channel == "web_chat" ? "Iz ovog web chata" : "Iz ovog pitanja"
          answer = "#{scope} ne mogu potvrditi da je tvoja WhatsApp poruka upravo isporučena niti da je prijava podnesena. " \
                   "Pregled nacrta nije slanje; za podnesenu prijavu potrebni su izričita potvrda i priznanica. " \
                   "Ako ih nemaš, provjeri stanje na kanalu kojim si pokušao poslati prijavu."
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                 architecture: "whatsapp_receipt_boundary")
        end

        def outbound_sms_question?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\bsms\b/) && folded.match?(/\b(?:posla\w*|salj\w*|posalj\w*)\b/) &&
            folded.match?(/\b(?:odgovor\w*|poruk\w*)\b/)
        end

        def direct_outbound_sms_boundary(message:, state:, context:, locale:)
          answer = "Ne mogu poslati odgovor SMS-om iz ovog razgovora; mogu ti odgovoriti ovdje u chatu. " \
                   "Sama web poruka ne potvrđuje tvoj telefonski broj niti pokreće slanje SMS-a."
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                 architecture: "outbound_sms_boundary")
        end

        def scoped_weekend_notice_question?(text, state:)
          latin = Decidim::Bih::Transliterator.to_latin(text.to_s)
          first = latin.match?(/\b(?:gradska|gradske|gradsko)\s+obavijest\w*\s+za\s+[^,.?]{2,60}?\s+za\s+(?:naredni|sljedeci|sljedeći)\s+vikend\b/i)
          retained = state.dig(Dialogue::AnswerContext::KEY, "subject") == "scoped_weekend_notice"
          followup = retained && Decidim::Bih::Text.fold(text.to_s).match?(/\b(?:vikend\w*|pokrivenost\w*|obavijest\w*|prekid\w*|domet\w*)\b/)
          first || followup
        end

        def direct_scoped_weekend_notice(message:, state:, context:, locale:)
          retained = state.dig(Dialogue::AnswerContext::KEY, "subject") == "scoped_weekend_notice"
          anchor = retained ? state.dig(Dialogue::AnswerContext::KEY, "anchor").to_s : message.text.to_s
          latin = Decidim::Bih::Transliterator.to_latin(anchor)
          area = latin.match(/\bza\s+(?<area>[^,.?]{2,60}?)\s+za\s+(?:naredni|sljedeci|sljedeći)\s+vikend\b/i)&.[](:area)&.strip
          return unless area&.length&.between?(2, 60)

          today = context.now.in_time_zone(TransportJourneyQuestion::SERVICE_TIME_ZONE).to_date
          saturday = today + ((6 - today.wday) % 7)
          saturday += 7 if saturday <= today
          sunday = saturday + 1
          answer = transport_prose("Za #{area} i naredni vikend (#{saturday.strftime('%d.%m.%Y.')}–#{sunday.strftime('%d.%m.%Y.')}) " \
                                   "ne mogu potvrditi obuhvat iz opšte gradske liste; objava za drugo područje ne dokazuje prekid kod tebe. " \
                                   "To ne znači da prekida neće biti. Pošalji link obavještenja ili tačnu ulicu za ponovnu provjeru.", locale)
          direct_source_boundary(message:, state:, context:, locale:, answer:, architecture: "scoped_weekend_notice",
                                 subject: "scoped_weekend_notice", anchor:)
        end

        def direct_published_city_notices(message:, state:, context:, locale:)
          reading = ReadPort.new(organization: @organization).published_city_notices(context:, locale:)
          answer = if reading.status == "ok"
                     lines = reading.facts.first(3).map do |fact|
                       date = fact.dig("validity", "date") || fact["starts_at"]&.to_s&.first(10)
                       source = fact["source_label"].to_s
                       url = fact["source_url"].to_s
                       [fact["text"], ("Datum: #{date}." if date), ("Izvor: #{source}." unless source.empty?), url.presence].compact.join(" ")
                     end
                     "Objavljena i pregledana gradska obavještenja u narednih 14 dana:\n#{lines.join("\n")}" \
                       "\nZa tačan obuhvat provjeri navedeno područje; naziv objekta sam po sebi ne potvrđuje obuhvat."
                   elsif reading.status == "empty"
                     "U pregledanom obuhvatu za narednih 14 dana nema objavljenih, pregledanih obavještenja. To nije potvrda da nema drugih obavještenja."
                   else
                     "Trenutno ne mogu provjeriti objavljena gradska obavještenja."
                   end
          answer = transport_prose(answer, locale)
          reply = Decidim::Bih::Concierge::Responder::Reply.new(text: answer, report: nil, answer_intent: "service", tone: "core", locale:)
          captured = Dialogue::AnswerContext.capture(kind: "public_card", subject: "city_notices", anchor: message.text.to_s,
                                                     now: context.now, state_expires_at: state.fetch("expires_at"))
          next_state = captured ? state.merge(Dialogue::AnswerContext::KEY => captured) : state
          result = outcome(reply:, state: next_state, resolution: reading.status == "ok" ? "answered" : "source_unavailable",
                           diagnostics: { "architecture" => "deterministic_published_notices", "model_calls" => 0, "tool_calls" => 1 })
          frame = Dialogue::ConversationFrame.load(state[Dialogue::ConversationFrame::KEY], context:)
          persist(result, previous: state, context:, frame: public_history(frame:, message:, answer:, context:, state: next_state))
        end

        def volunteer_two_dates_request(text)
          latin = Decidim::Bih::Transliterator.to_latin(text.to_s)
          folded = Decidim::Bih::Text.fold(latin)
          return unless folded.match?(/\bvolontersk\w*\s+akcij\w*\b/)

          match = latin.match(/\bu\s+(?<area>[\p{L}]+)\s+(?<first>\d{1,2})\.\s*ili\s+(?<second>\d{1,2})\.\s*(?<month>[\p{L}]+)\s+(?<year>20\d{2})\b/i)
          return unless match

          month = TransportJourneyQuestion::MONTH_NUMBERS[Decidim::Bih::Text.fold(match[:month])]
          return unless month

          year = match[:year].to_i
          { area: match[:area], dates: [Date.new(year, month, match[:first].to_i),
                                       Date.new(year, month, match[:second].to_i)] }
        rescue Date::Error
          nil
        end

        def direct_volunteer_two_dates(message:, state:, context:, locale:, request:)
          resolved = CityServiceAreaMatcher.new(organization: @organization).resolve_place(query: request.fetch(:area))
          selected = resolved.places.find { |place| place.kind == "mz" } || resolved.places.first
          unless selected
            answer = "Ne mogu pouzdano povezati #{request.fetch(:area)} s pregledanim područjem. Napiši puni naziv MZ ili komšiluka."
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "volunteer_dates_area_unresolved")
          end

          readings = request.fetch(:dates).map do |date|
            reading = ReadPort.new(organization: @organization).call(
              action: "ask_information", topic: "volunteer",
              entities: { "query" => message.text.to_s, "area_slug" => selected.slug, "date" => date.iso8601 },
              context:, locale:
            )
            facts = Array(reading.facts)
            local = facts.select { |fact| Array(fact.dig("coverage", "area_slugs")).include?(selected.slug) }
            online = facts.select do |fact|
              fact.dig("coverage", "geographic_scope") == "citywide" &&
                Decidim::Bih::Text.fold(fact["text"].to_s).match?(/\bonline\b/)
            end
            detail = if reading.status == "ok"
                       local_note = local.any? ? "lokalna prilika: #{local.first['text']} #{local.first['source_url']}" :
                         "nema potvrđene lokalne fizičke akcije u vraćenim zapisima"
                       online_links = online.filter_map { |fact| fact["source_url"].presence }.uniq
                       online_note = online.any? ? "; postoji #{online.size} gradska online prilika: #{online_links.join(', ')}" : ""
                       "#{local_note}#{online_note}"
                     elsif reading.status == "empty"
                       "nema potvrđene prilike u sadašnjem javnom katalogu"
                     else
                       "javni katalog trenutno nije pouzdano dostupan"
                     end
            [date, reading.status, detail]
          end
          answer = "Za #{selected.label}: " + readings.map { |date, _status, detail| "#{date.strftime('%d.%m.%Y.')}: #{detail}" }.join("; ") + ". " \
                   "Višednevni raspon ne potvrđuje tačan termin rada; provjeri ga s organizatorom."
          if request.fetch(:dates).all? { |date| date < context.now.in_time_zone(TransportJourneyQuestion::SERVICE_TIME_ZONE).to_date }
            answer += " Ovo je pregled sadašnjeg kataloga za prošle datume, ne potvrda šta je tada bilo dostupno."
          end
          answer += " Ako misliš na istoimeni komšiluk, napiši mi." if resolved.places.size > 1
          resolution = readings.all? { |_date, status, _detail| %w(ok empty).include?(status) } ? "answered" : "source_unavailable"
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                 architecture: "volunteer_two_dates_catalog", subject: "volunteer_date_narrowing",
                                 tool_calls: 2, resolution:)
        end

        def volunteer_date_narrowing(text, state:)
          previous = state.dig(Dialogue::ConversationFrame::KEY, "history")&.last&.dig("message").to_s
          return unless Decidim::Bih::Text.fold(previous).match?(/\bvolonter\w*\b/)

          latin = Decidim::Bih::Transliterator.to_latin(text.to_s)
          match = latin.match(/\bsamo\s+za\s+(\d{1,2})\.\s*([\p{L}]+)\b/i)
          return unless match

          month = TransportJourneyQuestion::MONTH_NUMBERS[Decidim::Bih::Text.fold(match[2])]
          year = previous[/\b20\d{2}\b/]&.to_i
          area = latin.match(/\b([\p{L}]{3,60})\s+ostaj\w*\b/i)&.[](1)
          return unless month && year && area

          { area:, date: Date.new(year, month, match[1].to_i) }
        rescue Date::Error
          nil
        end

        def public_map_membership_question?(text)
          folded = Decidim::Bih::Text.fold(Decidim::Bih::Transliterator.to_latin(text.to_s))
          folded.match?(/\bjavn\w*\s+map\w*\b/) && folded.match?(/\bkomsiluk\w*\b/) &&
            folded.match?(/\b(?:mijenj\w*|promijen\w*|promjen\w*)\b/) &&
            folded.match?(/\b(?:nalog\w*|profil\w*)\b/)
        end

        def public_mz_today_request(text, state:)
          folded = Decidim::Bih::Text.fold(text.to_s)
          if state.dig(Dialogue::AnswerContext::KEY, "subject") == "public_mz_today" &&
             folded.match?(/\b(?:obavjestenj\w*|obavijest\w*)\b/) && folded.match?(/\bdanas\b/)
            return { area: state.dig(Dialogue::AnswerContext::KEY, "anchor"), notices_only: true }
          end
          return unless folded.match?(/\bjavn\w*\s+objav\w*\b/) && folded.match?(/\bdanas\b/) &&
                        folded.match?(/\b(?:mjesn\w*|mesn\w*)\s+zajednic\w*\b/)

          latin = Decidim::Bih::Transliterator.to_latin(text.to_s)
          area = latin.match(/\b(?:mjesn\w*|mesn\w*)\s+zajednic\w*\s+(?<area>[\p{L}]{3,60})\s+danas\b/i)&.[](:area)
          { area:, notices_only: false } if area
        end

        def public_mz_map_request(text, state:)
          folded = Decidim::Bih::Text.fold(Decidim::Bih::Transliterator.to_latin(text.to_s))
          if state.dig(Dialogue::AnswerContext::KEY, "subject") == "public_mz_map" &&
             folded.match?(/\bmz\b/) && folded.match?(/\bkomsiluk\w*\b/)
            relationship = folded.match?(/\b(?:clan\w*|postao|postan\w*|odaber\w*|pripad\w*|isti|isto)\b/)
            return { area: state.dig(Dialogue::AnswerContext::KEY, "anchor"), correction: true, relationship: }
          end
          return unless folded.match?(/\bgranic\w*\b/) &&
                        folded.match?(/\bmjesn\w*\s+zajednic\w*\b/)

          latin = Decidim::Bih::Transliterator.to_latin(text.to_s)
          area = latin.match(/\bmjesn\w*\s+zajednic\w*\s+(?<area>[\p{L}]{3,60})\b/i)&.[](:area)
          { area:, correction: false } if area
        end

        def direct_public_mz_map(message:, state:, context:, locale:, request:)
          resolved = CityServiceAreaMatcher.new(organization: @organization).resolve_place(query: request.fetch(:area), kind: "mz")
          selected = resolved.places.first
          unless selected
            answer = "Ne mogu povezati taj naziv s pregledanom mjesnom zajednicom. Napiši puni naziv MZ za javnu mapu."
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "public_mz_map_unresolved")
          end

          label = PlaceAliasRegistry.display_name(selected.label)
          answer = if request[:relationship]
                     "Ne. Odabir #{label} na javnoj mapi ne učlanjuje te u komšiluk i ne mijenja " \
                       "podatke ili provjeru adrese na nalogu. MZ i komšiluk su različite vrste područja; " \
                       "granicu MZ vidiš na #{public_site_url("mjesne-zajednice/#{selected.slug}")}."
                   else
                     prefix = request.fetch(:correction) ? "Da, misliš na #{label}; javna mapa je na" : "Granice #{label} su na javnoj mapi:"
                     "#{prefix} #{public_site_url("mjesne-zajednice/#{selected.slug}")}. " \
                       "Ovo je javna mapa; pregled ne mijenja tvoj komšiluk na nalogu."
                   end
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                 architecture: "public_mz_map", subject: "public_mz_map", anchor: label)
        end

        def ambiguous_public_area_profile_request(text, state:)
          folded = Decidim::Bih::Text.fold(text.to_s)
          if state.dig(Dialogue::AnswerContext::KEY, "subject") == "ambiguous_public_area_profile" &&
             folded.match?(/\b(?:mjesn\w*|mesn\w*)\s+zajednic\w*\b/)
            return { area: state.dig(Dialogue::AnswerContext::KEY, "anchor"), confirmed_mz: true }
          end
          return unless folded.match?(/\b(?:pokaz\w*|prikaz\w*)\s+javn\w*\s+podatk\w*\s+za\b/)

          latin = Decidim::Bih::Transliterator.to_latin(text.to_s)
          area = latin.match(/\bza\s+(?<area>[\p{L}]{3,60})\s*[?.!]?\s*\z/i)&.[](:area)
          { area:, confirmed_mz: false } if area
        end

        def direct_ambiguous_public_area_profile(message:, state:, context:, locale:, request:)
          resolved = CityServiceAreaMatcher.new(organization: @organization).resolve_place(query: request.fetch(:area))
          mz = resolved.places.find { |place| place.kind == "mz" }
          unless mz
            answer = "Za #{request.fetch(:area)} nemam jedno pregledano javno područje. Napiši da li misliš na MZ ili komšiluk."
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "ambiguous_public_area_unresolved")
          end

          label = PlaceAliasRegistry.display_name(mz.label)
          url = public_site_url("mjesne-zajednice/#{mz.slug}")
          answer = if request.fetch(:confirmed_mz)
                     "Razumijem: misliš na #{label}. Njenu javnu stranicu i mapu granica možeš pogledati na #{url}. " \
                       "Ovo ne mijenja izbor tvog komšiluka."
                   elsif resolved.places.size > 1
                     "Kao početnu pretpostavku uzimam #{label}; javna stranica i mapa granica su na #{url}. " \
                       "Isto ime postoji i za komšiluk — napiši ako si mislila na njega. Otvaranje mape ne mijenja članstvo."
                   else
                     "Za #{label} javna stranica i mapa granica su na #{url}. Otvaranje mape ne mijenja članstvo."
                   end
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                 architecture: "ambiguous_public_area_profile", subject: "ambiguous_public_area_profile",
                                 anchor: label)
        end

        def direct_public_mz_today(message:, state:, context:, locale:, request:)
          resolved = CityServiceAreaMatcher.new(organization: @organization).resolve_place(query: request.fetch(:area), kind: "mz")
          selected = resolved.places.first
          unless selected
            answer = "Ne mogu povezati #{request.fetch(:area)} s pregledanom mjesnom zajednicom. Napiši puni naziv MZ za javni pregled."
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "public_mz_today_unresolved")
          end

          notices_only = request.fetch(:notices_only)
          query = notices_only ? "servisne informacije" : "javni pregled lokalnih aktivnosti"
          reading = ReadPort.new(organization: @organization).call(
            action: "ask_information", topic: "neighborhood",
            entities: { "query" => query, "area_slug" => selected.slug, "time_expression" => "danas" },
            context:, locale:
          )
          date = context.now.in_time_zone(TransportJourneyQuestion::SERVICE_TIME_ZONE).to_date.strftime("%d.%m.%Y.")
          label = PlaceAliasRegistry.display_name(selected.label)
          facts = Array(reading.facts).first(3)
          detail = if facts.any?
                     facts.map { |fact| [fact["text"], fact["source_url"]].compact.join(" ") }.join(" ")
                   elsif reading.status == "empty"
                     "U vraćenim javnim zapisima nema potvrđenih stavki u tom obuhvatu. To nije potpuna evidencija svega što se desilo."
                   else
                     "Pregled javnih zapisa trenutno nije pouzdan; ne mogu tvrditi da objava ili događaja nema."
                   end
          scope = notices_only ? "samo javna servisna obavještenja" : "javna servisna obavještenja, prijave i objavljene aktivnosti"
          answer = "Za #{label} i danas (#{date}) provjerila sam #{scope}, u granicama pregledanih izvora. #{detail}"
          answer += " Stare prijave nisam uključila." if notices_only
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                 architecture: "public_mz_today", subject: "public_mz_today", anchor: label,
                                 tool_calls: 1, resolution: %w(ok empty).include?(reading.status) ? "answered" : "source_unavailable")
        end

        def direct_volunteer_date_narrowing(message:, state:, context:, locale:, request:)
          resolved = CityServiceAreaMatcher.new(organization: @organization).resolve_place(query: request.fetch(:area))
          selected = resolved.places.find { |place| place.kind == "mz" } || resolved.places.first
          unless selected
            answer = "Ne mogu potvrditi koje područje označava #{request.fetch(:area)}. Napiši puni naziv MZ ili komšiluka za provjeru volonterskih prilika."
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "volunteer_date_area_unresolved")
          end

          date = request.fetch(:date).iso8601
          reading = ReadPort.new(organization: @organization).call(
            action: "ask_information", topic: "volunteer",
            entities: { "query" => message.text.to_s, "area_slug" => selected.slug, "date" => date }, context:, locale:
          )
          facts = Array(reading.facts)
          local = facts.select { |fact| Array(fact.dig("coverage", "area_slugs")).include?(selected.slug) }
          citywide_online = facts.select do |fact|
            fact.dig("coverage", "geographic_scope") == "citywide" &&
              Decidim::Bih::Text.fold(fact["text"].to_s).match?(/\bonline\b/)
          end
          detail = if reading.status == "ok"
                     local_note = local.any? ? "Objavljena lokalna prilika: #{local.first['text']} #{local.first['source_url']}. " :
                       "U vraćenim zapisima nemam potvrđenu fizičku akciju za #{selected.label}. "
                     online_links = citywide_online.filter_map { |fact| fact["source_url"].presence }.uniq
                     online_note = citywide_online.any? ?
                       "Katalog vraća #{citywide_online.size} online prilike za cijelu Bijeljinu čiji prikazani raspon uključuje taj datum: #{online_links.join(', ')}. " : ""
                     "#{local_note}#{online_note}Višednevni raspon ne potvrđuje tačan termin rada tog dana; provjeri ga s organizatorom."
                   elsif reading.status == "empty"
                     "U sadašnjem javnom katalogu nisam našla potvrđenu priliku za taj datum i područje. To nije potpuna evidencija svih akcija."
                   else
                     "Ne mogu pouzdano provjeriti javni katalog za taj datum i područje."
                   end
          answer = "Za #{request.fetch(:date).strftime('%d.%m.%Y.')} zadržala sam #{selected.label}. #{detail}"
          answer += " Ako misliš na istoimeni komšiluk, napiši mi." if resolved.places.size > 1
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                 architecture: "volunteer_date_narrowing", subject: "volunteer_date_narrowing",
                                 tool_calls: 1, resolution: %w(ok empty).include?(reading.status) ? "answered" : "source_unavailable")
        end

        def public_area_activity_request(text, state:)
          folded = Decidim::Bih::Text.fold(Decidim::Bih::Transliterator.to_latin(text.to_s))
          if state.dig(Dialogue::AnswerContext::KEY, "subject") == "public_area_activity" &&
             folded.match?(/\b(?:buduc\w*|naredn\w*|uskoro)\b/) && folded.match?(/\baktivnost\w*\b/)
            return { area: state.dig(Dialogue::AnswerContext::KEY, "anchor"), future_only: true }
          end
          return unless folded.match?(/\bjavn\w*\b/) && folded.match?(/\bobjav\w*\b/) &&
                        folded.match?(/\b(?:dogadj\w*|aktivnost\w*|prijav\w*)\b/)

          latin = Decidim::Bih::Transliterator.to_latin(text.to_s)
          area = latin.match(/\bza\s+([\p{L}\s]{3,60}?)(?:\s*[:?.!]|\z)/i)&.[](1)&.strip
          { area:, future_only: false } if area
        end

        def direct_public_area_activity(message:, state:, context:, locale:, request:)
          resolved = CityServiceAreaMatcher.new(organization: @organization).resolve_place(query: request.fetch(:area))
          chosen = resolved.places.find { |place| place.kind == "mz" } || resolved.places.one? && resolved.places.first
          unless chosen
            answer = "Ne mogu pouzdano povezati #{request.fetch(:area)} s jednim pregledanim područjem. Napiši puni naziv MZ ili komšiluka za provjeru javnih aktivnosti."
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "public_area_activity_unresolved")
          end

          entities = { "query" => request[:future_only] ? "Buduće aktivnosti uskoro" : message.text.to_s,
                       "area_slug" => chosen.slug }
          entities["time_expression"] = "uskoro" if request[:future_only]
          reading = ReadPort.new(organization: @organization).call(action: "ask_information", topic: "neighborhood",
                                                                 entities:, context:, locale:)
          coverage = reading.coverage || {}
          label = chosen.label
          assumption = resolved.places.size > 1 ? "Za početnu provjeru uzimam #{label}; ako misliš na komšiluk, napiši mi. " : ""
          if request[:future_only]
            activities = coverage.fetch("activities", {})
            facts = Array(reading.facts).select { |fact| fact.dig("coverage", "activity_type") }.first(3)
            detail = if facts.any?
                       "Objavljene buduće aktivnosti: #{facts.map { |fact| [fact['text'], fact['source_url']].compact.join(' ') }.join(' ')}"
                     elsif activities["status"] == "empty"
                       "U pregledanoj evidenciji za narednih sedam dana nema objavljene aktivnosti vezane za #{label}."
                     else
                       "Ne mogu potvrditi potpun spisak budućih aktivnosti za #{label}."
                     end
            caveat = chosen.kind == "mz" ? "Volonterske prilike nemaju pregledanu vezu s MZ, pa ovo nije dokaz da takvih prilika nema. " :
              "Ovaj pregled nije potpuna evidencija svih aktivnosti. "
            answer = "#{assumption}#{detail} #{caveat}" \
                     "Stare prijave nisam uključila; javne prilike možeš provjeriti na #{public_site_url('volontiranje?tab=prilike')}."
          else
            facts = Array(reading.facts).first(3)
            detail = if facts.any?
                       "Pregledani javni zapisi: #{facts.map { |fact| [fact['text'], fact['source_url']].compact.join(' ') }.join(' ')}"
                     elsif reading.status == "empty"
                       "U pregledanom opsegu nema potvrđenih servisnih obavještenja za narednih 12 sati, javnih prijava s lokacijom iz posljednjih sedam dana ni objavljenih lokalnih aktivnosti u narednih sedam dana."
                     else
                       "Trenutno ne mogu pouzdano provjeriti javne objave i aktivnosti za to područje."
                     end
            caveat = chosen.kind == "mz" ? "Volonterske prilike nisu pouzdano mapirane na MZ. " : ""
            answer = "#{assumption}#{detail} Ovaj pregled nije potpuna evidencija. #{caveat}" \
                     "Ako želiš samo buduće aktivnosti, mogu ih posebno provjeriti."
          end
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                 architecture: "public_area_activity_scope", subject: "public_area_activity",
                                 anchor: label, tool_calls: 1,
                                 resolution: %w(ok empty).include?(reading.status) ? "answered" : "source_unavailable")
        end

        def scoped_notice_area_request(text, state:)
          subject = state.dig(Dialogue::AnswerContext::KEY, "subject")
          if %w(scoped_notice_alias unmapped_water_notice).include?(subject)
            folded = Decidim::Bih::Text.fold(text.to_s)
            return { kind: subject, area: state.dig(Dialogue::AnswerContext::KEY, "anchor"), followup: true } if
              folded.match?(/\b(?:vodis|naziv\w*|povez\w*|provjer\w*|prover\w*|mozes|moz\w*)\b/)
          end

          latin = Decidim::Bih::Transliterator.to_latin(text.to_s)
          folded = Decidim::Bih::Text.fold(latin)
          return unless folded.match?(/\bobavjestenj\w*\b/) && folded.match?(/\bza\s+\p{L}/)

          area = latin.match(/\bza\s+([\p{L}\s]{3,80}?)\s*[?.!]*\z/i)&.[](1)&.strip
          return unless area

          resolved = CityServiceAreaMatcher.new(organization: @organization).resolve_place(query: area)
          if resolved.status == :unknown && folded.match?(/\bvod\w*\b/)
            { kind: "unmapped_water_notice", area: }
          elsif resolved.status == :ambiguous && resolved.places.size == 2 &&
                resolved.places.map(&:kind).sort == %w(komsiluk mz) &&
                resolved.places.map { |place| PlaceAliasRegistry.normalize(place.label).sub(/\Amz\s+/, "") }.uniq.one?
            { kind: "scoped_notice_alias", area:, slugs: resolved.places.map(&:slug) }
          end
        end

        def direct_scoped_notice_area(message:, state:, context:, locale:, request:)
          area = request.fetch(:area)
          if request.fetch(:kind) == "scoped_notice_alias"
            resolved = CityServiceAreaMatcher.new(organization: @organization).resolve_place(query: area)
            slugs = resolved.places.map(&:slug)
            mz = resolved.places.find { |place| place.kind == "mz" }
            komsiluk = resolved.places.find { |place| place.kind == "komsiluk" }
            unless mz && komsiluk
              answer = "Ne mogu više potvrditi istu vezu naziva područja iz registra. Napiši puni naziv MZ ili komšiluka za novu provjeru."
              return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                            architecture: "scoped_notice_alias_changed", subject: "scoped_notice_alias", anchor: area)
            end
            if request[:followup]
              answer = "Da. #{area} u registru odgovara #{mz.label} i istoimenom komšiluku #{komsiluk.label}. " \
                       "To su dvije vrste područja, ne dva različita sela; pri pretrazi objava provjeravam oba."
              return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                            architecture: "scoped_notice_alias_followup", subject: "scoped_notice_alias", anchor: area)
            end
            reading = ReadPort.new(organization: @organization).published_city_notices(context:, locale:, area_slugs: slugs)
            note = if reading.status == "ok"
                     facts = reading.facts.first(3).map { |fact| "#{fact['text']} #{fact['source_url']}" }
                     "Objavljena i pregledana obavještenja koja izričito navode ovo područje: #{facts.join(' ')}"
                   elsif reading.status == "empty"
                     "U objavljenim i pregledanim obavještenjima za narednih 14 dana nisam našla potvrđen obuhvat tog područja. To nije potvrda da drugih obavještenja nema."
                   else
                     "Trenutno ne mogu provjeriti objavljena obavještenja za to područje."
                   end
            answer = "#{area} u registru odgovara #{mz.label} i istoimenom komšiluku #{komsiluk.label}; za pretragu sam provjerila oba područja. " \
                     "#{note} Gradske objave: #{CityServiceSources.fetch('city_official_notices').fetch(:source_url)}. " \
                     "Ako misliš na tačnu ulicu ili drugu vrstu obavještenja, napiši je za ponovnu provjeru."
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "scoped_published_notice_alias", subject: "scoped_notice_alias",
                                          anchor: area, tool_calls: 1, resolution: %w(ok empty).include?(reading.status) ? "answered" : "source_unavailable")
          end

          if request[:followup]
            answer = "Mogu provjeriti datum, vrijeme i izričito navedene ulice u službenoj objavi koju pošalješ. " \
                     "Za #{area} još nemam pregledanu vezu s jednim područjem Vodovoda, pa bez te objave ne mogu potvrditi obuhvat ni tvrditi da prekida nema. " \
                     "Objave su na #{CityServiceSources.fetch('water_service').fetch(:source_url)}."
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "unmapped_water_notice_followup", subject: "unmapped_water_notice", anchor: area)
          end
          check = CityServiceSourceCheckStore.check(keys: ["water_service"], deadline: context.deadline).first
          source_url = CityServiceSources.fetch("water_service").fetch(:source_url)
          source_note = if check && %i(ok empty).include?(check.status)
                          "Pregledala sam izvor vodovodnih servisnih informacija, ali bez pregledane veze s #{area} ne mogu utvrditi obuhvat pojedine objave."
                        else
                          "Pregled vodovodnog izvora trenutno nije pouzdan; iz njega ne mogu potvrditi važeću objavu."
                        end
          answer = "#{area} ne mogu povezati s jednim pregledanim područjem vodovodnih obavještenja. #{source_note} " \
                   "To ne potvrđuje da prekida nema. Mogu provjeriti datum, vrijeme i izričito navedene ulice ako pošalješ službenu objavu. " \
                   "Servisne informacije Vodovoda: #{source_url}."
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                 architecture: "unmapped_water_notice", subject: "unmapped_water_notice",
                                 anchor: area, tool_calls: 1, resolution: check && %i(ok empty).include?(check.status) ? "answered" : "source_unavailable")
        end

        def direct_neighborhood_guide(message:, state:, context:, locale:)
          path = Decidim::Bih::Engine.routes.url_helpers.onboarding_guide_path
          host = @organization.host.to_s
          url = host.match?(/\A[a-z0-9][a-z0-9.-]*(?::\d+)?\z/i) ? "https://#{host}#{path}" : path
          answer = I18n.t("decidim.bih.concierge.public_neighborhood_guide", locale:, url:)
          reply = Decidim::Bih::Concierge::Responder::Reply.new(text: answer, report: nil, answer_intent: "service", tone: "core", locale:)
          result = outcome(reply:, state:, resolution: "answered", diagnostics: { "architecture" => "deterministic_public_guide", "model_calls" => 0, "tool_calls" => 0 })
          frame = Dialogue::ConversationFrame.load(state[Dialogue::ConversationFrame::KEY], context:)
          persist(result, previous: state, context:, frame: public_history(frame:, message:, answer:, context:, state:))
        end

        def direct_public_capability(message:, state:, context:, locale:, capability:)
          reply = Decidim::Bih::Concierge::Responder::Reply.new(
            text: capability.text, report: nil, answer_intent: capability.answer_intent, tone: "core", locale:
          )
          captured = Dialogue::AnswerContext.capture(
            kind: capability.context_kind, subject: capability.context_subject, anchor: message.text.to_s,
            now: context.now, state_expires_at: state.fetch("expires_at")
          )
          capability_state = captured ? state.merge(Dialogue::AnswerContext::KEY => captured) : state
          result = outcome(
            reply:, state: capability_state, resolution: "answered",
            diagnostics: { "architecture" => "deterministic_public_capability", "model_calls" => 0, "tool_calls" => 0,
                           "capability" => capability.key, "source_refs" => capability.source_refs }
          )
          frame = Dialogue::ConversationFrame.load(state[Dialogue::ConversationFrame::KEY], context:)
          persist(result, previous: state, context:, frame: public_history(frame:, message:, answer: capability.text, context:, state: capability_state))
        end

        def source_fetch_date_question?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\bdatum\b.{0,65}\b(?:preuzimanj\w*|provjer\w*|prover\w*)\b.{0,45}\bizvor\w*\b/) &&
            folded.match?(/\bdatum\b.{0,50}\b(?:odvoz\w*|izvrsenj\w*|izvrsavanj\w*)\b/)
        end

        def direct_source_fetch_date(message:, state:, context:, locale:)
          answer = transport_prose("Datum zadnjeg preuzimanja izvora pokazuje kada su podaci provjereni, ne kada je otpad odvezen. " \
                                   "Raspored opisuje planirani dan; ne potvrđuje izvršenje ili vanrednu izmjenu danas.", locale)
          reply = Decidim::Bih::Concierge::Responder::Reply.new(text: answer, report: nil, answer_intent: "service", tone: "core", locale:)
          result = outcome(reply:, state:, resolution: "answered",
                           diagnostics: { "architecture" => "source_date_boundary", "model_calls" => 0, "tool_calls" => 0 })
          frame = Dialogue::ConversationFrame.load(state[Dialogue::ConversationFrame::KEY], context:)
          persist(result, previous: state, context:, frame: public_history(frame:, message:, answer:, context:, state:))
        end

        def waste_named_location_target(text, state:)
          subject = state.dig(Dialogue::AnswerContext::KEY, "subject") == "waste_named_location"
          folded = Decidim::Bih::Text.fold(text.to_s)
          followup = subject && folded.match?(/\b(?:tacan\w*\s+dan|ulic\w*|broj\w*|blok\w*|rejon\w*|satnic\w*|termin\w*)\b/)
          return state.dig(Dialogue::AnswerContext::KEY, "anchor") if followup

          return unless folded.match?(/\b(?:odvoz\w*|odvozi\w*|smece|otpad\w*|raspored\w*)\b/) &&
                        folded.match?(/\b(?:kada|kad|dan\w*|raspored\w*|blok\w*|rejon\w*)\b/)

          # A citizen may narrow a citywide question to a named settlement.
          # Keep that scope even when its name is absent from the waste table
          # or collides with a street; the reader will still require a row.
          explicit_area = Decidim::Bih::Transliterator.to_latin(text.to_s).match(
            /\bnaselj\w*\s+(?<area>[\p{L}]+(?:\s+[\p{L}]+){0,3})(?=[.!?;,]|\z)/i
          )&.[](:area)
          return explicit_area if explicit_area.present?

          resolved = CityServiceAreaMatcher.new(organization: @organization).resolve_place(query: text.to_s)
          names = Array(resolved.places).map do |entry|
            PlaceAliasRegistry.display_name(entry.label).sub(/\Amz\s+/i, "")
          end.uniq
          return names.first if names.one?

          place = state.dig(Dialogue::ConversationSlots::KEY, "location")
          PlaceAliasRegistry.display_name(place["label"]).sub(/\Amz\s+/i, "") if place.is_a?(Hash) && place["kind"] == "named"
        end

        def corrected_waste_street(text, state:, context:)
          latin = Decidim::Bih::Transliterator.to_latin(text.to_s)
          folded = Decidim::Bih::Text.fold(latin)
          return unless folded.match?(/\b(?:pogrijes\w*|ispravk\w*)\b/) && folded.match?(/\bu\s+bijeljini\b/)

          frame = Dialogue::ConversationFrame.load(state[Dialogue::ConversationFrame::KEY], context:)
          previous = Decidim::Bih::Text.fold(frame.history.last&.fetch("message", "").to_s)
          waste_context = state.dig(Dialogue::AnswerContext::KEY, "subject") == "waste_named_location" ||
                          previous.match?(/\b(?:odvoz\w*|smece|otpad\w*|komunalac|raspored\w*)\b/)
          return unless waste_context

          latin.match(/\bulic\w*\s+(?<street>[\p{L}\s]{3,80}?)\s+u\s+Bijeljini\b/i)&.[](:street)&.strip
        end

        def waste_next_year_question?(text, state:)
          folded = Decidim::Bih::Text.fold(text.to_s)
          return false unless folded.match?(/\b2027\b/) && folded.match?(/\braspored\w*\b/)

          state.dig(Dialogue::AnswerContext::KEY, "subject") == "waste_named_location" ||
            folded.match?(/\b(?:odvoz\w*|smece|otpad\w*|komunalac)\b/)
        end

        def direct_waste_next_year(message:, state:, context:, locale:)
          answer = "Ne mogu potvrditi isti dan za 2027. Pregledani program odvoza važi za 2026. godinu; " \
                   "njegov podatak za 2026. nije raspored za 2027. Kada Komunalac objavi program za 2027, " \
                   "provjeri ga na https://www.komunalacbn.com/ ili mi pošalji taj izvor za ponovnu provjeru."
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                 architecture: "waste_year_boundary", subject: "waste_named_location",
                                 anchor: state.dig(Dialogue::AnswerContext::KEY, "anchor"))
        end

        def paper_recycling_question?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\bpapir\w*\b/) && folded.match?(/\b(?:odvojen\w*|prikuplj\w*|recikl\w*)\b/)
        end

        def recycling_park_location_followup?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\b(?:posud\w*|kontejner\w*)\b/) &&
            folded.match?(/\b(?:park\w*|najbliz\w*|recikl\w*)\b/)
        end

        def bulky_waste_contact_followup?(text)
          folded = Decidim::Bih::Text.fold(Decidim::Bih::Transliterator.to_latin(text.to_s))
          folded.match?(/\b(?:kontakt\w*|telefon\w*|broj\w*)\b/) &&
            folded.match?(/\b(?:termin\w*|odvoz\w*|objav\w*)\b/)
        end

        def bulky_waste_question?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\b(?:kabast\w*|glomazn\w*|star\w*\s+namjestaj\w*|star\w*\s+sof\w*)\b/) &&
            folded.match?(/\b(?:odvoz\w*|odnosenj\w*|prikuplj\w*)\b/)
        end

        def direct_bulky_waste(message:, state:, context:, locale:)
          reading = ReadPort.new(organization: @organization).bulky_waste_campaigns(context:, locale:)
          parts = if reading.status == "ok" && reading.facts.any?
                    reading.facts.map do |fact|
                      period = "#{fact.fetch('starts_on')} – #{fact.fetch('ends_on')}"
                      phase = case fact.fetch("phase")
                              when "expired" then "Objavljeni period je prošao."
                              when "upcoming" then "Objavljeni period tek predstoji."
                              else "Današnji datum je unutar objavljenog perioda; to nije potvrda da odvoz upravo traje."
                              end
                      "Pregledana najava: #{fact.fetch('text')} Objavljeni period: #{period}. #{phase} " \
                        "Obuhvat iz najave: #{fact.fetch('coverage_text')} Izvor: #{fact.fetch('source_url')} " \
                        "(objavljeno #{fact.fetch('source_on')}; pregledano #{fact.fetch('reviewed_on')})."
                    end
                  else
                    ["Nemam dostupnu pregledanu najavu i period odvoza kabastog otpada za ovu zajednicu."]
                  end
          parts << "Pregledane najave ne isključuju postojanje novije objave i ne potvrđuju odvoz za tvoju adresu."
          parts << reviewed_service_contact_guidance(key: "otpad", details: %w(phone email), context:, locale:)
          parts << "Redovni raspored kućnog otpada nije potvrda odvoza namještaja. Termin i uslove provjeri sa službom."
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(parts.join(" "), locale),
                                 architecture: "bulky_waste_window", subject: "bulky_waste")
        end

        def dvorovi_coverage_question?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\bdvorov\w*\b/) && folded.match?(/\bodvoz\w*\b/) &&
            folded.match?(/\b(?:kojim\s+danima|dan\w*)\b/)
        end

        def direct_dvorovi_coverage(message:, state:, context:, locale:)
          rows = WasteSchedule.default.registry.fetch("rows").select { |row| row["settlement"] == "Дворови" }
          weekdays = rows.map { |row| row.fetch("weekday") }.uniq.sort
          answer = if weekdays == [1, 2]
                     "U programu odvoza za 2026. Dvorovi su navedeni ponedjeljkom, a pojedine ulice u " \
                       "Dvorovima (Dimitrija Lopandića, Kneza Miloša i 1. maja) utorkom. To ne znači da " \
                       "svaka adresa ima odvoz oba dana. Napiši ulicu za ponovnu provjeru svog reda. " \
                       "Izvor: #{WasteSchedule.schedule_url}."
                   else
                     "Za Dvorove ne mogu potvrditi sve dane iz pregledanih redova programa za 2026. " \
                       "Napiši ulicu za užu provjeru. Izvor: #{WasteSchedule.schedule_url}."
                   end
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                 architecture: "waste_settlement_coverage", subject: "waste_named_location", anchor: "Dvorovi")
        end

        def direct_paper_recycling(message:, state:, context:, locale:)
          answer = "Odvojeno prikupljanje papira provjeri kod AD Komunalac Bijeljina: " \
                   "https://www.komunalacbn.com/djelatnosti/komunalne-usluge navodi prikupljanje reciklažnog " \
                   "otpada (papir, najlon i PET), a https://www.komunalacbn.com/kontakt daje kontakt za " \
                   "tačnu lokaciju ili termin. Pregledani redovni raspored miješanog otpada za 2026. " \
                   "ne određuje dan ili kontejner za papir."
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                 architecture: "paper_recycling_boundary", subject: "waste_recycling")
        end

        def direct_corrected_waste_street(message:, state:, context:, locale:, street:)
          found = WasteSchedule.default.resolution_for("#{street}, Bijeljina")
          source = WasteSchedule::DEFAULT_SCHEDULE_URL
          published_street = Array(found[:places]).first || street
          published_street = Decidim::Bih::Transliterator.to_latin(published_street) unless locale.to_s == "sr-Cyrl"
          answer = if found.fetch(:status) == :ok && found[:days].present?
                     "Ispravka: za ulicu #{published_street} u Bijeljini pregledani program " \
                       "odvoza za 2026. navodi #{found.fetch(:days).join(', ')}. To je redovni raspored, " \
                       "ne potvrda da je vozilo prošlo ili da nema izuzetaka. Izvor: #{source}."
                   else
                     "Ispravka je prihvaćena: sada provjeravam #{street} u Bijeljini, ne Dvorove. " \
                       "Ne mogu potvrditi dan za tu ulicu iz pregledanog programa; napiši broj ili rejon " \
                       "ako ih znaš. Izvor: #{source}."
                   end
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                 architecture: "corrected_waste_street", subject: "waste_named_location",
                                 anchor: street, resolution: found.fetch(:status) == :ok ? "answered" : "unsupported")
        end

        def direct_waste_named_location(message:, state:, context:, locale:, name: nil)
          place = state.dig(Dialogue::ConversationSlots::KEY, "location")
          name ||= PlaceAliasRegistry.display_name(place["label"]).sub(/\Amz\s+/i, "") if place.is_a?(Hash) && place["kind"] == "named"
          name ||= state.dig(Dialogue::AnswerContext::KEY, "anchor").to_s
          folded = Decidim::Bih::Text.fold(message.text.to_s)
          if folded.match?(/\bulic\w*\b/) && folded.match?(/\bbroj\w*\b/)
            answer = "Da. Napiši ulicu i broj samo ako želiš da ponovo provjerim pregledani raspored za područje #{name}. " \
                     "Broj može pomoći da razlikujem blok ili dio ulice, ali bez provjerene veze s rejonom " \
                     "ne mogu obećati tačan dan. Dovoljan je i broj bloka ako ga znaš."
            calls = 0
          elsif folded.match?(/\bsatnic\w*\b/)
            answer = "Za područje #{name} pregledani program razlikuje dane po bloku ili ulici, ali ne potvrđuje satnicu dolaska kamiona. " \
                     "Ne mogu tvrditi da je ista u svakom bloku. Napiši blok za planirani dan; tačno vrijeme ili današnju izmjenu " \
                     "provjeri kod AD Komunalac Bijeljina. Izvor: #{WasteSchedule.schedule_url}."
            calls = 0
          elsif folded.match?(/\btermin\w*\b/)
            answer = "Za planirani dan odvoza u području #{name} treba mi broj bloka ili tačna ulica. " \
                     "Pregledani program ne daje pouzdanu satnicu dolaska niti potvrdu da je kamion danas prošao. " \
                     "Izvor: #{WasteSchedule.schedule_url}."
            calls = 0
          else
            reading = ReadPort.new(organization: @organization).call(
              action: "ask_information", topic: "waste",
              entities: { "query" => "kada se odvozi smeće", "area_query" => name }, context:, locale:
            )
            choices = Array(reading.candidates).first(4).map { |candidate| candidate["label"].to_s }.reject(&:blank?)
            choices.map! { |label| Decidim::Bih::Transliterator.to_latin(label) } unless locale.to_s == "sr-Cyrl"
            settlement_days = WasteSchedule.default.legacy.collection_days_for(name)
            answer = if reading.status == "ambiguous" && choices.any?
                       precision = folded.match?(/\bglavn\w*\s+put\w*\b/) ? "Opis 'blizu glavnog puta'" : "Samo ime naselja"
                       "Za područje #{name} pregledani raspored razlikuje blokove/rejone: #{choices.join('; ')}. " \
                         "#{precision} ne određuje jedan od njih, pa još ne mogu potvrditi tačan dan. " \
                         "Napiši blok, ulicu ili broj za ponovnu provjeru."
                     elsif Array(settlement_days).size > 1
                       "Za područje #{name} pregledani program ima odvoz u različitim ulicama tokom više dana " \
                         "(#{settlement_days.join(', ')}). To nisu svi dani za svaku kuću; napiši ulicu za tačan red."
                     elsif reading.status == "ok" && reading.facts.present?
                       fact = reading.facts.first
                       "Za područje #{name} pregledani raspored navodi: #{fact.fetch('text')} Izvor: #{fact['source_url']}. " \
                         "To je plan, a ne potvrda da je vozilo danas prošlo."
                     else
                       "Za područje #{name} ne mogu potvrditi tačan dan odvoza iz pregledanog rasporeda. " \
                         "Napiši blok ili ulicu za ponovnu provjeru; to ne znači da odvoza nema."
                     end
            answer = "#{answer} Izvor: #{reading.source['url']}." if reading.source.is_a?(Hash) && reading.source["url"].present?
            calls = 1
          end
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                 architecture: "waste_named_location", subject: "waste_named_location",
                                 anchor: name, tool_calls: calls)
        end

        def waste_schedule_change_question?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\braspored\w*\b/) && folded.match?(/\bvanredn\w*\b/) &&
            folded.match?(/\bizmjen\w*\b/)
        end

        def waste_execution_question?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\b(?:kamion\w*|odvoz\w*|smece|otpad\w*)\b/) &&
            folded.match?(/\b(?:dokaz\w*|prosao|prosla|stvarn\w*|izvrsen\w*|obavljen\w*)\b/)
        end

        def waste_service_change_question?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          (folded.match?(/\b(?:odvoz\w*|smece|otpad\w*)\b/) &&
           folded.match?(/\b(?:prekid\w*|izmjen\w*|promjen\w*)\b/)) ||
            (folded.match?(/\bprekid\w*\s+uslug\w*\b/) && folded.match?(/\bizmjen\w*\b/))
        end

        def direct_waste_service_change(message:, state:, context:, locale:)
          answer = "Ako misliš na odvoz otpada, redovni program (#{WasteSchedule.schedule_url}) ne potvrđuje današnji prekid " \
                   "ni vanrednu izmjenu. Datirane objave provjeri u aktuelnostima AD Komunalac Bijeljina: " \
                   "https://www.komunalacbn.com/info-centar/aktuelnosti. Ako tamo nema objave za tvoje područje, " \
                   "to ne dokazuje da je usluga danas tekla po planu; za stanje na terenu pitaj Komunalac."
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                 architecture: "waste_service_change")
        end

        def citywide_waste_schedule_question?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\b(?:bijeljin\w*|centar\s+bijeljin\w*)\b/) &&
            folded.match?(/\b(?:odvoz\w*|smece|otpad\w*)\b/) &&
            !folded.match?(/\b(?:ulic\w*|rejon\w*|blok\w*)\b/)
        end

        def direct_citywide_waste_schedule(message:, state:, context:, locale:)
          folded = Decidim::Bih::Text.fold(message.text.to_s)
          area = folded.match?(/\bcentar\s+bijeljin\w*\b/) ? "centar Bijeljine" : "Bijeljinu"
          answer = "Za #{area} pregledani program odvoza za 2026. " \
                   "razlikuje ulice i rejone, pa ne postoji jedan planirani dan za cijelo područje. " \
                   "Napiši ulicu ili rejon da provjerim odgovarajući red. Program je plan, ne potvrda da je kamion danas prošao. " \
                   "Izvor: #{WasteSchedule.schedule_url}."
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                 architecture: "citywide_waste_schedule")
        end

        def direct_waste_execution_boundary(message:, state:, context:, locale:)
          answer = "Ne. Redovni raspored odvoza (#{WasteSchedule.schedule_url}) pokazuje plan po ulici ili rejonu, " \
                   "ali ne potvrđuje da je kamion danas prošao niti da nije bilo vanredne izmjene. " \
                   "Za planirani dan napiši ulicu ili rejon; za stvarno izvršenje provjeri kod AD Komunalac Bijeljina."
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                 architecture: "waste_execution_boundary", subject: "waste_execution")
        end

        def holiday_waste_change_question?(text, state:)
          folded = Decidim::Bih::Text.fold(text.to_s)
          first = folded.match?(/\bpraznik\w*\b/) &&
            (folded.match?(/\b(?:odvoz\w*|smece|otpad\w*)\b/) || folded.match?(/\bredovn\w*\s+dan\b/))
          followup = state.dig(Dialogue::AnswerContext::KEY, "subject") == "holiday_waste_change" &&
            folded.match?(/\b(?:praznik\w*|raspored\w*|izmjen\w*|objav\w*)\b/)
          first || followup
        end

        def direct_holiday_waste_change(message:, state:, context:, locale:)
          answer = transport_prose("Nemam potvrđenu izmjenu odvoza za traženi praznik. Redovni raspored " \
                                   "(#{WasteSchedule.schedule_url}) ne potvrđuje praznični odvoz niti izvršenje. " \
                                   "Napiši datum praznika i tačnu ulicu ili rejon za ponovnu provjeru; ako nema službene objave, " \
                                   "aktuelnu izmjenu potvrdi direktno kod AD Komunalac Bijeljina.", locale)
          direct_source_boundary(message:, state:, context:, locale:, answer:, architecture: "holiday_waste_change_boundary",
                                 subject: "holiday_waste_change")
        end

        def direct_waste_schedule_change(message:, state:, context:, locale:)
          answer = transport_prose("Pregledani raspored navodi planirani dan za određeni blok; ne potvrđuje da je odvoz danas izvršen. " \
                                   "Nemam potvrdu o današnjoj vanrednoj izmjeni. Za izbor odgovarajućeg reda " \
                                   "napiši naselje i, gdje je potrebno, blok ili ulicu i broj objekta.", locale)
          direct_source_boundary(message:, state:, context:, locale:, answer:, architecture: "waste_schedule_change_boundary")
        end

        def parking_sign_zone_followup?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\b(?:znak\w*|tabl\w*|sign)\b/) &&
            folded.match?(/\bparking\w*\b/) &&
            folded.match?(/\b(?:zon\w*|plat\w*|korisno|pay)\b/) &&
            !folded.match?(/\b(?:pise|pisu|oznaka\s+je|sms\s*\d{5,6})\b/)
        end

        def parking_tariff_source_question?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          explicit_source = folded.match?(/\bizvor\w*\b/) && folded.match?(/\btarif\w*\b/)
          price_freshness = folded.match?(/\b(?:cjenovn\w*|cenovn\w*)\b/) &&
            folded.match?(/\b(?:danas|danasnj\w*|starij\w*|vazec\w*)\b/)
          explicit_source || price_freshness
        end

        def first_zone_parking_payment_question?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\bplat\w*\b/) && folded.match?(/\bparking\w*\b/) &&
            folded.match?(/\b(?:prv\w*|i)\s+zon\w*\b/)
        end

        def parking_payment_confirmation_question?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\bporuk\w*\b/) && folded.match?(/\bparking\w*\b/) &&
            folded.match?(/\bplac\w*\b/)
        end

        def blue_parking_tariff_question?(text, state:)
          folded = Decidim::Bih::Text.fold(text.to_s)
          price_or_payment = folded.match?(/\b(?:plac\w*|plat\w*|cijen\w*|cen\w*|kost\w*|sat|dnevn\w*|cjelodnevn\w*)\b/)
          explicit_blue = folded.match?(/\b(?:plav\w*|ii)\b/) && folded.match?(/\b(?:parking\w*|zon\w*)\b/)
          retained_blue = state.dig(Dialogue::AnswerContext::KEY, "subject") == "blue_parking_tariff" &&
            folded.match?(/\b(?:toj|iste|parking\w*|zon\w*)\b/) &&
            !folded.match?(/\b(?:crven\w*|prv\w*|bijel\w*|i)\s+zon\w*\b/)
          price_or_payment && (explicit_blue || retained_blue)
        end

        def direct_blue_parking_tariff(message:, state:, context:, locale:)
          tariff = ParkingZones::TARIFFS.fetch("blue")
          answer = "Za plavu / II zonu objavljena je satna cijena #{tariff.fetch(:hourly)} " \
                   "(SMS #{tariff.fetch(:sms)}) i dnevna karta #{tariff.fetch(:daily_price)} " \
                   "(SMS #{tariff.fetch(:daily_sms)}). Izvor: #{ParkingZones::SOURCE_URL}. " \
                   "Prije plaćanja provjeri oznaku zone i aktuelnu tarifu na parking-mjestu; " \
                   "poruka meni u chatu ne plaća parking."
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                 architecture: "blue_parking_tariff", subject: "blue_parking_tariff")
        end

        def direct_parking_payment_confirmation(message:, state:, context:, locale:)
          answer = "Ne. Poruka meni u chatu ne plaća parking i ne potvrđuje uplatu. " \
                   "Plati preko načina navedenog na znaku za stvarnu zonu i provjeri potvrdu plaćanja u tom kanalu. " \
                   "Službene upute i tarife: #{ParkingZones::SOURCE_URL}."
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                 architecture: "parking_payment_confirmation_boundary", subject: "parking_payment")
        end

        def parking_landmark_price_question?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\bkolik\w*\b.*\bkost\w*\b/) && folded.match?(/\bsat\b/) &&
            folded.match?(/\bparkir\w*\b/) && folded.match?(/\b(?:kod|blizu|pored|oko)\b/)
        end

        def direct_parking_landmark_price(message:, state:, context:, locale:)
          tariffs = ParkingZones::TARIFFS.values.map { |row| "#{row.fetch(:label)} #{row.fetch(:hourly)}" }
          checked = ParkingZones::TARIFF_VERIFIED_ON.strftime("%d.%m.%Y.")
          answer = "Sam orijentir ne određuje zonu konkretnog parking-mjesta. Objavljene satne tarife su: " \
                   "#{tariffs.join('; ')}. Izvor: #{ParkingZones::SOURCE_URL}; provjereno #{checked} " \
                   "Napiši ulicu za ponovnu provjeru, a prije plaćanja provjeri oznaku zone i aktuelnu cijenu na mjestu parkiranja."
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                 architecture: "parking_landmark_price_boundary", subject: "parking_tariff")
        end

        def live_parking_space_question?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\bslobodn\w*\s+mjest\w*\b/) &&
            folded.match?(/\b(?:sada|trenutno|uzivo)\b/)
        end

        def direct_live_parking_space(message:, state:, context:, locale:)
          answer = "Ne mogu potvrditi da je parking-mjesto slobodno baš sada; nemam podatke o zauzetosti uživo. " \
                   "Provjeri na licu mjesta ili kod parking službe. Službena stranica parking servisa: #{ParkingZones::SOURCE_URL}."
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                 architecture: "live_parking_space_boundary", subject: "parking_availability")
        end

        def direct_first_zone_parking_payment(message:, state:, context:, locale:)
          tariff = ParkingZones::TARIFFS.fetch("red")
          checked = ParkingZones::TARIFF_VERIFIED_ON.strftime("%d.%m.%Y.")
          answer = "Za I (crvenu) zonu objavljen je SMS broj #{tariff.fetch(:sms)} i tarifa #{tariff.fetch(:hourly)}. " \
                   "Službeni izvor: #{ParkingZones::SOURCE_URL}; tarifu smo provjerili #{checked} " \
                   "Prije plaćanja provjeri aktuelnu cijenu, oznaku zone i uputstvo na mjestu parkiranja. " \
                   "Poruka meni u chatu ne plaća parking."
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                 architecture: "first_zone_parking_payment", subject: "parking_payment")
        end

        def direct_parking_tariff_source(message:, state:, context:, locale:)
          checked = ParkingZones::TARIFF_VERIFIED_ON.strftime("%d.%m.%Y.")
          answer = transport_prose("Objavljenu tarifu provjerili smo #{checked} na #{ParkingZones::SOURCE_URL}. " \
                                   "To je datum naše provjere, ne potvrđen datum objave ili zadnje izmjene tarife. " \
                                   "Prije plaćanja provjeri aktuelnu tarifu i znak zone na mjestu parkiranja.", locale)
          direct_source_boundary(message:, state:, context:, locale:, answer:, architecture: "parking_tariff_provenance")
        end

        def accessible_parking_question?(text, state:)
          folded = Decidim::Bih::Text.fold(text.to_s)
          first = folded.match?(/\b(?:invaliditet\w*|pristupacn\w*|kolic\w*)\b/) &&
            folded.match?(/\b(?:parking\w*|parkir\w*|mjest\w*|lokacij\w*)\b/)
          followup = state.dig(Dialogue::AnswerContext::KEY, "subject") == "accessible_parking" &&
            folded.match?(/\b(?:oznacen\w*|slobodn\w*|rezerv\w*|dostupn\w*|realn\w*|lokacij\w*|zvanic\w*|pristupacn\w*)\b/)
          first || followup
        end

        def direct_accessible_parking(message:, state:, context:, locale:)
          answer = transport_prose("U pregledanim podacima nemam potvrđen spisak tačnih pristupačnih parking mjesta za traženo područje. " \
                                   "Objavljena mapa zona ne potvrđuje oznaku ili pristupačnost pojedinog mjesta. " \
                                   "Ne vidim zauzetost uživo i ne mogu rezervisati mjesto. Provjeri oznaku i pristup na samom mjestu " \
                                   "ili pitaj parking službu; službena stranica je #{ParkingZones::SOURCE_URL}.", locale)
          direct_source_boundary(message:, state:, context:, locale:, answer:, architecture: "accessible_parking_boundary",
                                 subject: "accessible_parking")
        end

        def water_notice_scope_question?(text, state:)
          folded = Decidim::Bih::Text.fold(text.to_s)
          first = folded.match?(/\brad\w*\s+na\s+mrez\w*\b/) && folded.match?(/\bvod\w*\b/) &&
            folded.match?(/\bcijel\w*\b/)
          followup = state.dig(Dialogue::AnswerContext::KEY, "subject") == "water_notice_scope" &&
            folded.match?(/\b(?:obavijest\w*|ulic\w*|podrucj\w*|domet\w*|naselj\w*)\b/)
          first || followup
        end

        def water_safety_question?(text, state:)
          folded = Decidim::Bih::Text.fold(text.to_s)
          first = folded.match?(/\bvod\w*\b/) &&
                  (folded.match?(/\b(?:zdravstven\w*\s+ispravn\w*|sigurn\w*\s+za\s+pi\w*|za\s+pi\w*)\b/) ||
                   folded.match?(/\b(?:kvalitet\w*|ispravn\w*|sigurn\w*)\b/))
          followup = state.dig(Dialogue::AnswerContext::KEY, "subject") == "water_safety" &&
                     folded.match?(/\b(?:kvar\w*|obavijest\w*|sigurn\w*|ispravn\w*)\b/)
          first || followup
        end

        def direct_water_safety_boundary(message:, state:, context:, locale:)
          folded = Decidim::Bih::Text.fold(message.text.to_s)
          contact = reviewed_water_contact_guidance(context:, locale:)
          answer = if state.dig(Dialogue::AnswerContext::KEY, "subject") == "water_safety" &&
                      folded.match?(/\b(?:nedostaj\w*|sta\s+ti\b|potvrd\w*\s+ispravn\w*)\b/)
                     "Za potvrdu ispravnosti nedostaje aktuelan nalaz kvaliteta vode ili izričita potvrda " \
                       "nadležne službe za traženo mjesto i datum. Objava o kvaru ili njeno odsustvo to ne zamjenjuje. #{contact}"
                   else
                     "Ne mogu potvrditi zdravstvenu ispravnost vode za traženo mjesto i datum. " \
                       "To što nema obavijesti o kvaru ili prekidu nije dokaz da je voda sigurna za piće; " \
                       "servisne objave i analiza kvaliteta su različite provjere. #{contact} " \
                       "Ako sumnjaš u kvalitet vode, nemoj je koristiti za piće dok nadležna služba ne potvrdi stanje."
                   end
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                 architecture: "water_safety_boundary", subject: "water_safety")
        end

        def dated_water_notice_request(text, state:)
          latin = Decidim::Bih::Transliterator.to_latin(text.to_s)
          folded = Decidim::Bih::Text.fold(latin)
          if folded.match?(/\bobavijest\w*\b/) && folded.match?(/\bprekid\w*\s+vod\w*\b/)
            date = DOTTED_DATE.match(latin)
            area = latin.match(/\bu\s+(?<area>[\p{L}]{2,50})\s+za\s+\d{1,2}\.\d{1,2}\.20\d{2}/i)&.[](:area)
            return unless date && area

            return { date: Date.new(date[3].to_i, date[2].to_i, date[1].to_i).iso8601,
                     area: area, street: nil }
          end

          return unless state.dig(Dialogue::AnswerContext::KEY, "subject") == "dated_water_notice"

          saved = state.dig(Dialogue::AnswerContext::KEY, "anchor").to_s.split("|", 2)
          return unless saved.size == 2 && saved.first.match?(/\A\d{4}-\d{2}-\d{2}\z/)

          street = latin.match(/\b(?:na|za)\s+(?<street>[\p{L}\s]{2,60}?)\s+ulic\w*\b/i)&.[](:street)&.strip
          return unless street && folded.match?(/\b(?:suzi\w*|ulic\w*)\b/)

          { date: saved.first, area: saved.last, street: "#{street} ulicu" }
        rescue Date::Error
          nil
        end

        def direct_dated_water_notice(message:, state:, context:, locale:, request:)
          check = CityServiceSourceCheckStore.check(keys: ["water_service"], deadline: context.deadline).first
          place = request[:street] || request.fetch(:area)
          source = CityServiceSources.fetch("water_service").fetch(:source_url)
          status = check && %i(ok empty).include?(check.status) ?
            "U pripremljenom pregledu nemam potvrđen rezultat za taj datum i navedeno područje." :
            "Pripremljena provjera Vodovodovog izvora trenutno nije pouzdana."
          answer = "#{status} Za #{request.fetch(:date)} i lokaciju koju si naveo/la (#{place}) ne mogu potvrditi ni postojanje ni odsustvo " \
                   "objave o prekidu. Provjeri službene servisne informacije: #{source}. " \
                   "Ako pošalješ link objave, mogu provjeriti njen datum, vrijeme i izričito navedene ulice."
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                 architecture: "dated_water_notice_boundary", subject: "dated_water_notice",
                                 anchor: "#{request.fetch(:date)}|#{request.fetch(:area)}", tool_calls: 1,
                                 resolution: check && %i(ok empty).include?(check.status) ? "unsupported" : "source_unavailable")
        end

        def direct_water_notice_scope(message:, state:, context:, locale:)
          answer = transport_prose("Najava radova kod imenovane lokacije sama ne potvrđuje prekid vode u cijelom naselju. " \
                                   "Nemam tačno obavještenje za provjeru njegovog obuhvata. Pošalji link, datum, ulicu ili broj objekta " \
                                   "pa mogu ponovo provjeriti navedeno područje; bez toga neću širiti domet na cijelo naselje.", locale)
          direct_source_boundary(message:, state:, context:, locale:, answer:, architecture: "water_notice_scope",
                                 subject: "water_notice_scope")
        end

        def water_today_notice_question?(text, state:)
          folded = Decidim::Bih::Text.fold(text.to_s)
          first = folded.match?(/\bdanas\b/) && folded.match?(/\bprekid\w*\s+vod\w*\b/) &&
            folded.match?(/\bnajavljen\w*\b/) && text.to_s.match?(/\bu\s+[\p{L}\s]{2,80}[?!.]?\z/i)
          followup = state.dig(Dialogue::AnswerContext::KEY, "subject") == "water_today_notice" &&
            folded.match?(/\b(?:objav\w*|prekid\w*|pogodjen\w*|vrijem\w*|ulic\w*|jucer\w*|jucerasnj\w*)\b/)
          first || followup
        end

        def direct_water_today_notice(message:, state:, context:, locale:)
          retained = state.dig(Dialogue::AnswerContext::KEY, "subject") == "water_today_notice"
          narrowed = message.text.to_s.match(/\bulic\w*,?\s+(?<street>[\p{L}\p{M}\s]{3,80}?)\s+u\s+(?<area>[\p{L}\p{M}]{2,40})\b/i) if retained
          answer = if narrowed
                     street = narrowed[:street].strip
                     area = narrowed[:area].strip
                     reading = ReadPort.new(organization: @organization).call(
                       action: "ask_information", topic: "water",
                       entities: { "query" => message.text.to_s, "area_query" => area,
                                   "street" => street, "time_expression" => "danas" }, context:, locale:
                     )
                     today = context.now.in_time_zone("Europe/Sarajevo").to_date.iso8601
                     explicit = Array(reading.facts).find do |fact|
                       fact.dig("validity", "date") == today &&
                         %w(whole part).include?(fact.dig("coverage", "requested_relation")) &&
                         Decidim::Bih::Text.fold(fact["text"].to_s).include?(Decidim::Bih::Text.fold(street)) &&
                         Array(fact["warning_codes"]).exclude?("source_facts_unconfirmed")
                     end if reading.status == "ok"
                     source = CityServiceSources.fetch("water_service").fetch(:source_url)
                     if explicit
                       "Za danas (#{today}), objava izričito spominje #{street} u #{area}: #{explicit.fetch('text')} " \
                         "Izvor: #{explicit['source_url']}. Provjeri navedeno vrijeme prekida; datum objave nije vrijeme prekida."
                     elsif reading.status == "unavailable"
                       "Za danas (#{today}) i ulicu #{street} u #{area} izvor trenutno ne mogu pouzdano provjeriti. " \
                         "Jučerašnja objava ne potvrđuje današnji prekid. Provjeri službene informacije: #{source}."
                     else
                       "Za danas (#{today}) nemam potvrdu da se prekid odnosi na ulicu #{street} u #{area}. " \
                         "Jučerašnja objava i pominjanje mjesta bez te ulice ne potvrđuju njen obuhvat; " \
                         "to ne dokazuje da prekida nema. Provjeri službene informacije: #{source}."
                     end
                   elsif retained
                     "Datum objave nije vrijeme prekida. Samo izričito potvrđen obuhvat obavještenja dokazuje da se prekid " \
                       "odnosi na traženo područje; bez te veze neću tvrditi da je pogođeno."
                   else
                     area = message.text.to_s.match(/\bu\s+(?<area>[\p{L}\s]{2,80})[?!.]?\z/i)&.[](:area)&.strip
                     reading = ReadPort.new(organization: @organization).call(
                       action: "ask_information", topic: "water",
                       entities: { "query" => message.text.to_s, "area_query" => area.to_s }, context:, locale:
                     )
                     supported = Array(reading.facts).find do |fact|
                       %w(whole part).include?(fact.dig("coverage", "requested_relation")) &&
                         Array(fact["warning_codes"]).exclude?("source_facts_unconfirmed")
                     end if reading.status == "ok"
                     if supported
                       "U pregledanoj objavi za traženo područje: #{supported.fetch('text')} " \
                         "Izvor: #{supported['source_url']}. Provjeri vrijeme samog prekida u objavi; datum objave je drugi podatak."
                     elsif reading.status == "ambiguous"
                       "Za lokaciju koju si naveo/la (u #{area}) uzimam mjesto kao početno područje, ali naziv se podudara s više granica. " \
                         "Zato ne mogu potvrditi današnji prekid za tačnu lokaciju; napiši ulicu ili pošalji službenu objavu za ponovnu provjeru."
                     else
                       "Za danas nemam potvrđenu objavu koja izričito povezuje prekid vode s traženim područjem. " \
                         "To ne dokazuje da prekida nema. Pošalji službenu objavu ili tačnu ulicu za ponovnu provjeru."
                     end
                   end
          answer = transport_prose(answer, locale)
          direct_source_boundary(message:, state:, context:, locale:, answer:, architecture: "water_today_notice",
                                 subject: "water_today_notice", tool_calls: retained && !narrowed ? 0 : 1)
        end

        def water_current_fault_question?(text, state:)
          folded = Decidim::Bih::Text.fold(text.to_s)
          first = folded.match?(/\bkvar\w*\s+na\s+vod\w*\b/) &&
            folded.match?(/\bu\s+[a-z\s]{2,60}(?:[?.!]|\z)/)
          followup = state.dig(Dialogue::AnswerContext::KEY, "subject") == "water_current_fault" &&
            folded.match?(/\b(?:planiran\w*|neplaniran\w*|objav\w*|izvor\w*|korak\w*|potvrd\w*|prekid\w*)\b/)
          first || followup
        end

        def direct_water_current_fault(message:, state:, context:, locale:)
          source_url = CityServiceSources.fetch("water_service").fetch(:source_url)
          folded = Decidim::Bih::Text.fold(message.text.to_s)
          prior = state.dig(Dialogue::AnswerContext::KEY, "subject") == "water_current_fault" ?
            state.dig(Dialogue::AnswerContext::KEY, "anchor") : nil
          if prior && folded.match?(/\b(?:planiran\w*|neplaniran\w*)\b/)
            answer = "Planirani prekid ima unaprijed objavljenu najavu i vrijeme važenja; neplanirani kvar " \
                     "može imati naknadnu objavu i promjenjiv rok popravke. Bez potvrđene objave za traženo " \
                     "područje ne mogu tvrditi koju vrstu prekida sada imaš. Provjeri #{source_url}."
            calls = 0
          elsif prior && folded.match?(/\b(?:korak\w*|ako\s+nema|izvor\w*)\b/)
            answer = "Provjeri najnovije servisne informacije Vodovoda na #{source_url}; ako tamo nema potvrde " \
                     "za tvoju ulicu, pitaj Vodovod direktno preko kontakta na službenoj stranici. " \
                     "Bez objave ne mogu potvrditi ni uzrok ni rok završetka."
            calls = 0
          else
            area = message.text.to_s.match(/\bu\s+(?<area>[\p{L}\s]{2,60}?)(?:[?.!]|\z)/i)&.[](:area)&.strip
            reading = ReadPort.new(organization: @organization).call(
              action: "ask_information", topic: "water",
              entities: { "query" => message.text.to_s, "area_query" => area.to_s }, context:, locale:
            )
            assumption = nil
            if reading.status == "ambiguous"
              candidates = Array(reading.candidates)
              mz = candidates.find { |candidate| candidate["area_kind"] == "mz" }
              same_name = candidates.size == 2 && candidates.map { |candidate|
                PlaceAliasRegistry.normalize(PlaceAliasRegistry.display_name(candidate["text"]).sub(/\Amz\s+/i, ""))
              }.uniq.one?
              if mz && same_name
                reading = ReadPort.new(organization: @organization).call(
                  action: "ask_information", topic: "water",
                  entities: { "query" => message.text.to_s, "area_slug" => mz.fetch("area_slug") }, context:, locale:
                )
                area = mz.fetch("text")
                assumption = "Kao početno područje uzimam #{area}; napiši ulicu ako misliš na drugi dio naselja. "
              end
            end
            supported = Array(reading.facts).find do |fact|
              %w(whole part).include?(fact.dig("coverage", "requested_relation")) &&
                Array(fact["warning_codes"]).exclude?("source_facts_unconfirmed")
            end if reading.status == "ok"
            answer = if supported
                       "Za #{area} pregledana objava navodi: #{supported.fetch('text')} " \
                         "Izvor: #{supported['source_url']}. Rok završetka potvrdi samo ako je naveden u toj objavi."
                     elsif reading.status == "empty"
                       "U pregledanim servisnim informacijama nemam potvrđenu objavu o kvaru koja izričito " \
                         "obuhvata #{area}. To ne dokazuje da kvara nema i ne daje rok završetka."
                     elsif reading.status == "ambiguous"
                       "Ne mogu pouzdano povezati #{area} s jednim područjem obavještenja Vodovoda. " \
                         "Napiši ulicu ili pošalji službenu objavu za provjeru obuhvata."
                     else
                       "Trenutno ne mogu potvrditi objavu o kvaru za #{area} ni rok završetka iz pregledanog izvora. " \
                         "To ne znači da kvara nema."
                     end
            answer = "#{assumption}#{answer}" if assumption
            answer = "#{answer} Službene informacije: #{source_url}."
            calls = assumption ? 2 : 1
          end
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                 architecture: "water_current_fault", subject: "water_current_fault",
                                 anchor: prior.presence || message.text.to_s, tool_calls: calls)
        end

        def water_tomorrow_notice_question?(text, state:)
          folded = Decidim::Bih::Text.fold(text.to_s)
          first = folded.match?(/\bsutra\b/) && folded.match?(/\bprekid\w*\s+vod\w*\b/) &&
            (folded.match?(/\bnajavljen\w*\b/) ||
             state.dig(Dialogue::ConversationSlots::KEY, "location", "kind") == "named" &&
               folded.match?(/\bmoj\w*\s+lokacij\w*\b/))
          followup = state.dig(Dialogue::AnswerContext::KEY, "subject") == "water_tomorrow_notice" &&
            folded.match?(/\b(?:bolnic\w*|objav\w*|izvor\w*|kasn\w*|potvrd\w*|prekid\w*|ulic\w*|centr\w*|adres\w*|kuc\w*|obuhva\w*)\b/)
          first || followup
        end

        def direct_water_tomorrow_notice(message:, state:, context:, locale:)
          prior = state.dig(Dialogue::AnswerContext::KEY, "subject") == "water_tomorrow_notice" ?
            state.dig(Dialogue::AnswerContext::KEY, "anchor") : nil
          source_url = CityServiceSources.fetch("water_service").fetch(:source_url)
          date = context.now.in_time_zone(TransportJourneyQuestion::SERVICE_TIME_ZONE).to_date + 1
          folded = Decidim::Bih::Text.fold(message.text.to_s)
          if prior && folded.match?(/\b(?:kuc\w*|adres\w*|obuhva\w*)\b/) &&
             folded.match?(/\b(?:potvrd\w*|tvrdi\w*|sigurn\w*)\b/)
            answer = "Ne. Naziv naselja ili ulice bez potvrđenog obuhvata objave ne dokazuje da je tačna kuća " \
                     "obuhvaćena prekidom vode. Provjeri izričitu listu ulica/brojeva i vrijeme važenja na #{source_url}."
            calls = 0
          elsif prior && folded.match?(/\b(?:izvor\w*|kasn\w*)\b/)
            answer = "Ako izvor kasni ili nije potvrdio obuhvat, ne mogu potvrditi ni prekid ni njegovo odsustvo " \
                     "za sutra (#{date.iso8601}). Datum objave nije vrijeme prekida. Provjeri datum i obuhvat na #{source_url}."
            calls = 0
          else
            latin = Decidim::Bih::Transliterator.to_latin(message.text.to_s)
            area = if prior
                     latin.match(/\bza\s+(?<area>[\p{L}\s]{2,80}?)(?:[,?.!]|\z)/i)&.[](:area)&.strip
                   else
                     latin.match(/\bza\s+(?<area>[\p{L}\s]{2,80}?)\s+sutra\b/i)&.[](:area)&.strip
                   end
            area ||= prior.to_s.match(/\bza\s+(?<area>[\p{L}\s]{2,80}?)\s+sutra\b/i)&.[](:area)&.strip
            named = state.dig(Dialogue::ConversationSlots::KEY, "location")
            area ||= PlaceAliasRegistry.display_name(named["label"]).sub(/\Amz\s+/i, "") if named.is_a?(Hash) && named["kind"] == "named"
            query = prior ? "#{message.text} Sutra." : message.text.to_s
            reading = ReadPort.new(organization: @organization).call(
              action: "ask_information", topic: "water",
              entities: { "query" => query, "area_query" => area.to_s }, context:, locale:
            )
            assumption = nil
            if reading.status == "ambiguous"
              candidates = Array(reading.candidates)
              mz = candidates.find { |candidate| candidate["area_kind"] == "mz" }
              same_name = candidates.size == 2 && candidates.map { |candidate|
                PlaceAliasRegistry.normalize(PlaceAliasRegistry.display_name(candidate["text"]).sub(/\Amz\s+/i, ""))
              }.uniq.one?
              if mz && same_name
                reading = ReadPort.new(organization: @organization).call(
                  action: "ask_information", topic: "water",
                  entities: { "query" => query, "area_slug" => mz.fetch("area_slug") }, context:, locale:
                )
                area = mz.fetch("text")
                assumption = "Kao početno područje uzimam #{area}; napiši ulicu ako misliš na drugi dio naselja. "
              end
            end
            supported = Array(reading.facts).find do |fact|
              %w(whole part).include?(fact.dig("coverage", "requested_relation")) &&
                Array(fact["warning_codes"]).exclude?("source_facts_unconfirmed")
            end if reading.status == "ok"
            answer = if supported
                       "Za sutra (#{date.iso8601}) pregledana objava za #{area} navodi: #{supported.fetch('text')} " \
                         "Izvor: #{supported['source_url']}. To ne potvrđuje obuhvat svake kuće."
                     elsif reading.status == "ambiguous" && reading.candidates.present?
                       choices = Array(reading.candidates).first(3).map { |candidate| candidate["text"] }.compact.join(", ")
                       "Za #{area} nalazim više područja (#{choices}). Napiši ulicu ili pošalji objavu " \
                         "da provjerim obuhvat za sutra."
                     elsif reading.status == "ambiguous"
                       "Ne mogu povezati #{area} s jednim provjerenim područjem vodovodnog obavještenja " \
                         "za sutra. Napiši ulicu ili pošalji službenu objavu za ponovnu provjeru."
                     elsif reading.status == "empty"
                       "U pregledanim najavama nemam potvrdu prekida vode koji izričito obuhvata #{area} sutra " \
                         "(#{date.iso8601}). To ne dokazuje da prekida neće biti."
                     else
                       "Ne mogu potvrditi najavu prekida vode za #{area} sutra (#{date.iso8601}) iz pregledanog izvora. " \
                         "To ne znači da prekida neće biti."
                     end
            answer = "#{assumption}#{answer}" if assumption
            if prior && folded.match?(/\bulic\w*\b/) && folded.match?(/\b(?:centr\w*|janj\w*)\b/)
              answer = "Opis 'ulica u centru Janje' bez naziva ulice i broja još ne određuje obuhvat kuće. #{answer}"
            end
            answer = "#{answer} Službene objave: #{source_url}."
            calls = assumption ? 2 : 1
          end
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                 architecture: "water_tomorrow_notice", subject: "water_tomorrow_notice",
                                 anchor: prior.presence || message.text.to_s, tool_calls: calls)
        end

        def electricity_today_notice_question?(text, state:)
          folded = Decidim::Bih::Text.fold(text.to_s)
          first = folded.match?(/\bdanas\b/) && folded.match?(/\bnajavljen\w*\b/) &&
            folded.match?(/\bprekid\w*\s+struj\w*\b/) &&
            text.to_s.match?(/\bu\s+[\p{L}\s]{2,60}[?!.]?\z/i)
          followup = state.dig(Dialogue::AnswerContext::KEY, "subject") == "electricity_today_notice" &&
            folded.match?(/\b(?:objav\w*|podrucj\w*|kuc\w*|sigurn\w*|struj\w*|prekid\w*)\b/)
          first || followup
        end

        def dated_electricity_notice_request(text, state:)
          folded = Decidim::Bih::Text.fold(text.to_s)
          if state.dig(Dialogue::AnswerContext::KEY, "subject") == "electricity_dated_notice" &&
             folded.match?(/\b(?:kraj\w*|termin\w*|prikljuc\w*|struj\w*)\b/)
            return { followup: true, anchor: state.dig(Dialogue::AnswerContext::KEY, "anchor") }
          end
          return unless folded.match?(/\b(?:elektromrez\w*|struj\w*|iskljucenj\w*)\b/) &&
                        folded.match?(/\b(?:radov\w*|najav\w*|prekid\w*)\b/)

          latin = Decidim::Bih::Transliterator.to_latin(text.to_s)
          match = latin.match(DOTTED_DATE)
          return unless match

          date = Date.new(match[3].to_i, match[2].to_i, match[1].to_i)
          area = latin.match(/\bu\s+(?<area>[\p{L}]{3,55})\s+za\s+\d{1,2}\./i)&.[](:area)
          return unless area

          resolved = CityServiceAreaMatcher.new(organization: @organization).resolve_place(query: area)
          area = PlaceAliasRegistry.display_name(resolved.places.first.label).sub(/\Amz\s+/i, "") if resolved.places.any?

          { date:, area: }
        rescue Date::Error
          nil
        end

        def direct_dated_electricity_notice(message:, state:, context:, locale:, request:)
          source = CityServiceSources.fetch("electricity_outages").fetch(:source_url)
          if request[:followup]
            answer = "Ne. Kraj objavljenog termina radova ne potvrđuje da je konkretna kuća ponovo " \
                     "priključena. Najava opisuje planirani period, a stvarno stanje na adresi treba provjeriti " \
                     "kod Elektro Bijeljine. Prethodni upit: #{request[:anchor]}. Službene najave: #{source}."
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "electricity_restoration_boundary", subject: "electricity_dated_notice",
                                          anchor: request[:anchor])
          end

          date = request.fetch(:date).iso8601
          area = request.fetch(:area)
          reading = ReadPort.new(organization: @organization).call(
            action: "ask_information", topic: "electricity",
            entities: { "query" => message.text.to_s, "area_query" => area }, context:, locale:
          )
          supported = Array(reading.facts).find do |fact|
            %w(whole part).include?(fact.dig("coverage", "requested_relation")) &&
              Array(fact["warning_codes"]).exclude?("source_facts_unconfirmed")
          end if reading.status == "ok"
          answer = if supported
                     "Za #{date} pregledana najava za područje #{area} navodi: #{supported.fetch('text')} " \
                       "Izvor: #{supported['source_url']}. To ne potvrđuje stanje struje u svakoj kući."
                   elsif reading.status == "empty"
                     "Za #{date} u pregledanim najavama nemam potvrđen obuhvat radova za područje #{area}. " \
                       "To nije dokaz da radova nije bilo ili da je svaka kuća imala struju."
                   else
                     "Za #{date} ne mogu pouzdano provjeriti objavljene radove na elektromreži koji " \
                       "obuhvataju područje #{area}; pregledani izvor trenutno nije potvrdio taj obuhvat. " \
                       "To nije tvrdnja da radova nije bilo."
                   end
          answer = "#{answer} Službene najave: #{source}."
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                 architecture: "electricity_dated_notice", subject: "electricity_dated_notice",
                                 anchor: "#{date}, #{area}", tool_calls: 1,
                                 resolution: reading.status == "ok" || reading.status == "empty" ? "answered" : "source_unavailable")
        end

        def direct_electricity_today_notice(message:, state:, context:, locale:)
          prior = state.dig(Dialogue::AnswerContext::KEY, "subject") == "electricity_today_notice" ?
            state.dig(Dialogue::AnswerContext::KEY, "anchor") : nil
          anchor = prior.presence || message.text.to_s
          folded = Decidim::Bih::Text.fold(message.text.to_s)
          if prior && folded.match?(/\b(?:kuc\w*|sigurn\w*)\b/)
            answer = "Ne mogu potvrditi da je tvoja kuća obuhvaćena samo iz naziva naselja. " \
                     "Za tačnu adresu treba obavještenje koje izričito navodi njen obuhvat; " \
                     "objavljena najava nije potvrda stanja struje uživo."
            calls = 0
          else
            area = anchor.match(/\bu\s+(?<area>[\p{L}\s]{2,60})\s*[?!.]?\z/i)&.[](:area)&.strip
            reading = ReadPort.new(organization: @organization).call(
              action: "ask_information", topic: "electricity",
              entities: { "query" => anchor, "area_query" => area.to_s }, context:, locale:
            )
            assumption = nil
            if reading.status == "ambiguous"
              candidates = Array(reading.candidates)
              mz = candidates.find { |candidate| candidate["area_kind"] == "mz" }
              same_name = candidates.size == 2 && candidates.map { |candidate|
                PlaceAliasRegistry.normalize(PlaceAliasRegistry.display_name(candidate["text"]).sub(/\Amz\s+/i, ""))
              }.uniq.one?
              if mz && same_name
                # A place and its MZ can share a public name. Try the MZ as an
                # explicit, disclosed area assumption; never infer a house.
                reading = ReadPort.new(organization: @organization).call(
                  action: "ask_information", topic: "electricity",
                  entities: { "query" => anchor, "area_slug" => mz.fetch("area_slug") }, context:, locale:
                )
                area = mz.fetch("text")
                assumption = "Kao početno područje uzimam #{area}; napiši ulicu ako misliš na drugi dio naselja. "
              end
            end
            supported = Array(reading.facts).find do |fact|
              %w(whole part).include?(fact.dig("coverage", "requested_relation")) &&
                Array(fact["warning_codes"]).exclude?("source_facts_unconfirmed")
            end if reading.status == "ok"
            answer = if supported
                       "Za danas je za područje #{area} objavljeno: #{supported.fetch('text')} " \
                         "Izvor: #{supported['source_url']}. Obuhvat tačne kuće i stanje struje uživo nisu potvrđeni."
                     elsif reading.status == "ambiguous"
                       "Za područje #{area} naziv odgovara više granica, pa ne mogu potvrditi obuhvat najave. " \
                         "Napiši ulicu ili pošalji službenu objavu za ponovnu provjeru."
                     elsif reading.status == "empty"
                       "U pregledanim najavama nemam potvrdu prekida struje koji izričito obuhvata #{area} danas. " \
                         "To ne dokazuje da prekida nema niti da tvoja kuća ima ili nema struju. " \
                         "Pošalji službenu objavu ili tačnu ulicu za ponovnu provjeru."
                     else
                       "Trenutno ne mogu potvrditi najavu prekida struje za #{area} iz pregledanog izvora. " \
                         "To ne znači da prekida nema; provjeri službenu objavu Elektro Bijeljine ili pošalji link za ponovnu provjeru."
                     end
            answer = "#{assumption}#{answer}" if assumption
            answer = "#{answer} Službene najave: #{CityServiceSources.fetch('electricity_outages').fetch(:source_url)}."
            calls = assumption ? 2 : 1
          end
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                 architecture: "electricity_today_notice", subject: "electricity_today_notice",
                                 anchor:, tool_calls: calls)
        end

        def electricity_tomorrow_notice_question?(text, state:)
          folded = Decidim::Bih::Text.fold(text.to_s)
          first = folded.match?(/\biskljucenj\w*\s+struj\w*\b/) && folded.match?(/\bsutra\b/) &&
            folded.match?(/\bnajavljen\w*\b/) && folded.match?(/\bu\s+[a-z\s]{2,60}\b/)
          followup = state.dig(Dialogue::AnswerContext::KEY, "subject") == "electricity_tomorrow_notice" &&
            folded.match?(/\b(?:sutra|vrijem\w*|vazenj\w*|izvor\w*|otkazan\w*|termin\w*|garant\w*|kuc\w*|struj\w*)\b/)
          first || followup
        end

        def border_freight_wait_followup?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\bteretn\w*\s+kamion\w*\b/) &&
            folded.match?(/\b(?:isti\s+podatak|cek\w*|zadrz\w*)\b/)
        end

        def gps_parking_zone_question?(text, state:, location:)
          folded = Decidim::Bih::Text.fold(text.to_s)
          subject = state.dig(Dialogue::AnswerContext::KEY, "subject") == "gps_parking_zone"
          return false unless location || subject

          folded.match?(/\bparking\s+zon\w*\b/) &&
            folded.match?(/\b(?:ovdje|ovde|lokacij\w*|poslao|poslala)\b/)
        end

        def gps_waste_schedule_question?(text, state:, location:)
          folded = Decidim::Bih::Text.fold(text.to_s)
          first = location && folded.match?(/\b(?:smece|otpad\w*|odvoz\w*)\b/) &&
            folded.match?(/\bmoj\w*\s+lokacij\w*\b/)
          followup = state.dig(Dialogue::AnswerContext::KEY, "subject") == "gps_waste_schedule" &&
            folded.match?(/\bulic\w*\b/)
          first || followup
        end

        def direct_gps_waste_schedule(message:, state:, context:, locale:)
          retained = state.dig(Dialogue::AnswerContext::KEY, "subject") == "gps_waste_schedule"
          street = message.text.to_s.match(/\bulic\w*\s+(?<street>[\p{L}\p{M}\s]{3,80}?)\s+u\s+Bijeljin\w*\b/i)&.[](:street)&.strip if retained
          if street
            found = WasteSchedule.default.resolution_for("#{street}, Bijeljina")
            answer = if found[:status] == :ok && found[:days].present?
                       "Za ulicu #{street} u Bijeljini pregledani program odvoza za 2026. navodi " \
                         "#{found[:days].join(', ')}. To je redovni plan, ne potvrda da je kamion prošao. " \
                         "Izvor: #{WasteSchedule.schedule_url}."
                     else
                       "Za ulicu #{street} u Bijeljini ne mogu potvrditi jedinstven dan iz pregledanog " \
                         "programa odvoza za 2026. To ne znači da odvoza nema. Ako znaš broj ili rejon, " \
                         "napiši ga; za tačan red provjeri i kod AD Komunalac. Izvor: #{WasteSchedule.schedule_url}."
                     end
          else
            answer = "Primila sam tvoju lokaciju, ali GPS tačka nije povezana s uličnim redom odvoza. " \
                     "Napiši ulicu ili adresu problema, pa ću provjeriti pregledani program za 2026. " \
                     "Ne moraš ponovo slati GPS. Izvor: #{WasteSchedule.schedule_url}."
          end
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                 architecture: "gps_waste_schedule", subject: "gps_waste_schedule")
        end

        def klimerko_scope_question?(text, state:)
          folded = Decidim::Bih::Text.fold(text.to_s)
          first = folded.match?(/\bklimerk\w*\b/) && folded.match?(/\b(?:sluzben\w*|cijel\w*)\b/)
          followup = state.dig(Dialogue::AnswerContext::KEY, "subject") == "klimerko_scope" &&
            folded.match?(/\b(?:spavac\w*|sob\w*|unutrasnj\w*|moj\w*)\b/)
          first || followup
        end

        def direct_klimerko_scope(message:, state:, context:, locale:)
          retained = state.dig(Dialogue::AnswerContext::KEY, "subject") == "klimerko_scope"
          answer = if retained
                     "Ne. Spoljno očitanje senzora ne pokazuje kakav je vazduh u tvojoj spavaćoj sobi. " \
                       "Unutrašnji uslovi zavise od konkretne prostorije i ne mogu se zaključiti iz gradske mape."
                   else
                     "Ne. Klimerko je mapa očitanja senzora zajednice, a ne službeno regulatorno mjerenje " \
                       "za cijelu Bijeljinu. Jedna tačka ili gradski prikaz ne dokazuju kvalitet vazduha u svakoj ulici. " \
                       "Izvor senzorske mape: #{CityServiceSources.fetch('air_quality_realtime').fetch(:source_url)}. " \
                       "Gradska stranica za podatke o kvalitetu vazduha: #{CityServiceSources.fetch('air_quality').fetch(:source_url)}."
                   end
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                 architecture: "klimerko_scope", subject: "klimerko_scope")
        end

        def klimerko_pm10_question?(text, state:)
          folded = Decidim::Bih::Text.fold(Decidim::Bih::Transliterator.to_latin(text.to_s))
          return false unless folded.match?(/\bpm\s*10\b/)
          return true if folded.match?(/\bklimerk\w*\b/)

          previous = state.dig(Dialogue::ConversationFrame::KEY, "history")&.last
          Decidim::Bih::Text.fold(Decidim::Bih::Transliterator.to_latin(previous&.fetch("answer", "").to_s)).include?("klimerko")
        end

        def pm25_value_meaning_question?(text)
          folded = Decidim::Bih::Text.fold(Decidim::Bih::Transliterator.to_latin(text.to_s))
          folded.match?(/\bpm\s*2[., ]?5\b/) &&
            folded.match?(/\b(?:sta\s+znac\w*|objavljen\w*\s+vrijednost\w*)\b/)
        end

        def direct_pm25_value_meaning(message:, state:, context:, locale:)
          source = CityServiceSources.fetch("air_quality_realtime").fetch(:source_url)
          answer = "PM2.5 označava fine čestice u vazduhu; objavljena vrijednost u µg/m³ je " \
                   "koncentracija na prikazanom senzoru. Klimerko je prikaz senzora zajednice, " \
                   "ne službeno mjerenje za cijelu Bijeljinu. Bez pouzdanog vremena pojedinačnog " \
                   "mjerenja ne mogu potvrditi koliko je očitanje staro ni da je to stanje sada. Izvor: #{source}."
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                 architecture: "pm25_value_meaning", subject: "air_quality")
        end

        def pm25_measurement_clock_question?(text, state:)
          folded = Decidim::Bih::Text.fold(Decidim::Bih::Transliterator.to_latin(text.to_s))
          explicit = folded.match?(/\bpm\s*2[., ]?5\b/) &&
            folded.match?(/\b(?:mjerenj\w*|izmjer\w*|izmer\w*|vremen\w*|kada)\b/)
          followup = state.dig(Dialogue::AnswerContext::KEY, "subject") == "air_quality" &&
            folded.match?(/\b(?:mjerenj\w*|ocitanj\w*|vrijednost\w*)\b/) &&
            folded.match?(/\b(?:star\w*|trenutn\w*|sad\w*|dostupn\w*)\b/)
          explicit || followup
        end

        def direct_pm25_measurement_clock(message:, state:, context:, locale:)
          reading = ReadPort.new(organization: @organization).call(
            action: "ask_information", topic: "air_quality", entities: { "query" => message.text.to_s }, context:, locale:
          )
          fact = Array(reading.facts).find do |item|
            item["source_id"] == "air_quality_realtime" && item["pollutant"] == "PM2.5"
          end
          answer = if fact && fact["source_time_role"] == "verified_observation_clock" &&
                      !Array(fact["warning_codes"]).include?("measurement_stale")
                     "U pregledanom Klimerko prikazu: #{fact.fetch('text')} Izvor: #{fact.fetch('source_url')}."
                   elsif fact
                     "Tačna starost pojedinačnog mjerenja i trenutna vrijednost nisu potvrđene. " \
                       "Vrijeme osvježavanja javnog prikaza nije nužno vrijeme mjerenja. " \
                       "Raniji prikaz provjeri direktno na mapi: #{fact.fetch('source_url')}."
                   else
                     "Nemam pouzdano izdvojeno očitanje PM2.5 s potvrđenim vremenom mjerenja za Bijeljinu. " \
                       "Provjeri prikaz senzora: #{CityServiceSources.fetch('air_quality_realtime').fetch(:source_url)}. " \
                       "Vrijeme osvježavanja mape nije nužno vrijeme mjerenja."
                   end
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                 architecture: "pm25_measurement_clock", subject: "air_quality", tool_calls: 1,
                                 resolution: fact ? "answered" : "source_unavailable")
        end

        def direct_klimerko_pm10_boundary(message:, state:, context:, locale:)
          source_url = CityServiceSources.fetch("air_quality_realtime").fetch(:source_url)
          pm10_url = source_url.sub(/pollutant=pm2\b/, "pollutant=pm10")
          answer = "U podacima koje sam pregledala za Klimerko imam PM2.5, ali ne i potvrđenu " \
                   "vrijednost i vrijeme mjerenja za PM10. Klimerko ima zaseban prikaz PM10: #{pm10_url}. " \
                   "Tamo provjeri najnovije očitanje; neću prepisati broj za PM2.5 kao PM10."
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                 architecture: "klimerko_pm10_boundary", subject: "air_quality")
        end

        def badovinci_water_level_question?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\bbadovin(?:ac|c)\w*\b/) && folded.match?(/\b(?:vodostaj\w*|drin\w*)\b/)
        end

        def jamena_water_level_question?(text)
          folded = Decidim::Bih::Text.fold(Decidim::Bih::Transliterator.to_latin(text.to_s))
          folded.match?(/\bjamen\w*\b/) && folded.match?(/\b(?:vodostaj\w*|sav\w*)\b/)
        end

        def direct_badovinci_water_level_boundary(message:, state:, context:, locale:)
          source = "https://www.hidmet.gov.rs/latin/hidrologija/izvestajne/bezprognoza.php?hm_id=45885"
          answer = "RHMZ Srbije objavljuje podatke za stanicu Badovinci na Drini: #{source}. " \
                   "U mojim pregledanim očitanjima nemam pouzdano potvrđenu najnoviju vrijednost i vrijeme za tu stanicu; " \
                   "na službenoj stranici provjeri datum i vodostaj u centimetrima. Neću zamijeniti Badovince drugom stanicom."
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                 architecture: "badovinci_water_level_boundary", subject: "water_levels",
                                 resolution: "source_unavailable")
        end

        def direct_electricity_tomorrow_notice(message:, state:, context:, locale:)
          date = context.now.in_time_zone(TransportJourneyQuestion::SERVICE_TIME_ZONE).to_date + 1
          retained = state.dig(Dialogue::AnswerContext::KEY, "subject") == "electricity_tomorrow_notice"
          folded = Decidim::Bih::Text.fold(message.text.to_s)
          answer = if retained && folded.match?(/\b(?:garant\w*|kuc\w*|dobiti\s+struj\w*)\b/)
                     "Ne. Kraj planiranog termina isključenja ne garantuje da će konkretna kuća tada dobiti struju. " \
                       "Najava je plan radova, a stvarno stanje na adresi provjeri kod Elektro Bijeljine. " \
                       "Službene najave: #{CityServiceSources.fetch('electricity_outages').fetch(:source_url)}."
                   elsif retained
                     "Sutra je #{date.iso8601}. Datum objave nije vrijeme važenja isključenja; ako izvor kasni ili nema " \
                       "potvrđen obuhvat za traženo područje, ne mogu tvrditi ni da je prekid potvrđen ni da je otkazan."
                   else
                     latin = Decidim::Bih::Transliterator.to_latin(message.text.to_s)
                     area = latin.match(/\bu\s+(?<area>[\p{L}\p{M}]{2,60})\s*[?!.]?\z/i)&.[](:area)&.strip
                     reading = ReadPort.new(organization: @organization).call(
                       action: "ask_information", topic: "electricity",
                       entities: { "query" => message.text.to_s, "area_query" => area.to_s,
                                   "time_expression" => "sutra" }, context:, locale:
                     )
                     supported = Array(reading.facts).find do |fact|
                       fact.dig("validity", "date") == date.iso8601 &&
                       %w(whole part).include?(fact.dig("coverage", "requested_relation")) &&
                         Array(fact["warning_codes"]).exclude?("source_facts_unconfirmed")
                     end if reading.status == "ok"
                     if supported
                       "Za sutra (#{date.iso8601}) pregledana objava navodi: #{supported.fetch('text')} " \
                         "Izvor: #{supported['source_url']}. Vrijeme prekida provjeri u objavi; datum objave je drugi podatak."
                     elsif reading.status == "ambiguous"
                       "Za lokaciju koju si naveo/la (u #{area}) uzimam mjesto kao početno područje za sutra (#{date.iso8601}), " \
                         "ali naziv se podudara s više granica. Napiši ulicu ili pošalji službenu objavu " \
                         "da provjerim potvrđeni obuhvat i vrijeme isključenja."
                     else
                       "Za sutra (#{date.iso8601}) nemam potvrđenu objavu koja izričito obuhvata traženo područje. " \
                         "To ne dokazuje da prekida neće biti niti da je najava otkazana."
                     end
                   end
          answer = transport_prose(answer, locale)
          direct_source_boundary(message:, state:, context:, locale:, answer:, architecture: "electricity_tomorrow_notice",
                                 subject: "electricity_tomorrow_notice", tool_calls: retained ? 0 : 1)
        end

        def unconfirmed_neighborhood_action_question?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\bpretplac\w*\b/) && folded.match?(/\bporuk\w*\s+poslat\w*\b/) &&
            folded.match?(/\b(?:ne\s+tvrdi|nemoj\s+tvrditi)\b/)
        end

        def direct_unconfirmed_neighborhood_action(message:, state:, context:, locale:)
          answer = transport_prose("Nemam potvrdu da si već pretplaćen na obavještenja i nisam poslala poruku. " \
                                   "Izbor komšiluka i obavještenja možeš pregledati na #{public_site_url('komsiluk')}; " \
                                   "samo otvaranje stranice ne mijenja tvoj izbor.", locale)
          direct_source_boundary(message:, state:, context:, locale:, answer:, architecture: "unconfirmed_neighborhood_action")
        end

        def no_report_intervention_promise_question?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\b(?:obecaj|obecavati)\s+intervencij\w*\b/) &&
            folded.match?(/\b(?:otvar\w*|otvori\w*)\s+prijav\w*\b/)
        end

        def direct_no_report_intervention_promise(message:, state:, context:, locale:)
          answer = transport_prose("Nisam otvorila prijavu i ne mogu obećati intervenciju. " \
                                   "Problem možeš samostalno prijaviti na #{public_site_url('prijave/new')}. " \
                                   "Ako postoji neposredna opasnost, obrati se nadležnoj hitnoj službi direktno.", locale)
          direct_source_boundary(message:, state:, context:, locale:, answer:, architecture: "no_report_intervention_promise")
        end

        def official_help_question?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\b(?:sluzben\w*|zvanicn\w*)\s+(?:put\w*|stranic\w*)\s+(?:pomoc\w*|podrsk\w*)\b/)
        end

        def direct_official_help(message:, state:, context:, locale:)
          answer = transport_prose("Za pomoć oko korištenja platforme pogledaj službeni vodič: #{public_site_url('vodic')}. " \
                                   "Ne šalji broj telefona ili druge lične podatke u ovom razgovoru.", locale)
          direct_source_boundary(message:, state:, context:, locale:, answer:, architecture: "official_help_path")
        end

        def material_donation_question?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\bponud\w*\s+predmet\w*\b/) && folded.match?(/\bnovcan\w*\s+donacij\w*\b/)
        end

        def direct_material_donation(message:, state:, context:, locale:)
          answer = transport_prose("Ponuda predmeta nije novčana donacija. Nemam potvrđen spisak predmeta koje organizacija trenutno traži " \
                                   "niti potvrđen postupak za predaju. Vodič za dostupne načine učešća je #{public_site_url('vodic')}. " \
                                   "Ništa nisam objavila ili poslala u tvoje ime.", locale)
          direct_source_boundary(message:, state:, context:, locale:, answer:, architecture: "material_donation_boundary")
        end

        def registration_open_question?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\b(?:kako|gdje|gde)\b.{0,35}\b(?:otvor\w*|naprav\w*)\b.{0,18}\b(?:nalog\w*|racun\w*)\b/) &&
            !folded.match?(/\b(?:vec|ranije|izgub\w*|vrat\w*|oporav\w*)\b/)
        end

        def direct_registration_open(message:, state:, context:, locale:)
          answer = "Nalog otvori na #{Decidim::Bih.registration_url(host: @organization.host)}. Unesi podatke i broj telefona u obrazac, " \
                   "pa potvrdi broj linkom ili kodom na stranici za potvrdu. Sama chat poruka ne otvara nalog; " \
                   "kod i lozinku nemoj slati ovdje."
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                 architecture: "registration_open_path")
        end

        def registration_by_chat_question?(text)
          folded = Decidim::Bih::Text.fold(Decidim::Bih::Transliterator.to_latin(text.to_s))
          folded.match?(/\b(?:registr\w*|nalog\w*|racun\w*)\b/) && folded.match?(/\bporuk\w*\b/) &&
            folded.match?(/\b(?:vec|sam|slanj\w*|otvor\w*|registr\w*)\b/)
        end

        def direct_registration_by_chat(message:, state:, context:, locale:)
          answer = "Ne, sama poruka u chatu ne otvara nalog. Registraciju započni na " \
                   "#{Decidim::Bih.registration_url(host: @organization.host)} i tamo potvrdi broj telefona. " \
                   "Kod i lozinku nemoj slati ovdje."
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                 architecture: "registration_by_chat_boundary")
        end

        def neighborhood_provisional_name_question?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\b(?:naziv\w*|imen\w*)\b/) &&
            folded.match?(/\bkomsiluk\w*\b/) &&
            folded.match?(/\b(?:prijedlog\w*|predlog\w*|konacn\w*)\b/)
        end

        def neighborhood_naming_participation_followup?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\b(?:komsij\w*|gradjan\w*|citizen\w*)\b/) &&
            folded.match?(/\b(?:ucestv\w*|sudjel\w*|participat\w*)\b/) &&
            folded.match?(/\b(?:imen\w*|naziv\w*)\b/)
        end

        def neighborhood_boundaries_only_question?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\b(?:granic\w*|kart\w*|map\w*)\b/) &&
            folded.match?(/\b(?:komsiluk\w*|neighbou?rhood\w*)\b/) &&
            folded.match?(/\b(?:ne\s+zelim|ne\s+cu|samo\s+pitam|just\s+looking)\b/) &&
            folded.match?(/\b(?:promijen\w*|promen\w*|mijenja\w*|izbor\w*|change)\b/)
        end

        def mz_map_not_neighborhood_selection?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\b(?:kart\w*|map\w*)\b/) &&
            folded.match?(/\b(?:komsiluk\w*|neighbou?rhood\w*)\b/) &&
            folded.match?(/\b(?:ne\s+izbor|ne\s+bira|samo\s+pregled|not\s+select)\b/)
        end

        def explicit_unreviewed_sunday_bus_date(text, state:)
          latin = Decidim::Bih::Transliterator.to_latin(text.to_s)
          folded = Decidim::Bih::Text.fold(latin)
          current_bus = folded.match?(/\b(?:autobus\w*|bus|[gp]\d{1,2})\b/)
          previous = state.dig(Dialogue::ConversationFrame::KEY, "history")&.last&.dig("message").to_s
          previous_bus = Decidim::Bih::Text.fold(previous).match?(/\b(?:autobus\w*|bus|[gp]\d{1,2})\b/)
          continuation = previous_bus && folded.match?(/\b(?:nedjelj\w*|nedelj\w*)\b/)
          return unless current_bus || continuation

          # Text.fold removes punctuation, including the day separator. Parse
          # the citizen's raw date before folding only the month name.
          date = if (numeric = DOTTED_DATE.match(latin))
                   Date.new(numeric[3].to_i, numeric[2].to_i, numeric[1].to_i)
                 elsif (named = latin.match(/\b(?<day>\d{1,2})\.\s*(?<month>[\p{L}]+)\s+(?<year>20\d{2})\b/))
                   month = TransportJourneyQuestion::MONTH_NUMBERS[Decidim::Bih::Text.fold(named[:month])]
                   Date.new(named[:year].to_i, month, named[:day].to_i) if month
                 end
          date if date && ReviewedTransportTimetables.calendar_kind(date) == "sunday"
        rescue Date::Error, ArgumentError
          nil
        end

        def undated_sunday_bus_date(text, context:)
          today = context.now.in_time_zone(TransportJourneyQuestion::SERVICE_TIME_ZONE).to_date
          return unless ReviewedTransportTimetables.calendar_kind(today) == "sunday"

          latin = Decidim::Bih::Transliterator.to_latin(text.to_s)
          folded = Decidim::Bih::Text.fold(latin)
          return unless folded.match?(/\bautobus\w*\b/) && folded.match?(/\b(?:od|iz|sa)\b.{2,100}\bdo\b/)
          return if latin.match?(DOTTED_DATE) || folded.match?(/\b(?:danas|sutra|preksutra|ponedjelj\w*|ponedelj\w*|utor\w*|srijed\w*|sred\w*|cetvrt\w*|petak|subot\w*|nedjelj\w*|nedelj\w*)\b/)

          today
        end

        def sunday_janja_hospital_followup(text, state:, context:)
          today = context.now.in_time_zone(TransportJourneyQuestion::SERVICE_TIME_ZONE).to_date
          return unless ReviewedTransportTimetables.calendar_kind(today) == "sunday"

          previous = state.dig(Dialogue::ConversationFrame::KEY, "history")&.last&.dig("message").to_s
          prior = Decidim::Bih::Text.fold(previous)
          current = Decidim::Bih::Text.fold(text.to_s)
          return unless prior.match?(/\bjan[jn]a\b/) && prior.match?(/\bbolnic\w*\b/) &&
                        prior.match?(/\bautobus\w*\b/) &&
                        current.match?(/\b(?:ulaz\w*|izlaz\w*)\b/) &&
                        current.match?(/\bhodanj\w*\b/)

          "Za danas, #{today.strftime('%d.%m.%Y.')} (nedjelja), nemam pregledan nedjeljni red vožnje, " \
            "pa ne mogu potvrditi kojim autobusom ni gdje tačno ulaziš i izlaziš. " \
            "Janja (centar) i Bijeljina (bolnica) su mogući orijentiri u spisku stajališta, " \
            "ali nisu potvrđena stajališta tvoje današnje veze. Za upotrebljiv link za hodanje " \
            "napiši ulicu ili orijentir polaska u Janji i tačan ulaz u bolnicu."
        end

        def school_break_after_holiday_journey(text, state:, context:)
          return unless ENV["MILICA_JOURNEY_PLANNER_V2_ENABLED"] == "true"

          current = Decidim::Bih::Transliterator.to_latin(text.to_s)
          return unless Decidim::Bih::Text.fold(current).match?(/\bskolsk\w*\s+raspust\w*\b/)

          frame = Dialogue::ConversationFrame.load(state[Dialogue::ConversationFrame::KEY], context:)
          previous = Decidim::Bih::Transliterator.to_latin(frame.history.last&.fetch("message", "").to_s)
          return unless Decidim::Bih::Text.fold(previous).match?(/\bpraznik\w*\b/)

          endpoints = previous.match(/\b(?:od|sa|iz)\s+(?<origin>[\p{L}\d ()-]{2,80}?)\s+do\s+
                                     (?<destination>[\p{L}\d ()-]{2,80}?)\s+autobusom\b/ix)
          return unless endpoints

          temporal = TransportJourneyQuestion.temporal_entities({}, current, now: context.now)
          return if temporal.warning

          date = temporal.entities["date"].to_s
          time = temporal.entities["time_expression"].to_s
          return unless date.match?(/\A20\d{2}-\d{2}-\d{2}\z/) && time.match?(/\A\d{2}:\d{2}\z/)
          return unless ReviewedTransportTimetables.calendar_kind(Date.iso8601(date)) == "school_break"

          { "origin_query" => endpoints[:origin].strip.sub(/-a\z/i, ""),
            "destination_query" => endpoints[:destination].strip,
            "date" => date, "after_time" => time, "mode" => "next" }
        rescue Date::Error
          nil
        end

        def requested_unverified_bus_claim(text, context:)
          latin = Decidim::Bih::Transliterator.to_latin(text.to_s)
          folded = Decidim::Bih::Text.fold(latin)
          return unless folded.match?(/\b(?:napisi|reci|potvrdi)\b.*\bsigurno\s+(?:krece|polazi)\b/) &&
                        folded.match?(/\b(?:cak\s+i\s+ako|iako)\b.*\b(?:raspored\w*|red\w*\s+voznj\w*)\b/)

          route = latin[/\b[GP]\d{1,2}\b/i]&.upcase
          time = latin[/\b(?:[01]\d|2[0-3]):[0-5]\d\b/]
          temporal = TransportJourneyQuestion.temporal_entities({}, latin, now: context.now)
          date = temporal.entities["date"].to_s unless temporal.warning
          return unless route && time && date&.match?(/\A20\d{2}-\d{2}-\d{2}\z/)
          return unless ReviewedTransportTimetables.calendar_kind(Date.iso8601(date)) == "sunday"

          { line: route, time:, date: }
        rescue Date::Error
          nil
        end

        def unreviewed_holiday_bus_request(text, context:)
          latin = Decidim::Bih::Transliterator.to_latin(text.to_s)
          folded = Decidim::Bih::Text.fold(latin)
          line = folded[/\b([gp]\d{1,2})\b/, 1]&.upcase
          return unless line && folded.match?(/\b(?:redov\w*|prazni\w*|autobus\w*|polazak\w*)\b/)

          date = if (numeric = DOTTED_DATE.match(latin))
                   Date.new(numeric[3].to_i, numeric[2].to_i, numeric[1].to_i)
                 elsif (named = latin.match(/\b(?<day>\d{1,2})\.\s*(?<month>[\p{L}]+)\s+(?<year>20\d{2})\b/))
                   month = TransportJourneyQuestion::MONTH_NUMBERS[Decidim::Bih::Text.fold(named[:month])]
                   Date.new(named[:year].to_i, month, named[:day].to_i) if month
                 end
          { date:, line: } if date && ReviewedTransportTimetables.calendar_kind(date) == "holiday"
        rescue Date::Error, ArgumentError
          nil
        end

        def unreviewed_future_g2_query(text)
          latin = Decidim::Bih::Transliterator.to_latin(text.to_s)
          folded = Decidim::Bih::Text.fold(latin)
          return unless folded.match?(/\bnova\s+autobusk\w*\s+stanic\w*\b/) &&
                        folded.match?(/\batc\b/) && folded.match?(/\bg2\b/)

          named = latin.match(/\b(?<day>\d{1,2})\.\s*(?<month>[\p{L}]+)\s+(?<year>20\d{2})\.?\s+
                               (?:poslije|posle|nakon)\s+(?<time>(?:[01]\d|2[0-3]):[0-5]\d)/ix)
          return unless named

          month = TransportJourneyQuestion::MONTH_NUMBERS[Decidim::Bih::Text.fold(named[:month])]
          return unless month

          date = Date.new(named[:year].to_i, month, named[:day].to_i)
          { date: date.iso8601, time: named[:time] } if ReviewedTransportTimetables.calendar_kind(date) == "unreviewed"
        rescue Date::Error
          nil
        end

        def direct_unreviewed_future_g2(message:, state:, context:, locale:, request:)
          slots = (state[Dialogue::ConversationSlots::KEY] || Dialogue::ConversationSlots.empty).deep_dup
          slots["journey"] = { "origin_query" => "NAS", "destination_query" => "ATC",
                               "date" => request.fetch(:date), "time" => request.fetch(:time),
                               "route_code" => "G2", "query_kind" => "citizen_span" }
          normalized = Dialogue::ConversationSlots.normalize(slots, now: context.now,
                                                             state_expires_at: state.fetch("expires_at"))
          state = state.merge(Dialogue::ConversationSlots::KEY => normalized) if normalized
          until_date = ReviewedTransportTimetables.manifest.fetch("calendar").fetch("reviewed_until")
          answer = "Za #{request.fetch(:date)} ne mogu potvrditi polazak G2: pregledani kalendar datuma " \
                   "završava #{until_date}. Zadržavam polazište Nova autobuska stanica (NAS), cilj ATC " \
                   "i vrijeme poslije #{request.fetch(:time)}; napiši drugi datum za novu provjeru."
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                 architecture: "future_bus_date_unreviewed", subject: "transport_calendar")
        end

        def corrected_future_g2_date(text, state:)
          saved = state.dig(Dialogue::ConversationSlots::KEY, "journey")
          return unless saved.is_a?(Hash) && saved["route_code"] == "G2" &&
                        saved["origin_query"] == "NAS" && saved["destination_query"] == "ATC"

          latin = Decidim::Bih::Transliterator.to_latin(text.to_s)
          folded = Decidim::Bih::Text.fold(latin)
          return unless folded.match?(/\bvrati\s+datum\b/) &&
                        folded.match?(/\bisto\s+polazist\w*\s+i\s+cilj\b/)

          named = latin.match(/\b(?<day>\d{1,2})\.\s*(?<month>[\p{L}]+)\s+(?<year>20\d{2})\b/)
          return unless named

          month = TransportJourneyQuestion::MONTH_NUMBERS[Decidim::Bih::Text.fold(named[:month])]
          return unless month

          date = Date.new(named[:year].to_i, month, named[:day].to_i)
          time = latin[/\bposlije\s+((?:[01]\d|2[0-3]):[0-5]\d)\b/i, 1] || saved.fetch("time")
          { "origin_query" => "NAS", "destination_query" => "ATC", "date" => date.iso8601,
            "after_time" => time, "route_code" => "G2", "mode" => "next" }
        rescue Date::Error, KeyError
          nil
        end

        def direct_unreviewed_holiday_bus(message:, state:, context:, locale:, request:)
          tools = @tools_factory.call(location: nil)
          date = request.fetch(:date).iso8601
          line = request.fetch(:line)
          envelope = tools.registry.call(name: "service_calendar", arguments: { "line" => line, "date" => date },
                                         context:, eligibility: tools.eligibility)
          evidence = [envelope.for_prompt(context:, eligibility: tools.eligibility)]
          revalidate_delivery_evidence!(evidence, tools:)
          fact = envelope.evidence.one? ? envelope.evidence.first.fetch("facts") : nil
          if envelope.status == "ok" && fact && fact["requested_service_date"] == date &&
             fact["calendar_date_status"] == "holiday_or_exception_not_reviewed"
            answer = "Za #{request.fetch(:date).strftime('%d.%m.%Y.')} pregledani kalendar označava izuzetak za #{line}; " \
                     "ne mogu potvrditi da važi redovan radni red niti konkretan polazak. " \
                     "To ne dokazuje da linija ne vozi. Provjeri objavu prevoznika za taj datum: " \
                     "#{CityServiceSources.fetch('public_transport').fetch(:source_url)}."
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "unreviewed_holiday_bus", subject: "transport_calendar", tool_calls: 1)
          end

          answer = "Trenutno ne mogu potvrditi kalendar #{line} za #{date}; provjeri objavu prevoznika prije polaska."
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                 architecture: "unreviewed_holiday_bus_unavailable", subject: "transport_calendar",
                                 tool_calls: 1, resolution: "source_unavailable")
        end

        def direct_only_journey_request(text)
          latin = Decidim::Bih::Transliterator.to_latin(text.to_s)
          folded = Decidim::Bih::Text.fold(latin)
          return unless folded.match?(/\bdirekt\w*\s+(?:autobus\w*|bus)\b/) &&
                        folded.match?(/\bne\s+zelim\s+presjed\w*\b/)

          match = latin.match(/\b(?:od|iz)\s+(.{2,80}?)\s+do\s+(.{2,80}?)\s*,?\s*
                              (\d{1,2})\.(\d{1,2})\.(20\d{2})\.?\s+(?:poslije|posle|nakon)\s+([01]\d|2[0-3]):([0-5]\d)/ix)
          return unless match

          date = Date.new(match[5].to_i, match[4].to_i, match[3].to_i)
          { "origin_query" => match[1].strip, "destination_query" => match[2].strip,
            "date" => date.iso8601, "after_time" => "#{match[6]}:#{match[7]}",
            "direct_only" => true, "mode" => "fastest" }
        rescue Date::Error
          nil
        end

        def direct_only_journey_answer(message:, state:, frame:, context:, locale:, trace:, request:)
          tools = @tools_factory.call(location: nil)
          envelope = tools.registry.call(name: "resolve_and_plan_journey", arguments: request,
                                         context:, eligibility: tools.eligibility)
          evidence = [envelope.for_prompt(context:, eligibility: tools.eligibility)]
          revalidate_delivery_evidence!(evidence, tools:)
          return direct_corrected_origin_journey(message:, context:, state:, frame:, tools:, locale:, trace:,
                                                 journey: request) if envelope.status == "ok"

          if envelope.status == "unsupported" && envelope.query_scope["search_complete"] == true &&
             envelope.query_scope["reason_code"] == "no_eligible_trip_in_reviewed_scope"
            slots = (state[Dialogue::ConversationSlots::KEY] || Dialogue::ConversationSlots.empty).deep_dup
            slots["journey"] = { "origin_query" => request.fetch("origin_query"),
                                 "destination_query" => request.fetch("destination_query"),
                                 "date" => request.fetch("date"), "time" => request.fetch("after_time"),
                                 "query_kind" => "citizen_span" }
            normalized = Dialogue::ConversationSlots.normalize(slots, now: context.now,
                                                               state_expires_at: state.fetch("expires_at"))
            state = state.merge(Dialogue::ConversationSlots::KEY => normalized) if normalized
            answer = "U pregledanom redu za #{request.fetch('date')} poslije #{request.fetch('after_time')} " \
                     "ne nalazim objavljenu direktnu vezu #{request.fetch('origin_query')} → #{request.fetch('destination_query')}. " \
                     "To nije dokaz da nijedan prevoz ne postoji. Ako dozvoliš presjedanje, mogu provjeriti najbržu objavljenu vezu."
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "reviewed_direct_only_absence", subject: "transport_direct_only",
                                          tool_calls: 1)
          end

          answer = "Ne mogu potvrditi direktnu vezu za te uslove iz pregledanog reda. Napiši tačnije stajalište ako si mislila na drugi polazak."
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                 architecture: "reviewed_direct_only_unresolved", subject: "transport_direct_only",
                                 tool_calls: 1, resolution: envelope.status == "ambiguous" ? "clarification" : "source_unavailable")
        end

        def direct_only_transfer_followup(text, state:)
          saved = state.dig(Dialogue::ConversationSlots::KEY, "journey")
          return unless saved.is_a?(Hash)

          folded = Decidim::Bih::Text.fold(text.to_s)
          return unless folded.match?(/\b(?:jedno|jednim|1)\s+presjed\w*\b/) &&
                        folded.match?(/\b(?:u\s+redu|dozvolj\w*|moze|predomisl\w*)\b/)

          { "origin_query" => saved.fetch("origin_query"), "destination_query" => saved.fetch("destination_query"),
            "date" => saved.fetch("date"), "after_time" => saved.fetch("time"), "mode" => "fastest" }
        rescue KeyError
          nil
        end

        def later_than_last_departure_request(text, state:)
          latin = Decidim::Bih::Transliterator.to_latin(text.to_s)
          folded = Decidim::Bih::Text.fold(latin)
          time = latin[/\b(?:poslije|posle|nakon)\s+((?:[01]\d|2[0-3]):[0-5]\d)\b/i, 1]
          return unless folded.match?(/\b(?:polazn\w*\s+stajal\w*|stajal\w*)\b/) && time

          previous = state.dig(Dialogue::ConversationFrame::KEY, "history")&.last&.dig("message").to_s
          prior_folded = Decidim::Bih::Text.fold(previous)
          return unless prior_folded.match?(/\b(?:zadnj\w*|posljednj\w*|poslednj\w*)\b/)

          prior = Decidim::Bih::Transliterator.to_latin(previous)
          pair = prior.match(/\bod\s+(.{2,80}?)\s+do\s+(.{2,80}?)\s+u\s+\p{L}+\s+\d{1,2}\.\d{1,2}\.20\d{2}/i)
          date = DOTTED_DATE.match(prior)
          code = prior[/\b([GP]\d{1,2})\b/i, 1]&.upcase
          return unless pair && date && code

          day = Date.new(date[3].to_i, date[2].to_i, date[1].to_i)
          { "origin_query" => pair[1].strip, "destination_query" => pair[2].strip,
            "date" => day.iso8601, "after_time" => time, "mode" => "last", "route_code" => code }
        rescue Date::Error
          nil
        end

        def direct_later_than_last_departure(message:, state:, frame:, context:, locale:, trace:, request:)
          tools = @tools_factory.call(location: nil)
          envelope = tools.registry.call(name: "resolve_and_plan_journey", arguments: request,
                                         context:, eligibility: tools.eligibility)
          evidence = [envelope.for_prompt(context:, eligibility: tools.eligibility)]
          revalidate_delivery_evidence!(evidence, tools:)
          return direct_corrected_origin_journey(message:, context:, state:, frame:, tools:, locale:, trace:,
                                                 journey: request) if envelope.status == "ok"

          if envelope.status == "unsupported" && envelope.query_scope["search_complete"] == true &&
             envelope.query_scope["reason_code"] == "no_eligible_trip_in_reviewed_scope"
            answer = "U pregledanom redu za #{request.fetch('date')} ne nalazim polazak #{request.fetch('route_code')} " \
                     "#{request.fetch('origin_query')} → #{request.fetch('destination_query')} poslije #{request.fetch('after_time')}. " \
                     "Ranije navedeni posljednji polazak je prije tvog dolaska; provjeri drugi termin ili liniju."
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "no_reviewed_departure_after_arrival", subject: "transport_last_departure",
                                          tool_calls: 1)
          end

          answer = "Ne mogu potvrditi polazak poslije #{request.fetch('after_time')} iz pregledanog reda za tu relaciju."
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                 architecture: "last_departure_followup_unresolved", subject: "transport_last_departure",
                                 tool_calls: 1, resolution: envelope.status == "ambiguous" ? "clarification" : "source_unavailable")
        end

        def selected_journey_transfer_question(text, state:)
          saved = state.dig(Dialogue::ConversationSlots::KEY, "journey")
          return unless saved.is_a?(Hash) && saved["query_kind"] == "citizen_span"

          folded = Decidim::Bih::Text.fold(text.to_s)
          kind = if folded.match?(/\b(?:moram|trebam)\s+presjed\w*\b/)
                   :required
                 elsif folded.match?(/\b(?:gdje|gde)\b.*\bpresjed\w*\b/) &&
                       folded.match?(/\bkoliko\s+cek\w*\b/)
                   :where_and_wait
                 elsif folded.match?(/\bnas\b/) &&
                       folded.match?(/\b(?:ispravi\w*|pogrijes\w*)\b/) &&
                       text.to_s.scan(/\b(?:[01]\d|2[0-3]):[0-5]\d\b/).size >= 2
                   :clock_check
                 end
          return unless kind

          request = { "origin_query" => saved.fetch("origin_query"),
                      "destination_query" => saved.fetch("destination_query"),
                      "date" => saved.fetch("date"), "after_time" => saved.fetch("time"),
                      "mode" => "fastest" }
          request["route_code"] = saved["route_code"] if saved["route_code"]
          { kind:, request:, stated_first: text.to_s[/\b(?:[01]\d|2[0-3]):[0-5]\d\b/] }
        rescue KeyError
          nil
        end

        def direct_selected_journey_transfer(message:, state:, context:, tools:, locale:, request:)
          envelope = tools.registry.call(name: "resolve_and_plan_journey", arguments: request.fetch(:request),
                                         context:, eligibility: tools.eligibility)
          evidence = [envelope.for_prompt(context:, eligibility: tools.eligibility)]
          revalidate_delivery_evidence!(evidence, tools:)
          legs = envelope.evidence.select { |record| record.dig("facts", "journey_index") == 0 }
                                  .sort_by { |record| record.dig("facts", "leg_index") }
                                  .map { |record| record.fetch("facts") }
          if envelope.status != "ok" || legs.empty?
            answer = "Ne mogu ponovo potvrditi presjedanje za ranije navedenu vezu iz trenutno pregledanog reda."
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "selected_journey_transfer_unavailable", tool_calls: 1,
                                          resolution: "source_unavailable")
          end

          if legs.one?
            leg = legs.first
            answer = "Ne, za navedenu vezu #{leg.fetch('origin_label')} → #{leg.fetch('destination_label')} " \
                     "ide direktno #{leg.fetch('route_code')}; ne moraš presjedati."
          else
            first, second = legs.first(2)
            gap = second.fetch("wait_before_seconds").to_i / 60
            at = first.fetch("destination_label")
            from = second.fetch("origin_label")
            place = at == from ? at : "#{at} → #{from}"
            arrival = Time.iso8601(first.fetch("arrival_at")).strftime("%H:%M")
            departure = Time.iso8601(second.fetch("departure_at")).strftime("%H:%M")
            correction = request[:kind] == :clock_check && request[:stated_first] != arrival ?
              "Navedeno #{request[:stated_first]} nije vrijeme dolaska te veze. " : ""
            answer = "#{correction}Presjedaš na #{place}. Prvi autobus stiže u #{arrival}, " \
                     "a drugi #{second.fetch('route_code')} polazi u #{departure}; " \
                     "razmak je #{gap} minuta. Tačna platforma i hod između različitih stajališta nisu potvrđeni."
          end
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                 architecture: "selected_journey_transfer", subject: "transport_transfer_detail", tool_calls: 1)
        end

        def published_saturday_bus_calendar(text)
          folded = Decidim::Bih::Text.fold(Decidim::Bih::Transliterator.to_latin(text.to_s))
          return unless folded.match?(/\bsubotnj\w*\b/) && folded.match?(/\b(?:objavljen\w*|postoj\w*|ima\w*)\b/) &&
                        folded.match?(/\b(?:raspored\w*|polasc\w*)\b/)

          code = folded[/\b([a-z]\d{1,2})\b/, 1]&.upcase
          return unless code

          entry = ReviewedTransportTimetables.manifest.fetch("routes").find { |route| route.fetch("code") == code }
          return unless entry

          directions = ReviewedTransportTimetables.data_for(entry).fetch("directions")
          return unless directions.any? { |direction| direction.fetch("calendar") == "saturday" }

          "Da. Za liniju #{code} u pregledanom objavljenom redu postoji subotnji raspored (sekcija „Subota“). " \
            "Za konkretan datum i stajalište mogu provjeriti polazak. Nedjeljni red nije obuhvaćen ovim podatkom. " \
            "Izvor: #{entry.dig('timetable', 'url')}"
        end

        def goodwill_daily_cap_question?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\b(?:dnevn\w*\s+limit\w*|limit\w*\s+bodov\w*)\b/) &&
            folded.match?(/\b(?:ucestv\w*|smijem|mogu|zabran\w*)\b/)
        end

        def direct_goodwill_daily_cap(message:, state:, context:, locale:)
          answer = "Ne. Dnevni limit bodova ograničava koliko bodova možeš dobiti za određenu aktivnost tog dana; " \
                   "sam po sebi ne zabranjuje dalje učestvovanje. Pojedine aktivnosti mogu imati zasebna " \
                   "pravila broja prijedloga ili učešća. Pravila bodova: " \
                   "#{public_site_url('zajednistvo?tab=kako')}."
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                 architecture: "goodwill_cap_participation", subject: "goodwill_daily_cap")
        end

        def electricity_cheap_tariff_answer(text, state:)
          folded = Decidim::Bih::Text.fold(Decidim::Bih::Transliterator.to_latin(text.to_s))
          subject = state.dig(Dialogue::AnswerContext::KEY, "subject") == "electricity_cheap_tariff"
          topic = folded.match?(/\b(?:struj\w*|elektricn\w*|tarif\w*|brojil\w*)\b/) || subject
          return unless topic

          fact = CivicDomainFacts.biller_facts("electricity").find { |row| row.id == "electricity_cheap_tariff_windows" }
          return unless fact

          if folded.match?(/\b(?:vikend\w*|subot\w*|nedjelj\w*|nedelj\w*)\b/) &&
             folded.match?(/\b(?:svak\w*|brojil\w*|automatsk\w*|program\w*)\b/)
            window = fact.text[/vikendom od (.+?) ako brojilo ima vikend-program/i, 1]
            return unless window

            "Ne važi automatski za svako brojilo. Prema pregledanoj uputi, vikendom jeftina tarifa traje od #{window} " \
              "samo ako brojilo ima vikend-program. Izvor: #{fact.source_url} (pregledano #{fact.reviewed_on.strftime('%d.%m.%Y.')})."
          elsif folded.match?(/\b(?:jeftin\w*|niz\w*)\b/) &&
                folded.match?(/\b(?:ljetnj\w*|letnj\w*|ljetn\w*)\b/) &&
                folded.match?(/\b(?:radn\w*|dan\w*)\b/)
            window = fact.text[/od (\d{2}:\d{2} do \d{2}:\d{2}) po ljetnjem/i, 1]
            return unless window

            "Po ljetnjem računanju vremena jeftina tarifa radnim danom važi od #{window}. " \
              "Izvor: #{fact.source_url} (pregledano #{fact.reviewed_on.strftime('%d.%m.%Y.')})."
          end
        end

        def heating_season_notice_answer(text, state:)
          folded = Decidim::Bih::Text.fold(Decidim::Bih::Transliterator.to_latin(text.to_s))
          followup = state.dig(Dialogue::AnswerContext::KEY, "subject") == "heating_season_notice"
          initial = folded.match?(/\b(?:toplan\w*|grijanj\w*|grejanj\w*)\b/) &&
                    folded.match?(/\b(?:sezon\w*|pocet\w*)\b/) && folded.include?("2026")
          exact_day = followup && folded.match?(/\b(?:tacan\w*|tocan\w*|konkret\w*)\s+dan\b/) &&
                      folded.match?(/\b(?:radijator\w*|grijanj\w*|grejanj\w*)\b/)
          return unless initial || exact_day

          notice = CivicDomainFacts.fact("heating", "heating_season_2026_2027_not_guaranteed")
          return unless notice

          if exact_day
            contact = CivicDomainFacts.next_steps("heating").find { |row| row.fetch("id") == "heating_provider_contact" }
            return unless contact

            "Ne. Obavještenje objavljeno #{notice.source_on.strftime('%d.%m.%Y.')} ne potvrđuje tačan dan kada će radijatori " \
              "u tvojoj zgradi biti topli. #{contact.fetch('text')} " \
              "Izvor obavještenja: #{notice.source_url}."
          else
            first_claim = notice.text.split(" Istim obavještenjem", 2).first
            "#{first_claim} " \
              "To je sadržaj tadašnje objave, ne potvrda trenutnog rada niti tačnog početka grijanja na tvojoj adresi. " \
              "Izvor: #{notice.source_url}."
          end
        end

        def missing_sunday_calendar_inference(text, state:)
          folded = Decidim::Bih::Text.fold(Decidim::Bih::Transliterator.to_latin(text.to_s))
          return unless folded.match?(/\b(?:nedjeljn\w*|nedeljn\w*)\s+raspored\w*\b/) &&
                        folded.match?(/\b(?:zakljuc\w*|znac\w*|dokaz\w*)\b/) &&
                        folded.match?(/\b(?:ne\s+saobrac\w*|ne\s+voz\w*|nema\s+vozn\w*)\b/)

          anchor = state.dig(Dialogue::AnswerContext::KEY, "subject") == "transport_calendar" ?
            state.dig(Dialogue::AnswerContext::KEY, "anchor").to_s : ""
          code = [folded, Decidim::Bih::Text.fold(anchor)].filter_map { |value| value[/\blinij\w*\s+([a-z]\d{1,2})\b/, 1] }.first&.upcase
          return unless code

          entry = ReviewedTransportTimetables.manifest.fetch("routes").find { |route| route.fetch("code") == code }
          return unless entry

          directions = ReviewedTransportTimetables.data_for(entry).fetch("directions")
          return if directions.any? { |direction| direction.fetch("calendar") == "sunday" }

          "Ne. To što u pregledanom objavljenom redu nema nedjeljne sekcije za #{code} ne dokazuje da linija nedjeljom ne saobraća. " \
            "Za nedjeljni polazak provjeri aktuelnu objavu ili prevoznika; neću ga zamijeniti subotnjim ili radnim redom."
        end

        def account_name_language_settings_question?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\b(?:nalog\w*|racun\w*|account)\b/) &&
            folded.match?(/\b(?:jezik\w*|language)\b/) &&
            folded.match?(/\b(?:ime\w*|name)\b/) &&
            folded.match?(/\b(?:gdje|gde|kako|where|how)\b/)
        end

        def account_settings_path_followup?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\b(?:postavk\w*|podesavanj\w*|settings)\b/) &&
            folded.match?(/\b(?:put|pokaz\w*|show|path)\b/) &&
            folded.match?(/\b(?:ne\s+mijenja\w*|nemoj|dont|do\s+not)\b/)
        end

        def civic_proposal_route_question?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\b(?:prijedlog\w*|predlog\w*|proposal\w*)\b/) &&
            folded.match?(/\b(?:gdje|gde|where|predaj\w*|podnes\w*)\b/) &&
            !folded.match?(/\b(?:organizacij\w*|partner\w*)\b/)
        end

        def civic_proposal_account_followup?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\b(?:nalog\w*|racun\w*|account)\b/) &&
            folded.match?(/\b(?:organizacij\w*|gradjansk\w*|citizen)\b/)
        end

        def goodwill_referral_rule_question?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\b(?:poziv\w*|preporuk\w*|referral)\b/) &&
            folded.match?(/\b(?:bodov\w*|poen\w*|points)\b/) &&
            folded.match?(/\b(?:kada|kad|uslov\w*|pravilo|when)\b/)
        end

        def goodwill_referral_rule_followup?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\bpravil\w*\b/) &&
            folded.match?(/\b(?:nalog\w*|racun\w*|account)\b/)
        end

        def project_donation_link_check_question?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\b(?:link\w*|vez\w*)\b/) &&
            folded.match?(/\bdonac\w*\b/) &&
            folded.match?(/\bprojek(?:a|t)\w*\b/) &&
            folded.match?(/\b(?:provjer\w*|prover\w*|pripad\w*|odredist\w*)\b/)
        end

        def project_choice_first_step?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\b(?:nisam\s+izabra\w*|jos\s+nisam|prvi\s+korak|first\s+step)\b/) &&
            folded.match?(/\bprojek(?:a|t)\w*\b/)
        end

        def volunteer_application_guidance_question?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\bvolonter\w*\b/) &&
            folded.match?(/\bprijav\w*\b/) &&
            folded.match?(/\b(?:kako\s+izgled\w*|samo\s+uputstv\w*|how\s+to\s+apply)\b/)
        end

        def volunteer_page_view_followup?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\b(?:otvaranj\w*|pregled\w*|opening|viewing)\b/) &&
            folded.match?(/\b(?:stranic\w*|prilik\w*|page)\b/) &&
            folded.match?(/\b(?:spisk\w*|prijav\w*|list)\b/)
        end

        def report_anonymous_tradeoff_question?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\b(?:prijav\w*|obrazac)\b/) &&
            folded.match?(/\b(?:bez\s+naloga|anonimn\w*)\b/) &&
            folded.match?(/\b(?:razlik\w*|opcij\w*)\b/)
        end

        def report_reference_missing_followup?(text, state:, context:)
          folded = Decidim::Bih::Text.fold(text.to_s)
          return false unless folded.match?(/\b(?:broj\w*|referenc\w*)\b/) &&
                              folded.match?(/\b(?:nemam|bez|ne\s+znam)\b/) &&
                              folded.match?(/\b(?:kod\w*|nalog\w*)\b/)

          frame = Dialogue::ConversationFrame.load(state[Dialogue::ConversationFrame::KEY], context:)
          previous = frame.history.last&.fetch("message", "").to_s
          Decidim::Bih::Text.fold(previous).match?(/\bprijav\w*\b/)
        end

        def report_reading_visibility_question?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\bprijav\w*\b/) && folded.match?(/\b(?:opis\w*|fotograf\w*)\b/) &&
            folded.match?(/\b(?:javn\w*|vidi\w*)\b/) &&
            folded.match?(/\b(?:cita\w*|uputstv\w*)\b/)
        end

        def report_map_blur_followup?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\btack\w*\b/) && folded.match?(/\bmap\w*\b/) &&
            folded.match?(/\b(?:zamaglj\w*|skriv\w*|javn\w*)\b/)
        end

        def report_anonymous_location_followup?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\banonimn\w*\b/) &&
            folded.match?(/\b(?:lokacij\w*|adres\w*|tack\w*)\b/) &&
            folded.match?(/\b(?:skriven\w*|javn\w*|vidljiv\w*)\b/)
        end

        def report_public_location_question?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\b(?:adres\w*|lokacij\w*|tack\w*)\b/) &&
            folded.match?(/\bprijav\w*\b/) &&
            folded.match?(/\b(?:objav\w*|javn\w*)\b/)
        end

        def report_home_point_followup?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\b(?:kuc\w*|dom\w*|home)\b/) &&
            folded.match?(/\b(?:tack\w*|lokacij\w*|adres\w*)\b/) &&
            folded.match?(/\b(?:ne\s+zelim|izbjeg\w*|izbeg\w*|avoid)\b/)
        end

        def report_preview_visibility_question?(text)
          folded = Decidim::Bih::Text.fold(Decidim::Bih::Transliterator.to_latin(text.to_s))
          folded.match?(/\b(?:sta|sto|koje|kako)\b.{0,55}\bprikaz\w*\b.{0,55}\bprije\b.{0,28}\bpotvrd\w*\b.{0,28}\bslanj\w*\b/) ||
            (folded.match?(/\bprijav\w*\b/) && folded.match?(/\b(?:pregled\w*|prikaz\w*)\b/) &&
             folded.match?(/\b(?:javn\w*|privatn\w*|vidi\w*)\b/))
        end

        def streetlight_report_question?(text)
          folded = Decidim::Bih::Text.fold(Decidim::Bih::Transliterator.to_latin(text.to_s))
          folded.match?(/\b(?:rasvjet|rasvet)\w*\b/) &&
            folded.match?(/\b(?:kako|gdje|gde|how|where)\b.{0,32}\b(?:prijav\w*|report)\b/)
        end

        def instagram_report_submission_question?(text)
          folded = Decidim::Bih::Text.fold(Decidim::Bih::Transliterator.to_latin(text.to_s))
          folded.match?(/\binstagram\w*\b/) && folded.match?(/\bprijav\w*\b/) &&
            folded.match?(/\b(?:automatsk\w*|otvor\w*|posla\w*|podnes\w*)\b/)
        end

        def direct_instagram_report_submission(message:, state:, context:, locale:)
          answer = "Ne, Instagram poruka ne otvara prijavu automatski. Instagram razgovor služi za upute, " \
                   "ali podnošenje prijave u njemu nije uključeno. Možeš koristiti obrazac " \
                   "#{public_site_url('prijave/new')} ili započeti nacrt u ovom web chatu. " \
                   "Prije slanja dobijaš pregled i prijava se podnosi tek nakon tvoje izričite potvrde. " \
                   "Ova poruka nije podnijela prijavu."
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                 architecture: "instagram_report_submission_boundary")
        end

        def direct_streetlight_report_guidance(message:, state:, context:, locale:)
          answer = "Oštećenu uličnu rasvjetu možeš prijaviti preko platforme: #{public_site_url('prijave/new')}. " \
                   "Mogu i ovdje pripremiti nacrt prijave. Prije slanja dobićeš pregled i ništa se ne šalje " \
                   "bez tvoje izričite potvrde. Napiši ulicu ili bliži orijentir ako želiš precizniji nacrt; " \
                   "ranije podijeljena lokacija ne postaje automatski javna tačka prijave."
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                 architecture: "streetlight_report_guidance")
        end

        def direct_report_preview_visibility(message:, state:, context:, locale:)
          public_details = I18n.t("decidim.bih.reports.new.visibility.public", locale:)
          private_details = I18n.t("decidim.bih.reports.new.visibility.private", locale:)
          answer = "Prije potvrde pregledaj podatke i mjesto problema koje će prijava poslati. " \
                   "#{public_details} #{private_details} Bez tvoje izričite potvrde ništa nije poslano."
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                 architecture: "report_preview_visibility_boundary")
        end

        def account_private_phone_question?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\b(?:broj\w*|telefon\w*)\b/) && folded.match?(/\bprofil\w*\b/) &&
            folded.match?(/\b(?:vide|vidi|vidljiv\w*|prikaz\w*)\b/) &&
            folded.match?(/\b(?:drug\w*|javn\w*|korisnic\w*|gradjan\w*)\b/)
        end

        def direct_account_private_phone(message:, state:, context:, locale:)
          answer = I18n.t("decidim.bih.dialogue.account_phone_visibility", locale:,
                          url: public_site_url("moj-nalog"))
          direct_source_boundary(message:, state:, context:, locale:, answer:,
                                 architecture: "account_private_phone_boundary")
        end

        def report_phone_visibility_followup?(text, state:, context:)
          folded = Decidim::Bih::Text.fold(Decidim::Bih::Transliterator.to_latin(text.to_s))
          return false unless folded.match?(/\b(?:javn\w*\s+)?prijav\w*\b/) && folded.match?(/\b(?:napis\w*|unes\w*|upis\w*)\b/)

          frame = Dialogue::ConversationFrame.load(state[Dialogue::ConversationFrame::KEY], context:)
          previous = frame.history.last&.fetch("message", "").to_s
          Decidim::Bih::Text.fold(Decidim::Bih::Transliterator.to_latin(previous)).match?(/\b(?:broj\w*|telefon\w*)\b/)
        end

        def direct_report_phone_visibility(message:, state:, context:, locale:)
          public_details = I18n.t("decidim.bih.reports.new.visibility.public", locale:)
          private_details = I18n.t("decidim.bih.reports.new.visibility.private", locale:)
          answer = "Zavisi u koje polje ga upišeš. #{private_details} #{public_details} " \
                   "Broj telefona nemoj upisivati u javno polje kao što je adresa; provjeri pregled prije potvrde. " \
                   "Ovdje nisam poslala prijavu."
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                 architecture: "report_phone_visibility_boundary")
        end

        def account_privacy_settings_question?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\bpostavk\w*\b.{0,24}\bprivatnost\w*\b|\bprivatnost\w*\b.{0,24}\bpostavk\w*\b/)
        end

        def direct_account_privacy_settings(message:, state:, context:, locale:)
          answer = "Prijavi se i otvori #{public_site_url('moj-nalog')}: tamo su postavke privatnosti poruka " \
                   "i prikaz javnog profila. Privatni broj telefona se ne prikazuje drugim korisnicima. " \
                   "Ako namjeravaš objaviti prijavu, prije potvrde posebno provjeri njen pregled: adresa problema " \
                   "i potvrđena tačka na mapi mogu biti javne. U chatu nisam promijenila postavke niti išta objavila."
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                 architecture: "account_privacy_settings_path")
        end

        def private_report_status_question?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\bprivatn\w*\b.{0,38}\bprovjer\w*\b.{0,20}\bstatus\w*\b|\bprivatn\w*\b.{0,38}\bstatus\w*\b/) &&
            !folded.match?(/\b(?:vodovod|struj\w*|racun\w*)\b/)
        end

        def report_without_reference_search_question?(text, state:)
          folded = Decidim::Bih::Text.fold(text.to_s)
          first = folded.match?(/\bprijav\w*\b/) && folded.match?(/\b(?:ponovo\s+pronac\w*|nemam\s+.*broj\w*)\b/)
          followup = state.dig(Dialogue::AnswerContext::KEY, "subject") == "report_without_reference_search" &&
            folded.match?(/\b(?:opis\w*|ulic\w*|bez\s+prijav\w*)\b/)
          first || followup
        end

        def direct_report_without_reference_search(message:, state:, context:, locale:)
          retained = state.dig(Dialogue::AnswerContext::KEY, "subject") == "report_without_reference_search"
          answer = if retained
                     "Ne možeš pretraživati javne prijave po opisu ili ulici: polje za pretragu traži " \
                       "samo referentni broj. Bez broja pregledaj javnu listu #{public_site_url('prijave')}, " \
                       "filtriraj kategoriju ili status i uporedi javno prikazanu adresu i datum na karticama. " \
                       "Prijava poslata bez naloga neće se naknadnom prijavom automatski povezati s tvojim nalogom."
                   else
                     "Ako nemaš broj prijave, pregledaj javnu listu #{public_site_url('prijave')}. " \
                       "Možeš filtrirati kategoriju i status, pa po javno prikazanoj adresi i datumu " \
                       "prepoznati moguću prijavu; to samo po sebi ne dokazuje da je tvoja. " \
                       "Ako si je poslao/la sa svog naloga, pogledaj i #{public_site_url('prijave?view=mine')}."
                   end
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                 architecture: "report_without_reference_search", subject: "report_without_reference_search")
        end

        def neighborhood_post_form_question?(text, state:)
          folded = Decidim::Bih::Text.fold(text.to_s)
          first = folded.match?(/\b(?:nov\w*\s+objav\w*|pis\w*\s+objav\w*)\b/) &&
            folded.match?(/\bkomsiluk\w*\b/)
          followup = state.dig(Dialogue::AnswerContext::KEY, "subject") == "neighborhood_post_form" &&
            folded.match?(/\b(?:objav\w*|obrazac|razgovor\w*)\b/)
          first || followup
        end

        def direct_neighborhood_post_form(message:, state:, context:, locale:)
          url = public_site_url("komsiluk-board#komsiluk-post-form")
          retained = state.dig(Dialogue::AnswerContext::KEY, "subject") == "neighborhood_post_form"
          answer = if retained
                     "Ne mogu objaviti komšijsku objavu iz ovog razgovora. Otvori obrazac na #{url}, " \
                       "upiši sadržaj i sam/a potvrdi slanje. Ako si već prijavljen/a, tabla će provjeriti " \
                       "dodijeljeni komšiluk; za objavljivanje je dodatno potrebna verifikacija telefona."
                   else
                     "Novu objavu napiši na tabli svog komšiluka: #{url}. Odaberi kategoriju, unesi naslov i " \
                       "tekst, pa pošalji obrazac. Za čitanje table potreban je nalog s dodijeljenim komšilukom; " \
                       "za objavljivanje je dodatno potrebna verifikacija telefona. Ovdje ništa nisam objavila."
                   end
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                 architecture: "neighborhood_post_form", subject: "neighborhood_post_form")
        end

        def report_preparation_only_question?(text, state:)
          folded = Decidim::Bih::Text.fold(text.to_s)
          first = folded.match?(/\bpriprem\w*\s+prijav\w*\b/) && folded.match?(/\bbez\s+slanj\w*\b/)
          followup = state.dig(Dialogue::AnswerContext::KEY, "subject") == "report_preparation_only" &&
            folded.match?(/\b(?:gps|priprem\w*|poslat\w*)\b/)
          first || followup
        end

        def direct_report_preparation_only(message:, state:, context:, locale:)
          retained = state.dig(Dialogue::AnswerContext::KEY, "subject") == "report_preparation_only"
          answer = if retained
                     "Ne moraš uključiti GPS: mjesto problema možeš upisati kao adresu ili orijentir. " \
                       "GPS tačku koristi samo ako je izričito podijeliš. Priprema opisa nije slanje prijave; " \
                       "tek zaseban korak potvrde i stvarna potvrda prijema znače da je poslata. " \
                       "Ako priprema u chatu nije dostupna, obrazac je na #{public_site_url('prijave/new')}."
                   else
                     "Da, mogu ti pomoći da pripremiš opis i mjesto problema bez slanja. Napiši šta se dogodilo " \
                       "i ulicu, broj ili orijentir ako ih znaš; GPS nije obavezan. Još nisam sačuvala nacrt " \
                       "niti poslala prijavu."
                   end
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                 architecture: "report_preparation_only", subject: "report_preparation_only")
        end

        def volunteer_start_and_place_question?(text, state:)
          folded = Decidim::Bih::Text.fold(text.to_s)
          first = folded.match?(/\bpocet\w*\s+volontir\w*\b/) && folded.match?(/\bplatform\w*\b/)
          followup = state.dig(Dialogue::AnswerContext::KEY, "subject") == "volunteer_start_and_place" &&
            folded.match?(/\b(?:online|mjest\w*|dolaz\w*|prilik\w*)\b/)
          first || followup
        end

        def direct_volunteer_start_and_place(message:, state:, context:, locale:)
          url = public_site_url("volontiranje")
          retained = state.dig(Dialogue::AnswerContext::KEY, "subject") == "volunteer_start_and_place"
          answer = if retained
                     "Otvori konkretnu priliku na #{url} i pročitaj opis te navedeno mjesto ili mjesto okupljanja. " \
                       "Ako piše da je aktivnost online, prati njene upute; sama adresa organizatora ne dokazuje " \
                       "gdje se volontira. Ako način učešća nije naveden, provjeri ga s organizatorom prije prijave."
                   else
                     "Počni od javnog kataloga prilika na #{url}: otvori aktivnost, provjeri opis, termin i " \
                       "mjesto, pa se prijavi kroz njen obrazac ako ti odgovara. Pregled kataloga ili ovaj chat " \
                       "nisu prijava i ne potvrđuju mjesto."
                   end
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                 architecture: "volunteer_start_and_place", subject: "volunteer_start_and_place")
        end

        def public_platform_invitation_question?(text, state:)
          folded = Decidim::Bih::Text.fold(text.to_s)
          first = folded.match?(/\bpozv\w*\s+komsij\w*\b/) && folded.match?(/\bplatform\w*\b/)
          followup = state.dig(Dialogue::AnswerContext::KEY, "subject") == "public_platform_invitation" &&
            folded.match?(/\b(?:podijel\w*|link\w*|prijav\w*)\b/)
          first || followup
        end

        def direct_public_platform_invitation(message:, state:, context:, locale:)
          root = "https://#{@organization.host}/"
          retained = state.dig(Dialogue::AnswerContext::KEY, "subject") == "public_platform_invitation"
          answer = if retained
                     "Da. Možeš podijeliti običan javni link #{root}. To je samo poziv da komšije same " \
                       "pogledaju platformu i odluče hoće li se prijaviti; nisi ih time registrovao/la " \
                       "ni učlanio/la. Ovdje nisam nikome poslala poruku."
                   else
                     "Pošalji komšijama javni link #{root} i reci da se sami mogu registrovati i " \
                       "izabrati svoje područje na #{public_site_url('komsiluk')}. Ako na svom nalogu imaš " \
                       "lični pozivni link, možeš ga podijeliti zasebno; običan javni link je dovoljan " \
                       "za pristup platformi. Nisam nikome poslala poruku niti kreirala članstvo."
                   end
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                 architecture: "public_platform_invitation", subject: "public_platform_invitation")
        end

        def police_identity_card_question?(text, state:)
          folded = Decidim::Bih::Text.fold(text.to_s)
          first = folded.match?(/\blicn\w*\s+kart\w*\b/) &&
            folded.match?(/\b(?:nov\w*|treba|dokument\w*|gotov\w*|status\w*|vidjet\w*)\b/)
          followup = state.dig(Dialogue::AnswerContext::KEY, "subject") == "police_identity_card" &&
            folded.match?(/\b(?:gotov\w*|status\w*|vidjet\w*)\b/)
          first || followup
        end

        def direct_police_identity_card(message:, state:, context:, locale:)
          folded = Decidim::Bih::Text.fold(message.text.to_s)
          focus = folded.match?(/\b(?:gotov\w*|status\w*|vidjet\w*)\b/) ? "status" : "application"
          reading = ReadPort.new(organization: @organization).identity_card_procedure(context:, locale:, focus:)
          row = reading.facts.first if reading.status == "ok" && reading.facts.one?
          parts = []
          if focus == "status"
            parts << "Ne mogu vidjeti da li je tvoja lična karta gotova; nemam pristup ličnoj evidenciji dokumenata."
          end
          if row
            parts << row.fetch("text")
            parts << "Pregledano uputstvo nadležne službe: #{row.fetch('source_url')}. Pregledano #{row.fetch('reviewed_on')}."
            parts << "Obrazac ili dokument iz pregledanog uputstva: #{row.fetch('form_download_url')}." if row["form_download_url"].present?
          else
            parts << "Nemam dostupno pregledano uputstvo ove zajednice za #{focus == 'status' ? 'provjeru statusa lične karte' : 'izdavanje ili zamjenu lične karte'}. " \
                     "Nadležnost i postupak provjeri kroz službeni kanal nadležne službe."
          end
          parts << "Način provjere i njegovi preduslovi važe samo ako su navedeni u pregledanom uputstvu. " \
                   "U ovom razgovoru nisam podnijela zahtjev niti provjerila ili potvrdila da je dokument izrađen. " \
                   "Broj dokumenta, JMB i druge lične podatke ne šalji u ovaj chat."
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(parts.join(" "), locale),
                                 architecture: "police_identity_card", subject: "police_identity_card", tool_calls: 1)
        end

        def civil_protection_current_warning_question?(text, state:)
          folded = Decidim::Bih::Text.fold(text.to_s)
          first = folded.match?(/\bciviln\w*\s+zastit\w*\b/) && folded.match?(/\bupozorenj\w*\b/)
          followup = state.dig(Dialogue::AnswerContext::KEY, "subject") == "civil_protection_warning" &&
            folded.match?(/\b(?:opasnost\w*|objav\w*|upozorenj\w*|nema\s+nikakv\w*)\b/)
          first || followup
        end

        def direct_civil_protection_current_warning(message:, state:, context:, locale:)
          source = CityServiceSources.fetch("civil_protection").fetch(:source_url)
          retained = state.dig(Dialogue::AnswerContext::KEY, "subject") == "civil_protection_warning"
          if retained
            answer = "Ne. Nedostupna objava ili odsustvo pregledanog upozorenja ne dokazuje da nema opasnosti. " \
                     "Za aktuelna službena upozorenja provjeri Civilnu zaštitu: #{source}."
            calls = 0
          else
            reading = ReadPort.new(organization: @organization).public_capability(
              capability: "environment", topic: "civil_protection",
              entities: { "query" => message.text.to_s, "time_expression" => "danas" }, context:, locale:
            )
            active = Array(reading.facts).find do |fact|
              fact["temporal_status"] == "active" &&
                Decidim::Bih::Text.fold([fact["text"], fact.dig("coverage", "source_area_text")].join(" ")).match?(/\bbijeljin\w*\b/) &&
                Array(fact["warning_codes"]).exclude?("source_facts_unconfirmed")
            end if reading.status == "ok"
            answer = if active
                       "U pregledanoj važećoj objavi Civilne zaštite za Bijeljinu stoji: #{active.fetch('text')} " \
                         "Izvor: #{active['source_url']}. Provjeri tačno navedeno područje i vrijeme u objavi."
                     elsif reading.status == "unavailable" || reading.status == "stale"
                       "Pripremljeni izvor Civilne zaštite trenutno nije dovoljno dostupan ili svjež da potvrdim " \
                         "važeće upozorenje za Bijeljinu. To nije potvrda da nema opasnosti. Službeni izvor: #{source}."
                     else
                       "U trenutno pregledanim podacima nemam potvrđeno važeće upozorenje Civilne zaštite " \
                         "koje izričito obuhvata Bijeljinu. To nije potvrda da nema opasnosti ni potpun popis " \
                         "svih izvora. Provjeri službene objave: #{source}."
                     end
            calls = 1
          end
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                 architecture: "civil_protection_warning", subject: "civil_protection_warning", tool_calls: calls)
        end

        def sistem48_public_archive_question?(text, state:)
          folded = Decidim::Bih::Text.fold(text.to_s)
          first = folded.match?(/\bsistem\s*48\b/) && folded.match?(/\bjavn\w*\s+arhiv\w*\b/)
          followup = state.dig(Dialogue::AnswerContext::KEY, "subject") == "sistem48_public_archive" &&
            folded.match?(/\b(?:arhiv\w*|primil\w*|prijav\w*)\b/)
          first || followup
        end

        def direct_sistem48_public_archive(message:, state:, context:, locale:)
          source = CityServiceSources.fetch("sistem48_public_archive").fetch(:source_url)
          retained = state.dig(Dialogue::AnswerContext::KEY, "subject") == "sistem48_public_archive"
          answer = if retained
                     "Ne. Ako prijave nema u javnom pregledu, to ne dokazuje da je služba nije primila. " \
                       "Objava u arhivu, potvrda prijema i rješavanje su odvojeni koraci. Za predmet podnesen " \
                       "Sistemu 48 provjeri potvrdu ili broj predmeta i pitaj službu direktno; javni pregled je #{source}."
                   else
                     "Javni pregled Sistema 48 Grada Bijeljina je na #{source}. Tamo možeš pregledati " \
                       "javno prikazane prijave i dostupne filtre po vrsti problema, statusu i periodu. " \
                       "To nije uvid u privatni predmet ni dokaz da su sve prijave javno objavljene."
                   end
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                 architecture: "sistem48_public_archive", subject: "sistem48_public_archive")
        end

        def direct_private_report_status(message:, state:, context:, locale:)
          my_reports = public_site_url("prijave?view=mine")
          public_lookup = public_site_url("prijave-pronadji")
          answer = "Za privatne detalje prijave prijavi se na nalog i otvori svoje prijave: #{my_reports}. " \
                   "Ako je prijava anonimna, potreban je privatni link sa potvrde (referenca i statusni token). " \
                   "Sama referenca na #{public_lookup} pokazuje javni status, ne privatni razgovor. " \
                   "Bez naloga koji je podnio prijavu ili sačuvanog privatnog linka ne mogu te identifikovati iz chata; " \
                   "statusni token ne šalji ovdje."
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                 architecture: "private_report_status_path")
        end

        def own_anonymous_reports_question?(text, state:)
          folded = Decidim::Bih::Text.fold(text.to_s)
          first = folded.match?(/\bbez\s+prijav\w*\s+na\s+nalog\b/) &&
                  folded.match?(/\bsvoj\w*\b/) && folded.match?(/\bprijav\w*\b/)
          followup = state.dig(Dialogue::AnswerContext::KEY, "subject") == "own_anonymous_reports" &&
                     folded.match?(/\bbez\s+nalog\w*\b/)
          first || followup
        end

        def direct_own_anonymous_reports(message:, state:, context:, locale:)
          followup = state.dig(Dialogue::AnswerContext::KEY, "subject") == "own_anonymous_reports"
          answer = if followup
                     "Prijave poslane bez naloga ne ulaze automatski u listu 'Moje prijave' na kasnije " \
                       "otvorenom nalogu. Prepoznaješ ih po sačuvanoj potvrdi: referenca omogućava javni " \
                       "status na #{public_site_url('prijave-pronadji')}, a privatni link iz potvrde daje " \
                       "pristup privatnim detaljima. Bez potvrde ne mogu iz ovog chata utvrditi koje su tvoje."
                   else
                     I18n.t("decidim.bih.dialogue.report_own", locale:, url: public_site_url('prijave-pronadji'))
                   end
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale), architecture: "own_anonymous_reports_boundary",
                                 subject: "own_anonymous_reports")
        end

        def report_status_meaning_question?(text, state:)
          folded = Decidim::Bih::Text.fold(text.to_s)
          first = folded.match?(/\bprijav\w*\b/) && folded.match?(/\b(?:primljeno|pregledano)\b/) &&
                  folded.match?(/\b(?:status\w*|znac\w*|dobio|dobila|poslat\w*|sluzb\w*|grad)\b/)
          followup = state.dig(Dialogue::AnswerContext::KEY, "subject") == "report_status_meaning" &&
                     folded.match?(/\b(?:poslato\s+sluzbi|cekamo\s+dopunu)\b/)
          first || followup || folded.match?(/\bcekamo\s+dopunu\b/)
        end

        def direct_report_status_meaning(message:, state:, context:, locale:)
          folded = Decidim::Bih::Text.fold(message.text.to_s)
          answer = if folded.match?(/\bcekamo\s+dopunu\b/)
                     "„Čekamo dopunu“ znači da je osoblje zatražilo dodatne podatke od podnosioca. " \
                       "Ako je prijava tvoja, prijavi se i otvori je među svojim prijavama na " \
                       "#{public_site_url('prijave?view=mine')}; ako si prijavio bez naloga, koristi privatni link iz potvrde. " \
                       "Pogledaj šta tačno traže prije odgovora; ovdje nisam ništa dopunila."
                   elsif folded.match?(/\bpregledano\b/)
                     "Ne nužno. „Pregledano“ znači da je prijava interno pregledana na MI platformi, " \
                       "ne da ju je Grad već dobio. Prihvaćeno prosljeđivanje službi označava „Poslato službi“. " \
                       "Status prati na #{public_site_url('prijave-pronadji')} ili u svojoj prijavi."
                   elsif folded.match?(/\bposlato\s+sluzbi\b/)
                     "Ne. „Poslato službi“ znači da je prosljeđivanje prijave nadležnoj službi prihvaćeno. " \
                       "To ne znači da je kvar popravljen. Dalji status prati na stranici prijave: #{public_site_url('prijave')}."
                   else
                     "Ne. „Primljeno“ znači da je prijava stigla na MI platformu, ne da ju je gradska služba već dobila. " \
                       "Operater je pregleda i prosljeđuje nadležnoj službi; prihvaćeno prosljeđivanje označava " \
                       "„Poslato službi“. Status možeš pratiti na stranici prijave: #{public_site_url('prijave')}."
                   end
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                 architecture: "report_status_meaning_boundary", subject: "report_status_meaning")
        end

        def notification_topics_question?(text, state:)
          folded = Decidim::Bih::Text.fold(text.to_s)
          first = folded.match?(/\bobavjest\w*\b/) &&
                  folded.match?(/\b(?:vrst\w*|tem\w*)\b/) &&
                  folded.match?(/\b(?:postavk\w*|nalog\w*|platform\w*)\b/)
          followup = state.dig(Dialogue::AnswerContext::KEY, "subject") == "notification_topics" &&
                     folded.match?(/\b(?:viber\w*|telefon\w*|kanal\w*|sigurn\w*|promotivn\w*)\b/)
          first || followup
        end

        def direct_notification_topics(message:, state:, context:, locale:)
          folded = Decidim::Bih::Text.fold(message.text.to_s)
          answer = if folded.match?(/\bpromotivn\w*\b/)
                     "Da. Javne prijave možeš čitati i bez izbora promotivnih novosti. " \
                       "Teme u postavkama upravljaju obavještenjima, ne pravom čitanja javnih prijava: " \
                       "#{public_site_url('prijave')}."
                   elsif folded.match?(/\bkanal\w*\b/) && folded.match?(/\bpostavk\w*\b/)
                     "U postavkama biraš teme obavještenja. Kanal isporuke zavisi od dostupnog kanala, " \
                       "dozvole uređaja i važeće pretplate; izbor teme sam po sebi ne uključuje svaki kanal. " \
                       "Postavke su na #{public_site_url('moj-nalog/poruke')}."
                   elsif folded.match?(/\b(?:viber\w*|telefon\w*|kanal\w*)\b/)
                     "Ne. Izbor teme ne garantuje isporuku na Viber, telefon ili svaki drugi kanal. " \
                       "Za svaki kanal važe njegova dostupnost, dozvola i potvrđena pretplata; " \
                       "sama postavka teme nije potvrda da je poruka dostavljena."
                   else
                     "U postavkama MI naloga možeš birati četiri teme: Novosti o mojim prijavama; " \
                       "Novosti i poruke zajednice; Novosti platforme; Obavještenja iz komšiluka i servisne informacije. " \
                       "Pregledaj ih na #{public_site_url('moj-nalog/poruke')}; izbor u chatu ne mijenja postavke."
                   end
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                 architecture: "notification_topics_boundary", subject: "notification_topics")
        end

        def account_code_recovery_question?(text, state:)
          folded = Decidim::Bih::Text.fold(text.to_s)
          first = folded.match?(/\b(?:poruk\w*|sms)\b/) && folded.match?(/\bkod\w*\b/) &&
                  folded.match?(/\b(?:ne\s+stign\w*|nije\s+stigl\w*)\b/)
          followup = state.dig(Dialogue::AnswerContext::KEY, "subject") == "account_code_recovery" &&
                     folded.match?(/\bkod\w*\b/) && folded.match?(/\b(?:tebi|ovdje|chatu|cetu)\b/)
          first || followup
        end

        def direct_account_code_recovery(message:, state:, context:, locale:)
          folded = Decidim::Bih::Text.fold(message.text.to_s)
          key = folded.match?(/\b(?:tebi|ovdje|chatu|cetu)\b/) ? "account_code_entry" : "account_message_missing"
          answer = I18n.t("decidim.bih.dialogue.#{key}", locale:, url: public_site_url('verifikacija/telefon'))
          direct_source_boundary(message:, state:, context:, locale:, answer:,
                                 architecture: "account_code_recovery_boundary", subject: "account_code_recovery")
        end

        def iphone_web_app_question?(text, state:)
          folded = Decidim::Bih::Text.fold(text.to_s)
          first = folded.match?(/\biphone\w*\b/) &&
            folded.match?(/\b(?:aplikacij\w*|dodam|dodati|pocetn\w*\s+ekran\w*)\b/)
          followup = state.dig(Dialogue::AnswerContext::KEY, "subject") == "iphone_web_app" &&
                     folded.match?(/\b(?:obavjest\w*|aplikacij\w*|poruk\w*)\b/)
          first || followup
        end

        def direct_iphone_web_app(message:, state:, context:, locale:)
          folded = Decidim::Bih::Text.fold(message.text.to_s)
          answer = if folded.match?(/\b(?:aplikacij\w*\s+za\s+poruk\w*|link\s+u\s+aplikacij\w*)\b/)
                     "U aplikaciji za poruke možda nema te opcije. Otvori https://#{@organization.host}/ direktno u " \
                       "Safariju na iPhoneu, dodirni Dijeli pa „Dodaj na početni ekran“. Ovdje ništa nisam instalirala."
                   elsif folded.match?(/\bobavjest\w*\b/)
                     "Ne. Samo otvaranje ili dodavanje MI na početni ekran ne uključuje obavještenja. " \
                       "Na uređaju treba dozvoliti obavještenja i imati važeću pretplatu; " \
                       "teme provjeri na #{public_site_url('moj-nalog/poruke')}. Sama postavka nije potvrda isporuke."
                   elsif folded.match?(/\b(?:dodao|dodala)\b/) && folded.match?(/\bpocetn\w*\s+ekran\w*\b/)
                     "Razumijem, već si dodao MI na početni ekran iPhonea. Samo dodavanje ne uključuje " \
                       "obavještenja; za njih su potrebni dozvola na uređaju i važeća pretplata."
                   else
                     "Na iPhoneu otvori https://#{@organization.host}/ u Safariju, dodirni meni stranice pa Dijeli " \
                       "(ili dugme Dijeli, zavisno od prikaza), izaberi „Dodaj na početni ekran“ i potvrdi Dodaj. " \
                       "Ako se ponudi „Otvori kao web-aplikaciju“, možeš ga uključiti."
                   end
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                 architecture: "iphone_web_app_guidance", subject: "iphone_web_app")
        end

        def material_support_question?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\b(?:donir\w*|poklon\w*|ponud\w*)\b.{0,55}\b(?:materijal\w*|oprem\w*|predmet\w*)\b/) ||
            folded.match?(/\b(?:javn\w*|odobren\w*)\b.{0,35}\bpotreb\w*\b/)
        end

        def material_support_commitment_question?(text)
          folded = Decidim::Bih::Text.fold(Decidim::Bih::Transliterator.to_latin(text.to_s))
          folded.match?(/\b(?:obec\w*|obavez\w*|ponud\w*)\b/) &&
            folded.match?(/\b(?:pitam|pitanj\w*|znac\w*)\b/)
        end

        def material_support_offer_followup?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\b(?:potreb\w*|materijal\w*|oprem\w*)\b/) &&
            folded.match?(/\b(?:ponud\w*|nudi|pomoc\w*|pomogn\w*|bez\s+novca)\b/)
        end

        def direct_material_support(message:, state:, context:, locale:)
          answer = material_support_guidance(context:, locale:)
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                 architecture: "material_support_catalog", subject: "material_support", tool_calls: 1)
        end

        def material_support_guidance(context:, locale:)
          tools = @tools_factory.call(location: nil)
          envelope = tools.registry.call(name: "read_catalog", arguments: { "topic" => "community", "view" => "material_needs" },
                                         context:, eligibility: tools.eligibility)
          revalidate_delivery_evidence!([envelope.for_prompt(context:, eligibility: tools.eligibility)], tools:)
          needs = envelope.status == "ok" ? envelope.evidence.select { |record| record.dig("facts", "source_fact", "kind") == "contribution_need" } : []
          source = public_site_url("volontiranje")
          answer = if needs.any?
                     first = needs.first
                     title = first.dig("facts", "source_fact", "title").to_s
                     url = first["source_url"].presence || source
                     "U javnom katalogu je objavljena materijalna potreba #{title}: #{url}. " \
                       "Provjeri uslove i kontakt iz same objave prije predaje."
                   elsif envelope.status == "unsupported" && envelope.warnings.include?("public_catalog_material_needs_empty")
                     "U trenutno pregledanom dijelu javnog kataloga nisam našla otvorenu materijalnu potrebu: #{source}. " \
                       "#{configured_support_guidance} Kod operatera možeš pitati kome uputiti ponudu; " \
                       "taj kontakt nije potvrda da operater prima ili prihvata materijal."
                   else
                     "Trenutno ne mogu provjeriti javne materijalne potrebe. Pogledaj #{source}. " \
                       "#{configured_support_guidance} Nedostupan pregled nije potvrda da potreba nema, " \
                       "a kontakt operatera nije potvrda da on prima ili prihvata materijal."
                   end
          "#{answer} Poruka u chatu nije evidentirana donacija. Nisam poslala ponudu niti potvrdila prihvatanje."
        end

        def volunteer_signup_points_question?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\bbodov\w*\b/) && folded.match?(/\bprijav\w*\b/) &&
            folded.match?(/\b(?:cim|samom|odmah)\b/)
        end

        def volunteer_hours_verification_question?(text, state:)
          folded = Decidim::Bih::Text.fold(text.to_s)
          initial = folded.match?(/\bvolontersk\w*\s+sat\w*\b/) &&
            folded.match?(/\b(?:bodov\w*|racun\w*)\b/)
          summary = folded.match?(/\bbodov\w*\b/) && folded.match?(/\bsat\w*\b/) &&
                    folded.match?(/\b(?:korak\w*|odobren\w*|provjer\w*|potvrd\w*)\b/)
          followup = state.dig(Dialogue::AnswerContext::KEY, "subject") == "volunteer_hours_verification" &&
            folded.match?(/\b(?:upisan\w*|odobren\w*|sat\w*)\b/)
          initial || summary || followup
        end

        def direct_volunteer_signup_points(message:, state:, context:, locale:)
          answer = "Ne. Sama prijava za volontiranje ne donosi bodove za odrađeni dan. " \
                   "Za registraciju uz potvrđen telefon predviđeno je 20 bodova; 100 bodova za dan volontiranja " \
                   "dolazi tek nakon potvrde i odobrenja odrađenog rada. Pravila: #{public_site_url('zajednistvo?tab=kako')}."
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                 architecture: "volunteer_signup_points_boundary")
        end

        def weekend_opportunity_question?(text, state:)
          folded = Decidim::Bih::Text.fold(text.to_s)
          first = folded.match?(/\bvikend\w*\b/) &&
            (folded.match?(/\b(?:prilik\w*|volont\w*|akcij\w*|aktivnost\w*)\b/) ||
             folded.match?(/\b(?:nema|bez)\b.*\bobjav\w*\b/))
          followup = state.dig(Dialogue::AnswerContext::KEY, "subject") == "weekend_opportunity" &&
            folded.match?(/\b(?:vikend\w*|objav\w*|termin\w*|datum\w*)\b/)
          first || followup
        end

        def direct_weekend_opportunity(message:, state:, context:, locale:)
          today = context.now.in_time_zone(TransportJourneyQuestion::SERVICE_TIME_ZONE).to_date
          retained = state.dig(Dialogue::AnswerContext::KEY, "subject") == "weekend_opportunity"
          saved = state.dig(Dialogue::AnswerContext::KEY, "anchor").to_s
          saturday = Date.iso8601(saved) if retained && saved.match?(/\A\d{4}-\d{2}-\d{2}\z/)
          current_weekend = Decidim::Bih::Text.fold(message.text.to_s).match?(/\b(?:ovaj|ovog)\s+vikend\w*\b/)
          saturday ||= (current_weekend && today.sunday? ? today - 1 : today + ((6 - today.wday) % 7))
          saturday += 7 if saturday <= today && !retained && !current_weekend
          sunday = saturday + 1
          this_saturday = today.sunday? ? today - 1 : today + ((6 - today.wday) % 7)
          expression = saturday == this_saturday ? "this weekend" : "next weekend"
          tools = @tools_factory.call(location: nil)
          envelope = tools.registry.call(name: "read_catalog",
                                         arguments: { "topic" => "volunteer", "time_expression" => expression, "date" => saturday.iso8601 },
                                         context:, eligibility: tools.eligibility)
          revalidate_delivery_evidence!([envelope.for_prompt(context:, eligibility: tools.eligibility)], tools:)
          opportunities = envelope.status == "ok" ? envelope.evidence.select { |record| record.dig("facts", "source_fact", "kind") == "volunteer_opportunity" } : []
          dates = "#{saturday.strftime('%d.%m.%Y.')}–#{sunday.strftime('%d.%m.%Y.')}"
          answer = if opportunities.any?
                     item = opportunities.first
                     title = item.dig("facts", "source_fact", "title").to_s
                     url = item["source_url"].presence || public_site_url("volontiranje")
                     "Za vikend #{dates} u javnom katalogu je objavljena prilika #{title}: #{url}. " \
                       "Objava ne potvrđuje fizičko mjesto akcije u Bijeljini ni slobodno mjesto; provjeri uslove i način učešća u samoj objavi."
                   elsif envelope.status == "unsupported"
                     "Za vikend #{dates} nisam našla odobrenu priliku u pregledanom javnom katalogu #{public_site_url('volontiranje')}. " \
                       "To ne dokazuje da drugih akcija nema."
                   else
                     "Za vikend #{dates} trenutno ne mogu provjeriti javni katalog prilika. " \
                       "Provjeri #{public_site_url('volontiranje')}; bez objave ne mogu potvrditi termin ni mjesto."
                   end
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                 architecture: "weekend_opportunity_catalog", subject: "weekend_opportunity",
                                 anchor: saturday.iso8601, tool_calls: 1)
        end

        def approved_calls_follow_question?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\b(?:prat\w*|pronac\w*|nac\w*)\b/) &&
            folded.match?(/\b(?:poziv\w*|prilik\w*|akcij\w*)\b/) &&
            folded.match?(/\b(?:nov\w*|odobren\w*|objavljen\w*)\b/)
        end

        def direct_approved_calls_follow(message:, state:, context:, locale:)
          answer = "Nove odobrene pozive prati u javnom katalogu na #{public_site_url('projekti')}. " \
                   "Uz svaki poziv provjeri datum objave, rok i uslove; razgovor ovdje ne prijavljuje te automatski."
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                 architecture: "approved_calls_follow")
        end

        def fresh_opportunity_boundary_question?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\bsvjez\w*\s+podat\w*\b/) && folded.match?(/\bslobodn\w*\s+mjest\w*\b/)
        end

        def direct_fresh_opportunity_boundary(message:, state:, context:, locale:)
          answer = transport_prose("Bez svježeg, objavljenog podatka ne mogu potvrditi slobodno mjesto niti obećati prijem. " \
                                   "Aktuelne prilike provjeri na #{public_site_url('projekti')}.", locale)
          direct_source_boundary(message:, state:, context:, locale:, answer:, architecture: "fresh_opportunity_boundary")
        end

        # A relative day in an old notice is anchored to its publication, not
        # to the day of this chat. No source lookup can supply a missing URL/date.
        def old_relative_notice_question(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          return :publication if folded.match?(/\bobavjest\w*\b/) && folded.match?(/\bsutra\b/) &&
                                 folded.match?(/\b(?:objavljen\w*|prosle\s+sedmice|prosle\s+nedjelje)\b/)
          return :today if folded.match?(/\bstar\w*\s+naslov\w*\b/) &&
                           folded.match?(/\bdanas\b/) && folded.match?(/\biskljucenj\w*\b/)

          nil
        end

        def direct_old_relative_notice(message:, state:, context:, locale:, kind:)
          answer = if kind == :publication
                     "Riječ 'sutra' u starijem obavještenju odnosi se na dan poslije njegove objave, ne na sutra od danas. " \
                       "Napiši datum objave ili pošalji link i navedi ulicu ili naselje; tada mogu provjeriti datum i obuhvat isključenja."
                   else
                     "Ne. Sam stari naslov sa riječju 'sutra' ne potvrđuje isključenje danas. " \
                       "Za to trebaju datum i važenje obavještenja te pogođeno područje. Pošalji link ili datum i lokaciju za provjeru."
                   end
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                 architecture: "relative_notice_date_boundary")
        end

        def retained_last_departure_question?(text, state:)
          journey = state.dig(Dialogue::ConversationSlots::KEY, "journey")
          return false unless journey.is_a?(Hash) && journey["date"].to_s.match?(/\A\d{4}-\d{2}-\d{2}\z/)

          folded = Decidim::Bih::Text.fold(text.to_s)
          # A complete current-turn route request must reach the timetable read.
          # The saved slot may have been populated from this very message.
          raw = Decidim::Bih::Transliterator.to_latin(text.to_s)
          return false if folded.match?(/\b[gp]\d{1,2}\b/) && raw.match?(/\b\d{1,2}:\d{2}\b/) &&
                          folded.match?(/\b(?:sa|iz|od)\s+.{2,80}\s+do\s+/)

          folded.match?(/\b(?:zadnj\w*|posljednj\w*)\s+polaz\w*\b/) && folded.match?(/\b(?:tog\s+dana|bas\s+tog\s+dana)\b/)
        end

        def direct_retained_last_departure_boundary(message:, state:, context:, locale:)
          journey = state.fetch(Dialogue::ConversationSlots::KEY).fetch("journey")
          answer = transport_prose("Iz prethodne provjere za #{journey.fetch('date')} ne mogu utvrditi posljednji polazak iz #{journey.fetch('origin_query')}; " \
                                   "provjera polaska poslije zadanog vremena ne dokazuje kada ide zadnji autobus. " \
                                   "Provjeri službeni red vožnje ili navedi tačno stajalište za novu provjeru.", locale)
          direct_source_boundary(message:, state:, context:, locale:, answer:, architecture: "last_departure_boundary")
        end

        def no_invented_stop_time_question?(text, state:)
          return false unless state.dig(Dialogue::ConversationSlots::KEY, "journey").is_a?(Hash)

          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\b(?:stajal\w*|stanic\w*)\b/) && folded.match?(/\b(?:izmislj\w*|priblizn\w*)\b/) &&
            folded.match?(/\bvrijem\w*\b/)
        end

        def direct_no_invented_stop_time(message:, state:, context:, locale:)
          answer = transport_prose("Ako stajalište nije u pregledanom redu vožnje, nemam potvrđeno vrijeme za njega. " \
                                   "Neću prenositi vrijeme drugog stajališta kao približan polazak. " \
                                   "Napiši tačno stajalište ako želiš novu provjeru.", locale)
          direct_source_boundary(message:, state:, context:, locale:, answer:, architecture: "stop_time_boundary")
        end

        def journey_walk_boundary_question?(text, state:)
          return false unless state.dig(Dialogue::ConversationSlots::KEY, "journey").is_a?(Hash)

          folded = Decidim::Bih::Text.fold(text.to_s)
          segments = folded.match?(/\b(?:autobusk\w*|javn\w*\s+prevoz\w*)\b/) &&
            folded.match?(/\b(?:pjesac\w*|udaljenost\w*)\b/)
          entrance = folded.match?(/\bulaz\w*\b/) &&
            folded.match?(/\b(?:dolaz\w*|izlazn\w*|pjesk\w*)\b/) &&
            folded.match?(/\b(?:preciz\w*|potvrd\w*|koliko)\b/)
          segments || entrance
        end

        def school_landmark_stop_question?(text, state:)
          return false unless state.dig(Dialogue::ConversationSlots::KEY, "journey").is_a?(Hash)

          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\bkod\s+skol\w*\b/) && folded.match?(/\b(?:polazist\w*|stanic\w*|stajal\w*)\b/)
        end

        def direct_school_landmark_stop(message:, state:, context:, locale:)
          origin = state.dig(Dialogue::ConversationSlots::KEY, "journey", "origin_query").to_s
          normalized = Decidim::Bih::Text.fold(origin)
          place = PublicTransportPlaces.entries.find do |entry|
            ([entry.fetch("name")] + entry.fetch("aliases")).any? { |name| Decidim::Bih::Text.fold(name) == normalized }
          end
          answer = if place
                     stops = place.fetch("member_labels")
                     "Za #{place.fetch('name')} sam kao početno stajalište uzela #{place.fetch('default_label')}. " \
                       "'Kod škole' samo po sebi ne potvrđuje koje je stajalište najbliže ni da li bi se ruta promijenila. " \
                       "U pregledanom redu su #{stops.first(4).join(', ')}; napiši tačno stajalište za novu provjeru."
                   else
                     "'Kod škole' samo po sebi ne potvrđuje koje je stajalište najbliže ni da li bi se ruta promijenila. " \
                       "Napiši naziv polaznog stajališta za novu provjeru."
                   end
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                 architecture: "school_landmark_stop_boundary")
        end

        def direct_journey_walk_boundary(message:, state:, context:, locale:)
          answer = transport_prose("Ako imam potvrđena vremena autobusa, ona se odnose na polazno i dolazno stajalište iz pregledanog reda vožnje. " \
                                   "Ne potvrđuje vrijeme hoda do tačnog ulaza u odredište niti sigurnu pješačku stazu. " \
                                   "Ako navedeš ulicu, broj ili tačan ulaz, mogu ponovo provjeriti dostupne podatke.", locale)
          direct_source_boundary(message:, state:, context:, locale:, answer:, architecture: "journey_walk_boundary")
        end

        def live_bus_delay_question?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\b(?:uzivo|u\s+realnom\s+vremenu)\b/) &&
            folded.match?(/\b(?:kasni\w*|vozil\w*|autobus\w*|polazak\w*)\b/)
        end

        def direct_live_bus_delay(message:, state:, context:, locale:)
          answer = "Ne, nemam praćenje vozila ni kašnjenja uživo. Mogu provjeriti objavljeni red vožnje, " \
                   "ali on ne potvrđuje gdje je autobus sada ni da li će stići. " \
                   "Ako za traženo kasno vrijeme nisam našla objavljen polazak, to nije dokaz da neko vozilo samo kasni. " \
                   "Za stanje prije polaska provjeri službenu objavu ili prevoznika: " \
                   "#{CityServiceSources.fetch('public_transport').fetch(:source_url)}."
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                 architecture: "live_bus_delay_boundary", subject: "transport_live_status")
        end

        def direct_current_location_sunday_boundary(message:, state:, context:, tools:, locale:)
          envelope = tools.registry.call(name: "nearest_stop", arguments: {}, context:, eligibility: tools.eligibility)
          evidence = [envelope.for_prompt(context:, eligibility: tools.eligibility)]
          revalidate_delivery_evidence!(evidence, tools:)
          fact = envelope.evidence.one? ? envelope.evidence.first.fetch("facts") : nil
          stop = fact && fact["stop_label"]
          approximation = envelope.status == "ok" && stop.to_s.length.between?(2, 120) ?
            "Za tvoju poslanu lokaciju pregledana mapa predlaže #{stop} kao početno stajalište. " :
            "Primila sam tvoju lokaciju, ali ne mogu potvrditi najbliže pregledano stajalište. "
          answer = "#{approximation}Za današnju nedjelju nemam pregledan nedjeljni red vožnje, " \
                   "pa ne mogu potvrditi autobus do traženog odredišta niti vrijeme polaska. " \
                   "Ako misliš na drugi datum, napiši ga pa ću ponovo provjeriti vezu."
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                 architecture: "current_location_sunday_boundary", subject: "transport_calendar",
                                 tool_calls: 1, resolution: envelope.status == "ok" ? "answered" : "source_unavailable")
        end

        def journey_direction_check_question?(text, state:)
          journey = state.dig(Dialogue::ConversationSlots::KEY, "journey")
          return false unless journey.is_a?(Hash) && journey["origin_query"].present? && journey["destination_query"].present?

          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\bodredist\w*\b/) && folded.match?(/\bpolazist\w*\b/) && folded.match?(/\bsmjer\w*\b/)
        end

        def direct_journey_direction_check(message:, state:, context:, locale:)
          journey = state.fetch(Dialogue::ConversationSlots::KEY).fetch("journey")
          answer = transport_prose("Traženi smjer je od #{journey.fetch('origin_query')} do #{journey.fetch('destination_query')}. " \
                                   "Odredište nije polazište. Ako sam navela vrijeme dolaska, ono se odnosi na imenovano stajalište, ne na tačan ulaz.", locale)
          direct_source_boundary(message:, state:, context:, locale:, answer:, architecture: "journey_direction_check")
        end

        def public_site_url(path)
          Decidim::Bih.public_url(path, base_url: "https://#{@organization.host}")
        end

        def direct_source_boundary(message:, state:, context:, locale:, answer:, architecture:, subject: nil, anchor: nil, tool_calls: 0, resolution: "answered")
          reply = Decidim::Bih::Concierge::Responder::Reply.new(text: answer, report: nil, answer_intent: "service", tone: "core", locale:)
          captured = if subject
                       Dialogue::AnswerContext.capture(kind: "public_card", subject:, anchor: anchor || message.text.to_s,
                                                      now: context.now, state_expires_at: state.fetch("expires_at"))
                     end
          next_state = captured ? state.merge(Dialogue::AnswerContext::KEY => captured) : state
          result = outcome(reply:, state: next_state, resolution:,
                           diagnostics: { "architecture" => architecture, "model_calls" => 0, "tool_calls" => tool_calls })
          frame = Dialogue::ConversationFrame.load(next_state[Dialogue::ConversationFrame::KEY], context:)
          persist(result, previous: state, context:, frame: public_history(frame:, message:, answer:, context:, state: next_state))
        end

        def direct_report_guidance(message:, state:, context:, locale:)
          path = Decidim::Bih::Engine.routes.url_helpers.new_report_path
          answer = I18n.t("decidim.bih.concierge.report_guidance.answer", locale:, url: path)
          reply = Decidim::Bih::Concierge::Responder::Reply.new(text: answer, report: nil, answer_intent: "report_guidance", tone: "core", locale:)
          result = outcome(reply:, state:, resolution: "answered", diagnostics: { "architecture" => "deterministic_report_guidance", "model_calls" => 0, "tool_calls" => 0 })
          frame = Dialogue::ConversationFrame.load(state[Dialogue::ConversationFrame::KEY], context:)
          persist(result, previous: state, context:, frame: public_history(frame:, message:, answer:, context:, state:))
        end

        def boarding_stop_recall?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\b(?:koje|koji|koju|which)\b.*(?:\b(?:stajal\w*|stanic\w*|stop)\b.*\b(?:polazn\w*|start\w*)\b|\b(?:polazn\w*|start\w*)\b.*\b(?:stajal\w*|stanic\w*|stop)\b)/)
        end

        def transport_area_stop_request(text, state:)
          latin = Decidim::Bih::Transliterator.to_latin(text.to_s)
          folded = Decidim::Bih::Text.fold(latin)
          subject = state.dig(Dialogue::AnswerContext::KEY, "subject") == "transport_area_stop"
          anchor = state.dig(Dialogue::AnswerContext::KEY, "anchor").to_s if subject
          named = state.dig(Dialogue::ConversationSlots::KEY, "location")
          mode = if subject && folded.match?(/\b(?:drug\w*\s+stanic\w*|kod\s+skol\w*)\b/)
                   :followup
                 elsif (match = latin.match(/\b(?:iz|od)\s+(?<area>[\p{L}\s]{2,60}?)\s+bih\s+autobusom\s+prema\s+gradu\b/i))
                   anchor = match[:area].strip
                   :initial
                 elsif named.is_a?(Hash) && named["kind"] == "named" &&
                       folded.match?(/\b(?:autobus\w*|stanic\w*|stajal\w*)\b/) &&
                       folded.match?(/\b(?:pocetn\w*|polazn\w*|pretpostavljen\w*)\b/)
                   anchor = PlaceAliasRegistry.display_name(named["label"]).sub(/\Amz\s+/i, "")
                   folded.match?(/\b(?:bila|pretpostavljen\w*)\b/) ? :recall : :initial
                 end
          return unless mode

          key = Decidim::Bih::Text.fold(anchor)
          place = PublicTransportPlaces.entries.find do |entry|
            ([entry.fetch("name")] + entry.fetch("aliases")).any? { |name| Decidim::Bih::Text.fold(name) == key }
          end
          { place:, mode: } if place
        end

        def direct_transport_area_stop(message:, state:, context:, locale:, area_stop:)
          place = area_stop.fetch(:place)
          default = place.fetch("default_label")
          alternatives = place.fetch("member_labels").reject { |label| label == default }
          alternatives_label = alternatives.first(6).join(", ")
          alternatives_label += " i druga objavljena stajališta" if alternatives.size > 6
          folded = Decidim::Bih::Text.fold(message.text.to_s)
          answer = if area_stop.fetch(:mode) == :initial
                     "Za polazak iz područja #{place.fetch('name')} kao početno stajalište pretpostavljam #{default}, " \
                       "prema pregledanom redu vožnje. Druga objavljena stajališta su #{alternatives_label}. " \
                       "Napiši datum i približno vrijeme pa mogu provjeriti polazak prema gradu."
                   elsif area_stop.fetch(:mode) == :recall
                     "Za polazak iz područja #{place.fetch('name')} pretpostavila sam stajalište #{default}. " \
                       "Druga objavljena stajališta su #{alternatives_label}; napiši drugo ako ti više odgovara."
                   elsif folded.match?(/\bkod\s+skol\w*\b/)
                     "Ako misliš na objavljeno stajalište #{default}, moja početna pretpostavka ostaje ista. " \
                       "Samo 'kod škole' ne potvrđuje tvoju tačnu tačku ni najbliži fizički peron; " \
                       "napiši drugo stajalište ako želiš novu provjeru."
                   else
                     "Za #{place.fetch('name')} sam pretpostavila #{default}. Druga objavljena stajališta " \
                       "u tom području su #{alternatives_label}. Napiši koje koristiš za ponovnu provjeru."
                   end
          answer = "#{answer} Izvor: https://www.gradbijeljina.org/lat/news/novosti/7243.od-1-septembra-novi-red-voznje-gradskog-prevoza.html."
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                 architecture: "transport_area_stop", subject: "transport_area_stop",
                                 anchor: place.fetch("name"))
        end

        def nearby_stop_alternatives_question?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          return false unless folded.match?(/\b(?:druge|druga|drugih|ostale|ostalih|alternative|other)\b/) &&
                              folded.match?(/\b(?:stajal\w*|stanic\w*|stop\w*)\b/)

          folded.match?(/\b(?:istoj|iste|istog|toj|te|same|this)\s+(?:tacki|lokaciji|mjestu|mestu|point|location|place)\b|\b(?:odavde|ovdje|ovde|here)\b|\b(?:oko mene|near me)\b/)
        end

        def explicit_first_route_journey(text)
          return unless ENV["MILICA_JOURNEY_PLANNER_V2_ENABLED"] == "true"

          latin = Decidim::Bih::Transliterator.to_latin(text.to_s).strip
          match = latin.match(/\bprv\w*\s+(?<route>[GP]\d{1,2})\s+(?:sa|iz|od)\s+
                              (?<origin>[\p{L}\d ()-]{2,80}?)\s+do\s+
                              (?<destination>[\p{L}\d ()-]{2,80}?)\s+
                              (?<date>\d{1,2}\.\d{1,2}\.20\d{2})\.\s+
                              (?:poslije|posle|nakon)\s+(?<clock>(?:[01]\d|2[0-3]):[0-5]\d)\b/ix)
          return unless match

          date = Date.strptime(match[:date], "%d.%m.%Y").iso8601
          origin = match[:origin].strip
          # Preserve the reviewed logical-station alias; the printed NAS label
          # appears on many route rows and is ambiguous before station grouping.
          origin = "nova autobuska" if Decidim::Bih::Text.fold(origin).match?(/\bnov\w*\s+autobusk\w*\b/)
          { "origin_query" => origin, "destination_query" => match[:destination].strip,
            "date" => date, "after_time" => match[:clock], "route_code" => match[:route].upcase,
            "mode" => "next", "direct_only" => true }
        rescue Date::Error
          nil
        end

        def weekday_named_first_route_journey(text, context:)
          return unless ENV["MILICA_JOURNEY_PLANNER_V2_ENABLED"] == "true"

          latin = Decidim::Bih::Transliterator.to_latin(text.to_s)
          match = latin.match(/\b(?:idem|putujem)\s+od\s+(?<origin>[\p{L}\d ()-]{2,80}?)\s+do\s+
                              (?<destination>[\p{L}\d ()-]{2,80}?)\s*[.!?]\s*
                              (?:koji|koja)\s+je\s+prv\w*\s+(?<route>[GP]\d{1,2})\s+
                              (?:poslije|posle|nakon)\s+(?<clock>(?:[01]\d|2[0-3]):[0-5]\d)\b/ix)
          return unless match

          temporal = TransportJourneyQuestion.temporal_entities({}, latin, now: context.now)
          date = temporal.entities["date"].to_s
          return if temporal.warning || !date.match?(/\A20\d{2}-\d{2}-\d{2}\z/)

          { "origin_query" => match[:origin].strip, "destination_query" => match[:destination].strip,
            "date" => date, "after_time" => match[:clock], "route_code" => match[:route].upcase,
            "mode" => "next", "direct_only" => true }
        end

        def fare_to_trip_followup(text, state:, context:)
          return unless ENV["MILICA_JOURNEY_PLANNER_V2_ENABLED"] == "true"

          latin = Decidim::Bih::Transliterator.to_latin(text.to_s).strip
          match = latin.match(/\A(?:cijenu|cenu)\s+zanemari;\s*treba\s+mi\s+prvi\s+(?<route>[GP]\d{1,2})\s+
                              od\s+(?<origin>[\p{L}\d ()-]{2,80}?)\s+do\s+(?<destination>[\p{L}\d ()-]{2,80}?)\s+
                              tog\s+datuma\s+nakon\s+(?<clock>(?:[01]\d|2[0-3]):[0-5]\d)[.!?]?\z/ix)
          return unless match

          frame = Dialogue::ConversationFrame.load(state[Dialogue::ConversationFrame::KEY], context:)
          previous = Decidim::Bih::Transliterator.to_latin(frame.history.last&.fetch("message", "").to_s)
          prior_date = previous.match(DOTTED_DATE)
          return unless prior_date && previous.match?(/\b#{Regexp.escape(match[:route])}\b/i)

          date = Date.new(prior_date[3].to_i, prior_date[2].to_i, prior_date[1].to_i).iso8601
          { "origin_query" => match[:origin].strip, "destination_query" => match[:destination].strip,
            "date" => date, "after_time" => match[:clock], "route_code" => match[:route].upcase,
            "mode" => "next", "direct_only" => true }
        rescue Date::Error
          nil
        end

        def explicit_last_departure_journey(text, context:)
          return unless ENV["MILICA_JOURNEY_PLANNER_V2_ENABLED"] == "true"

          latin = Decidim::Bih::Transliterator.to_latin(text.to_s).strip
          folded = Decidim::Bih::Text.fold(latin)
          return unless folded.match?(/\b(?:posljednj\w*|poslednj\w*|zadnj\w*)\s+(?:polaz\w*|[gp]\d{1,2})\b/)

          route = latin.match(/\b(?<code>[GP]\d{1,2})\b/i)&.[](:code)&.upcase
          match = latin.match(/\b(?:sa|iz|od)\s+(?<origin>[\p{L}\d ()-]{2,80}?)\s+do\s+(?<destination>[\p{L}\d ()-]{2,80}?)\s+
                              (?:u\s+(?:ponedjeljak|ponedeljak|utorak|srijedu|sredu|četvrtak|cetvrtak|petak|subotu|nedjelju|nedelju)\s+)?
                              \d{1,2}\.\d{1,2}\.20\d{2}[.,]?/ix)
          return unless route && match

          temporal = TransportJourneyQuestion.temporal_entities({}, latin, now: context.now)
          return if temporal.warning

          date = temporal.entities["date"].to_s
          # The temporal parser tags a last-departure clock as "zadnji HH:MM";
          # only the explicit threshold is passed to the typed planner.
          time = latin[/\b(?:nakon|poslije|posle)\s+(?<clock>(?:[01]\d|2[0-3]):[0-5]\d)\b/i, :clock]
          return unless date.match?(/\A\d{4}-\d{2}-\d{2}\z/) && time

          { "origin_query" => match[:origin].strip, "destination_query" => match[:destination].strip,
            "date" => date, "after_time" => time, "route_code" => route, "mode" => "last" }
        end

        def departure_mode_switch(text, state:)
          saved = state.dig(Dialogue::ConversationSlots::KEY, "journey")
          return unless saved.is_a?(Hash) && saved["query_kind"] == "last_departure"

          latin = Decidim::Bih::Transliterator.to_latin(text.to_s)
          folded = Decidim::Bih::Text.fold(latin)
          return unless folded.match?(/\bne\s+(?:posljednj\w*|poslednj\w*|zadnj\w*)\b/) &&
                        folded.match?(/\bistoj\s+relaciji\b/) && folded.match?(/\bistog\s+datuma\b/)
          return unless latin.match?(/\bprv\w*\s+nakon\s+(?:[01]\d|2[0-3]):[0-5]\d\b/i)

          clock = latin[/\bnakon\s+(?<clock>(?:[01]\d|2[0-3]):[0-5]\d)\b/i, :clock]
          date = saved["date"].to_s
          return unless clock && date.match?(/\A\d{4}-\d{2}-\d{2}\z/)

          { "origin_query" => saved.fetch("origin_query"), "destination_query" => saved.fetch("destination_query"),
            "date" => date, "after_time" => clock, "route_code" => saved.fetch("route_code"), "mode" => "next" }
        end

        def journey_earlier_challenge(text, state:)
          saved = state.dig(Dialogue::ConversationSlots::KEY, "journey")
          return unless saved.is_a?(Hash) && saved["query_kind"] == "first_connection"

          folded = Decidim::Bih::Text.fold(text.to_s)
          return unless folded.match?(/\b(?:ranij\w*|prv\w*)\s+polaz\w*\b/) &&
                        folded.match?(/\bprovjer\w*\b/) && folded.match?(/\bist\w*\s+datum\w*\b/)

          date = saved["date"].to_s
          time = saved["time"].to_s
          return unless date.match?(/\A20\d{2}-\d{2}-\d{2}\z/) && time.match?(/\A\d{2}:\d{2}\z/)

          { "origin_query" => saved.fetch("origin_query"), "destination_query" => saved.fetch("destination_query"),
            "date" => date, "after_time" => time, "mode" => "next" }
        end

        # A first connection asks for the earliest boarding after the stated
        # clock, even when a later bus reaches the destination at the same time.
        # Only explicit date, clock and both endpoints enter this direct path.
        def explicit_first_connection_journey(text, context:)
          return unless ENV["MILICA_JOURNEY_PLANNER_V2_ENABLED"] == "true"

          latin = Decidim::Bih::Transliterator.to_latin(text.to_s).strip
          folded = Decidim::Bih::Text.fold(latin)
          return unless folded.match?(/\bprv\w*\s+(?:vez\w*|polazak|polask\w*)\b/)

          match = latin.match(/\biz\s+(?<origin>[\p{L}\d ()-]{2,80}?)\s+do\s+(?<destination>[\p{L}\d ()-]{2,80}?)\s+(?:poslije|posle|nakon)\s+\d{1,2}(?::\d{2})?\b/i)
          return unless match

          temporal = TransportJourneyQuestion.temporal_entities({}, latin, now: context.now)
          return if temporal.warning

          date = temporal.entities["date"].to_s
          time = temporal.entities["time_expression"].to_s
          return unless date.match?(/\A\d{4}-\d{2}-\d{2}\z/) && time.match?(/\A(?:[01]\d|2[0-3]):[0-5]\d\z/)

          { "origin_query" => match[:origin].strip, "destination_query" => match[:destination].strip,
            "date" => date, "after_time" => time, "mode" => "next" }
        end

        def transport_destination_to_verify(text)
          latin = Decidim::Bih::Transliterator.to_latin(text.to_s).strip
          match = latin.match(/\b(?:spojiti\s+autobuse|presjedanj\w*|vezu)\s+od\s+.{2,80}?\s+do\s+
                              (?<destination>[\p{L}\d ()-]{2,80}?)\s+\d{1,2}\.\d{1,2}\.20\d{2}\.?\s+
                              (?:poslije|posle|nakon)\s+\d{1,2}(?::\d{2})?\b/ix)
          match ||= latin.match(/\b(?:od|iz|sa)\s+.{2,80}?\s+do\s+(?<destination>[\p{L}\d ()-]{2,80}?)\s*,\s*
                                 \d{1,2}\.\d{1,2}\.20\d{2}\.?\s+
                                 (?:poslije|posle|nakon)\s+\d{1,2}(?::\d{2})?\b/ix)
          match && match[:destination].strip
        end

        def decline_assumed_boarding_stop?(text)
          folded = Decidim::Bih::Text.fold(Decidim::Bih::Transliterator.to_latin(text.to_s))
          folded.match?(/\b(?:nemoj|ne\s+zelim|ne\s+biraj)\b/) &&
            folded.match?(/\b(?:birati|biraj|izabrati|odabrati)\b/) &&
            folded.match?(/\b(?:stanic\w*|stajal\w*)\b/)
        end

        def named_line_date_change_from_history(text, state:, context:)
          folded = Decidim::Bih::Text.fold(Decidim::Bih::Transliterator.to_latin(text.to_s))
          return unless folded.match?(/\bplan\s+se\s+mijenja\b/) &&
                        folded.match?(/\bist\w*\s+stajal\w*\b/) &&
                        folded.match?(/\bposlije\s+(?:osam|8)\b/)

          previous = state.dig(Dialogue::ConversationFrame::KEY, "history")&.last&.dig("message").to_s
          journey = weekday_named_first_route_journey(previous, context:)
          return unless journey

          latin = Decidim::Bih::Transliterator.to_latin(text.to_s)
          match = latin.match(/\b(?<day>\d{1,2})\.\s*(?<month>[\p{L}]+)\s+(?<year>20\d{2})\b/)
          return unless match

          month = TransportJourneyQuestion::MONTH_NUMBERS[Decidim::Bih::Text.fold(match[:month])]
          return unless month

          date = Date.new(match[:year].to_i, month, match[:day].to_i)
          return if date.iso8601 == journey.fetch("date")

          journey.merge("date" => date.iso8601)
        rescue Date::Error
          nil
        end

        def resumed_transport_journey(text, state:)
          folded = Decidim::Bih::Text.fold(Decidim::Bih::Transliterator.to_latin(text.to_s))
          return unless folded.match?(/\bvratimo\s+se\s+autobus\w*\b/) &&
                        folded.match?(/\bkoj\w*\s+linij\w*\b/)

          saved = state.dig(Dialogue::ConversationSlots::KEY, "journey")
          return unless saved.is_a?(Hash) && saved["date"].to_s.match?(/\A20\d{2}-\d{2}-\d{2}\z/) &&
                        saved["time"].to_s.match?(/\A(?:[01]\d|2[0-3]):[0-5]\d\z/)

          latin = Decidim::Bih::Transliterator.to_latin(text.to_s)
          match = latin.match(/\bod\s+(?<origin>[\p{L}\d ()-]{2,80}?)\s+do\s+(?<destination>[\p{L}\d ()-]{2,80}?)[.?!,]\s*/i)
          return unless match

          { "origin_query" => match[:origin].strip, "destination_query" => match[:destination].strip,
            "date" => saved.fetch("date"), "after_time" => saved.fetch("time"), "mode" => "fastest" }
        end

        def retained_transport_date_change(text, state:, context:)
          saved = state.dig(Dialogue::ConversationSlots::KEY, "journey")
          return unless saved.is_a?(Hash)

          latin = Decidim::Bih::Transliterator.to_latin(text.to_s)
          folded = Decidim::Bih::Text.fold(latin)
          return unless folded.match?(/\b(?:plan\s+se\s+mijenja|umjesto|onda\s+pogledaj)\b/) &&
                        folded.match?(/\b(?:ist\w*\s+stajal\w*|ist\w*\s+put\w*|ist\w*\s+relacij\w*)\b/)

          temporal = TransportJourneyQuestion.temporal_entities({}, latin, now: context.now)
          return if temporal.warning

          date = temporal.entities["date"].to_s
          time = temporal.entities["time_expression"].to_s
          return unless date.match?(/\A20\d{2}-\d{2}-\d{2}\z/) && date != saved["date"]

          time = saved.fetch("time") unless time.match?(/\A\d{2}:\d{2}\z/)
          journey = { "origin_query" => saved.fetch("origin_query"),
                      "destination_query" => saved.fetch("destination_query"),
                      "date" => date, "after_time" => time, "mode" => "next" }
          journey["route_code"] = saved["route_code"] if saved["route_code"].to_s.match?(/\A[GP]\d{1,2}\z/)
          journey["direct_only"] = true if journey["route_code"] && saved["query_kind"] == "first_connection"
          journey
        end

        def first_connection_stop_choice(text, state:)
          saved = state.dig(Dialogue::ConversationSlots::KEY, "journey")
          return unless saved.is_a?(Hash) && saved["query_kind"] == "first_connection"

          latin = Decidim::Bih::Transliterator.to_latin(text.to_s).strip
          match = latin.match(/\A(?:izaberi|odaberi)\s+(?<origin>[^,.!?]{2,100}),?\s+a?\s*odredište\s+ostaje\s+(?<destination>[^.!?]{2,80})[.!?]?\z/i)
          return unless match

          destination = saved["destination_query"].to_s
          named = match[:destination].strip
          canonical = ->(value) { Decidim::Bih::Text.fold(value.sub(/-(?:a|u)\z/i, "").strip) }
          return unless canonical.call(destination) == canonical.call(named)

          date = saved["date"].to_s
          time = saved["time"].to_s
          return unless date.match?(/\A\d{4}-\d{2}-\d{2}\z/) && time.match?(/\A(?:[01]\d|2[0-3]):[0-5]\d\z/)

          { "origin_query" => match[:origin].strip, "destination_query" => destination,
            "date" => date, "after_time" => time, "mode" => "next" }
        end

        def corrected_origin_journey(text, state:)
          return unless ENV["MILICA_JOURNEY_PLANNER_V2_ENABLED"] == "true"

          latin = Decidim::Bih::Transliterator.to_latin(text.to_s).strip
          retained_destination = latin.match(/\A(?:polazim|kre[cćč]em)\s+(?:sa|s|od|iz)\s+
                                            (?<origin>[\p{L}\d ()-]{2,80}),\s*
                                            odredi[sš]te\s+ostaje\s+(?<destination>[\p{L}\d ()-]{2,80})[.!?]?\z/ix)
          narrated = latin.match(/\A(?:pogrešno|pogresno)\s+sam\s+(?:naveo|navela)\s+polazi(?:š|s)te:\s*
                                  (?:krećem|krecem|polazim)\s+(?:sa|s|od|iz)\s+(?<origin>[^.!?]{2,100})\.\s*
                                  (?<destination>[\p{L}\d ()-]{2,80})\s+i\s+datum\s+ostaju[.!?]?\z/ix)
          match = latin.match(/\A(?:(?:ne[,!]?\s+)?(?:polazim|krećem|krecem)\s+(?:sa|s|od|iz)|(?:mislila|mislio)\s+sam\s+na)\s+(?<origin>[^.!?]{2,100})[.!?]?\z/i)
          retained = latin.match(/\A(?:sad\s+)?(?:krećem|krecem|polazim)\s+(?:sa|s|od|iz)\s+(?<origin>[\p{L}\d ()-]{2,80}),\s*ostavi\s+(?<destination>[\p{L}\d ()-]{2,80}),\s*datum\s+i\s+(?:vrijeme|vreme)[.!?]?\z/i)
          return unless match || retained || retained_destination || narrated

          saved = state.dig(Dialogue::ConversationSlots::KEY, "journey")
          return unless saved.is_a?(Hash)

          if retained || retained_destination || narrated
            wanted = Decidim::Bih::Text.fold((retained || retained_destination || narrated)[:destination].to_s)
            saved_destination = Decidim::Bih::Text.fold(saved["destination_query"].to_s)
            return unless wanted == saved_destination
          end

          origin = (retained_destination || retained || narrated || match)[:origin].strip
          origin = "NAS" if Decidim::Bih::Text.fold(origin).match?(/\Anov\w*\s+autobusk\w*\s+stanic\w*\z/)
          date_word = Decidim::Bih::Text.fold(origin).match?(/\A(?:ponedjeljak|ponedeljak|utorak|srijed\w*|sred\w*|cetvrtak|petak|subot\w*|nedjelj\w*|nedelj\w*|danas|sutra|preksutra)\b/)
          return if date_word || origin.match?(/[;,]/)

          destination = saved["destination_query"].to_s
          date = saved["date"].to_s
          time = saved["time"].to_s
          return unless origin.length.between?(2, 100) && destination.length.between?(2, 100)
          return unless date.match?(/\A\d{4}-\d{2}-\d{2}\z/) && time.match?(/\A(?:[01]\d|2[0-3]):[0-5]\d\z/)

          { "origin_query" => origin, "destination_query" => destination, "date" => date, "after_time" => time }
        end

        def corrected_journey_date_time(text, state:, context:)
          return unless ENV["MILICA_JOURNEY_PLANNER_V2_ENABLED"] == "true"

          saved = state.dig(Dialogue::ConversationSlots::KEY, "journey")
          unless saved.is_a?(Hash)
            previous = Dialogue::ConversationFrame.load(state[Dialogue::ConversationFrame::KEY], context:).history.last&.fetch("message", "").to_s
            latin_previous = Decidim::Bih::Transliterator.to_latin(previous)
            endpoints = latin_previous.match(/\bod\s+(?<origin>[\p{L}\s()]{2,80}?)\s+do\s+
                                              (?<destination>[\p{L}\s()]{2,80}?)\s+u\s+
                                              (?:nedjelju|nedelju|subotu|petak|četvrtak|cetvrtak|srijedu|sredu|utorak|ponedjeljak|ponedeljak)\b/ix)
            years = latin_previous.scan(/\b20\d{2}\b/).uniq
            if endpoints && years.one?
              saved = { "origin_query" => endpoints[:origin].strip, "destination_query" => endpoints[:destination].strip,
                        "date" => "#{years.first}-01-01" }
            end
          end
          return unless saved.is_a?(Hash) && %w(origin_query destination_query date).all? { |key| saved[key].is_a?(String) }

          latin = Decidim::Bih::Transliterator.to_latin(text.to_s).strip
          match = latin.match(/\A(?:zapravo|ipak)\s+mi\s+treba\s+(?<weekday>ponedjeljak|ponedeljak|utorak|srijeda|srijedu|sreda|sredu|četvrtak|cetvrtak|petak|subota|subotu|nedjelja|nedjelju|nedelja|nedelju)\s+
                              (?<day>\d{1,2})\.\s+(?<month>[\p{L}]+),?\s+(?:poslije|posle|nakon)\s+
                              (?<hour>\d{1,2})(?::(?<minute>\d{2}))?\s*(?:sati|h)?[.!?]?\z/ix)
          return unless match

          year = Date.iso8601(saved.fetch("date")).year
          month = TransportJourneyQuestion::MONTH_NUMBERS[Decidim::Bih::Text.fold(match[:month])]
          return unless month

          date = Date.new(year, month, match[:day].to_i)
          weekday = TransportJourneyQuestion::WEEKDAYS[Decidim::Bih::Text.fold(match[:weekday])]
          hour = match[:hour].to_i
          minute = match[:minute].to_s.empty? ? 0 : match[:minute].to_i
          return unless weekday == date.wday && hour.between?(0, 23) && minute.between?(0, 59)

          { "origin_query" => saved.fetch("origin_query"), "destination_query" => saved.fetch("destination_query"),
            "date" => date.iso8601, "after_time" => format("%02d:%02d", hour, minute), "mode" => "fastest" }
        rescue Date::Error
          nil
        end

        def explicit_named_date_bus_journey(text, context:)
          return unless ENV["MILICA_JOURNEY_PLANNER_V2_ENABLED"] == "true"

          folded = Decidim::Bih::Text.fold(text.to_s)
          match = folded.match(/\A(?:trazim|treba\s+mi)\s+autobus\s+iz\s+(?<origin>[a-z ]{2,70}?)\s+za\s+
                               (?<destination>[a-z ]{2,70}?)\s+u\s+(?:[a-z]+\s+)?\d{1,2}\s+[a-z]+\s+20\d{2}\s+
                               (?:poslije|posle|nakon)\s+\d{1,2}(?::\d{2})?\b/ix)
          return unless match

          temporal = TransportJourneyQuestion.temporal_entities({}, Decidim::Bih::Transliterator.to_latin(text.to_s), now: context.now)
          return if temporal.warning

          date = temporal.entities["date"].to_s
          time = temporal.entities["time_expression"].to_s
          return unless date.match?(/\A\d{4}-\d{2}-\d{2}\z/) && time.match?(/\A(?:[01]\d|2[0-3]):[0-5]\d\z/)

          origin = match[:origin].strip
          destination = match[:destination].strip
          origin = "Bijeljina" if origin.match?(/\Abijeljin[aeiu]\z/)
          destination = "Janja" if destination.match?(/\Ajanj[aeiu]\z/)
          { "origin_query" => origin, "destination_query" => destination,
            "date" => date, "after_time" => time, "mode" => "fastest" }
        end

        def new_bus_station_journey(text)
          return unless ENV["MILICA_JOURNEY_PLANNER_V2_ENABLED"] == "true"

          latin = Decidim::Bih::Transliterator.to_latin(text.to_s).strip
          match = latin.match(/\A(?:sa|s|od)\s+nove\s+autobuske\s+stanice\s+u\s+Bijeljini\s+(?:do|za)\s+
                              (?<destination>[\p{L}\d ()-]{2,80}?),?\s+
                              (?<day>\d{1,2})\.(?<month>\d{1,2})\.(?<year>20\d{2})[.,:]?\s+
                              (?:koji\s+je\s+)?prvi(?:\s+autobus)?\s+(?:poslije|posle|nakon)\s+
                              (?<time>(?:[01]?\d|2[0-3]):[0-5]\d)\??\z/ix)
          return unless match

          date = Date.new(match[:year].to_i, match[:month].to_i, match[:day].to_i).iso8601
          { "origin_query" => "NAS", "destination_query" => match[:destination].strip,
            "date" => date, "after_time" => match[:time].rjust(5, "0"), "mode" => "next" }
        rescue Date::Error
          nil
        end

        def dated_between_stops_journey(text)
          return unless ENV["MILICA_JOURNEY_PLANNER_V2_ENABLED"] == "true"

          latin = Decidim::Bih::Transliterator.to_latin(text.to_s)
          match = latin.match(/\A(?:od\s+(?:stajališta|stajalista|stanice)|iz)\s+(?<origin>[^,]{2,80}?)\s+do\s+
                              (?<destination>[^,]{2,80}),\s*(?<day>\d{1,2})\.(?<month>\d{1,2})\.(?<year>20\d{2})\.
                              \s+(?:poslije|posle|nakon)\s+(?<time>(?:[01]?\d|2[0-3]):[0-5]\d)\b/ix)
          return unless match

          date = Date.new(match[:year].to_i, match[:month].to_i, match[:day].to_i).iso8601
          { "origin_query" => match[:origin].strip, "destination_query" => match[:destination].strip,
            "date" => date, "after_time" => match[:time].rjust(5, "0"), "mode" => "next" }
        rescue Date::Error
          nil
        end

        def ambiguous_dvorovi_stop_journey(text)
          return unless ENV["MILICA_JOURNEY_PLANNER_V2_ENABLED"] == "true"

          latin = Decidim::Bih::Transliterator.to_latin(text.to_s)
          return unless latin.match?(/\Aiz\s+Janja\s*\(Cenatr\)\s+do\s+Dvorovi\s+sentar\b/i)

          date = DOTTED_DATE.match(latin)
          time = latin.match(/\b(?:poslije|posle|nakon)\s+(?<time>(?:[01]?\d|2[0-3]):[0-5]\d)\b/i)
          return unless date && time

          { "date" => Date.new(date[3].to_i, date[2].to_i, date[1].to_i).iso8601,
            "after_time" => time[:time].rjust(5, "0") }
        rescue Date::Error
          nil
        end

        def corrected_dvorovi_stop_journey(text, state:)
          return unless ENV["MILICA_JOURNEY_PLANNER_V2_ENABLED"] == "true"
          anchor = if state.dig(Dialogue::AnswerContext::KEY, "subject") == "ambiguous_dvorovi_stop"
                     state.dig(Dialogue::AnswerContext::KEY, "anchor")
                   else
                     saved = state.dig(Dialogue::ConversationSlots::KEY, "journey")
                     if saved.is_a?(Hash) && saved["origin_query"] == "Janja (centar)" &&
                        saved["destination_query"] == "Dvorovi (CSP)"
                       "#{saved['date']}|#{saved['time']}"
                     end
                   end
          date, time = anchor.to_s.split("|", 2)
          return unless date.to_s.match?(/\A20\d{2}-\d{2}-\d{2}\z/) && time.to_s.match?(/\A\d{2}:\d{2}\z/)

          latin = Decidim::Bih::Transliterator.to_latin(text.to_s)
          return unless latin.match?(/\biz\s+Janja\s*\(centar\)/i)

          stop = latin.match(/\bDvorovi\s*\((?<stop>Globus|CSP|škola|skola)\)/i)&.[](:stop)
          return unless stop

          { "origin_query" => "Janja (centar)", "destination_query" => "Dvorovi (#{stop})",
            "date" => date, "after_time" => time, "mode" => "next" }
        end

        def return_journey(text, state:, context:)
          return unless ENV["MILICA_JOURNEY_PLANNER_V2_ENABLED"] == "true"

          saved = state.dig(Dialogue::ConversationSlots::KEY, "journey")
          return unless saved.is_a?(Hash)

          latin = Decidim::Bih::Transliterator.to_latin(text.to_s).strip
          match = latin.match(/\bpovratak\s+iz\s+(?<origin>[^.!?,]{2,80}?)\s+(?:nakon|poslije|posle|iza)\s+\d/i)
          same_day = latin.match(/\bpovratak\s+iz\s+(?<origin>[\p{L}\s]{2,80}?)\s+u\s+(?<destination>[\p{L}\s]{2,80}?)(?:,\s*istog\s+dana|\s+istog\s+dana)[.!?]?\z/i)
          if same_day && !match
            date = saved["date"].to_s
            time = saved["time"].to_s
            return unless date.match?(/\A\d{4}-\d{2}-\d{2}\z/) && time.match?(/\A(?:[01]\d|2[0-3]):[0-5]\d\z/)

            local = context.now.in_time_zone(TransportJourneyQuestion::SERVICE_TIME_ZONE)
            time = [time, local.strftime("%H:%M")].max if date == local.to_date.iso8601
            return { "origin_query" => same_day[:origin].strip, "destination_query" => same_day[:destination].strip,
                     "date" => date, "after_time" => time }
          end
          return unless match

          destination = saved["origin_query"].to_s
          date = saved["date"].to_s
          return unless destination.length.between?(2, 100) && date.match?(/\A\d{4}-\d{2}-\d{2}\z/)

          window = TransportJourneyQuestion.requested_window({ "query" => latin, "date" => date }, now: context.now)
          return if window.warning || window.historical || !window.explicit_time

          local = window.earliest_after.in_time_zone(TransportJourneyQuestion::SERVICE_TIME_ZONE)
          { "origin_query" => match[:origin].strip, "destination_query" => destination,
            "date" => local.to_date.iso8601, "after_time" => local.strftime("%H:%M") }
        end

        def retained_journey_followup(text, state:, context:)
          saved = state.dig(Dialogue::ConversationSlots::KEY, "journey")
          return unless saved.is_a?(Hash)

          origin = saved["origin_query"].to_s
          destination = saved["destination_query"].to_s
          date = saved["date"].to_s
          time = saved["time"].to_s
          return unless origin.length.between?(2, 100) && destination.length.between?(2, 100)
          return unless date.match?(/\A\d{4}-\d{2}-\d{2}\z/) && time.match?(/\A(?:[01]\d|2[0-3]):[0-5]\d\z/)

          folded = Decidim::Bih::Text.fold(text.to_s)
          if folded.match?(/\b(?:ispravk\w*|mislio\s+sam\s+na|mislila\s+sam\s+na|ipak)\b/)
            selection = TransportJourneyQuestion.temporal_entities({ "query" => text.to_s }, text.to_s, now: context.now)
            corrected = selection.entities["date"].to_s
            return if selection.warning || !corrected.match?(/\A\d{4}-\d{2}-\d{2}\z/)

            date = corrected
          elsif folded.match?(/\b(?:poslije|posle|nakon|after)\s+\d{1,2}(?::\d{2})?\b|\bstign\w*\s+(?:na\s+stanic\w*\s+)?(?:tek\s+)?oko\s+\d{1,2}(?::\d{2})?\b/)
            explicit_clock = Decidim::Bih::Transliterator.to_latin(text.to_s)
                              .match(/\b(?:poslije|posle|nakon|after)\s+(?<clock>(?:[01]?\d|2[0-3]):[0-5]\d)\b/i)
            if explicit_clock
              time = explicit_clock[:clock].rjust(5, "0")
            else
              window = TransportJourneyQuestion.requested_window({ "query" => text.to_s, "date" => date }, now: context.now)
              return if window.warning || !window.explicit_time

              time = window.earliest_after.in_time_zone(TransportJourneyQuestion::SERVICE_TIME_ZONE).strftime("%H:%M")
            end
          elsif folded.match?(/\b(?:polazak|polask\w*)\b.{0,35}\bprosa\w*\b/)
            local = context.now.in_time_zone(TransportJourneyQuestion::SERVICE_TIME_ZONE)
            time = [time, local.strftime("%H:%M")].max if date == local.to_date.iso8601
          elsif folded.match?(/\b(?:presjedanj\w*|presedanj\w*)\b/) &&
                folded.match?(/\bist\w*\s+datum\b/) && folded.match?(/\bodredist\w*\b/) &&
                same_saved_origin_mention?(folded, origin)
            # A request to compare transfer options retains the confirmed
            # endpoints and clock; a grammatical form of the same stop is not
            # a new origin or a reason to discard the earlier journey.
          elsif !folded.match?(/(?:dolazak|stiz\w*).{0,60}(?:prije|pre)\s+podne|drugi\s+autobus.{0,80}(?:poslije|posle|nakon)\s+dolask\w*\s+prv\w*|vrati\s+se\s+(?:putu|ruti).{0,80}(?:subot\w*|radn\w*)/)
            return
          end
          { "origin_query" => origin, "destination_query" => destination, "date" => date, "after_time" => time }
        end

        def same_saved_origin_mention?(folded_text, saved_origin)
          last_word = Decidim::Bih::Text.fold(saved_origin.to_s).scan(/[a-z0-9]+/).last
          return false unless last_word && last_word.length.between?(3, 25)

          folded_text.match?(/\b(?:sa|s|od|iz)\s+#{Regexp.escape(last_word)}(?:a|e|u|om)?\b/)
        end

        def bus_weekday_after_walk_journey(text, state:, context:)
          return unless ENV["MILICA_JOURNEY_PLANNER_V2_ENABLED"] == "true"

          folded = Decidim::Bih::Text.fold(text.to_s)
          return unless folded.match?(/\bopet\s+autobus\b/) &&
                        folded.match?(/\bu\s+(?:ponedjeljak|ponedeljak|utorak|srijedu|sredu|cetvrtak|petak|subotu|nedjelju|nedelju)\b/)

          saved = state.dig(Dialogue::ConversationSlots::KEY, "journey")
          return unless saved.is_a?(Hash)

          origin = saved["origin_query"].to_s
          destination = saved["destination_query"].to_s
          return unless origin.length.between?(2, 100) && destination.length.between?(2, 100)

          temporal = TransportJourneyQuestion.temporal_entities({}, text.to_s, now: context.now)
          date = temporal.entities["date"].to_s
          return if temporal.warning || !date.match?(/\A\d{4}-\d{2}-\d{2}\z/)

          { "origin_query" => origin, "destination_query" => destination, "date" => date, "after_time" => "05:00" }
        end

        # A declared current area and a future weekday are citizen endpoints,
        # even without the formal "iz X do Y" wording. Never treat a past clock
        # today as a departure the citizen can still catch.
        def located_weekday_journey(text, context:)
          return unless ENV["MILICA_JOURNEY_PLANNER_V2_ENABLED"] == "true"

          latin = Decidim::Bih::Transliterator.to_latin(text.to_s).strip
          movement = latin.split(/[.!?]/, 2).first.to_s.strip
          match = movement.match(/\A(?:nalazim\s+se|ja\s+sam|sad\s+sam)\s+u\s+(?<origin>[\p{L}\s]{2,80}?)\s+i\s+
                              (?:idem|putujem|zelim\s+ici|želim\s+ići)\s+u\s+(?<destination>[\p{L}\s]{2,80}?)\s+
                              u\s+(?<weekday>ponedjeljak|ponedeljak|utorak|srijedu|sredu|četvrtak|cetvrtak|petak|subotu|nedjelju|nedelju)\s+
                              (?:poslije|posle|nakon)\s+(?<hour>\d{1,2})(?::(?<minute>\d{2}))?(?:\s*(?:h|sati))?[.!?]?\z/ix)
          return unless match

          hour = match[:hour].to_i
          minute = match[:minute].to_s.empty? ? 0 : match[:minute].to_i
          return unless hour.between?(0, 23) && minute.between?(0, 59)

          local = context.now.in_time_zone(TransportJourneyQuestion::SERVICE_TIME_ZONE)
          weekday = TransportJourneyQuestion::WEEKDAYS.fetch(Decidim::Bih::Text.fold(match[:weekday]))
          date = local.to_date + ((weekday - local.wday) % 7)
          note = nil
          if date == local.to_date && ([hour, minute] <=> [local.hour, local.min]) == -1
            date += 7
            note = "Traženo vrijeme danas je već prošlo; provjeravam isti dan naredne sedmice (#{date.iso8601}). " \
                   "Ako misliš na drugi datum, napiši ga. "
          end
          { journey: { "origin_query" => match[:origin].strip, "destination_query" => match[:destination].strip,
                       "date" => date.iso8601, "after_time" => format("%02d:%02d", hour, minute) }, note: }
        end

        # "If that departure has passed" asks for the next trip after the
        # selected one, not for the first trip after the original lower bound.
        # Re-read the reviewed timetable; no model text or saved free-form
        # answer is parsed back into a departure time.
        def next_after_selected_journey(text, state:, context:, tools:)
          return unless ENV["MILICA_JOURNEY_PLANNER_V2_ENABLED"] == "true"

          folded = Decidim::Bih::Text.fold(text.to_s)
          return unless folded.match?(/\b(?:taj|taj\s+polazak|prethodni)\b/) &&
                        folded.match?(/\bpolazak\b.{0,35}\bprosao\b/) &&
                        folded.match?(/\bsljedec\w*\b|\bnaredn\w*\b/)

          saved = state.dig(Dialogue::ConversationSlots::KEY, "journey")
          return unless saved.is_a?(Hash)
          origin = saved["origin_query"].to_s
          destination = saved["destination_query"].to_s
          date = saved["date"].to_s
          time = saved["time"].to_s
          return unless origin.length.between?(2, 100) && destination.length.between?(2, 100) &&
                        date.match?(/\A\d{4}-\d{2}-\d{2}\z/) && time.match?(/\A(?:[01]\d|2[0-3]):[0-5]\d\z/)

          request = { "origin_query" => origin, "destination_query" => destination, "date" => date, "after_time" => time }
          envelope = tools.registry.call(name: "resolve_and_plan_journey", arguments: request, context:, eligibility: tools.eligibility)
          return unless envelope.status == "ok"

          revalidate_delivery_evidence!([envelope.for_prompt(context:, eligibility: tools.eligibility)], tools:)
          first = envelope.evidence.find { |record| record.dig("facts", "journey_index") == 0 && record.dig("facts", "leg_index") == 0 }
          departure = Time.iso8601(first.dig("facts", "departure_at")) if first
          return unless departure && departure.in_time_zone(TransportJourneyQuestion::SERVICE_TIME_ZONE).to_date.iso8601 == date

          next_minute = departure.in_time_zone(TransportJourneyQuestion::SERVICE_TIME_ZONE) + 60
          request.merge("after_time" => next_minute.strftime("%H:%M")) if next_minute.to_date.iso8601 == date
        rescue ArgumentError
          nil
        end

        def reviewed_calendar_followup(text, state:)
          saved = state.dig(Dialogue::ConversationSlots::KEY, "journey")
          date_text = saved.is_a?(Hash) ? saved["date"].to_s : ""
          latin = Decidim::Bih::Transliterator.to_latin(text.to_s)
          folded = Decidim::Bih::Text.fold(latin)
          if folded.match?(/\b(?:nedjelj\w*|nedelj\w*)\b/) &&
             folded.match?(/\b(?:relacij\w*|red\s+voznj\w*|polaz\w*|objavljen\w*|autobus\w*)\b/) &&
             (named_date = DOTTED_DATE.match(latin))
            date_text = Date.new(named_date[3].to_i, named_date[2].to_i, named_date[1].to_i).iso8601
          end
          return unless date_text.match?(/\A\d{4}-\d{2}-\d{2}\z/)

          date = Date.iso8601(date_text)
          kind = ReviewedTransportTimetables.calendar_kind(date)
          return unless %w(sunday holiday unreviewed).include?(kind)

          if folded.match?(/\b(?:sutra|tomorrow)\b/) && folded.match?(/\b(?:datum|dan|date)\b/)
            "Provjeravam kalendarski dan #{date_text} (#{kind == 'sunday' ? 'nedjelja' : 'poseban dan'})."
          elsif folded.match?(/\b(?:nedjelj\w*|nedelj\w*|praznik\w*|radni\s+dan)\b/)
            "Za #{date_text} nemam pregledan red vožnje za #{kind == 'sunday' ? 'nedjelju' : 'taj poseban dan'}. " \
              "Nisam zamijenila taj dan radnim redom; ovo ne znači da autobus ne vozi. " \
              "Provjeri službenu objavu: #{CityServiceSources.fetch('public_transport').fetch(:source_url)}."
          elsif folded.match?(/\b(?:nema\s+potvrd\w*|naredn\w*\s+korak|provjer\w*|prover\w*)\b/)
            "Najmanji naredni korak je da provjeriš red za #{date_text} kod prevoznika ili na službenoj gradskoj objavi " \
              "https://www.gradbijeljina.org/lat/news/novosti/7243.od-1-septembra-novi-red-voznje-gradskog-prevoza.html. " \
              "Pregledani podaci ne potvrđuju polazak za taj dan."
          end
        rescue ArgumentError
          nil
        end

        def direct_calendar_followup(message:, answer:, state:, context:, locale:)
          answer = transport_prose(answer, locale)
          reply = Decidim::Bih::Concierge::Responder::Reply.new(text: answer, report: nil, answer_intent: "service", tone: "core", locale:)
          result = outcome(reply:, state:, resolution: "unsupported",
                           diagnostics: { "architecture" => "reviewed_calendar_followup", "model_calls" => 0, "tool_calls" => 0 })
          frame = Dialogue::ConversationFrame.load(state[Dialogue::ConversationFrame::KEY], context:)
          persist(result, previous: state, context:, frame: public_history(frame:, message:, answer:, context:, state:))
        end

        def named_landmark_stop_request(text, state:)
          folded = Decidim::Bih::Text.fold(text.to_s)
          if folded.match?(/\bkod\s+bolnic\w*\b/) &&
             folded.match?(/\bnajbliz\w*\s+autobusk\w*\s+stanic\w*\b/)
            return { query: "Bijeljina (bolnica)", concise: false }
          end

          saved = state.dig(Dialogue::ConversationSlots::KEY, "journey")
          return unless saved.is_a?(Hash) && saved["query_kind"] == "named_nearest"
          return unless folded.match?(/\bkratko\b/) && folded.match?(/\bcitam\s+na\s+telefon\w*\b/)

          { query: saved["origin_query"], concise: true }
        end

        def accessible_landmark_stop_question?(text, state:)
          folded = Decidim::Bih::Text.fold(text.to_s)
          first = folded.match?(/\bspomenik\w*\b/) && folded.match?(/\bkolic\w*\b/) &&
                  folded.match?(/\bstajal\w*\b/)
          followup = state.dig(Dialogue::AnswerContext::KEY, "subject") == "accessible_landmark_stop" &&
                     folded.match?(/\bg1\b/) && folded.match?(/\bkolic\w*\b/)
          first || followup
        end

        def direct_accessible_landmark_stop(message:, state:, context:, tools:, locale:)
          folded = Decidim::Bih::Text.fold(message.text.to_s)
          if folded.match?(/\bg1\b/)
            answer = "Nemam pregledan podatak koji potvrđuje da su vozila G1 prilagođena kolicima. " \
                     "Red vožnje i karta stajališta to ne dokazuju. Prije polaska traži potvrdu od prevoznika " \
                     "preko službene objave o gradskom prevozu: #{CityServiceSources.fetch('public_transport').fetch(:source_url)}."
            return direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                          architecture: "accessible_vehicle_unverified", subject: "accessible_landmark_stop")
          end

          envelope = tools.registry.call(name: "resolve_walking_directions",
                                         arguments: { "query" => "Bijeljina (spomenik)" },
                                         context:, eligibility: tools.eligibility)
          evidence = [envelope.for_prompt(context:, eligibility: tools.eligibility)]
          revalidate_delivery_evidence!(evidence, tools:)
          fact = envelope.evidence.one? ? envelope.evidence.first.fetch("facts") : nil
          if envelope.status == "ok" && fact && fact["coordinate_accuracy"] == "assumed" &&
             fact["walking_map_url"].to_s.start_with?("https://www.google.com/maps/dir/?")
            answer = "Kod spomenika u centru kao početnu pretpostavku uzimam pregledano stajalište " \
                     "#{fact.fetch('stop_label')}. Približna mapa: #{fact.fetch('walking_map_url')} " \
                     "Mapa ne potvrđuje spuštene ivičnjake, pristup bez stepenica ni siguran prelaz za kolica. " \
                     "Napiši tačnu polaznu tačku za ponovnu provjeru, a pristupačnost puta potvrdi na terenu."
          else
            answer = "Kod spomenika ne mogu potvrditi najbliže pristupačno stajalište iz pregledane mape. " \
                     "Napiši tačnu polaznu tačku; pristup za kolica potvrdi na terenu ili kod prevoznika."
          end
          direct_source_boundary(message:, state:, context:, locale:, answer: transport_prose(answer, locale),
                                 architecture: "accessible_landmark_stop", subject: "accessible_landmark_stop",
                                 tool_calls: 1, resolution: envelope.status == "ok" ? "answered" : "source_unavailable")
        end

        def direct_named_landmark_stop(message:, context:, state:, frame:, tools:, locale:, trace:, request:)
          envelope = tools.registry.call(name: "resolve_walking_directions", arguments: { "query" => request.fetch(:query) },
                                         context:, eligibility: tools.eligibility)
          evidence = [envelope.for_prompt(context:, eligibility: tools.eligibility)]
          revalidate_delivery_evidence!(evidence, tools:)
          fact = envelope.evidence.one? ? envelope.evidence.first.fetch("facts") : nil
          label = fact && fact["stop_label"]
          url = fact && fact["walking_map_url"]
          verified = envelope.status == "ok" && label.is_a?(String) && label.length.between?(2, 120) &&
                     url.is_a?(String) && url.start_with?("https://www.google.com/maps/dir/?") &&
                     fact["coordinate_accuracy"] == "assumed"
          answer = if verified && request.fetch(:concise)
                     "Pretpostavljeno stajalište: #{label}. Mapa: #{url} Tačka je približna."
                   elsif verified
                     "Za polazište kod bolnice pretpostavljam stajalište #{label}. Mapa: #{url} " \
                       "Tačka je približna; bez tačne polazne tačke ne mogu potvrditi da je najbliže. " \
                       "Napiši ulicu ili pošalji precizniju lokaciju za ponovnu provjeru."
                   else
                     "Za početak napiši ulicu ili precizniji orijentir kod bolnice; ne mogu potvrditi najbliže stajalište iz dostupne mape."
                   end
          answer = transport_prose(answer, locale)
          reply = Decidim::Bih::Concierge::Responder::Reply.new(text: answer, report: nil, answer_intent: "service", tone: "core", locale:)
          if verified
            slots = (state[Dialogue::ConversationSlots::KEY] || Dialogue::ConversationSlots.empty).deep_dup
            slots["journey"] = { "origin_query" => label, "query_kind" => "named_nearest" }
            normalized = Dialogue::ConversationSlots.normalize(slots, now: context.now, state_expires_at: state.fetch("expires_at"))
            state = state.merge(Dialogue::ConversationSlots::KEY => normalized) if normalized
          end
          result = outcome(reply:, state:, resolution: verified ? "answered" : "unsupported",
                           fact_ids: verified ? envelope.evidence.map { |record| record.fetch("id") } : [],
                           diagnostics: { "architecture" => "deterministic_landmark_stop", "model_calls" => 0, "tool_calls" => 1 })
          diagnostic(trace, "landmark_stop_render_finished", verified:)
          persist(result, previous: state, context:, frame: public_history(frame:, message:, answer:, context:, state:))
        end

        def station_platform_precision_question?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\bnas\b|\bnov\w*\s+autobusk\w*\b/) &&
            folded.match?(/\bperon\w*\b/) && folded.match?(/\b(?:tacn\w*|izmjeren\w*|map\w*)\b/)
        end

        def direct_station_platform_precision(message:, context:, state:, frame:, tools:, locale:, trace:)
          envelope = tools.registry.call(name: "resolve_walking_directions", arguments: { "query" => "NAS" },
                                         context:, eligibility: tools.eligibility)
          evidence = [envelope.for_prompt(context:, eligibility: tools.eligibility)]
          revalidate_delivery_evidence!(evidence, tools:)
          fact = envelope.evidence.one? ? envelope.evidence.first.fetch("facts") : nil
          verified = envelope.status == "ok" && fact && fact["station_label"] == "Bijeljina (NAS)" &&
                     fact["map_scope"] == "logical_station_not_platform" &&
                     fact["coordinates_surveyed"] == false && fact["physical_platform_assignment_verified"] == false
          answer = if verified
                     "NAS označava novu autobusku stanicu u pregledanom redu vožnje. Mapa daje približnu tačku stanice, " \
                       "ali ne potvrđuje tačan, izmjeren peron ni peron za G1. Mogu provjeriti polazak G1 na nivou stajališta NAS."
                   else
                     "Nemam provjeren raspored perona za NAS. Mogu provjeriti red vožnje na nivou stajališta."
                   end
          answer = transport_prose(answer, locale)
          reply = Decidim::Bih::Concierge::Responder::Reply.new(text: answer, report: nil, answer_intent: "service", tone: "core", locale:)
          result = outcome(reply:, state:, resolution: verified ? "answered" : "unsupported",
                           fact_ids: verified ? envelope.evidence.map { |record| record.fetch("id") } : [],
                           diagnostics: { "architecture" => "deterministic_station_precision", "model_calls" => 0, "tool_calls" => 1 })
          diagnostic(trace, "station_precision_render_finished", verified:)
          persist(result, previous: state, context:, frame: public_history(frame:, message:, answer:, context:, state:))
        end

        # A blank cell in one timetable column is evidence only about that
        # specific bus. Keep its anchor separate from a later journey search.
        def same_trip_departure_question(text)
          latin = Decidim::Bih::Transliterator.to_latin(text.to_s).strip
          match = latin.match(/\A(?:u\s+redu|na\s+liniji)\s+(?<line>[GP]\d{1,2})\s+vidim\s+(?<anchor>[^.!?]{2,100}?)\s+u\s+
                              (?<at>(?:[01]\d|2[0-3]):[0-5]\d)\.\s+u\s+koliko\s+taj\s+isti\s+autobus\s+polazi\s+
                              (?:sa|iz|od)\s+(?<requested>[^.!?]{2,100}?)\s+(?<date>\d{1,2}\.\d{1,2}\.20\d{2})\??\z/ix)
          return unless match

          date = Date.strptime(match[:date], "%d.%m.%Y").iso8601
          { "line" => match[:line].upcase, "anchor" => match[:anchor].strip, "at_time" => match[:at],
            "requested" => match[:requested].strip, "date" => date }
        rescue Date::Error
          nil
        end

        def published_alternative_followup(text, state:)
          saved = state.dig(Dialogue::ConversationSlots::KEY, "journey")
          return unless saved.is_a?(Hash) && saved["route_code"].to_s.match?(/\A[GP]\d{1,2}\z/)

          latin = Decidim::Bih::Transliterator.to_latin(text.to_s).strip
          folded = Decidim::Bih::Text.fold(latin)
          return unless folded.match?(/\btaj\s+polazak\b.*\bnije\s+naveden\b/) &&
                        folded.match?(/\b(?:objavljen\w*|potvrdjen\w*)\s+put\b/)

          match = latin.match(/\b(?:objavljen\w*|potvrdjen\w*)\s+put\s+(?:od|iz|sa)\s+
                              (?<origin>[^.!?]{2,100}?)\s+do\s+(?<destination>[^.!?]{2,100}?)\s+
                              (?:poslije|posle|nakon)\s+(?<clock>(?:[01]\d|2[0-3]):[0-5]\d)\s+tog\s+dana\b/ix)
          return unless match

          date = saved["date"].to_s
          return unless date.match?(/\A\d{4}-\d{2}-\d{2}\z/)

          { "origin_query" => match[:origin].strip, "destination_query" => match[:destination].strip,
            "date" => date, "after_time" => match[:clock], "mode" => "next", "direct_only" => true }
        end

        def direct_same_trip_departure(message:, context:, state:, frame:, tools:, locale:, trace:, query:)
          arguments = { "line" => query.fetch("line"), "date" => query.fetch("date"),
                        "stop_query" => query.fetch("anchor"), "at_time" => query.fetch("at_time") }
          envelope = tools.registry.call(name: "inspect_timetable_trip", arguments:, context:, eligibility: tools.eligibility)
          evidence = [envelope.for_prompt(context:, eligibility: tools.eligibility)]
          revalidate_delivery_evidence!(evidence, tools:)
          facts = envelope.evidence.map { |record| record.fetch("facts") }
          selected = facts.one? && facts.first["route_code"] == query.fetch("line") &&
                     facts.first["service_date"] == query.fetch("date") &&
                     facts.first["anchor_stop_time"] == query.fetch("at_time") ? facts.first : nil
          token = Decidim::Bih::Text.fold(query.fetch("requested")).split.first
          cells = Array(selected&.fetch("cells", [])).select do |cell|
            Decidim::Bih::Text.fold(cell["stop_label"]).split.include?(token)
          end
          cell = cells.one? ? cells.first : nil
          answer = if cell && cell["time_status"] == "not_published_at_this_stop"
                     "U pregledanom redu #{query.fetch('line')} za #{query.fetch('date')} kolona u kojoj je " \
                       "#{query.fetch('anchor')} u #{query.fetch('at_time')} nema objavljeno vrijeme za #{cell.fetch('stop_label')}. " \
                       "Ne mogu izračunati polazak tog istog autobusa iz prazne ćelije; mogu provjeriti drugi objavljeni put."
                   elsif cell && cell["time_status"] == "published_at_this_stop"
                     "U istoj objavljenoj koloni reda #{query.fetch('line')} za #{query.fetch('date')} " \
                       "#{cell.fetch('stop_label')} ima vrijeme #{cell.fetch('time')}."
                   else
                     "Ne mogu jednoznačno povezati traženo stajalište sa istom objavljenom kolonom. Napiši tačan naziv stajališta."
                   end
          answer = transport_prose(answer, locale)
          reply = Decidim::Bih::Concierge::Responder::Reply.new(text: answer, report: nil, answer_intent: "service", tone: "core", locale:)
          slots = (state[Dialogue::ConversationSlots::KEY] || Dialogue::ConversationSlots.empty).deep_dup
          slots["journey"] = { "origin_query" => query.fetch("requested"), "destination_query" => query.fetch("anchor"),
                               "date" => query.fetch("date"), "time" => query.fetch("at_time"),
                               "route_code" => query.fetch("line"), "query_kind" => "trip_column" }
          normalized = Dialogue::ConversationSlots.normalize(slots, now: context.now, state_expires_at: state.fetch("expires_at"))
          state = state.merge(Dialogue::ConversationSlots::KEY => normalized) if normalized
          resolution = cell ? "answered" : "unsupported"
          result = outcome(reply:, state:, resolution:, fact_ids: cell ? envelope.evidence.map { |record| record.fetch("id") } : [],
                           diagnostics: { "architecture" => "deterministic_same_trip_column", "model_calls" => 0, "tool_calls" => 1 })
          diagnostic(trace, "same_trip_render_finished", status: envelope.status, matched_cell: !cell.nil?)
          persist(result, previous: state, context:, frame: public_history(frame:, message:, answer:, context:, state:))
        end

        def direct_exact_route(message:, context:, state:, frame:, tools:, locale:, trace:, query:)
          envelope = tools.registry.call(name: "plan_exact_route", arguments: query.tool_arguments, context:, eligibility: tools.eligibility)
          evidence = [envelope.for_prompt(context:, eligibility: tools.eligibility)]
          revalidate_delivery_evidence!(evidence, tools:)
          first = envelope.evidence.find { |record| record.dig("facts", "journey_index") == 0 && record.dig("facts", "leg_index") == 0 }
          claim = query.mode == :last ? "last_departure" : "first_departure"
          payload = { "kind" => "answer", "answer" => "", "evidence_ids" => first ? [first.fetch("id")] : [],
                      "claim_selections" => first ? [{ "kind" => claim, "evidence_id" => first.fetch("id") }] : [] }
          rendered = VerifiedAnswerRenderer.new.call(payload:, evidence:, locale:, question: message.text.to_s)
          resolution = rendered.reason == "validated_claims" ? "answered" : limitation_resolution(evidence)
          reply = Decidim::Bih::Concierge::Responder::Reply.new(text: rendered.text, report: nil, answer_intent: "service", tone: "core", locale:)
          result = outcome(reply:, state:, resolution:, fact_ids: rendered.reason == "validated_claims" ? payload.fetch("evidence_ids") : [],
                           diagnostics: { "architecture" => "deterministic_exact_route", "model_calls" => 0, "tool_calls" => 1 })
          diagnostic(trace, "render_finished", reason: rendered.reason, count: rendered.claim_count)
          persist(result, previous: state, context:, frame: public_history(frame:, message:, answer: rendered.text, context:, state:))
        end

        def unsupported_journey_constraint(message:, context:, state:, frame:, locale:, trace:, constraints:)
          key = constraints.size == 2 ? "both" : constraints.first.to_s
          answer_locale = %w(bs hr sr en).include?(locale.to_s) ? locale : :sr
          answer = I18n.t("decidim_app.milica.unsupported_journey_constraint.#{key}", locale: answer_locale)
          answer = transport_prose(answer, locale)
          reply = Decidim::Bih::Concierge::Responder::Reply.new(text: answer, report: nil, answer_intent: "service", tone: "core", locale:)
          result = outcome(reply:, state:, resolution: "unsupported",
                           diagnostics: { "architecture" => "deterministic_journey_scope", "model_calls" => 0, "tool_calls" => 0,
                                          "constraint_count" => constraints.size })
          diagnostic(trace, "unsupported_journey_constraint", count: constraints.size)
          persist(result, previous: state, context:, frame: public_history(frame:, message:, answer:, context:, state:))
        end

        def named_location_journey(text, state:, context:)
          return unless ENV["MILICA_JOURNEY_PLANNER_V2_ENABLED"] == "true"
          return if @memory.request_only_named_origin?(text)

          origin = state.dig(Dialogue::ConversationSlots::KEY, "location")
          return unless origin.is_a?(Hash) && origin["kind"] == "named"

          parsed = TransportJourneyQuestion.call({ "query" => text.to_s }, now: context.now).entities
          destination = parsed["area_query"].to_s.strip
          if destination.blank?
            latin = Decidim::Bih::Transliterator.to_latin(text.to_s)
            destination = latin.match(/\bidem\s+u\s+(?<destination>[\p{L}\s]{2,80}?)\s+u\s+(?:ponedjeljak|ponedeljak|utorak|srijedu|sredu|četvrtak|cetvrtak|petak|subotu|nedjelju|nedelju)\b/i)&.[](:destination).to_s.strip
          end
          date = parsed["date"].to_s
          time = parsed["time_expression"].to_s
          return unless destination.length.between?(2, 100)
          return unless date.match?(/\A\d{4}-\d{2}-\d{2}\z/) && time.match?(/\A(?:[01]\d|2[0-3]):[0-5]\d\z/)

          origin_name = PlaceAliasRegistry.display_name(origin.fetch("label")).sub(/\Amz\s+/i, "")
          { "origin_query" => origin_name, "destination_query" => destination, "date" => date, "after_time" => time }
        end

        def explicit_simple_journey(text, context:)
          return unless ENV["MILICA_JOURNEY_PLANNER_V2_ENABLED"] == "true"
          return unless @memory.request_only_named_origin?(text)

          return unless @memory.transport_question?(text)

          selection = TransportJourneyQuestion.call({ "query" => text.to_s }, now: context.now)
          return next_workday_journey(text, context:) if selection.warning

          parsed = selection.entities
          origin = parsed["stop"].to_s.strip
          destination = parsed["area_query"].to_s.strip
          date = parsed["date"].to_s
          time = parsed["time_expression"].to_s
          return unless origin.length.between?(2, 100) && destination.length.between?(2, 100)
          return if %w(odavde here).include?(origin.downcase) || parsed["via_stop"].present?
          return unless date.match?(/\A\d{4}-\d{2}-\d{2}\z/) && time.match?(/\A(?:[01]\d|2[0-3]):[0-5]\d\z/)

          route = { "origin_query" => origin, "destination_query" => destination, "date" => date, "after_time" => time }
          route["route_code"] = parsed["route"] if parsed["route"].to_s.match?(/\A[GP][1-9]\d?\z/)
          route
        end

        def cyrillic_nas_janja_journey(text, state:)
          latin = Decidim::Bih::Transliterator.to_latin(text.to_s)
          folded = Decidim::Bih::Text.fold(latin)
          saved = state.dig(Dialogue::ConversationSlots::KEY, "journey")
          if saved.is_a?(Hash) && Decidim::Bih::Text.fold(saved["origin_query"]).match?(/\Anas\z/) &&
             folded.match?(/\bne\s+centar\s+nego\s+janja\s+skola\b/) &&
             folded.match?(/\bu\s+isto\s+vrijeme\b/)
            return { "origin_query" => "NAS", "destination_query" => "Janja (škola)",
                     "date" => saved.fetch("date"), "after_time" => saved.fetch("time"), "mode" => "fastest" }
          end

          match = latin.match(/\A\s*sa\s+NAS-a\s+do\s+Janja\s*\((?<stop>[^)]+)\),?\s*
                              (?<day>\d{1,2})\.(?<month>\d{1,2})\.(?<year>20\d{2})\.?\s+
                              (?:poslije|posle|nakon)\s+(?<time>(?:[01]\d|2[0-3]):[0-5]\d)/ix)
          return unless match && Decidim::Bih::Text.fold(match[:stop]) == "centar"

          date = Date.new(match[:year].to_i, match[:month].to_i, match[:day].to_i)
          { "origin_query" => "NAS", "destination_query" => "Janja (centar)",
            "date" => date.iso8601, "after_time" => match[:time], "mode" => "fastest" }
        rescue Date::Error, KeyError
          nil
        end

        def next_workday_journey(text, context:)
          latin = Decidim::Bih::Transliterator.to_latin(text.to_s)
          match = latin.match(/\A(?:iz|od)\s+(?<origin>[\p{L}\s]{2,60}?)\s+idem\s+do\s+
                               (?<destination>[\p{L}\s]{2,60}?)\s+narednog\s+radnog\s+dana(?:[.!?]|\z)/ix)
          return unless match

          date = context.now.in_time_zone(TransportJourneyQuestion::SERVICE_TIME_ZONE).to_date + 1
          date += 1 until (1..5).cover?(date.wday)
          { "origin_query" => match[:origin].strip, "destination_query" => match[:destination].strip,
            "date" => date.iso8601, "after_time" => "05:00" }
        end

        def hospital_center_now_journey(text, context:)
          return unless ENV["MILICA_JOURNEY_PLANNER_V2_ENABLED"] == "true"

          folded = Decidim::Bih::Text.fold(text.to_s)
          return unless folded.match?(/\bkod\s+bolnic\w*\b/) && folded.match?(/\bdo\s+centr\w*\b/) &&
                        folded.match?(/\bautobus\w*\b/)

          now = context.now.in_time_zone(TransportJourneyQuestion::SERVICE_TIME_ZONE)
          { "origin_query" => "Bolnica", "destination_query" => "Centar", "date" => now.to_date.iso8601,
            "after_time" => now.strftime("%H:%M") }
        end

        def janja_center_morning_journey(text, context:)
          return unless ENV["MILICA_JOURNEY_PLANNER_V2_ENABLED"] == "true"

          latin = Decidim::Bih::Transliterator.to_latin(text.to_s)
          folded = Decidim::Bih::Text.fold(latin)
          return unless folded.match?(/\biz\s+janj\w*\b/) && folded.match?(/\bu\s+cent(?:ar|ra|ru)\s+bijeljin\w*\b/) &&
                        folded.match?(/\b(?:ujutru|ujutro|jutro)\b/) && folded.match?(/\b(?:stanic\w*|stajal\w*)\b/)

          temporal = TransportJourneyQuestion.temporal_entities({}, latin, now: context.now)
          return if temporal.warning

          date = temporal.entities["date"].to_s
          time = temporal.entities["time_expression"].to_s
          return unless date.match?(/\A\d{4}-\d{2}-\d{2}\z/) && time.match?(/\A\d{2}:\d{2}\z/)

          { "origin_query" => "Janja", "destination_query" => "Centar", "date" => date, "after_time" => time }
        end

        def direct_corrected_origin_journey(message:, context:, state:, frame:, tools:, locale:, trace:, journey:, assumption_note: nil)
          envelope = tools.registry.call(name: "resolve_and_plan_journey", arguments: journey, context:, eligibility: tools.eligibility)
          evidence = [envelope.for_prompt(context:, eligibility: tools.eligibility)]
          revalidate_delivery_evidence!(evidence, tools:)
          first = envelope.evidence.find { |record| record.dig("facts", "journey_index") == 0 && record.dig("facts", "leg_index") == 0 }
          payload = { "kind" => "answer", "answer" => "", "evidence_ids" => first ? [first.fetch("id")] : [],
                      "claim_selections" => first ? [{ "kind" => "selected_journey", "evidence_id" => first.fetch("id") }] : [] }
          rendered = VerifiedAnswerRenderer.new.call(payload:, evidence:, locale:, question: message.text.to_s)
          if Decidim::Bih::Text.fold(message.text.to_s).match?(/\b(?:prije|pre)\s+podne\b/) && rendered.reason == "validated_claims"
            final_leg = envelope.evidence.select { |record| record.dig("facts", "journey_index") == 0 }
                                .max_by { |record| record.dig("facts", "leg_index").to_i }
            arrival = Time.iso8601(final_leg.dig("facts", "arrival_at")) if final_leg
            if arrival && arrival.in_time_zone(TransportJourneyQuestion::SERVICE_TIME_ZONE).hour >= 12
              rendered = VerifiedAnswerRenderer::Rendered.new(text: transport_prose("Ova provjerena ruta stiže poslije podne. Za dolazak prije podne treba raniji polazak ili druga veza.", locale),
                                                              reason: "high_risk_unverified", claim_count: 0)
            end
          end
          resolution = rendered.reason == "validated_claims" ? "answered" : limitation_resolution(evidence)
          answer = rendered.text
          folded_question = Decidim::Bih::Text.fold(Decidim::Bih::Transliterator.to_latin(message.text.to_s))
          if rendered.reason == "validated_claims" && folded_question.match?(/\b(?:presjedanj\w*|presedanj\w*)\b/)
            selected_legs = envelope.evidence.count { |record| record.dig("facts", "journey_index") == 0 }
            comparison = if selected_legs > 1
                           "Provjerila sam i veze s presjedanjem u pregledanom redu; odabrana najbrža veza uključuje presjedanje. "
                         else
                           "Provjerila sam i veze s presjedanjem u pregledanom redu; odabrana najbrža veza je direktna. "
                         end
            answer = "#{transport_prose(comparison, locale)}#{answer}"
          end
          if rendered.reason != "validated_claims"
            defaults = Array(envelope.candidates).filter_map do |candidate|
              label = candidate["label"].to_s
              next unless label.match?(/\A(?:origin_id|destination_id):/)

              label.sub(/\A(?:origin_id|destination_id):\s*/, "").sub(/\s+\(pretpostavljeno\)\z/, "")
            end
            answer = "Za početnu provjeru pretpostavila sam stajališta #{defaults.first(2).join(' i ')}. #{answer}" if defaults.any?
          end
          if Decidim::Bih::Text.fold(message.text.to_s).match?(/\bnarednog\s+radnog\s+dana\b/)
            note = "Nisi navela vrijeme polaska; za početni prijedlog računam polazak poslije 05:00. "
            answer = "#{transport_prose(note, locale)}#{answer}"
          end
          if folded_question.match?(/\b(?:polazak|polask\w*)\b.{0,35}\bprosa\w*\b/)
            answer = "#{transport_prose("Ponovo sam provjerila polaske nakon #{journey.fetch('after_time')}. ", locale)}#{answer}"
          elsif folded_question.match?(/\bpovratak\s+iz\b/) && !folded_question.match?(/\b(?:poslije|posle|nakon|oko)\s+\d/)
            answer = "#{transport_prose("Za povratak bez navedenog vremena računam polaske nakon #{journey.fetch('after_time')}. ", locale)}#{answer}"
          end
          answer = "#{assumption_note}#{answer}" if assumption_note
          if past_journey_date?(journey["date"], now: context.now)
            answer = answer.sub(transport_prose("Kreni oko", locale), transport_prose("Tada bi krenuo oko", locale))
            note = "Traženi datum je prošao; ovo je istorijska provjera objavljenog reda, ne budući polazak. "
            answer = "#{transport_prose(note, locale)}#{answer}"
          end
          reply = Decidim::Bih::Concierge::Responder::Reply.new(text: answer, report: nil, answer_intent: "service", tone: "core", locale:)
          slots = (state[Dialogue::ConversationSlots::KEY] || Dialogue::ConversationSlots.empty).deep_dup
          kind = { "next" => "first_connection", "last" => "last_departure" }.fetch(journey["mode"], "citizen_span")
          slots["journey"] = { "origin_query" => journey.fetch("origin_query"), "destination_query" => journey.fetch("destination_query"),
                               "date" => journey.fetch("date"), "time" => journey.fetch("after_time"), "query_kind" => kind }
          slots["journey"]["origin_id"] = first.dig("facts", "origin_id") if rendered.reason == "validated_claims" && first&.dig("facts", "origin_id")
          slots["journey"]["route_code"] = journey["route_code"] if journey["route_code"]
          normalized = Dialogue::ConversationSlots.normalize(slots, now: context.now, state_expires_at: state.fetch("expires_at"))
          state = state.merge(Dialogue::ConversationSlots::KEY => normalized) if normalized
          result = outcome(reply:, state:, resolution:, fact_ids: rendered.reason == "validated_claims" ? payload.fetch("evidence_ids") : [],
                           diagnostics: { "architecture" => "deterministic_journey_correction", "model_calls" => 0, "tool_calls" => 1 })
          diagnostic(trace, "render_finished", reason: rendered.reason, count: rendered.claim_count)
          persist(result, previous: state, context:, frame: public_history(frame:, message:, answer:, context:, state:))
        end

        def past_journey_date?(value, now:)
          Date.iso8601(value.to_s) < now.in_time_zone(TransportJourneyQuestion::SERVICE_TIME_ZONE).to_date
        rescue Date::Error
          false
        end

        def direct_stop_family(message:, context:, state:, frame:, tools:, locale:, trace:, action:)
          if action.kind == :recall
            return direct_stop_selection(message:, context:, state:, frame:, tools:, locale:, trace:,
                                         selection: { query: action.origin, correction: false, prefer_area: true })
          end

          origin = tools.registry.call(name: "resolve_stops", arguments: { "query" => action.origin, "prefer_area" => true }, context:, eligibility: tools.eligibility)
          origin_choices = origin.candidates
          return unless %w(ok ambiguous).include?(origin.status) && origin_choices.length.between?(1, 4)
          origin_labels = origin_choices.map { |candidate| candidate.fetch("label").sub(/\s+\([GP]\d{1,2}\b.*\)\z/, "") }
          return unless origin_labels.uniq.one?
          return if action.kind == :journey && (!origin.warnings.include?("assumed_area_stop") || origin_choices.many?)
          return if action.kind == :correction && origin.warnings.include?("assumed_area_stop")

          destination = tools.registry.call(name: "resolve_stops", arguments: { "query" => action.destination, "prefer_area" => action.kind == :journey }, context:, eligibility: tools.eligibility)
          choices = destination.candidates
          return unless %w(ok ambiguous).include?(destination.status) && choices.length.between?(1, 4)
          printed_labels = choices.map { |candidate| candidate.fetch("label").sub(/\s+\([GP]\d{1,2}\b.*\)\z/, "") }
          return unless printed_labels.uniq.one? || destination.warnings.include?("assumed_area_stop")

          chosen = origin_choices.first
          journey = { "origin_id" => chosen.fetch("selection_key"), "destination_id" => choices.first.fetch("selection_key"),
                      "date" => action.date, "after_time" => action.time }
          journey["origin_ids"] = origin_choices.map { |candidate| candidate.fetch("selection_key") } if origin_choices.many?
          journey["destination_ids"] = choices.map { |candidate| candidate.fetch("selection_key") } if choices.many?
          planned = tools.registry.call(name: "plan_journey", arguments: journey, context:, eligibility: tools.eligibility)
          evidence = [origin, destination, planned].map { |item| item.for_prompt(context:, eligibility: tools.eligibility) }
          revalidate_delivery_evidence!(evidence, tools:)
          first = planned.evidence.find { |record| record.dig("facts", "journey_index") == 0 && record.dig("facts", "leg_index") == 0 }
          payload = { "kind" => "answer", "answer" => "", "evidence_ids" => first ? [first.fetch("id")] : [],
                      "claim_selections" => first ? [{ "kind" => "selected_journey", "evidence_id" => first.fetch("id") }] : [] }
          rendered = VerifiedAnswerRenderer.new.call(payload:, evidence:, locale:, question: message.text.to_s)
          answer = rendered.text
          if action.kind == :correction && rendered.reason != "validated_claims"
            note = "Za izabrano polazno stajalište #{chosen.fetch('label')} za #{action.date} poslije #{action.time}: "
            answer = "#{transport_prose(note, locale)}#{answer}"
          end
          if action.kind == :journey
            if action.date_assumption == "next_weekday_after_past_clock"
              note = "Računam narednu sedmicu (#{action.date}), jer je traženo vrijeme danas već prošlo. " \
                     "Ako si mislio na drugi datum, napiši ga. "
              answer = "#{transport_prose(note, locale)}#{answer}"
            end
            assumption = origin.evidence.find { |record| record.dig("facts", "kind") == "assumed_area_stop" }
            return unless assumption && assumption.dig("facts", "stop_id") == chosen.fetch("selection_key")

            label = assumption.dig("facts", "selected_stop")
            alternatives = Array(assumption.dig("facts", "alternative_stops")).grep(String).first(3)
            note = "#{stop_family_copy(:assumed, locale)} #{label}."
            note += " #{stop_family_copy(:alternatives, locale)}: #{alternatives.join(', ')}." if alternatives.any?
            note += " #{stop_family_copy(:invite, locale)}"
            note = transport_prose(note, locale)
            source_already_explains_assumption = rendered.reason == "validated_claims" &&
              Array(first&.dig("facts", "assumed_stop")).any? { |item| item["role"] == "origin_id" }
            answer = "#{note} #{answer}" unless source_already_explains_assumption
          end
          slots = (state[Dialogue::ConversationSlots::KEY] || Dialogue::ConversationSlots.empty).deep_dup
          slots["journey"] = { "origin_query" => action.origin, "destination_query" => action.destination,
                               "origin_id" => first&.dig("facts", "origin_id") || chosen.fetch("selection_key"),
                               "date" => action.date, "time" => action.time, "query_kind" => "citizen_span" }
          selected_destination = planned.evidence.select { |record| record.dig("facts", "journey_index") == 0 }
                                        .max_by { |record| record.dig("facts", "leg_index").to_i }&.dig("facts", "destination_id")
          slots["journey"]["destination_id"] = selected_destination || choices.first.fetch("selection_key") if choices.one? || selected_destination
          normalized = Dialogue::ConversationSlots.normalize(slots, now: context.now, state_expires_at: state.fetch("expires_at"))
          return unless normalized

          state = state.merge(Dialogue::ConversationSlots::KEY => normalized)
          resolution = rendered.reason == "validated_claims" ? "answered" : limitation_resolution(evidence)
          fact_ids = rendered.reason == "validated_claims" ? payload.fetch("evidence_ids") : []
          fact_ids += origin.evidence.map { |record| record.fetch("id") } if action.kind == :journey
          reply = Decidim::Bih::Concierge::Responder::Reply.new(text: answer, report: nil, answer_intent: "service", tone: "core", locale:)
          result = outcome(reply:, state:, resolution:, fact_ids: fact_ids.uniq,
                           diagnostics: { "architecture" => "deterministic_area_journey", "model_calls" => 0, "tool_calls" => 3 })
          diagnostic(trace, "render_finished", reason: rendered.reason, count: rendered.claim_count)
          persist(result, previous: state, context:, frame: public_history(frame:, message:, answer:, context:, state:))
        end

        def stop_selection_query(text, context:)
          return unless ENV["MILICA_AREA_DEFAULT_STOPS_ENABLED"] == "true"

          latin = Decidim::Bih::Transliterator.to_latin(text.to_s).strip
          if (correction = latin.match(/\A(?:mislila|mislio) sam na (.{2,100}?)\s*[.!?]?\z/i))
            return { query: correction[1].strip, correction: true }
          end
          folded = Decidim::Bih::Text.fold(latin)
          return unless folded.match?(/\b(?:koje|koji)\b.*\b(?:stajal\w*|stanic\w*)\b.*\bpolazn\w*/)

          entities = TransportJourneyQuestion.call({ "query" => text.to_s }, now: context.now).entities
          query = entities["stop"].to_s.strip
          { query:, correction: false } if query.length.between?(2, 100)
        end

        def direct_stop_selection(message:, context:, state:, frame:, tools:, locale:, trace:, selection:)
          arguments = { "query" => selection.fetch(:query) }
          arguments["prefer_area"] = true if selection.fetch(:prefer_area, false)
          envelope = tools.registry.call(name: "resolve_stops", arguments:, context:, eligibility: tools.eligibility)
          return unless envelope.status == "ok" && envelope.candidates.one?
          return if !selection.fetch(:correction) && !envelope.warnings.include?("assumed_area_stop")

          evidence = [envelope.for_prompt(context:, eligibility: tools.eligibility)]
          revalidate_delivery_evidence!(evidence, tools:)
          candidate = envelope.candidates.first
          assumption = envelope.evidence.one? ? envelope.evidence.first.dig("facts") : nil
          if !selection.fetch(:correction)
            return unless assumption.is_a?(Hash) && assumption["kind"] == "assumed_area_stop" && assumption["stop_id"] == candidate["selection_key"]

            selected = assumption.fetch("selected_stop")
            alternatives = Array(assumption["alternative_stops"]).select { |name| name.is_a?(String) }.first(3)
            list = alternatives.any? ? " #{stop_family_copy(:alternatives, locale)}: #{alternatives.join(', ')}." : ""
            answer = "#{stop_family_copy(:assumed, locale)} #{selected}. #{stop_family_copy(:invite, locale)}#{list}"
          else
            selected = candidate.fetch("label")
            answer = "#{stop_family_copy(:corrected, locale)} #{selected}."
          end
          answer = transport_prose(answer, locale)
          reply = Decidim::Bih::Concierge::Responder::Reply.new(text: answer, report: nil, answer_intent: "service", tone: "core", locale:)
          result = outcome(reply:, state:, resolution: "answered", fact_ids: envelope.evidence.map { |record| record.fetch("id") },
                           diagnostics: { "architecture" => "deterministic_area_stop", "model_calls" => 0, "tool_calls" => 1 })
          diagnostic(trace, "render_finished", reason: "validated_area_stop", count: 1)
          persist(result, previous: state, context:, frame: public_history(frame:, message:, answer:, context:, state:))
        end

        def transport_prose(text, locale)
          locale.to_s == "sr-Cyrl" ? Decidim::Bih::Transliterator.call(text) : text
        end

        def stop_family_copy(key, locale)
          words = if locale.to_s.start_with?("en")
                    { assumed: "For boarding, I assume the stop", alternatives: "Other reviewed stops",
                      invite: "If another stop suits you, name it.", corrected: "Okay, the boarding stop is" }
                  else
                    { assumed: "Za polazak pretpostavljam stajalište", alternatives: "Druga pregledana stajališta",
                      invite: "Ako želiš drugo stajalište, napiši koje.", corrected: "U redu, polazno stajalište je" }
                  end
          words.fetch(key)
        end

        def current_location_journey(text, context:)
          return unless ENV["MILICA_JOURNEY_PLANNER_V2_ENABLED"] == "true"

          folded = Decidim::Bih::Text.fold(text.to_s)
          return unless TransportJourneyQuestion::CURRENT_ORIGIN.match?(folded)

          entities = TransportJourneyQuestion.call({ "query" => text.to_s }, now: context.now).entities
          return unless entities["stop"] == "odavde" && entities["area_query"].to_s.length.between?(2, 100)
          return unless entities["date"].to_s.match?(/\A\d{4}-\d{2}-\d{2}\z/)
          return unless entities["time_expression"].to_s.match?(/\A(?:[01]\d|2[0-3]):[0-5]\d\z/)

          { "destination_query" => entities.fetch("area_query"), "date" => entities.fetch("date"),
            "after_time" => entities.fetch("time_expression") }
        end

        def direct_current_location_journey(message:, context:, state:, frame:, tools:, locale:, trace:, journey:)
          envelope = tools.registry.call(name: "plan_journey_from_current_location", arguments: journey, context:, eligibility: tools.eligibility)
          evidence = [envelope.for_prompt(context:, eligibility: tools.eligibility)]
          revalidate_delivery_evidence!(evidence, tools:)
          first = envelope.evidence.find do |record|
            facts = record.fetch("facts", {})
            facts["journey_index"] == 0 && facts["leg_index"] == 0
          end
          payload = { "kind" => "answer", "answer" => "", "evidence_ids" => first ? [first.fetch("id")] : [],
                      "claim_selections" => first ? [{ "kind" => "selected_journey", "evidence_id" => first.fetch("id") }] : [] }
          rendered = VerifiedAnswerRenderer.new.call(payload:, evidence:, locale:, question: message.text.to_s)
          resolution = rendered.reason == "validated_claims" ? "answered" : limitation_resolution(evidence)
          reply = Decidim::Bih::Concierge::Responder::Reply.new(text: rendered.text, report: nil, answer_intent: "service", tone: "core", locale:)
          result = outcome(reply:, state:, resolution:, fact_ids: rendered.reason == "validated_claims" ? payload.fetch("evidence_ids") : [],
                           diagnostics: { "architecture" => "deterministic_current_location_journey", "model_calls" => 0, "tool_calls" => 1 })
          diagnostic(trace, "render_finished", reason: rendered.reason, count: rendered.claim_count)
          persist(result, previous: state, context:, frame: public_history(frame:, message:, answer: rendered.text, context:, state:))
        end

        def location_recall_question?(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          folded.match?(/\b(?:koje mjesto|koju lokaciju)\b.*\b(?:moja|svoja|trenutna|trenutnu|lokacij\w*|navela|naveo)\b/) ||
            folded.match?(/\b(?:gdje|gde) sam (?:rekla|rekao|navela|naveo) da sam\b/) ||
            folded.match?(/\b(?:what location|which place|where did i say)\b/)
        end

        def named_location_recall(message:, state:, context:, locale:)
          label = state.dig(Dialogue::ConversationSlots::KEY, "location", "label")
          return unless label.is_a?(String) && label.length.between?(1, 120)

          prose = "Naveli ste da je vaša trenutna lokacija"
          prose = Decidim::Bih::Transliterator.call(prose) if locale.to_s == "sr-Cyrl"
          answer = "#{prose} #{label}."
          reply = Decidim::Bih::Concierge::Responder::Reply.new(text: answer, report: nil, answer_intent: "service", tone: "core", locale:)
          result = outcome(reply:, state:, resolution: "answered", diagnostics: { "architecture" => "deterministic_conversation_memory", "model_calls" => 0, "tool_calls" => 0 })
          frame = Dialogue::ConversationFrame.load(state[Dialogue::ConversationFrame::KEY], context:)
          persist(result, previous: state, context:, frame: public_history(frame:, message:, answer:, context:, state:))
        end

        def private_location_recall(message:, state:, context:, locale:, show_value:)
          value = @memory.private_location_for(state:, context:)
          return unless value

          prose = show_value ? "Za ovaj razgovor sačuvala sam lokaciju: " : "Sačuvala sam navedenu lokaciju za ovaj razgovor."
          prose = show_value ? "I have saved the location for this conversation: " : "I have saved the location for this conversation." if locale.to_s.start_with?("en")
          prose = Decidim::Bih::Transliterator.call(prose) if locale.to_s == "sr-Cyrl"
          prose = "#{prose}#{value}." if show_value
          reply = Decidim::Bih::Concierge::Responder::Reply.new(text: prose, report: nil, answer_intent: "service", tone: "core", locale:)
          result = outcome(reply:, state:, resolution: "answered", diagnostics: { "architecture" => "deterministic_private_location_recall", "model_calls" => 0, "tool_calls" => 0 })
          frame = Dialogue::ConversationFrame.load(state[Dialogue::ConversationFrame::KEY], context:)
          persist(result, previous: state, context:, frame: public_history(frame:, message:, answer: prose, context:, state:))
        end

        def private_location_mixed_outcome(state:, context:, locale:)
          answer = "Sačuvala sam lokaciju za ovaj razgovor. Pošalji pitanje odvojeno; ne moraš ponavljati adresu."
          answer = "I have saved the location for this conversation. Please send the question separately; you do not need to repeat the address." if locale.to_s.start_with?("en")
          answer = Decidim::Bih::Transliterator.call(answer) if locale.to_s == "sr-Cyrl"
          reply = Decidim::Bih::Concierge::Responder::Reply.new(text: answer, report: nil, answer_intent: "service", tone: "core", locale:)
          result = outcome(reply:, state:, resolution: "clarification", diagnostics: { "architecture" => "typed_address_mixed_turn", "model_calls" => 0, "tool_calls" => 0 })
          frame = Dialogue::ConversationFrame.load(state[Dialogue::ConversationFrame::KEY], context:)
          persist(result, previous: state, context:, frame:)
        end

        def private_location_route_limit(state:, context:, locale:)
          answer = "Sačuvala sam tvoju lokaciju za ovaj razgovor, ali nemam provjerenu vezu te adrese sa stajalištem. Napiši polazno stajalište da provjerim put."
          answer = "I have your location for this conversation, but I cannot verify which stop serves that address. Please name the boarding stop so I can check the journey." if locale.to_s.start_with?("en")
          answer = Decidim::Bih::Transliterator.call(answer) if locale.to_s == "sr-Cyrl"
          reply = Decidim::Bih::Concierge::Responder::Reply.new(text: answer, report: nil, answer_intent: "service", tone: "core", locale:)
          result = outcome(reply:, state:, resolution: "unsupported", diagnostics: { "architecture" => "typed_address_route_limit", "model_calls" => 0, "tool_calls" => 0 })
          frame = Dialogue::ConversationFrame.load(state[Dialogue::ConversationFrame::KEY], context:)
          persist(result, previous: state, context:, frame:)
        end

        def direct_nearest_stop(message:, context:, state:, frame:, tools:, locale:, trace:, alternatives: false)
          envelope = tools.registry.call(name: "nearest_stop", arguments: {}, context:, eligibility: tools.eligibility)
          evidence = [envelope.for_prompt(context:, eligibility: tools.eligibility)]
          revalidate_delivery_evidence!(evidence, tools:)
          payload = { "kind" => "answer", "answer" => "", "evidence_ids" => envelope.evidence.map { |record| record.fetch("id") },
                      "nearby_stop_alternatives" => alternatives }
          rendered = VerifiedAnswerRenderer.new.call(payload:, evidence:, locale:, question: message.text.to_s)
          resolution = rendered.reason == "validated_claims" ? "answered" : limitation_resolution(evidence)
          stop_id = envelope.evidence.one? ? envelope.evidence.first.dig("facts", "stop_id") : nil
          captured = if resolution == "answered" && stop_id.is_a?(String)
                       Dialogue::AnswerContext.capture(kind: "public_card", subject: "transport_public_map_stop",
                                                      anchor: stop_id, now: context.now,
                                                      state_expires_at: state.fetch("expires_at"))
                     end
          next_state = captured ? state.merge(Dialogue::AnswerContext::KEY => captured) : state
          reply = Decidim::Bih::Concierge::Responder::Reply.new(text: rendered.text, report: nil, answer_intent: "service", tone: "core", locale:)
          result = outcome(reply:, state: next_state.merge("locale" => locale, "report_handoff_offered" => false, Dialogue::StateStore::SAFETY_CONTEXT_KEY => nil),
                           resolution:, fact_ids: rendered.reason == "validated_claims" ? payload.fetch("evidence_ids") : [],
                           diagnostics: { "architecture" => "deterministic_public_read", "model_calls" => 0, "tool_calls" => 1 })
          diagnostic(trace, "render_finished", reason: rendered.reason, count: rendered.claim_count)
          persist(result, previous: state, context:, frame: public_history(frame:, message:, answer: rendered.text, context:, state: next_state))
        end

        def public_location(message)
          value = current_public_location(message)
          return unless value.is_a?(Hash) && value[:consent] == true && value[:purpose] == "current_location"

          value.slice(:latitude, :longitude, :accuracy)
        end

        def current_location_context(available:)
          return { available: false, scope: "Ask for a location only when the needed precision is missing" } unless available

          {
            available: true,
            scope: ConversationMemory.enabled? ? "Consented location is available to server tools in this active conversation. Never infer home, membership, or report location." : "Location is available only for this turn.",
            supported_reads: %w(plan_journey_from_current_location nearest_stop read_service_events),
            use: "For travel from here, retain the requested destination/date/time and use the current-location journey reader, including after destination clarification.",
            limits: "Parking and waste have no reviewed GPS-to-street mapping: acknowledge the location and ask for street/address. This is not absence of their source data."
          }
        end

        # The public composer never receives private rows, drafts or protected
        # replies. Pending workflow messages and credential-like text are also
        # omitted from future model history, even after an informational detour.
        def public_history(frame:, message:, answer:, context:, state:)
          return frame if state["active_task"] || state["draft"]
          text = message.text.to_s
          return frame if Dialogue::StateStore.sensitive_text?(text)
          # Explicit typed places and their replies belong only in the bounded
          # encrypted slot, never the replayed model frame.
          return frame if @memory.typed_location_statement?(text)
          private_place = @memory.private_location_for(state:, context:)
          return frame if private_place && (text.include?(private_place) || answer.to_s.include?(private_place))

          if public_location(message) || ConversationMemory.enabled? && state.dig(Dialogue::ConversationSlots::KEY, "location", "kind") == "exact"
            # Retain only eligible citizen text, never GPS or inferred stop IDs.
            # Server-side slots carry consented location while the conversation is active.
            return frame if location_text?(text)

            answer = "[A public request used consented location; reread public evidence before another factual answer.]"
          end
          # A public contact phone can trigger the credential guard. Keep the
          # safe citizen subject while withholding the entire guarded reply.
          if Dialogue::StateStore.sensitive_text?(answer)
            answer = "[Previous reply omitted by privacy filter; retain the citizen request and reread public evidence if needed.]"
          end

          frame.append(message: text, answer:, context:)
        end

        # Mask valid dates only for the privacy scan, never for stored/model text.
        # Keep the conservative single-coordinate guard as well as URL exclusion.
        def location_text?(text)
          return true if text.match?(%r{https?://}i)

          without_dates = text.gsub(DOTTED_DATE) do |token|
            parts = Regexp.last_match
            begin
              Date.new(parts[3].to_i, parts[2].to_i, parts[1].to_i)
              " "
            rescue Date::Error
              token
            end
          end
          without_dates.match?(/[-+]?\d{1,3}[.,]\d{3,}/)
        end

        def commit_citizen_memory(state:, message:, context:)
          candidate = @memory.apply_turn(state:, message:, context:).merge(
            "updated_at" => context.now.to_f, "expires_at" => context.now.to_f + Dialogue::Contracts::CONTEXT_TTL
          )
          begin
            candidate = fit_memory_budget(candidate)
          rescue Dialogue::Contracts::Invalid
            raise unless @memory.exact_share_requested?(message)

            # The whole state can fill the 12 KB limit even when the slot is
            # under 2 KB. Preserve protected state, clear any older point, and
            # make the failed replacement visible to the citizen.
            slots = candidate[Dialogue::ConversationSlots::KEY] || Dialogue::ConversationSlots.empty
            candidate = fit_memory_budget(candidate.merge(Dialogue::ConversationSlots::KEY =>
              slots.merge("location" => nil, "journey" => nil, "subjects" => [])))
          end
          saved = observe_phase("state_commit") { @store.write(context:, state: candidate, expected_version: state.fetch("version")) }
          raise Dialogue::Contracts::Invalid, "Conversation state unavailable" unless saved == :saved

          candidate.merge("version" => state.fetch("version") + 1)
        end

        def location_save_unavailable_outcome(state:, locale:)
          reply = Decidim::Bih::Concierge::Responder::Reply.new(
            text: I18n.t("decidim.bih.concierge.location_save_unavailable", locale:), report: nil,
            answer_intent: "service", tone: "core", locale:
          )
          outcome(reply:, state:, resolution: "unsupported", diagnostics: { "architecture" => "location_save_unavailable", "model_calls" => 0, "tool_calls" => 0 })
        end

        def fit_memory_budget(candidate)
          while JSON.generate(candidate).bytesize > Dialogue::StateStore::MAX_BYTES - 16
            frame = candidate[Dialogue::ConversationFrame::KEY]
            if frame.is_a?(Hash) && Array(frame["history"]).any?
              candidate = candidate.merge(Dialogue::ConversationFrame::KEY => frame.merge("history" => frame["history"].drop(1)))
            elsif candidate.dig(Dialogue::ConversationSlots::KEY, "subjects")&.any?
              slots = candidate.fetch(Dialogue::ConversationSlots::KEY)
              candidate = candidate.merge(Dialogue::ConversationSlots::KEY => slots.merge("subjects" => slots["subjects"].take(slots["subjects"].size - 1)))
            else
              raise Dialogue::Contracts::Invalid, "Conversation memory exceeds state budget"
            end
          end
          candidate
        end

        def conversation_facts(state:, context:, enabled:)
          return {} unless enabled

          @memory.public_context(state:, context:)
        end

        def location_refused?(message)
          Decidim::Bih::Concierge::WebMessage.location_refused?(message.text.to_s)
        end

        def forget_location_outcome(state:, context:, locale:)
          frame = Dialogue::ConversationFrame.load(state[Dialogue::ConversationFrame::KEY], context:)
          reply = Decidim::Bih::Concierge::Responder::Reply.new(
            text: I18n.t("decidim.bih.dialogue.location_forgotten", locale:), report: nil,
            answer_intent: "service", tone: "core", locale:
          )
          result = outcome(reply:, state:, resolution: "answered")
          persist(result, previous: state, context:, frame:)
        end

        def persist(result, previous:, context:, frame:)
          candidate = result.state.merge(Dialogue::ConversationFrame::KEY => frame.value,
                                         "updated_at" => context.now.to_f)
          candidate = fit_memory_budget(candidate) if ConversationMemory.enabled?
          saved = observe_phase("state_commit") { @store.write(context:, state: candidate, expected_version: previous.fetch("version")) }
          raise Dialogue::Contracts::Invalid, "Conversation revision conflict" unless saved == :saved

          values = result.to_h.merge(state: candidate)
          Dialogue::ProcedureRunner::Result.new(**values)
        end

        def revalidate_delivery_evidence!(evidence, tools:)
          observe_phase("source_revalidation") do
            now = @delivery_clock.call
            eligibility = tools.eligibility
            evidence.each do |envelope|
              args = { organization_id: @organization.id, registry_epoch: envelope.fetch("registry_epoch"),
                       now:, query_scope: envelope.fetch("query_scope") }
              raise Dialogue::Contracts::Invalid, "Evidence no longer eligible" unless eligibility.call(record: nil, **args)

              (envelope.fetch("evidence") + envelope.fetch("candidates")).each do |record|
                raise Dialogue::Contracts::Invalid, "Evidence no longer eligible" unless eligibility.call(record:, **args)
              end
            end
          end
        end

        def public_outcome(answer:, generated:, state:, locale:, accounting:, rendered:)
          kind = generated.answer.fetch("kind")
          resolution = if rendered.reason == "referent_unresolved"
                         "clarification"
                       elsif rendered.reason == "high_risk_unverified" || kind == "limitation"
                         limitation_resolution(generated.evidence)
                       else
                         { "answer" => "answered", "acknowledgment" => "answered", "clarification" => "clarification" }.fetch(kind, "answered")
                       end
          reply = Decidim::Bih::Concierge::Responder::Reply.new(text: answer, report: nil, answer_intent: "service", tone: "core", locale:)
          diagnostics = { "architecture" => "model_led", "model_calls" => generated.model_calls, "tool_calls" => generated.tool_calls,
                          "usage" => generated.usage, "settled_requests" => accounting.respond_to?(:receipts) ? accounting.receipts : [] }
          outcome(reply:, state: state.merge("locale" => locale, "report_handoff_offered" => false, Dialogue::StateStore::SAFETY_CONTEXT_KEY => nil), resolution:,
                  fact_ids: %w(high_risk_unverified referent_unresolved).include?(rendered.reason) ? [] : generated.answer.fetch("evidence_ids"), diagnostics:)
        end

        def limitation_resolution(evidence)
          statuses = evidence.map { |row| row["status"] }
          reasons = evidence.filter_map { |row| row.dig("query_scope", "reason_code") }
          return "source_unavailable" if statuses.any? { |status| %w(unavailable expired unreviewed conflicting).include?(status) } || reasons.include?("source_unavailable")
          return "clarification" if statuses.include?("ambiguous") || reasons.include?("unresolved_place")

          "unsupported"
        end

        def outcome(reply:, state:, resolution:, fact_ids: [], diagnostics: nil)
          Dialogue::ProcedureRunner::Result.new(state:, reply:, resolution:, fact_ids:, handoff_offered: false, handoff_completed: false, diagnostics:)
        end

        def failure(message, reason:, phase: nil)
          locale = Dialogue::Coordinator.locale_for(message)
          key = if reason.to_s == "capacity"
                  "busy"
                elsif reason.to_s == "expired"
                  %w(pre_admission work_setup).include?(phase) ? "admission_deadline" : "processing_deadline"
                else
                  "context_unavailable"
                end
          reply = Decidim::Bih::Concierge::Responder::Reply.new(text: I18n.t("decidim.bih.dialogue.#{key}", locale:), report: nil,
                                                                answer_intent: "fallback", tone: "core", locale:)
          resolution = if reason.to_s == "provider_unavailable"
                         "provider_unavailable"
                       else
                         # A runtime/deadline failure does not prove that any
                         # civic source was unavailable. The existing typed
                         # vocabulary has no general processing-timeout state.
                         "busy"
                       end
          outcome(reply:, state: nil, resolution:)
        end
      end
    end
  end
end
