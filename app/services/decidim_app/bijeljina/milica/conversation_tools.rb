# frozen_string_literal: true

require "uri"
require "time"
require_relative "public_tool_evidence"
require_relative "public_knowledge_tools"
require_relative "transport_tools"
require_relative "platform_guidance_tools"
require_relative "budget_snapshot_read"

module DecidimApp
  module Bijeljina
    module Milica
      # Request-local production catalog: existing public projections and prepared
      # sources, never fixture registries or ordinary legacy answering.
      class ConversationTools
        Dialogue = Decidim::Bih::Concierge::Dialogue
        CAPABILITIES = {
          "waste_schedule" => %w(waste), "service_events" => %w(water electricity heating),
          "environment" => %w(weather air_quality water_levels civil_protection roads bulky_waste),
          "public_calls" => %w(public_calls), "reference" => %w(budget gazette donation),
          "catalog" => %w(volunteer community participation rewards facilities), "public_activity" => %w(neighborhood),
          "area" => %w(neighborhood), "mz_contact" => %w(neighborhood), "parking" => %w(parking)
        }.freeze
        CAPABILITY_DESCRIPTIONS = {
          "waste_schedule" => "Reviewed collection days for an actual named street/settlement. Never replace GPS or an unknown street with Bijeljina/the municipality. Not truck status.",
          "service_events" => "Reviewed dated water, electricity or heating notices for a named area or consented current location. Preserve requested date " \
                              "and coverage limits. A query-area match is not proof the returned notice affects that area: check the notice's applicability_to_requested_area status and confirmed_affected_areas before attributing an outage.",
          "environment" => "Reviewed weather, air quality, river levels, civil protection, road or bulky-waste publications. Coverage and freshness may " \
                           "be limited; no unsupported live-status claim.",
          "public_calls" => "Prepared public calls, dates and eligibility. Unreviewed/unavailable is not no calls; only scoped empty means no verified matches. No application or personal eligibility.",
          "reference" => "Public budget, gazette or donation source data. Budget includes the prepared partial allocation table and headline; " \
                         "fiscal_year selects the budget year only.",
          "catalog" => "Publicly visible volunteering, community projects and approved material/community needs, participation, rewards or facilities " \
                       "catalog. For a place to browse projects, choose community/projects even when no project rows are current. Donation totals use read_reference. No signup, payment, redemption or private records.",
          "public_activity" => "Public area activity summaries. Resolve geographic ambiguity; unavailable/unmapped is not no activities. Empty is limited to returned scope/time windows. Not private board or membership.",
          "area" => "Public geographic identity, boundaries and map links for administrative MZ or komsiluk areas. They are distinct kinds. Use " \
                    "area_query with the explicit kind/name (MZ followed by its name), or a known area_slug. Not account policy or the " \
                    "authenticated neighbourhood picker.",
          "mz_contact" => "Public administrative MZ directory contact for the named MZ. Use area_query with MZ and its name, or known MZ area_slug. Not " \
                          "komsiluk membership or account policy. If a citizen guesses the public phone is absent, check the returned directory fact and correct that premise when a public number is present.",
          "parking" => "Reviewed street-to-parking-zone lookup. Supply the street in query, street or address. Published tariffs are available " \
                       "separately through read_parking_tariffs."
        }.freeze
        CAPABILITY_PARAMETERS = {
          "waste_schedule" => %w(query date area_query street address),
          "service_events" => %w(query date area_query area_slug street address),
          "environment" => %w(query date area_query area_slug),
          "public_calls" => %w(query date area_query area_slug),
          "reference" => %w(query date), "catalog" => %w(query date time_expression area_query area_slug),
          "public_activity" => %w(query date area_query area_slug),
          "area" => %w(area_query area_slug), "mz_contact" => %w(query area_query area_slug),
          "parking" => %w(query area_query street address)
        }.freeze
        REUSABLE_TRANSPORT_OPERATIONS = %w(resolve_stops plan_journey resolve_and_plan_journey plan_exact_route
                                           plan_journey_from_current_location service_calendar inspect_timetable_trip
                                           resolve_walking_directions nearest_stop walking_directions).freeze
        attr_reader :registry, :registry_epoch

        def initialize(organization:, source_checker: nil, read_port: nil, timetable: nil, knowledge: nil, location: nil, observer: nil, clock: -> { Time.current }) # rubocop:disable Metrics/ParameterLists -- explicit source injection
          @organization = organization
          @clock = clock
          @location = location&.deep_dup&.freeze
          @observer = observer
          @source_checker = source_checker || CityServiceSourceCheckStore.new(clock:)
          @directory = CityDirectory.for(organization)
          @read_port = read_port || ReadPort.new(organization:, source_checker: @source_checker, directory: @directory)
          @timetable = timetable || PublicTransportTimetable.new(prepared_only: true, snapshot_store: @source_checker, clock:,
                                                                 source_validator: method(:approved_transport_source?))
          @registry_epoch = "public-tools-v1:#{organization.id}"
          @knowledge = knowledge || PublicKnowledgeTools.new(organization:, registry_epoch:, source_checker: @source_checker, directory: @directory)
          @issued = {}
          @checked = {}
          @registry = Dialogue::ReadToolRegistry.new(definitions: definitions.map { |definition| track(definition) })
        end

        # Current public facts, through the same tracked/revalidated readers.
        # No static duplicate policy and no cache of tenant or personal state.
        def initial_evidence(context:)
          [registry.call(name: "read_platform_guidance", arguments: { "subject" => "overview" }, context:, eligibility:)]
        end

        def eligibility = method(:eligible?)

        def capabilities = CAPABILITIES

        def definitions
          transport = TransportTools.new(organization_id: @organization.id, registry_epoch:, timetable: @timetable, notices: [], location: @location, observer: @observer).definitions
          transport = transport.map { |spec| spec.merge("handler" => ->(arguments:, context:) { transport_read(spec.fetch("name"), arguments, context) }) }
          transport + @knowledge.definitions + public_definitions
        end

        private

        # Optional community data must not prevent unrelated public tools from
        # being constructed. Explicitly configured malformed data still raises.
        def configured_biller_ids
          return nil if CivicDomainFacts::CONFIG_DIR.empty?

          CivicDomainFacts.billers.map { |biller| biller.fetch("id") }.presence
        end

        def public_definitions
          scalar = PublicToolEvidence.method(:string)
          capability_definitions + [
            spec("read_directory", "City-office directory: search gives choices; pass a returned selection_key as key for full facts. Candidate id is a citation handle, not the lookup key. Utility contacts use read_civic_guidance; MZ contacts use read_mz_contact.",
                 { "query" => scalar.call(300), "key" => scalar.call(80) }, [], :directory_read),
            spec("read_procedure", "Reviewed procedure instructions, fees and eligibility. Choose key by meaning from this catalogue: #{ServiceProcedures.all.map { |card| "#{card.fetch(:key)}=#{card.fetch(:title)}" }.join('; ')}. " \
                                    "Select directly when the citizen's subject is clear; query is optional discovery. Candidate id is citation only. Missing or unreviewed fields stay unknown; no form submission.",
                 { "query" => scalar.call(300), "key" => scalar.call(80, ServiceProcedures.all.map { |card| card.fetch(:key) }.presence) }, [], :procedure_read),
            spec("read_civic_guidance", "Reviewed utility provider information: contact phones, opening hours, fault-reporting channels, billing guidance; also recycling and " \
                                        "heating coverage limits. For provider contacts use domain billing and the named biller, including electricity for " \
                                        "the configured electricity provider. These are public service facts, not current outages or personal bill balances.",
                 { "domain" => scalar.call(40, %w(billing recycling heating_network)), "biller" => scalar.call(80, configured_biller_ids),
                   "focus" => scalar.call(30, %w(published personal coverage location glass self_haul)) }, %w(domain), :civic_read),
            spec("read_parking_tariffs", "Published parking tariffs and SMS numbers, optionally a zone. Does not pay or locate a street.",
                 { "zone" => scalar.call(12, %w(white red blue)) }, [], :parking_tariffs),
            spec("read_platform_guidance", "Public policy, not private state: points=volunteer signup/attendance/hour approval/redemption; voting=points versus votes; " \
                                           "reports=preparation/privacy/status/no-number recovery; neighborhood=board/picker permissions; feedback=ratings; " \
                                           "account=sign-in/verification; platform=MI home/sharing and operator; launch=event-reward invitations, not neighbor signup; race=scoring/cached standings. Overview is policy, not a source inventory.",
                 { "subject" => scalar.call(30, PlatformGuidanceTools::READ_SUBJECTS) }, %w(subject), :platform_guidance),
            spec("read_public_notice", "Prepared border passenger waits and public benefit notices. Not personal entitlement, account payment or guaranteed current wait.",
                 { "source" => scalar.call(30, %w(bihamk_border pio_notices jfdz_notices)), "query" => scalar.call(500), "date" => scalar.call(10) },
                 %w(source), :public_notice),
            spec("read_foundation", "Foundation community/philanthropic role and local-project support, public contact, funding or idea-call boundary. Distinct from MI platform funding or municipal authority; no private phone/submission.",
                 { "facet" => scalar.call(20, %w(identity contact funding apply)) }, %w(facet), :foundation_read)
          ]
        end

        def capability_definitions
          scalar = PublicToolEvidence.method(:string)
          common = { "query" => scalar.call(500), "date" => scalar.call(10), "time_expression" => scalar.call(80), "area_query" => scalar.call(160), "area_slug" => scalar.call(160),
                     "street" => scalar.call(160), "address" => scalar.call(200) }
          CAPABILITIES.map do |capability, topics|
            name = "read_#{capability}"
            properties = common.slice(*CAPABILITY_PARAMETERS.fetch(capability))
            if capability == "catalog"
              properties["view"] = scalar.call(24, %w(projects material_needs organizations giving_guidance))
              properties["view"]["description"] = "For community only: choose the public data collection by meaning. Material help uses material_needs; funded projects use projects; organization profiles use organizations; payment instructions use giving_guidance. Omit for an overview or other topics."
            end
            properties["place_kind"] = scalar.call(12, %w(mz komsiluk)) if capability == "area"
            properties["topic"] = scalar.call(40, topics) unless topics.one?
            if capability == "reference"
              properties["fiscal_year"] = { "type" => "integer", "minimum" => 1900, "maximum" => 2100,
                                            "description" => "Budget only: requested fiscal year; omitted means current local year." }
            end
            description = "#{CAPABILITY_DESCRIPTIONS.fetch(capability)} #{location_availability(capability)}"
            PublicToolEvidence.definition(name, description, properties, topics.one? ? [] : ["topic"], lambda do |arguments:, context:|
              topic = topics.one? ? topics.first : arguments.fetch("topic")
              values = public_service(arguments.merge("capability" => capability, "topic" => topic), context)
              PublicToolEvidence.envelope(values, organization_id: @organization.id, registry_epoch:, operation: name, arguments:)
            end)
          end
        end

        def location_availability(capability)
          if %w(parking waste_schedule).include?(capability)
            return "No GPS-to-street mapping: acknowledge supplied GPS and ask for the street."
          end

          return "" unless %w(service_events environment catalog public_activity area mz_contact).include?(capability)

          available = @location && (@location[:consent] == true || @location["consent"] == true)
          if available
            "Current consented location is available; explicit area wins. Not residence."
          else
            "No current consented location; use a named place if needed."
          end
        end

        def spec(name, description, properties, required, method)
          PublicToolEvidence.definition(name, description, properties, required, lambda do |arguments:, context:|
            values = public_send(method, arguments, context)
            PublicToolEvidence.envelope(values, organization_id: @organization.id, registry_epoch:, operation: name, arguments:)
          end)
        end

        public

        def public_service(arguments, context)
          capability = arguments.fetch("capability")
          topic = arguments.fetch("topic")
          raise Dialogue::Contracts::Invalid, "Capability/topic mismatch" unless CAPABILITIES.fetch(capability).include?(topic)

          return BudgetSnapshotRead.new(organization: @organization).call(fiscal_year: arguments["fiscal_year"], context:) if capability == "reference" && topic == "budget"
          raise Dialogue::Contracts::Invalid, "Fiscal year only applies to budget" if arguments.has_key?("fiscal_year")

          entities = arguments.except("capability", "topic", "place_kind", "view")
          # Keep a supplied area alongside a named street. The reader uses both
          # to distinguish reviewed streets with the same name in different
          # settlements, and never falls back to a municipality for an unknown
          # specific place.
          place_kind = capability == "mz_contact" ? "mz" : arguments["place_kind"]
          @read_port.public_capability(capability:, topic:, entities:, context:, locale: "sr", location: @location, place_kind:, catalog_view: arguments["view"])
        end

        def directory_read(arguments, context)
          entries = arguments["key"].present? ? [@directory.find(arguments["key"])].compact : @directory.search(arguments.fetch("query", ""), limit: 8)
          if entries.many?
            candidates = entries.map { |entry| { "id" => entry.fetch(:key).to_s, "selection_key" => entry.fetch(:key).to_s, "label" => entry.fetch(:title) } }
            return { status: "ambiguous", candidates:, warnings: %w(directory_search_candidates_not_service_facts choose_directory_key_or_refine_query) }
          end

          facts = entries.flat_map do |entry|
            if (card = ServiceProcedures.find(entry.fetch(:key)))
              next Array(ProcedureRead.new(source_store: @source_checker).call(card:, locale: "sr", now: context.now)[:facts])
            end

            atomic = entry[:content_origin] == "admin_override" ? [] : DirectoryServiceFacts.eligible(DirectoryServiceFacts.all(entry.fetch(:key)), now: context.now)
            unless atomic.empty?
              next atomic.map { |fact| fact.stringify_keys.merge("source_id" => "directory:#{entry.fetch(:key)}", "warning_codes" => ["reviewed_directory_not_live_status"]) }
            end

            { "id" => "directory:#{entry.fetch(:key)}", "source_id" => "directory:#{entry.fetch(:key)}", "text" => entry.fetch(:answer),
              "source_url" => entry[:source_url], "title" => entry[:title], "source_checked_on" => entry[:source_checked_on],
              "content_origin" => entry[:content_origin], "warning_codes" => %w(reviewed_directory_not_live_status unspecified_details_remain_unknown) }
          end
          { status: facts.empty? ? "empty" : "ok", facts:, warnings: ["reviewed_directory_not_live_status"] }
        end

        def procedure_read(arguments, context)
          card = arguments["key"].present? ? ServiceProcedures.find(arguments["key"]) : ServiceProcedures.match_query(arguments["query"])
          unless card
            candidates = ServiceProcedures.all.map { |item| { "id" => item.fetch(:key), "selection_key" => item.fetch(:key), "label" => item.fetch(:title) } }
            return { status: "ambiguous", candidates:, warnings: ["procedure_selection_required"] }
          end
          ProcedureRead.new(source_store: @source_checker).call(card:, locale: "sr", now: context.now)
        end

        def civic_read(arguments, context)
          question = CivicDomainQuestion::Question.new(domain: arguments.fetch("domain").to_sym, biller: arguments["biller"], focus: arguments.fetch("focus", "published").to_sym)
          CivicDomainRead.new(organization: @organization).call(question:, context:, locale: "sr")
        end

        def parking_tariffs(arguments, _context)
          rows = arguments["zone"] ? ParkingZones::TARIFF_AMOUNTS.slice(arguments["zone"]) : ParkingZones::TARIFF_AMOUNTS
          facts = rows.map do |zone, row|
            { "id" => "parking:#{zone}", "source_id" => "parking:tariffs", "text" => row.fetch(:label), "source_url" => ParkingZones::SOURCE_URL,
              "zone" => zone, "tariff" => row, "currency" => "BAM", "amount_unit" => "fening", "reviewed_on" => ParkingZones::TARIFF_VERIFIED_ON.iso8601,
              "published_at" => nil, "updated_at" => nil }
          end
          { status: "ok", facts:, warnings: %w(published_tariff_not_payment_confirmation street_segment_requires_separate_lookup review_date_is_not_publication_or_update_date) }
        end

        def platform_guidance(arguments, context)
          PlatformGuidanceTools.new(organization: @organization).call(subject: arguments.fetch("subject"), context:)
        end

        def public_notice(arguments, context)
          CitizenNoticeRead.new(source_store: @source_checker).read_source(key: arguments.fetch("source"), entities: arguments.except("source"), context:, locale: "sr")
        end

        def foundation_read(arguments, context)
          FoundationRead.new(organization: @organization).read_facet(facet: arguments.fetch("facet"), context:, locale: "sr")
        end

        private

        def transport_read(name, arguments, context)
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          checks = @source_checker.check(keys: ["public_transport"], max_items: CityServiceSourceCheckStore::MAX_ITEMS, deadline: context.deadline)
          notices = checks.select { |check| [:ok, :empty].include?(check.status) }.flat_map(&:notices)
          observe_transport_source_read(started, checks.size)
          tools = TransportTools.new(organization_id: @organization.id, registry_epoch:, timetable: @timetable, notices:, location: @location, observer: @observer)
          handler = tools.definitions.find { |row| row.fetch("name") == name }.fetch("handler")
          handler.call(arguments:, context:)
        end

        def observe_transport_source_read(started, count)
          return unless @observer

          duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round(3)
          @observer.call(phase: "transport_source_read", status: "ok", duration_ms:, count:)
        rescue StandardError
          nil # Diagnostics must never change a public read.
        end

        def approved_transport_source?(url, source_key)
          return false unless source_key == "public_transport"

          configured = URI.parse(CityServiceSources.fetch(source_key).fetch(:source_url))
          candidate = URI.parse(url)
          candidate.scheme == "https" && !candidate.userinfo && candidate.host == configured.host && candidate.port == configured.port
        rescue URI::InvalidURIError, KeyError
          false
        end

        def track(definition)
          handler = definition.fetch("handler")
          definition.merge("handler" => lambda do |arguments:, context:|
            raise Dialogue::Contracts::Invalid, "Public tenant mismatch" unless context.organization_id == @organization.id

            result = scoped(bounded_read(handler, arguments, context), arguments)
            key = PublicToolEvidence.digest(result.query_scope)
            @issued[key] = { handler:, arguments:, context:, result: }
            @checked[key] = result if read_result_reuse?(result.query_scope)
            result
          end)
        end

        def bounded_read(handler, arguments, context)
          CityServiceNoticeCollector.send(:within_deadline, context.deadline) { handler.call(arguments:, context:) }
        end

        def scoped(envelope, arguments)
          Dialogue::EvidenceEnvelope.new(
            organization_id: envelope.organization_id, registry_epoch: envelope.registry_epoch, status: envelope.status,
            evidence: envelope.evidence.map { |record| public_record_identity(with_public_destination(record), "fact") },
            candidates: envelope.candidates.map { |record| public_record_identity(record, "candidate") },
            warnings: envelope.warnings, coverage_complete: envelope.coverage_complete,
            query_scope: envelope.query_scope.merge("subject_ids" => Array(envelope.query_scope["subject_ids"]) + ["query:#{PublicToolEvidence.digest(arguments)}"])
          )
        end

        # Navigation destinations come from authorized host readers, never citizen
        # text. Preserve their route and tenant; do not invent an external source.
        def with_public_destination(record)
          path = record.dig("facts", "source_fact", "destination")
          return record unless path.is_a?(String) && path.start_with?("/") && !path.start_with?("//")
          return record if path.match?(/[\\\x00-\x20]/)

          uri = URI.parse(path)
          return record if uri.host || uri.scheme

          facts = record.fetch("facts")
          routes = facts.fetch("public_routes", {}).merge("destination" => "https://#{@organization.host}#{path}")
          record.merge("facts" => facts.merge("public_routes" => routes))
        rescue URI::InvalidURIError
          record
        end

        # Different readers may describe one source entity with different roles
        # or labels. Canonical citation identity covers the complete returned view;
        # source provenance and explicit reader selection keys remain unchanged.
        def public_record_identity(record, kind)
          record.merge("id" => "#{kind}:#{PublicToolEvidence.digest(record)}")
        end

        def eligible_context?(issued, now)
          return false unless issued

          context = issued.fetch(:context)
          current = @clock.call
          !context.deadline.expired? && now >= context.now && now <= current &&
            current.in_time_zone("Europe/Sarajevo").to_date == context.now.in_time_zone("Europe/Sarajevo").to_date
        end

        def revalidate(key, issued, query_scope)
          if read_result_reuse?(query_scope) && (current = @checked[key]) && reusable_receipt_current?(current, issued, query_scope)
            observe_read_reuse(query_scope)
            return true
          end

          current = scoped(bounded_read(issued.fetch(:handler), issued.fetch(:arguments), issued.fetch(:context)), issued.fetch(:arguments))
          @checked[key] = current
          current.status == issued.fetch(:result).status && current.query_scope == query_scope && current.warnings == issued.fetch(:result).warnings
        end

        def read_result_reuse?(query_scope)
          ENV["MILICA_READ_RESULT_REUSE_ENABLED"] == "true" &&
            REUSABLE_TRANSPORT_OPERATIONS.include?(query_scope["operation"])
        end

        def reusable_receipt_current?(current, issued, query_scope)
          return false unless current.equal?(issued.fetch(:result)) ||
                              (current.status == issued.fetch(:result).status && current.warnings == issued.fetch(:result).warnings)
          return false unless current.query_scope == query_scope

          now = @clock.call
          (current.evidence + current.candidates).all? do |record|
            expiry = record["review_expires_at"] || record["valid_until"]
            expiry.nil? || Time.iso8601(expiry) > now
          end
        rescue ArgumentError, TypeError
          false
        end

        def observe_read_reuse(query_scope)
          @observer&.call(phase: "read_result_reuse", status: "ok", duration_ms: 0, operation: query_scope["operation"], count: 1)
        rescue StandardError
          nil
        end

        def eligible?(record:, organization_id:, registry_epoch:, now:, query_scope:)
          return false unless organization_id == @organization.id && registry_epoch == @registry_epoch

          key = PublicToolEvidence.digest(query_scope)
          issued = @issued[key]
          return false unless eligible_context?(issued, now)

          return revalidate(key, issued, query_scope) if record.nil?

          current = @checked[key]
          current && (current.evidence + current.candidates).include?(record)
        rescue StandardError
          false
        end
      end
    end
  end
end
