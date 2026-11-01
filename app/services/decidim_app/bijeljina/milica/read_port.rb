# frozen_string_literal: true

require "timeout"
require "date"
require "digest"
require "time"
require "uri"
require_relative "parking_question"
require_relative "../parking_zones"
require_relative "transport_fare_answer"
require_relative "transport_journey_question"
require_relative "event_answer"
require_relative "procedure_fee_read"
require_relative "service_follow_up_read"
require_relative "mz_contact_answer"
require_relative "public_neighborhood_activity"
require_relative "neighborhood_notice_selection"
require_relative "neighborhood_activity_read"
require_relative "activity_question_context"
require_relative "foundation_read"
require_relative "read_metrics"
require_relative "civic_domain_question"
require_relative "civic_domain_read"
require_relative "../civic_domain_facts"
require_relative "../place_alias_registry"
require_relative "citizen_notice_read"
require_relative "citizen_reference_read"

module DecidimApp
  module Bijeljina
    module Milica
      # Read-only, tenant-scoped adapter from validated dialogue slots to the
      # existing Bijeljina civic data. It never turns a candidate entity into
      # authority and never returns domain records to the conversation layer.
      class ReadPort
        MAX_FACTS = 8
        MAX_TEXT_LENGTH = 1_000
        MAX_LOCATION_ACCURACY_METERS = 1_000_000
        LOCATION_PURPOSES = %w(current_location resolve_current_question).freeze
        LOCATION_PROVENANCES = %w(browser_geolocation current_turn_browser legacy_explicit_location).freeze
        TRANSPORT_CURRENT_ORIGINS = [
          "odavde", "ovdje", "ovde", "tu", "here", "moja lokacija", "moje lokacije", "moju lokaciju", "mojoj lokaciji",
          "ove lokacije", "ovoj lokaciji", "trenutna lokacija", "trenutne lokacije", "trenutnoj lokaciji",
          "moja trenutna lokacija", "moje trenutne lokacije", "my location", "my current location", "current location"
        ].freeze
        BOARD_LIMIT = 5
        REPORT_LIMIT = 5
        DIRECTORY_TOPIC_KEYS = {
          "waste" => :otpad,
          "water" => :vodovod_servis,
          "electricity" => :struja_iskljucenja,
          "transport" => :javni_prevoz,
          "parking" => :parking,
          "heating" => :toplana_grijanje,
          "roads" => :putevi_saobracaj,
          # Wave 3 package O: reviewed contact cards, answered without an area.
          "health" => :zdravstvo_apoteke,
          "social_welfare" => :socijalna_zastita,
          "agriculture" => :poljoprivreda_podsticaji,
          "permits" => :gradjevinske_dozvole_legalizacija,
          "education" => :upis_skola_vrtic,
          "animals" => :psi_lutalice
        }.freeze
        EVENT_TOPICS = %w(water electricity heating).freeze
        # Questions about what is happening somewhere need the somewhere; a
        # how-to question ("kako da volontiram") keeps the city-wide catalog.
        ACTIVITY_PLACE_TOPICS = %w(volunteer community participation).freeze
        PLACE_BOUND_ACTIVITY = /\b(?:akcij\w*|aktivnost\w*|dogadja\w*|desav\w*|dogod\w*|okupljan\w*|sastan\w*|ciscenj\w*|radn[aeu] akcij\w*|
                                     events?|happening|activit\w*|meetings?|gathering\w*|clean[- ]?ups?)\b/x
        PUBLIC_ACTIONS = %w(ask_information choose_area).freeze
        RELATIVE_DAYS = { "danas" => 0, "today" => 0, "sutra" => 1, "tomorrow" => 1 }.freeze
        # "sada" asks about the present, not about a calendar day. It takes the
        # forward current window; reading it as "today" would answer with an
        # outage that ended this morning. Kept in step with
        # Read::Base::TODAY_EXPRESSIONS, which classifies days rather than
        # windows and therefore folds these into today on purpose.
        CURRENT_EXPRESSIONS = [
          "now", "currently", "right now", "trenutno", "trenutacno", "sada", "sad",
          "momentalno", "odmah", "upravo", "upravo sada", "ovog trenutka", "u ovom trenutku"
        ].freeze
        # A named part of a day is not the whole day. Hours are local wall
        # clock in the service timezone; `to` above 24 rolls into the next day
        # ("noćas" runs 20:00 → 06:00). Without these, "ima li večeras
        # isključenja" fell out of the vocabulary entirely and was answered
        # with "za koji dan pitaš?".
        DAY_PARTS = {
          "jutros" => { day: 0, from: 5, to: 12 }, "jutro" => { day: 0, from: 5, to: 12 },
          "prijepodne" => { day: 0, from: 5, to: 12 }, "prije podne" => { day: 0, from: 5, to: 12 },
          "popodne" => { day: 0, from: 12, to: 18 }, "poslijepodne" => { day: 0, from: 12, to: 18 },
          "poslije podne" => { day: 0, from: 12, to: 18 }, "predvece" => { day: 0, from: 16, to: 20 },
          "veceras" => { day: 0, from: 17, to: 24 }, "uvece" => { day: 0, from: 17, to: 24 },
          "nocas" => { day: 0, from: 20, to: 30 },
          "sutra ujutru" => { day: 1, from: 5, to: 12 }, "sutra ujutro" => { day: 1, from: 5, to: 12 },
          "sutra uvece" => { day: 1, from: 17, to: 24 }
        }.freeze
        # "Ima li najava isključenja?" asks what has been ANNOUNCED, not what
        # is in effect in the next twelve hours. Answering it from the current
        # window is how five announced outages sat in the feed, unmentioned,
        # while the citizen was told there was nothing.
        ANNOUNCEMENT_PATTERN = /\b(?:najav\w*|planiran\w*|planov\w*|predstoj\w*|naredn\w*|slijede\w*|sljede\w*|sledec\w*|iduc\w*|uskoro|ubuduce)\b/
        ANNOUNCEMENT_WINDOW = 14.days

        def initialize(organization:, event_feed: nil, source_checker: nil, timetable: nil, area_matcher: nil, directory: nil, duplicate_finder: nil, waste_schedule: nil) # rubocop:disable Metrics/ParameterLists
          @organization = organization
          @event_feed = event_feed || CityServiceEventFeed.new(organization:)
          @source_checker = source_checker || CityServiceSourceCheckStore.new
          @timetable = timetable || PublicTransportTimetable.new(source_validator: method(:approved_source_url?))
          @area_matcher = area_matcher || CityServiceAreaMatcher.new(organization:)
          @directory = directory || CityDirectory
          @duplicate_finder = duplicate_finder || Decidim::Bih::DuplicateFinder.new
          @bundled_waste_schedule = waste_schedule.nil?
          @waste_schedule = waste_schedule
        end

        def call(action:, topic:, entities:, context:, locale: "sr", location: nil) # rubocop:disable Metrics/ParameterLists
          raise contracts::Invalid, "Trusted context required" unless context.is_a?(contracts::TrustedContext)

          within_deadline(context.deadline) do
            validate_context!(context)
            action = contract_enum!(action, contracts::ACTIONS)
            topic = contract_enum!(topic, contracts::TOPICS)
            locale = contract_enum!(locale.to_s, contracts::LOCALES)
            entities = normalize_entities(entities)
            location = normalize_location(location)

            I18n.with_locale(locale) do
              ReadMetrics.measure(topic:, action:) do
                read_with_supplied_area(action:, topic:, entities:, context:, locale:, location:)
              end
            end
          end
        rescue CityServiceNoticeCollector::DeadlineExceeded
          result("unavailable", warnings: ["deadline_exceeded"])
        rescue CityServiceNoticeCollector::InvalidDeadline
          result("unavailable", warnings: ["invalid_deadline"])
        rescue CivicDomainFacts::MissingDomain
          result("unavailable", warnings: ["reviewed_civic_facts_unavailable"])
        rescue contracts::Invalid
          raise
        rescue StandardError => e
          if defined?(Decidim::Bih::City::WasteScheduleError) && e.is_a?(Decidim::Bih::City::WasteScheduleError)
            return result("unavailable", warnings: ["schedule_unavailable"])
          end

          return result("unavailable", warnings: ["deadline_exceeded"]) if defined?(ActiveRecord::QueryCanceled) && e.is_a?(ActiveRecord::QueryCanceled)

          log_failure(e, action)
          result("unavailable", warnings: ["read_failed"])
        end

        # Broad city-notice questions need published, reviewed records across
        # services and a forward announcement window. The ordinary service
        # reader is scoped to one service and a short current-status window.
        def published_city_notices(context:, locale: "sr", area_slugs: nil)
          raise contracts::Invalid, "Trusted context required" unless context.is_a?(contracts::TrustedContext)

          within_deadline(context.deadline) do
            validate_context!(context)
            return result("not_authorized", warnings: ["public_reads_not_allowed"]) unless context.allows?("public_reads")

            scope = CityServiceEvent.for_organization(organization).citizen_visible.reviewed_facts
                                    .where(state: %w(board_published published)).where.not(published_at: nil)
                                    .where(published_at: ..context.now)
                                    .where("ends_at IS NULL OR ends_at > ?", context.now)
                                    .where("starts_at IS NULL OR starts_at < ?", context.now + ANNOUNCEMENT_WINDOW)
            slugs = Array(area_slugs).map(&:to_s).uniq.first(2)
            scope = published_notice_area_scope(scope, slugs)
            events = scope.order(Arel.sql("COALESCE(starts_at, created_at) ASC"), :id).limit(MAX_FACTS).to_a
            facts = events.map { |event| event_fact(event, locale:, now: context.now) }
            result(facts.empty? ? "empty" : "ok", facts:, source: aggregate_sources(facts),
                                                  coverage: slugs.any? ? { "area_slugs" => slugs, "scope" => "reviewed_published_notices" } : nil,
                                                  warnings: facts.empty? ? ["no_published_notice_in_reviewed_window"] : [])
          end
        rescue CityServiceNoticeCollector::DeadlineExceeded, CityServiceNoticeCollector::InvalidDeadline
          result("unavailable", warnings: ["deadline_exceeded"])
        end

        # Dedicated deterministic follow-up port, never dispatched from model
        # entity slots. The caller supplies an ID from trusted prior evidence.
        def transport_walking_directions(stop_id:, context:, locale: "sr")
          raise contracts::Invalid, "Trusted context required" unless context.is_a?(contracts::TrustedContext)

          within_deadline(context.deadline) do
            validate_context!(context)
            locale = contract_enum!(locale.to_s, contracts::LOCALES)
            return result("not_authorized", warnings: ["public_reads_not_allowed"]) unless context.allows?("public_reads")

            stop = timetable.walking_directions(stop_id:, deadline: context.deadline)
            fact = transport_walking_fact(stop, locale:)
            return result("empty", warnings: ["reviewed_stop_not_found"]) unless fact

            result("ok", facts: [fact], source: { "id" => fact.fetch("source_id"), "label" => fact.fetch("source_label") },
                         warnings: fact.fetch("warning_codes"))
          end
        rescue CityServiceNoticeCollector::DeadlineExceeded, CityServiceNoticeCollector::InvalidDeadline
          result("unavailable", warnings: ["deadline_exceeded"])
        end

        # Stable ID supplied by normalized server-side evidence, never model
        # query slots. The usual tenant, actor, deadline and read policy apply.
        def service_follow_up(source_id:, focus:, context:, locale: "sr", details: [])
          raise contracts::Invalid, "Trusted context required" unless context.is_a?(contracts::TrustedContext)

          within_deadline(context.deadline) do
            validate_context!(context)
            locale = contract_enum!(locale.to_s, contracts::LOCALES)
            return result("not_authorized", warnings: ["public_reads_not_allowed"]) unless context.allows?("public_reads")

            values = ServiceFollowUpRead.new(directory:, allowed_keys: DIRECTORY_TOPIC_KEYS.values, organization_id: organization.id,
                                             source_url_validator: method(:safe_source_url)).call(source_id:, focus:, now: context.now, locale:, details:)
            result(values.delete(:status), **values)
          end
        rescue CityServiceNoticeCollector::DeadlineExceeded, CityServiceNoticeCollector::InvalidDeadline
          result("unavailable", warnings: ["deadline_exceeded"])
        end

        # Fixed subject read, not a model-controlled request for arbitrary
        # inactive calls. Reuses the prepared public-call source/version policy.
        def agricultural_call_timing(context:, locale: "sr")
          raise contracts::Invalid, "Trusted context required" unless context.is_a?(contracts::TrustedContext)

          within_deadline(context.deadline) do
            validate_context!(context)
            locale = contract_enum!(locale.to_s, contracts::LOCALES)
            return result("not_authorized", warnings: ["public_reads_not_allowed"]) unless context.allows?("public_reads")

            values = PublicCallsReader.new(organization:, source_checker:, area_matcher:)
                                      .call(entities: { "query" => "poljoprivreda" }, context:, locale:, view: "reviewed_timing")
            typed_public_result(values)
          end
        rescue CityServiceNoticeCollector::DeadlineExceeded, CityServiceNoticeCollector::InvalidDeadline
          result("unavailable", warnings: ["deadline_exceeded"])
        end

        # Historical/current announcement snapshots need an explicit reviewed
        # period. They must not borrow today's operational event window.
        def bulky_waste_campaigns(context:, locale: "sr")
          raise contracts::Invalid, "Trusted context required" unless context.is_a?(contracts::TrustedContext)

          within_deadline(context.deadline) do
            validate_context!(context)
            contract_enum!(locale.to_s, contracts::LOCALES)
            return result("not_authorized", warnings: ["public_reads_not_allowed"]) unless context.allows?("public_reads")

            values = BulkyWasteCampaignRead.new(organization_host: organization.host, reviewed_hosts: CivicDomainFacts::REVIEWED_HOSTS)
                                          .call(day: context.now.in_time_zone("Europe/Sarajevo").to_date)
            result(values.delete(:status), **values)
          end
        rescue CityServiceNoticeCollector::DeadlineExceeded, CityServiceNoticeCollector::InvalidDeadline
          result("unavailable", warnings: ["deadline_exceeded"])
        end

        # Explicit document/channel/community metadata is required: a generic
        # registrar card or another community's procedure cannot supply fees.
        def birth_extract_procedures(context:, locale: "sr", channel: "all")
          raise contracts::Invalid, "Trusted context required" unless context.is_a?(contracts::TrustedContext)

          within_deadline(context.deadline) do
            validate_context!(context)
            locale = contract_enum!(locale.to_s, contracts::LOCALES)
            channel = contract_enum!(channel, %w(all online counter))
            return result("not_authorized", warnings: ["public_reads_not_allowed"]) unless context.allows?("public_reads")

            channels = channel == "all" ? %w(online counter) : [channel]
            cards = ServiceProcedures.all.select do |card|
              card[:document_kind] == "birth_extract" && channels.include?(card[:channel]) &&
                card[:organization_host].is_a?(String) && card[:organization_host].downcase == organization.host.to_s.downcase
            end
            reads = channels.map do |requested|
              matches = cards.select { |card| card[:channel] == requested }
              if matches.one?
                ProcedureRead.new(source_store: source_checker).call(card: matches.first, locale:, now: context.now)
              else
                { status: matches.empty? ? "empty" : "ambiguous", warnings: ["birth_extract_channel_#{matches.empty? ? 'unavailable' : 'ambiguous'}"] }
              end
            end
            facts = reads.select { |read| read[:status] == "ok" }.flat_map { |read| read.fetch(:facts) }.map do |fact|
              fact.merge("coverage" => fact.fetch("coverage").merge("organization_id" => organization.id, "organization_host" => organization.host))
            end
            available = facts.map { |fact| fact.fetch("channel") }
            status = facts.any? ? "ok" : (%w(ambiguous unreviewed stale unavailable).find { |value| reads.any? { |read| read[:status] == value } } || "empty")
            result(status, facts:, source: aggregate_sources(facts),
                   coverage: { "organization_id" => organization.id, "requested_channels" => channels,
                               "available_channels" => available, "unavailable_channels" => channels - available },
                   validity: { "live_status" => false }, warnings: reads.flat_map { |read| Array(read[:warnings]) }.uniq)
          end
        rescue ServiceProcedures::InvalidConfiguration
          result("unavailable", warnings: ["procedure_configuration_invalid"])
        rescue CityServiceNoticeCollector::DeadlineExceeded, CityServiceNoticeCollector::InvalidDeadline
          result("unavailable", warnings: ["deadline_exceeded"])
        end

        # This is guidance for a published municipal case-status procedure,
        # never access to a citizen's case. A generic or other-tenant card is
        # insufficient, even if it has a familiar provider key.
        def municipal_case_status_procedure(context:, locale: "sr")
          raise contracts::Invalid, "Trusted context required" unless context.is_a?(contracts::TrustedContext)

          within_deadline(context.deadline) do
            validate_context!(context)
            locale = contract_enum!(locale.to_s, contracts::LOCALES)
            return result("not_authorized", warnings: ["public_reads_not_allowed"]) unless context.allows?("public_reads")

            cards = ServiceProcedures.all.select do |card|
              card[:document_kind] == "municipal_case_status" && card[:channel] == "online" &&
                card[:organization_host].is_a?(String) && card[:organization_host].downcase == organization.host.to_s.downcase
            end
            unless cards.one?
              return result(cards.empty? ? "empty" : "ambiguous", warnings: ["municipal_case_procedure_#{cards.empty? ? 'unavailable' : 'ambiguous'}"])
            end

            values = ProcedureRead.new(source_store: source_checker).call(card: cards.first, locale:, now: context.now)
            if values[:status] == "ok"
              values[:facts] = values.fetch(:facts).map do |fact|
                fact.merge("coverage" => fact.fetch("coverage").merge("organization_id" => organization.id, "organization_host" => organization.host))
              end
              values[:validity] = values.fetch(:validity).merge("personal_case_access" => false, "request_submitted" => false)
            end
            typed_public_result(values)
          end
        rescue ServiceProcedures::InvalidConfiguration
          result("unavailable", warnings: ["procedure_configuration_invalid"])
        rescue CityServiceNoticeCollector::DeadlineExceeded, CityServiceNoticeCollector::InvalidDeadline
          result("unavailable", warnings: ["deadline_exceeded"])
        end

        # Published document guidance is separate from personal document data.
        # Application and status channels have distinct reviewed purposes; one
        # cannot supply the other's prerequisites or evidence of completion.
        def identity_card_procedure(context:, locale: "sr", focus: "application")
          raise contracts::Invalid, "Trusted context required" unless context.is_a?(contracts::TrustedContext)

          within_deadline(context.deadline) do
            validate_context!(context)
            locale = contract_enum!(locale.to_s, contracts::LOCALES)
            focus = contract_enum!(focus, %w(application status))
            return result("not_authorized", warnings: ["public_reads_not_allowed"]) unless context.allows?("public_reads")

            cards = ServiceProcedures.all.select do |card|
              card[:document_kind] == "identity_card_#{focus}" && %w(online counter).include?(card[:channel]) &&
                card[:organization_host].is_a?(String) && card[:organization_host].downcase == organization.host.to_s.downcase
            end
            unless cards.one?
              return result(cards.empty? ? "empty" : "ambiguous", warnings: ["identity_card_#{focus}_procedure_#{cards.empty? ? 'unavailable' : 'ambiguous'}"])
            end

            values = ProcedureRead.new(source_store: source_checker).call(card: cards.first, locale:, now: context.now)
            if values[:status] == "ok"
              values[:facts] = values.fetch(:facts).map do |fact|
                fact.merge("coverage" => fact.fetch("coverage").merge("organization_id" => organization.id, "organization_host" => organization.host))
              end
              values[:validity] = values.fetch(:validity).merge("personal_document_access" => false, "request_submitted" => false)
            end
            typed_public_result(values)
          end
        rescue ServiceProcedures::InvalidConfiguration
          result("unavailable", warnings: ["procedure_configuration_invalid"])
        rescue CityServiceNoticeCollector::DeadlineExceeded, CityServiceNoticeCollector::InvalidDeadline
          result("unavailable", warnings: ["deadline_exceeded"])
        end

        def procedure_follow_up(procedure_id:, focus:, context:, locale: "sr")
          raise contracts::Invalid, "Trusted context required" unless context.is_a?(contracts::TrustedContext)

          within_deadline(context.deadline) do
            validate_context!(context)
            locale = contract_enum!(locale.to_s, contracts::LOCALES)
            return result("not_authorized", warnings: ["public_reads_not_allowed"]) unless context.allows?("public_reads")

            values = ProcedureFeeRead.new(directory:, procedure_reader: ProcedureRead.new(source_store: source_checker))
                                     .call(procedure_id:, focus:, now: context.now, locale:)
            result(values.delete(:status), **values)
          end
        rescue CityServiceNoticeCollector::DeadlineExceeded, CityServiceNoticeCollector::InvalidDeadline
          result("unavailable", warnings: ["deadline_exceeded"])
        end

        # The source identity comes only from the runner's normalized public
        # evidence. The host allowlist selects the supported reference and
        # rereads its reviewed snapshot; no prior prose or model URL is reused.
        def public_reference_follow_up(source_ids:, message:, context:, locale: "sr")
          raise contracts::Invalid, "Trusted context required" unless context.is_a?(contracts::TrustedContext)

          within_deadline(context.deadline) do
            validate_context!(context)
            locale = contract_enum!(locale.to_s, contracts::LOCALES)
            return unless context.allows?("public_reads")
            return unless source_ids.is_a?(Array) && source_ids.any? && (source_ids - FoundationRead::SOURCE_IDS).empty?

            source_identity = source_ids.first
            entities = { "query" => message }
            return unless FoundationRead.handles?(topic: "community", entities:, source_identity:)

            values = FoundationRead.new(organization:).call(topic: "community", entities:, context:, locale:, source_identity:)
            result(values.delete(:status), **values) if values
          end
        rescue CityServiceNoticeCollector::DeadlineExceeded, CityServiceNoticeCollector::InvalidDeadline
          result("unavailable", warnings: ["deadline_exceeded"])
        end

        # A board reference carries no citizen text in a URL. Resolve it on
        # every turn through the same organization and assigned-board boundary.
        def notice_reference(post_id:, context:, locale: "sr")
          raise contracts::Invalid, "Trusted context required" unless context.is_a?(contracts::TrustedContext)

          within_deadline(context.deadline) do
            validate_context!(context)
            return denied_neighborhood_access("neighborhood_membership_required").result unless context.allows?("neighborhood_reads")

            actor = actor_for!(context)
            return denied_neighborhood_access("verified_actor_required").result unless verified_notice_actor?(actor)

            profile = read_query(context.deadline) { Decidim::Bih::CitizenProfile.find_by(organization:, user: actor) }
            return denied_neighborhood_access("assigned_neighborhood_required").result unless assigned_notice_profile?(profile)

            post = read_query(context.deadline) do
              Decidim::Bih::KomsilukPost.visible.where(organization:, komsiluk_id: profile.komsiluk_id).find_by(id: post_id)
            end
            return result("empty", warnings: ["notice_unavailable"]) unless post

            result("ok", facts: [board_fact(post, profile.komsiluk, locale:)],
                         source: { "id" => "komsiluk_board" },
                         coverage: { "organization_id" => organization.id, "area_slugs" => [profile.komsiluk.slug], "visibility" => "member_board" })
          end
        rescue CityServiceNoticeCollector::DeadlineExceeded, CityServiceNoticeCollector::InvalidDeadline
          result("unavailable", warnings: ["deadline_exceeded"])
        end

        # Typed public capability bridge. Selection belongs to the model's
        # validated tool arguments, never the legacy sentence-routing predicates.
        # Private boards, own reports and actor records are deliberately absent.
        def public_capability(capability:, topic:, entities:, context:, locale: "sr", location: nil, place_kind: nil, catalog_view: nil) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/ParameterLists -- closed public dispatch with separate trusted location
          within_deadline(context.deadline) do
            validate_context!(context)
            return result("not_authorized", warnings: ["public_reads_not_allowed"]) unless context.allows?("public_reads")

            validate_public_place_kind!(capability, place_kind)
            validate_catalog_view!(capability, topic, catalog_view)
            entities = normalize_entities(entities)
            entities = entities.merge("view" => catalog_view) if catalog_view
            # Named places override GPS; self-referential area names retain the consented point.
            entities, location = public_capability_location(capability, entities, location)
            # Public model reads must not infer a place from a private profile.
            return result("ambiguous", warnings: ["area_required"]) if public_place_required?(capability, entities, location)

            locale = contract_enum!(locale, contracts::LOCALES)
            options = { entities:, context:, locale: }
            case capability
            when "waste_schedule" then waste_schedule_read(**options)
            when "service_events" then service_event_read(topic:, **options, location:)
            when "environment" then typed_public_result(SourceRead.new(source_checker:, organization:).call(topic:, **options))
            when "public_calls" then typed_public_result(PublicCallsReader.new(organization:, area_matcher:).call(**options, location:))
            when "reference" then typed_public_result(ReferenceRead.new(organization:).call(topic:, **options))
            when "catalog" then typed_public_result(PlatformCatalogRead.new(organization:, area_matcher:).call(topic:, **options, location:))
            when "public_activity" then public_neighborhood_activity_read(**options, location:)
            when "area" then area_read(**options, location:, place_kind:)
            when "mz_contact" then mz_contact_read(**options, location:, place_kind:)
            when "parking" then parking_street_read(entities:, locale:) || result("ambiguous", warnings: ["parking_street_or_lot_required"])
            else raise contracts::Invalid, "Unknown direct public capability"
            end
          end
        end

        def typed_public_result(values)
          result(values.fetch(:status), **values.except(:status))
        end

        private

        def verified_notice_actor?(actor)
          actor && actor.confirmed_at && !actor.deleted? && !actor.blocked?
        end

        def assigned_notice_profile?(profile)
          profile&.assigned? && assigned_area?(profile.komsiluk)
        end

        def validate_catalog_view!(capability, topic, catalog_view)
          return unless catalog_view
          return if capability == "catalog" && topic == "community" && %w(projects material_needs organizations giving_guidance).include?(catalog_view)

          raise contracts::Invalid, "Unsupported catalog view"
        end

        def public_capability_location(capability, entities, location)
          location = normalize_location(location)
          entities = entities.except("area_query") if capability == "service_events" && location && self_referential_area_query?(entities["area_query"])
          location = nil if %w(area_slug area_query).any? { |key| entities[key].present? }
          [entities, location]
        end

        def read_with_supplied_area(**request)
          action, topic, entities, context, locale, location = request.values_at(:action, :topic, :entities, :context, :locale, :location)
          supplied_area = ActivityQuestionContext.call(action:, topic:, entities:) if context.allows?("public_reads")
          entities = entities.merge("area_query" => supplied_area.query) if supplied_area
          answer = if supplied_area&.warning
                     result("ambiguous", warnings: [supplied_area.warning])
                   else
                     dispatch(action:, topic:, entities:, context:, locale:, location:)
                   end
          supplied_area ? answer.with(coverage: (answer.coverage || {}).merge(supplied_area.coverage)) : answer
        end

        def published_notice_area_scope(scope, slugs)
          if slugs.one?
            scope.where("affected_area_slugs @> ?::jsonb", [slugs.first].to_json)
          elsif slugs.size == 2
            scope.where("affected_area_slugs @> ?::jsonb OR affected_area_slugs @> ?::jsonb", [slugs.first].to_json, [slugs.last].to_json)
          else
            scope
          end
        end

        attr_reader :organization, :event_feed, :source_checker, :timetable, :area_matcher, :directory, :duplicate_finder

        # Nedostajući lokalni raspored ne smije blokirati ostale javne čitače.
        def waste_schedule
          @waste_schedule ||= DecidimApp::Bijeljina::WasteSchedule.default
        end

        def dispatch(action:, topic:, entities:, context:, locale:, location:) # rubocop:disable Metrics/ParameterLists
          return report_status(entities:, context:, locale:) if action == "report_status"
          return nearby_reports(entities:, context:, locale:, location:) if action == "report_problem"
          return neighborhood_read(entities:, context:, locale:, location:) if action == "neighborhood_information"
          return area_read(entities:, context:, locale:, location:) if action == "choose_area"
          return information_read(topic:, entities:, context:, locale:, location:) if PUBLIC_ACTIONS.include?(action)

          result("unavailable", warnings: ["unsupported_read_action"])
        end

        # Keep public-read authorization and topic dispatch in one auditable entry point.
        # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
        def information_read(topic:, entities:, context:, locale:, location:)
          return result("not_authorized", warnings: ["public_reads_not_allowed"]) unless context.allows?("public_reads")

          if CitizenNoticeRead.source_key(topic:, entities:)
            values = CitizenNoticeRead.new(source_store: source_checker).call(topic:, entities:, context:, locale:)
            return result(values.delete(:status), **values)
          end

          if CitizenReferenceRead.handles?(topic:, entities:)
            values = CitizenReferenceRead.new(organization:).call(topic:, entities:, context:, locale:)
            return result(values.delete(:status), **values)
          end

          if FoundationRead.handles?(topic:, entities:)
            foundation = FoundationRead.new(organization:).call(topic:, entities:, context:, locale:)
            return result(foundation.delete(:status), **foundation) if foundation
          end

          if topic == "parking"
            parking_query = ParkingQuestion.call(query: entities["query"], location:)
            return result("ambiguous", warnings: ["parking_zone_required"]) if parking_query == :clarify

            if parking_query.nil?
              street = parking_street_read(entities:, locale:)
              return street if street
            end
            entities = entities.merge("query" => parking_query) if parking_query
          end

          # Which question is being asked is decided before which source is
          # read. A recycling question must not be answered from the
          # mixed-waste calendar, and a billing question must not be answered
          # from the outage feed; both used to happen because the topic alone
          # decided the handler.
          if (civic = CivicDomainQuestion.call(topic:, entities:))
            values = CivicDomainRead.new(organization:).call(question: civic, context:, locale:)
            return result(values.delete(:status), **values)
          end

          # WHICH question is being asked decides which source answers it. A
          # contact, website, operator or opening-hours question is answered
          # from the reviewed directory card for the topic, whatever else the
          # topic's live feed could have been asked. Without this, "koji je broj
          # telefona Komunalca?" was answered with last week's collection day.
          # Resolve known stop navigation and transport calendars before
          # generic directory link/opening-hours facets such as "nedjeljom".
          if topic == "transport" && (entities["category"] == "stop_navigation" || TransportJourneyQuestion.calendar_question?(entities))
            return transport_read(entities:, context:, locale:, location:)
          end
          return directory_read(topic:, entities:, locale:, now: context.now) if directory_facet_question?(topic:, entities:)
          return directory_read(topic:, entities:, locale:, now: context.now) if Decidim::Bih::Concierge::Dialogue::ServiceQuestion.directory_lookup?(topic:, entities:)
          return directory_read(topic:, entities:, locale:, now: context.now) if topic == "transport" && transport_fare_answer(entities)
          return transport_read(entities:, context:, locale:, location:) if topic == "transport"

          if CityServiceSources::TOPIC_SOURCE_KEYS.has_key?(topic)
            values = SourceRead.new(source_checker:, organization:).call(topic:, context:, locale:, entities:)
            return result(values.delete(:status), **values)
          end
          if topic == "public_calls"
            values = PublicCallsReader.new(organization:, area_matcher:).call(entities:, context:, locale:, location:)
            return result(values.delete(:status), **values)
          end
          if ReferenceRead::TOPICS.include?(topic)
            values = ReferenceRead.new(organization:).call(topic:, entities:, context:, locale:)
            return result(values.delete(:status), **values)
          end
          if %w(volunteer community participation rewards facilities).include?(topic)
            return result("ambiguous", warnings: ["activity_area_required"]) if activity_area_required?(topic, entities, location)

            families = scoped_activity_families(topic, entities, location)
            return scoped_neighborhood_activities(entities:, context:, locale:, location:, selection: [topic, families]) if families

            values = PlatformCatalogRead.new(organization:, area_matcher:).call(topic:, entities:, context:, locale:, location:)
            return result(values.delete(:status), **displayable_area_labels(values))
          end
          return service_event_read(topic:, entities:, context:, locale:, location:) if EVENT_TOPICS.include?(topic)
          return public_neighborhood_activity_read(entities:, context:, locale:, location:) if topic == "neighborhood"
          return waste_schedule_read(entities:, context:, locale:) if topic == "waste" && waste_schedule_question?(entities)

          directory_read(topic:, entities:, locale:, now: context.now)
        end
        # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

        # Topics whose reviewed directory card carries the contact, the site
        # and the opening hours. A facet question on one of them never needs a
        # neighbourhood first.
        DIRECTORY_FACET_TOPICS = %w(waste water electricity heating roads transport parking city_service).freeze

        def directory_facet_question?(topic:, entities:)
          return false unless DIRECTORY_FACET_TOPICS.include?(topic)

          Decidim::Bih::Concierge::Dialogue::QuestionFacet.directory?(entities["query"])
        end

        # The weekly collection snapshot answers collection-day questions. It
        # used to answer EVERY waste turn that happened to carry a place slot,
        # so a fee question and a recycling-yard question both came back as
        # "Odvoz otpada: srijeda" — the retained street, not the new question,
        # selected the reader.
        def waste_schedule_question?(entities)
          return false if waste_schedule_query(entities).blank?

          facet = Decidim::Bih::Concierge::Dialogue::QuestionFacet.call(entities["query"])
          facet.nil? || %w(schedule coverage status).include?(facet)
        end

        # "Is there a clean-up this weekend" cannot be answered city-wide: the
        # citizen is asked for the place before any catalog is declared empty
        # or unavailable. Decided before slot filling, never after.
        def activity_area_required?(topic, entities, location)
          return false unless ACTIVITY_PLACE_TOPICS.include?(topic)
          return false if explicit_area_or_location?(entities:, location:)
          return true if %w(date time_expression).any? { |key| entities[key].to_s.strip.present? }

          PLACE_BOUND_ACTIVITY.match?(Decidim::Bih::Text.fold(entities["query"]))
        end

        # Registry markers such as "(prijedlog)" are internal; the typed slugs
        # and kinds stay exactly as the catalog returned them.
        def displayable_area_labels(values)
          Array(values[:candidates]).each { |candidate| candidate["label"] = PlaceAliasRegistry.display_name(candidate["label"]) if candidate.is_a?(Hash) && candidate["label"] }
          Array(values.dig(:coverage, "requested_areas")).each { |area| area["label"] = PlaceAliasRegistry.display_name(area["label"]) if area.is_a?(Hash) && area["label"] }
          values
        end

        # Keep source-year, requested-time and district-resolution guards in the order they constrain answers.
        # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
        def waste_schedule_read(entities:, context:, locale:)
          query = waste_schedule_query(entities)
          return result("ambiguous", warnings: %w(waste_named_street_or_settlement_required gps_to_street_mapping_not_reviewed)) if query.blank?

          source = waste_schedule_source
          capture_date = waste_schedule_capture_date
          source_year = waste_schedule_year
          current_year = context.now.in_time_zone("Europe/Sarajevo").year
          coverage = {
            "organization_id" => organization.id,
            "query" => query,
            "schedule_kind" => "weekly",
            "source_captured_on" => capture_date&.iso8601,
            "source_year" => source_year,
            "covered_entries" => waste_schedule.areas.size
          }.compact
          validity = {
            "schedule_year" => source_year,
            "source_captured_on" => capture_date&.iso8601,
            "live_status" => false,
            "holiday_exceptions" => false
          }.compact
          # Warning codes here must never read as a time, date or day: the
          # dialogue runner turns such an ambiguity into "za koji dan pitaš?",
          # and a weekly schedule never needs a day from the citizen.
          warnings = %w(snapshot_not_live_status schedule_exceptions_not_in_snapshot)
          # "Nisu pokupili smeće" asks whether a truck passed, which the weekly
          # snapshot cannot confirm. The schedule is still the right answer, but
          # it is a plan, and saying so is the difference between answering and
          # appearing to confirm.
          if CivicDomainQuestion.observed_collection?(entities["query"])
            warnings += ["schedule_is_plan_not_observed_collection"]
            coverage["question"] = "observed_collection"
            validity["observed_collection_known"] = false
          end

          requested_year = requested_waste_year(entities) || current_year
          return result("stale", source:, coverage:, validity:, warnings: warnings + ["schedule_year_mismatch"]) if source_year && requested_year != source_year

          requested_on = requested_waste_date(entities, context.now)
          if requested_on
            coverage["requested_on"] = requested_on.iso8601
          elsif entities["date"].present? || entities["time_expression"].present?
            # "kad", "u 15h": not a date the weekly schedule can filter by. The
            # weekly answer is still the right one; say the period was not applied.
            warnings += ["requested_period_not_applied"]
          end
          resolution = waste_schedule.resolution_for(query, on: requested_on) if waste_schedule.respond_to?(:resolution_for)
          if resolution
            capture_date = apply_waste_resolution_evidence(resolution, coverage:, validity:, warnings:, capture_date:)
            if resolution[:status] == :ambiguous
              coverage["matching_districts"] = Array(resolution[:candidates]).filter_map { |row| row[:district] || row["district"] }.uniq.first(10)
              candidates = Array(resolution[:candidates]).map do |row|
                item = row.stringify_keys
                { "id" => [item["settlement"], item["place"], item["district"]].compact.join(":"),
                  "label" => item["label"] || [item["place"], item["settlement"], item["district"] && "rejon #{item["district"]}"].compact.uniq.join(" — ") }
              end
              return result("ambiguous", source:, coverage:, validity:, candidates:,
                                         warnings: warnings + ["waste_district_or_street_segment_required"])
            end
            return result("unavailable", source:, coverage:, validity:, warnings:) if resolution[:status] == :unavailable
          end
          days = resolution ? resolution[:days] : waste_schedule.collection_days_for(query)
          if days.present?
            limitation = I18n.t("decidim.bih.dialogue.waste_schedule_limit", year: source_year, locale:)
            places = waste_schedule_places(resolution)
            label = places.any? ? places.first(3).join(", ") : query
            coverage["matched_places"] = places.first(8) if places.any?
            source_conflict = resolution && resolution[:status] == :conflicting
            warnings |= ["conflicting_current_facts"] if source_conflict
            coverage["source_identity_note"] = resolution[:identity_note] if source_conflict
            coverage["source_rows"] = Array(resolution[:rows]).map { |row| row.slice("id", "place", "weekday", "district", "scope", "source_pdf_page") } if source_conflict
            fact = {
              "id" => "waste_schedule:#{Digest::SHA256.hexdigest(query)[0, 16]}",
              "kind" => "waste_schedule",
              "text" => localized_text(
                [I18n.t("decidim.bih.concierge.waste.found", area: label, days: day_names(days, locale:), locale:), limitation].join("\n\n"),
                locale
              ),
              "source_id" => source.fetch("id"),
              "source_label" => source.fetch("label", "Komunalac waste schedule"),
              "source_url" => source["url"],
              "source_captured_on" => capture_date&.iso8601,
              "coverage" => coverage.merge("collection_days" => days),
              "warning_codes" => warnings
            }.compact
            if source_conflict
              fact["text"] =
                "Pregledani izvor sadrži više redova za isti naziv ulice, s različitim danima. " \
                "Nije utvrđeno da li se odnose na različite dijelove ulice; ne potvrđivati oba dana za svaku adresu."
            end
            # The legacy read contract represents explicit conflicts as
            # unreviewed + conflicting_current_facts. The public adapter
            # retains their facts under EvidenceEnvelope's conflicting status.
            return result(source_conflict ? "unreviewed" : "ok", facts: [fact], source:, coverage:, validity:, warnings:)
          end

          if (gap = waste_schedule_gap(query))
            coverage["unmapped_districts"] = gap.fetch(:districts)
            return result("unreviewed", source:, coverage:, validity:, warnings: warnings + ["partial_coverage"])
          end

          result("empty", source:, coverage:, validity:, warnings: warnings + ["no_reviewed_matching_schedule"])
        rescue KeyError, Decidim::Bih::City::WasteScheduleError => e
          log_failure(e, "waste")
          result("unavailable", source: source, warnings: ["schedule_unavailable"])
        end
        # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

        def apply_waste_resolution_evidence(resolution, coverage:, validity:, warnings:, capture_date:)
          warnings.replace(warnings | Array(resolution[:warnings]).map(&:to_s))
          validity.merge!(resolution.fetch(:validity, {}).stringify_keys)
          if resolution[:source_checked_at]
            capture_date = resolution[:source_checked_at].to_date
            coverage["source_captured_on"] = capture_date.iso8601
            validity["source_captured_on"] = capture_date.iso8601
          end
          rows = Array(resolution[:rows]).map(&:stringify_keys)
          coverage["source_pdf_pages"] = rows.filter_map { |row| row["source_pdf_page"] }.uniq.first(20)
          coverage["source_route_ids"] = rows.filter_map { |row| row["id"] }.uniq.first(20)
          capture_date
        end

        def requested_waste_date(entities, now)
          expression = entities["date"].presence || entities["time_expression"].presence
          return nil unless expression

          starts_at, _ends_at, warning = time_window(entities, now)
          warning ? nil : starts_at.in_time_zone("Europe/Sarajevo").to_date
        end

        def directory_read(topic:, entities:, locale:, now: Time.current)
          entry = directory_entry(topic, entities)
          return directory_guidance_result(entry, topic:, query: entities["query"], locale:) if entry && entry[:content_origin] == "admin_override"

          card = ServiceProcedures.match_query(entities["query"])
          return procedure_directory_result(card, locale:, now:) if card

          return result("empty", warnings: ["no_reviewed_directory_match"]) unless entry

          prepared = prepared_directory_result(entry, query: entities["query"], locale:, now:)
          return prepared if prepared

          directory_guidance_result(entry, topic:, query: entities["query"], locale:)
        end

        def directory_guidance_result(entry, topic:, query:, locale:)
          fare = topic == "transport" && TransportFareAnswer.call(entry:, query:)
          answer = fare ? fare.fetch(:text) : DirectoryAnswer.call(entry:, query:, locale:)
          source_url = fare ? fare.fetch(:source_url) : entry.fetch(:source_url)
          metadata, reviewed_on = directory_evidence(entry)
          fact = {
            "id" => "service:#{entry.fetch(:key)}",
            "kind" => "service_directory",
            "text" => bounded_text(localized_text(answer, locale)),
            "source_id" => "city_services:#{entry.fetch(:key)}",
            "source_label" => entry.fetch(:title),
            "source_url" => safe_source_url(source_url),
            "observed_at" => reviewed_on,
            "coverage" => { "organization_id" => organization.id, "scope" => "reviewed_static_directory" },
            "warning_codes" => ["snapshot_not_live_status"]
          }
          fact["provenance"] = Array(metadata&.fetch(:facts, [])).map do |item|
            item.slice(:id, :kind, :source_checked_on, :source_url).stringify_keys
          end.first(8)
          validity = { "reviewed_on" => reviewed_on, "live_status" => false }
          result(
            "ok",
            facts: [fact],
            source: source_hash(fact),
            coverage: fact.fetch("coverage"),
            validity:,
            warnings: fact.fetch("warning_codes")
          )
        end

        def directory_evidence(entry)
          metadata = directory.respond_to?(:metadata_for) ? directory.metadata_for(entry.fetch(:key)) : {}
          reviewed_on = metadata&.fetch(:source_checked_on, nil) || entry[:source_checked_on] || CityServicesData::SOURCE_VERIFIED_ON.iso8601
          [metadata, reviewed_on]
        end

        def prepared_directory_result(entry, query:, locale:, now:)
          return if entry[:content_origin] == "admin_override"

          card = directory.procedure_for(entry.fetch(:key)) if directory.respond_to?(:procedure_for)
          return procedure_directory_result(card, locale:, now:) if card

          atomic = DirectoryServiceFacts.select(entry:, query:, now:)
          atomic_directory_result(entry, atomic, locale:) if atomic.any?
        end

        def procedure_directory_result(card, locale:, now:)
          values = ProcedureRead.new.call(card:, locale:, now:)
          result(values.delete(:status), **values)
        end

        def atomic_directory_result(entry, rows, locale:)
          facts = rows.map do |row|
            { "id" => row.fetch(:id), "kind" => "service_directory", "subject_id" => row.fetch(:subject_id),
              "predicate" => row.fetch(:predicate), "text" => bounded_text(localized_text(row.fetch(:text), locale)),
              "source_id" => "city_services:#{entry.fetch(:key)}", "source_label" => entry.fetch(:title),
              "source_url" => safe_source_url(row.fetch(:source_url)), "reviewed_on" => row.fetch(:source_checked_on),
              "source_locator" => row.fetch(:source_locator), "source_published_at" => row[:source_published_at],
              "logical_id" => row.fetch(:logical_id), "fact_revision" => row.fetch(:fact_revision), "document_id" => row.fetch(:document_id),
              "source_document_sha256" => row.fetch(:source_document_sha256), "publisher_id" => row.fetch(:publisher_id),
              "coverage" => { "organization_id" => organization.id, "scope" => "reviewed_public_office_fact" },
              "warning_codes" => ["snapshot_not_live_status"] }
          end
          result("ok", facts:, source: aggregate_sources(facts), coverage: facts.first.fetch("coverage"),
                       validity: { "live_status" => false, "reviewed_on" => rows.map { |row| row[:source_checked_on] }.min },
                       warnings: ["snapshot_not_live_status"])
        end

        def transport_fare_answer(entities)
          entry = directory.find(:javni_prevoz)
          TransportFareAnswer.call(entry:, query: entities["query"]) if entry
        end

        def service_event_read(topic:, entities:, context:, locale:, location:)
          area = service_event_area(entities:, location:)
          return area.result if area.result

          announced = announcement_question?(entities)
          starts_at, ends_at, time_warning = time_window(entities, context.now, announcement: announced)
          return result("ambiguous", candidates: [], warnings: [time_warning]) if time_warning

          query = event_feed.query(topic:, area_identifiers: area.slugs, starts_at:, ends_at:, deadline: context.deadline)
          answer = service_event_answer(query, topic:, context:, locale:, window: [area.slugs, starts_at, ends_at])
          with_scope(answer, area.scope_warnings + announcement_warnings(announced), area.scope_coverage.merge(announcement_coverage(announced)))
        end

        def service_event_answer(query, topic:, context:, locale:, window:)
          slugs, starts_at, ends_at = window
          return source_empty_result(topic, query, context) if query.status == :empty
          return conflicting_event_result(query, locale:, now: context.now, slugs:) if query.status == :conflict
          return result("unavailable", warnings: [query.error_code.to_s]) unless query.status == :ok

          facts = query.events.first(MAX_FACTS).map { |event| event_fact(event, locale:, now: context.now, requested_area_slugs: slugs) }
          result(
            "ok",
            facts:,
            source: aggregate_sources(facts),
            checked_at: latest_fact_time(facts, "checked_at"),
            coverage: query_coverage(slugs, starts_at, ends_at),
            validity: { "starts_at" => time_value(starts_at), "ends_at" => time_value(ends_at) },
            warnings: facts.flat_map { |fact| fact.fetch("warning_codes", []) }.uniq
          )
        end

        def announcement_warnings(announced) = announced ? ["announcement_window_not_current_status"] : []

        def announcement_coverage(announced) = announced ? { "window" => "announced_and_current" } : {}

        # The renderer prints at most four warning sentences, so this order is
        # a priority, not decoration: what actually happened, then the claim we
        # must never make from silence, then how the question was scoped. The
        # absence claim is deliberately ahead of every scope caveat — dropping
        # it would let an unmatched feed read as "there is no outage".
        WARNING_PRIORITY = %w(
          source_scope_or_time_not_matched no_matching_source_notice source_extraction_incomplete
          source_extraction_failed source_publication_stale source_unavailable
          absence_not_evidence_of_normal_service
          citywide_query_scope street_coverage_not_published_by_source announcement_window_not_current_status
          location_near_area_boundary
          source_content_not_operator_reviewed
        ).freeze

        # Statuses that describe a read of the requested window. An
        # unavailable or unauthorized answer says nothing about that window, so
        # a scope caveat on it ("these are announced works…") would be a claim
        # about something we never looked at.
        SCOPED_READ_STATUSES = %w(ok empty stale unreviewed).freeze

        # The scope caveats belong to the question, not to the source check, so
        # they survive every branch of +source_empty_result+ without that
        # method having to know about them.
        def with_scope(answer, warnings, coverage)
          return answer if warnings.empty? && coverage.empty?
          return answer unless SCOPED_READ_STATUSES.include?(answer.status)

          combined = (Array(answer.warnings) + warnings).compact_blank.map(&:to_s).uniq
          answer.with(warnings: combined.each_with_index.sort_by { |code, index| [WARNING_PRIORITY.index(code) || WARNING_PRIORITY.length, index] }.map(&:first),
                      coverage: (answer.coverage || {}).merge(coverage))
        end

        # An unresolved geographic target is a question we could not place, not
        # a checked-empty answer about the data. Three outcomes, in order:
        #
        #   1. the citizen named the city — a legitimate query scope the area
        #      matcher already knows how to read (+match_query+). Run the read
        #      citywide and say so.
        #   2. the citizen named something else we cannot place — ask WHICH
        #      neighbourhood ("ambiguous"), a question they can answer, rather
        #      than asserting there is no verified data.
        #   3. the citizen gave only a street or address — these satisfy
        #      +has_location?+ and are then dropped, which silently widens the
        #      read to the whole city. Widen, but say so: no reviewed
        #      crosswalk turns a street into a service area.
        #
        # Scoped to the service-event read on purpose: the neighbourhood,
        # activity and MZ reads have their own fallbacks keyed on the "empty"
        # outcome (+public_mz_fallback+) and are not changed here.
        def service_event_area(entities:, location:)
          area = resolve_area(entities:, location:)
          approximate = approximate_service_event_area(area, location)
          return approximate if approximate
          return street_scoped_area(area, entities:, location:) unless area.result
          # Only an unresolved NAME is re-read. An ambiguous name, a location
          # outside the reviewed areas and an unauthorized read keep theirs.
          return area unless area.result.status == "empty" && area.result.warnings.include?("area_not_found")

          citywide_query_area(entities:, location:) ||
            AreaOutcome.new([], area.source, result("ambiguous", candidates: area.result.candidates, warnings: ["area_not_found"]))
        end

        def boundary_current_location?(area, location)
          location && area.source == :current_location && area.result&.warnings&.include?("location_near_area_boundary")
        end

        def approximate_service_event_area(area, location)
          if boundary_current_location?(area, location)
            # The point is inside reviewed polygons, but its error circle crosses
            # an edge. Read those polygons as a labelled approximation, never as
            # proof that the citizen's street is affected. Very coarse fixes
            # still need a more precise location.
            accuracy = location["accuracy"].to_f
            if accuracy <= 100
              tentative = area_matcher.resolve(location: location.merge("accuracy" => 0))
              if tentative.status == :ok && tentative.areas.any?
                labels = public_area_label_names(tentative.areas.map(&:slug))
                return AreaOutcome.new(tentative.areas, :approximate_current_location, nil,
                                       { "location_scope" => "boundary_best_guess", "assumed_area_labels" => labels },
                                       ["location_near_area_boundary"])
              end
            end
          end
          nil
        end

        def citywide_query_area(entities:, location:)
          return if location || entities["area_slug"].to_s.strip.present?

          query = entities["area_query"].to_s.strip
          return if query.blank?

          match = area_matcher.match_query(query)
          return if match.unknown? || match.targeting_level != "citywide"

          scope_role = match.coverage["scope_role"] || "citizen_query"
          AreaOutcome.new([], :citizen_query_citywide, nil,
                          { "scope" => "citywide", "scope_role" => scope_role, "requested_query" => "city" },
                          ["citywide_query_scope"])
        end

        def street_scoped_area(area, entities:, location:)
          return area unless area.areas.empty?
          return area if location || %w(area_slug area_query).any? { |key| entities[key].to_s.strip.present? }

          value = %w(street address).filter_map { |key| entities[key].to_s.strip.presence }.first
          return area unless value

          # The model puts a SETTLEMENT in the street slot often enough that it
          # cannot be treated as a street on the slot's say-so: "Dvorovi",
          # "komsiluk Dvorovi" and "Kad nestaje struja u Janji?" all arrived
          # this way, were widened to the whole city, and were then announced
          # with "I know the street from your question". A value the area
          # matcher recognises is a PLACE, so it is read as one — which answers
          # it when it is one area and asks which when it is several.
          named = resolve_area(entities: entities.merge("area_query" => value), location:)
          return named unless unplaced_area?(named)

          AreaOutcome.new(area.areas, area.source, nil,
                          { "scope" => "citywide", "street_to_area_crosswalk" => "not_reviewed" },
                          ["street_coverage_not_published_by_source"])
        end

        # A resolution that placed nothing: no areas, and an outcome whose only
        # complaint is that the name is not one of ours. An ambiguous name HAS
        # been placed — the citizen is simply owed the question of which one.
        def unplaced_area?(outcome)
          outcome.areas.empty? &&
            (outcome.result.nil? || Array(outcome.result.warnings).include?("area_not_found"))
        end

        def announcement_question?(entities)
          Decidim::Bih::Text.fold(entities["query"].to_s).match?(ANNOUNCEMENT_PATTERN)
        end

        def conflicting_event_result(query, locale:, now:, slugs:)
          facts = query.events.first(2).map { |event| event_fact(event, locale:, now:, requested_area_slugs: slugs) }
          result("unreviewed", facts:, source: aggregate_sources(facts), checked_at: latest_fact_time(facts, "checked_at"),
                               validity: { "conflict" => "conflicting_current_facts" }, warnings: ["conflicting_current_facts"])
        end

        # Error codes that mean the source answered but we could not turn its
        # content into facts. That is an extraction failure, which is not the
        # same claim as "the provider is unreachable" and must not be reported
        # as one.
        EXTRACTION_FAILURE_CODES = %w(
          partial_source_coverage article_links_missing article_fetch_incomplete
          article_deadline_exceeded timetable_preparation_failed partial_timetable_preparation
        ).freeze
        # An unmatched feed proves nothing about the citizen's street. Attached
        # to every non-`ok` service read so no renderer can turn silence into
        # "there is no outage".
        NO_ABSENCE_CLAIM = "absence_not_evidence_of_normal_service"

        def source_empty_result(topic, query, context)
          source_key = CityServiceEventFeed::SERVICE_FILTERS.fetch(topic.to_sym).fetch(:source_keys).first
          check = source_checker.check(keys: [source_key], max_items: 1, deadline: context.deadline).first
          coverage = source_coverage(topic, query, check)
          source = source_reference(source_key)
          error_code = check&.error_code.to_s
          extraction_failed = EXTRACTION_FAILURE_CODES.include?(error_code)
          case check&.status
          when :empty
            # Reviewed and genuinely nothing published — distinct from "nothing
            # matched your area" below, and from a source we could not read.
            result("empty", source:, checked_at: safe_time(check.checked_at, context.now), coverage:,
                            warnings: ["no_matching_source_notice", NO_ABSENCE_CLAIM])
          when :ok, :unreviewed
            # An extraction failure is a source we could not turn into facts:
            # it stays "unreviewed", because nothing was checked. Everything
            # else here is a source we DID read, whose collected notices simply
            # do not cover the area or period asked about. That is a scoped
            # zero-result, not a pending review — reporting it as "unreviewed"
            # told the citizen a review was outstanding and booked the turn as
            # a source outage (resolution "source_unavailable") when the source
            # was available. The coverage status ("unmatched") keeps it
            # distinct from a reviewed-empty publication.
            if extraction_failed
              result("unreviewed", source:, checked_at: safe_time(check.checked_at, context.now), coverage:,
                                   warnings: ["source_extraction_incomplete", error_code, NO_ABSENCE_CLAIM])
            else
              result("empty", source:, checked_at: safe_time(check.checked_at, context.now), coverage:,
                              warnings: ["source_scope_or_time_not_matched", NO_ABSENCE_CLAIM,
                                         ("source_content_not_operator_reviewed" if check.status == :unreviewed)])
            end
          when :stale
            result("stale", source:, checked_at: safe_time(check.checked_at, context.now), coverage:,
                            warnings: ["source_publication_stale", error_code, NO_ABSENCE_CLAIM])
          when :malformed
            result("unavailable", source:, coverage:, warnings: ["source_extraction_failed", error_code, NO_ABSENCE_CLAIM])
          else
            result("unavailable", source:, coverage:,
                                  warnings: [extraction_failed ? "source_extraction_failed" : "source_unavailable", error_code.presence, NO_ABSENCE_CLAIM].compact)
          end
        end

        # Heating is the one service whose household footprint is unpublished,
        # so an unmatched heating read is unmapped coverage, never "not
        # affected". Keeping that in the coverage contract means the renderer
        # does not have to know it.
        def source_coverage(topic, query, check)
          coverage = query_coverage(query.area_identifiers, query.starts_at, query.ends_at)
          coverage["status"] = check&.status == :empty ? "reviewed_empty" : "unmatched"
          coverage["network_footprint"] = "not_published" if topic.to_s == "heating"
          coverage["requested_areas"] = public_area_labels(query.area_identifiers)
          coverage
        end

        # Keep explicit place selection, permitted profile fallback and empty-source caveats together.
        def public_neighborhood_activity_read(entities:, context:, locale:, location:)
          area = resolve_area(entities:, location:)
          area = public_mz_fallback(area, entities:, context:, location:)
          return area.result if area.result

          area = resolve_assigned_area(context) if area.areas.empty? && !explicit_area_or_location?(entities:, location:)
          return result("ambiguous", warnings: ["area_required"]) if area.slugs.empty?

          mode = neighborhood_public_mode(entities["query"])
          starts_at, ends_at, time_warning = neighborhood_time_window(mode:, entities:, context:)
          return result("ambiguous", warnings: [time_warning]) if time_warning

          return combined_neighborhood_result(area:, entities:, context:, locale:, window: [starts_at, ends_at, mode]) unless mode == :services

          query = event_feed.query(topic: nil, area_identifiers: area.slugs, starts_at:, ends_at:, deadline: context.deadline)
          coverage = query_coverage(area.slugs, starts_at, ends_at).merge("scope" => "collected_public_service_notices")
          neighborhood_query_result(query, coverage:, locale:, now: context.now, slugs: area.slugs)
        end

        def neighborhood_public_mode(query)
          kind = Decidim::Bih::Concierge::Dialogue::Procedures::Komsiluk.requested_kind(Decidim::Bih::Text.fold(query))
          [:services, :reports].include?(kind) ? kind : :activity
        end

        def neighborhood_time_window(mode:, entities:, context:)
          return time_window(entities, context.now) unless mode == :activity
          return [context.now, context.now + 7.days, nil] if ActivityQuestionContext.soon?(entities)
          return time_window(entities, context.now) unless Decidim::Bih::Text.fold(entities["time_expression"]).match?(/\b(?:vikend\w*|weekend\w*)\b/)

          # Only an explicit activity weekend reuses the existing local-day
          # catalog calendar. Utility/report-only/default/weekday windows stay
          # on their existing path; conflicting dates remain a clarification.
          first, last = NeighborhoodActivityRead.new(organization:, area_matcher:).requested_window(entities:, context:, topic: "participation")
          [first, last, nil]
        rescue ArgumentError => e
          raise unless %w(invalid_catalog_date unsupported_catalog_time).include?(e.message)

          [nil, nil, e.message]
        end

        def combined_neighborhood_result(area:, entities:, context:, locale:, window:)
          starts_at, ends_at, mode = window
          coverage = query_coverage(area.slugs, starts_at, ends_at).merge(
            "scope" => mode == :reports ? "area_public_reports" : "collected_public_neighborhood_activity",
            "area_labels" => area.areas.map { |record| localized_area_name(record, locale) }
          )
          reports = public_neighborhood_reports(area:, entities:, context:, locale:, window: [starts_at, ends_at])
          coverage["reports"] = reports.coverage
          return result(reports.status, facts: reports.facts, coverage:, warnings: reports.warnings) if mode == :reports

          query = event_feed.query(topic: nil, area_identifiers: area.slugs, starts_at:, ends_at:, deadline: context.deadline)
          notice_result = neighborhood_query_result(query, coverage:, locale:, now: context.now, slugs: area.slugs)
          coverage["notices"] = { "status" => notice_result.status, "starts_at" => time_value(starts_at), "ends_at" => time_value(ends_at) }
          # Leave conflicting evidence on its existing explicit renderer rather
          # than present a normal aggregate that could hide disagreement.
          return notice_result if query.status == :conflict

          activities = public_neighborhood_catalog(area:, entities:, context:, locale:, window: [starts_at, ends_at])
          coverage["activities"] = activities.coverage
          selection = NeighborhoodNoticeSelection.call(facts: notice_result.facts, requested_slugs: area.slugs, limit: MAX_FACTS - reports.facts.length)
          coverage["notices"].merge!(selection.coverage)
          aggregate_neighborhood_result(selection:, reports:, activities:, notice_result:, coverage:)
        end

        def aggregate_neighborhood_result(selection:, reports:, activities:, notice_result:, coverage:)
          groups = [selection.facts, reports.facts] + activities.facts.group_by { |fact| fact.dig("coverage", "activity_type") }.values
          facts = (0...MAX_FACTS).flat_map { |index| groups.filter_map { |group| group[index] } }.first(MAX_FACTS)
          notice_warnings = notice_result.status == "ok" ? facts.flat_map { |fact| fact.fetch("warning_codes", []) }.uniq : notice_result.warnings
          warnings = notice_warnings + selection.warnings + reports.warnings + activities.warnings
          warnings << "neighborhood_activity_list_bounded" if groups.sum(&:length) > MAX_FACTS
          warnings << "neighborhood_notices_unavailable" if notice_result.status == "unavailable"
          status = neighborhood_aggregate_status(facts, notice_result, reports, activities)
          result(status, facts:, source: aggregate_sources(facts), coverage:,
                         checked_at: notice_result.checked_at, warnings:)
        end

        def neighborhood_aggregate_status(facts, notice_result, reports, activities)
          return "ok" if facts.any?
          return "unavailable" if [notice_result.status, reports.status, activities.status].include?("unavailable")

          "empty"
        end

        def public_neighborhood_catalog(area:, entities:, context:, locale:, window:)
          starts_at, ends_at = window
          read_query(context.deadline) do
            NeighborhoodActivityRead.new(organization:).call(
              areas: area.areas, context:, starts_at:, ends_at:,
              explicit_time: entities["date"].present? || entities["time_expression"].present?, locale:
            )
          end
        rescue StandardError => e
          raise if e.is_a?(CityServiceNoticeCollector::DeadlineExceeded)

          NeighborhoodActivityRead::Result.new("unavailable", [], { "status" => "unavailable" }, ["neighborhood_activity_unavailable"])
        end

        def scoped_activity_families(topic, entities, location)
          return unless explicit_area_or_location?(entities:, location:)

          query = Decidim::Bih::Text.fold(entities["query"])
          # Direct volunteering keeps the owning catalog's category and
          # recurring-calendar support; only combined summaries use the new
          # deliberately narrower scheduled-volunteer projection.
          if topic == "community" && query.match?(/\b(?:projek\w*|donacij\w*|projects?|donations?)\b/) &&
             !query.match?(/\b(?:organiz\w*|udruzen\w*|partner\w*|potreb\w*|oprem\w*|materijal\w*)\b/)
            return ["projects"]
          end
          return ["meetings"] if topic == "participation" && !query.match?(/\b(?:prijedlo\w*|predlo\w*|proposal\w*|glas\w*|vot\w*|proces\w*)\b/)

          nil
        end

        def scoped_neighborhood_activities(entities:, context:, locale:, location:, selection:)
          topic, families = selection
          area = public_mz_fallback(resolve_area(entities:, location:), entities:, context:, location:)
          return area.result if area.result
          return result("ambiguous", warnings: ["area_required"]) if area.slugs.empty?

          reader = NeighborhoodActivityRead.new(organization:)
          starts_at, ends_at = reader.requested_window(entities:, context:, topic:)
          activity = read_query(context.deadline) do
            reader.call(areas: area.areas, context:, starts_at:, ends_at:, explicit_time: true, locale:, family_keys: families)
          end
          coverage = { "scope" => "public_neighborhood_activities", "area_slugs" => area.slugs,
                       "area_labels" => area.areas.map { |record| localized_area_name(record, locale) }, "activities" => activity.coverage }
          result(activity.status, facts: activity.facts, coverage:, source: aggregate_sources(activity.facts), warnings: activity.warnings)
        rescue ArgumentError => e
          raise unless %w(invalid_catalog_date unsupported_catalog_time).include?(e.message)

          result("ambiguous", warnings: [e.message])
        end

        def public_neighborhood_reports(area:, entities:, context:, locale:, window:)
          starts_at, ends_at = window
          read_query(context.deadline) do
            PublicNeighborhoodActivity.new(organization:).call(
              areas: area.areas, now: context.now, starts_at:, ends_at:,
              explicit_time: entities["date"].present? || entities["time_expression"].present?, locale:
            )
          end
        rescue StandardError => e
          raise if e.is_a?(CityServiceNoticeCollector::DeadlineExceeded)

          PublicNeighborhoodActivity::Result.new("unavailable", [], { "status" => "unavailable" }, ["public_reports_unavailable"])
        end

        def neighborhood_query_result(query, coverage:, locale:, now:, slugs:)
          return conflicting_event_result(query, locale:, now:, slugs:) if query.status == :conflict

          if query.status == :empty
            # A database result is not a check of external operators or proof
            # that nothing is happening. Never trigger a network fetch here.
            return result("empty", coverage:, warnings: ["no_matching_collected_notices"])
          end
          return result("unavailable", coverage:, warnings: [query.error_code.to_s]) unless query.status == :ok

          facts = query.events.first(MAX_FACTS).map { |event| event_fact(event, locale:, now:, requested_area_slugs: slugs) }
          result("ok", facts:, source: aggregate_sources(facts), checked_at: latest_fact_time(facts, "checked_at"),
                       coverage:, validity: coverage.slice("starts_at", "ends_at"),
                       warnings: facts.flat_map { |fact| fact.fetch("warning_codes", []) }.uniq)
        end

        # Zone from a named street through the reviewed street/segment rows. A
        # coordinate never becomes a zone (the official map is an image). An
        # unknown street is asked for by name; a named place that still cannot
        # be mapped falls back to the sign-colour question.
        def parking_street_read(entities:, locale:)
          named = %w(street address area_query).filter_map { |key| entities[key].presence }
          query = entities["query"].to_s
          lookup = ParkingZones.default
          street = named.lazy.filter_map { |text| lookup.lookup_named(text) }.first || lookup.lookup(query)
          return parking_street_result(street, locale:) if street

          folded = Decidim::Bih::Text.fold(query)
          return unless unmapped_parking_street?(query, folded)
          return result("ambiguous", warnings: ["parking_street_not_in_reviewed_catalog"]) if named.any? || Decidim::Bih::Text.fold(query).match?(/\bulic\w*\b/)

          result("ambiguous", warnings: ["parking_street_or_lot_required"])
        end

        def unmapped_parking_street?(query, folded)
          ParkingQuestion.street_mention?(query) && DirectoryAnswer::ZONE_COLORS.values.none? { |color| color.match?(folded) }
        end

        def parking_street_result(street, locale:)
          checked_on = street[:source_checked_on]
          checked_on = checked_on.iso8601 if checked_on.respond_to?(:iso8601)
          fact = {
            "id" => "parking_street:#{street.fetch(:normalized_street_name).tr(" ", "-")}",
            "kind" => "parking_zone",
            "text" => bounded_text(localized_text(ParkingZones.default.street_summary(street), locale)),
            "source_id" => "parking_zone_streets",
            "source_label" => "Parking servis Bijeljina, službena mapa zona",
            "source_url" => safe_source_url(street[:source_url] || ParkingZones.source_url),
            "observed_at" => checked_on,
            "coverage" => { "organization_id" => organization.id, "street" => street.fetch(:street_name), "zone" => street.fetch(:zone),
                            "scope" => "reviewed_street_segment_map", "segment_note" => street.fetch(:segment_note) },
            "warning_codes" => %w(zone_sign_on_site_prevails snapshot_not_live_status)
          }.compact
          result("ok", facts: [fact], source: source_hash(fact), coverage: fact.fetch("coverage"),
                       validity: { "reviewed_on" => checked_on, "live_status" => false }.compact, warnings: fact.fetch("warning_codes"))
        end

        def transport_read(entities:, context:, locale:, location:) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
          if entities["category"] == "stop_navigation" || TransportJourneyQuestion.nearest_stop?(entities)
            return transport_nearest_stop_read(entities:, location:, context:,
                                               locale:)
          end
          return transport_calendar_read(entities:, context:, locale:) if TransportJourneyQuestion.calendar_question?(entities)

          if Decidim::Bih::Text.fold(entities["query"].to_s).match?(/\bmedjugradsk\w*\b/) &&
             Decidim::Bih::Text.fold(entities["query"].to_s).match?(/\b(?:odvoji|razlik\w*|podat\w*|podac\w*|red\w*)\b/)
            source = source_reference("public_transport")
            fact = { "id" => "transport_scope:city_suburban", "kind" => "transport_scope",
                     "text" => localized_text("Pregledani izvori obuhvataju gradske i prigradske linije Bijeljine. " \
                                              "Iz njih ne mogu potvrditi međugradski red vožnje niti nastavak putovanja u drugi grad; " \
                                              "taj dio puta treba provjeriti kod međugradskog prevoznika. " \
                                              "Gradski polazak nije dokaz da postoji odgovarajuća međugradska veza.", locale),
                     "source_id" => source.fetch("id"), "source_label" => source.fetch("label"), "source_url" => source.fetch("url") }
            return result("ok", facts: [fact], source:, coverage: { "scope" => "reviewed_city_and_suburban_lines" })
          end

          if (warning = transport_capability_warning(entities["query"]))
            return result("empty", validity: { "live_vehicle_status" => false, "accessibility_verified" => false }, warnings: [warning])
          end

          journey = TransportJourneyQuestion.call(entities, now: context.now)
          invalidated = entities["route"].present? && journey.entities["route"].blank? ? ["route"] : []
          invalidated << "transfer_mode" if entities["transfer_mode"].present? && journey.entities["transfer_mode"].blank?
          invalidated << "via_stop" if entities["via_stop"].present? && journey.entities["via_stop"].blank?
          invalidated << "stop" if journey.warning == "transport_origin_required" && entities["stop"].present? && journey.entities["stop"].blank?
          query_coverage = { "transport_query_entities" => journey.entities.slice("stop", "area_query", "date", "time_expression", "route", "via_stop", "transfer_mode"),
                             "transport_query_invalidated_entities" => invalidated }
          return result("ambiguous", coverage: query_coverage, warnings: [journey.warning]) if journey.warning

          entities = journey.entities
          return result("ambiguous", coverage: query_coverage, warnings: ["transport_origin_required"]) if transport_origin_required?(entities, location)

          check = source_checker.check(keys: ["public_transport"], max_items: CityServiceSourceCheckStore::MAX_ITEMS, deadline: context.deadline).first
          return source_check_failure(check, context.now).with(coverage: query_coverage) unless check && [:ok, :empty].include?(check.status)

          if check.notices.empty?
            return result("empty", source: source_reference("public_transport"), checked_at: safe_time(check.checked_at, context.now),
                                   coverage: query_coverage, warnings: ["no_reviewed_timetable_source"])
          end

          notices = check.notices.select { |notice| approved_source_url?(notice.url, notice.source_key) }
          return result("unavailable", source: source_reference("public_transport"), coverage: query_coverage, warnings: ["source_url_not_allowed"]) if notices.empty?

          calendar_kind = transport_calendar_kind(entities)
          return result("ambiguous", coverage: query_coverage, warnings: ["transport_calendar_date_required"]) if calendar_kind && entities["date"].blank?

          window = TransportJourneyQuestion.requested_window(entities, now: context.now)
          return result("ambiguous", coverage: query_coverage, warnings: [window.warning]) if window.warning

          calendar_options = calendar_kind ? { service_day_kind: calendar_kind } : {}
          origin = transport_origin(entities)
          query = transport_timetable_query(origin:, entities:, notices:, location:, window:, context:, calendar_options:)
          street = nil
          if query.status == :empty && transport_query_value(query, :unmatched, []).include?("origin") && (street = transport_street_origin(origin))
            query = transport_timetable_query(origin: nil, entities:, notices:, location: street.fetch("location"), window:, context:, calendar_options:)
          end
          query_warnings = Array(query.warnings).dup
          query_warnings << "partial_timetable_preparation" if check.error_code == :partial_timetable_preparation
          query_warnings << "origin_resolved_from_street" if street
          if query.status == :ambiguous
            return result("ambiguous", coverage: query_coverage, candidates: query.candidates, validity: transport_search_limits, warnings: query_warnings)
          end

          if (check.error_code == :partial_timetable_preparation) && (query.status == :empty)
            return result("unavailable", source: source_reference("public_transport"), coverage: query_coverage, warnings: ["partial_timetable_preparation"])
          end

          if query.status == :empty
            return result("empty", source: source_reference("public_transport"), checked_at: safe_time(check.checked_at, context.now),
                                   coverage: query_coverage, validity: transport_search_limits, warnings: query_warnings)
          end
          if query.status == :unreviewed
            return result("unreviewed", source: source_reference("public_transport"), coverage: query_coverage, validity: transport_search_limits, warnings: query_warnings)
          end
          return result("unavailable", coverage: query_coverage, validity: transport_search_limits, warnings: query_warnings) unless query.status == :ok

          if entities["transfer_mode"] == "direct" && query.itinerary.legs.size > 1
            return result("empty", source: source_reference("public_transport"), coverage: query_coverage,
                                   validity: transport_search_limits.merge("maximum_transfers" => 0), warnings: ["no_feasible_journey_within_transfer_limit"])
          end

          facts, sources = transport_journey_facts(query, check:, locale:, now: context.now, window:, street:)
          if facts.first && Decidim::Bih::Text.fold(entities["query"].to_s).match?(/\b(?:skolsk\w*|redovn\w*)\b.*\bpolaz\w*\b/)
            kind = query.itinerary.legs.first.calendar&.fetch("kind", nil)
            calendar = { "school_day" => "školski dan", "school_break" => "školski raspust", "saturday" => "subotu" }[kind]
            if calendar
              note = "Ovaj polazak je iz objavljenog rasporeda za #{calendar}. To samo po sebi ne znači da je vožnja namijenjena isključivo učenicima."
              facts.first["text"] = "#{localized_text(note, locale)} #{facts.first.fetch("text")}"
            end
          end
          if facts.first && Decidim::Bih::Text.fold(entities["query"].to_s).match?(/\b(?:moram|moraju|treba|potrebno|da li)\b.*\b(?:presjed\w*|presed\w*)\b/)
            legs = query.itinerary.legs
            answer = if legs.one?
                       "Ne, ovaj objavljeni polazak je direktan, bez presjedanja."
                     else
                       "Da, za ovu objavljenu vezu potrebno je presjedanje: u sljedeći autobus ulaziš na stajalištu #{legs[1].origin_label}."
                     end
            facts.first["text"] = "#{localized_text(answer, locale)} #{facts.first.fetch("text")}"
          end
          if Decidim::Bih::Text.fold(entities["query"].to_s).match?(/\b(?:gdje|gde|koliko)\b.*\b(?:presjed\w*|presed\w*|cekam|cekan\w*)\b/)
            legs = query.itinerary.legs
            if legs.size > 1
              first, second = legs.first(2)
              minutes = ((second.departure_at - first.arrival_at) / 60).to_i
              text = "Presjedanje #{first.route_code} → #{second.route_code}: izlaziš na #{first.destination_label} " \
                     "u #{first.arrival_at.strftime("%H:%M")}, a ulaziš na #{second.origin_label} u #{second.departure_at.strftime("%H:%M")}. " \
                     "Po objavljenom redu razmak je #{minutes} minuta. " \
                     "To nije potvrda stanja uživo niti provjerenog pješačkog prelaza."
              leg = facts.find { |fact| fact["kind"] == "transport_leg" }
              facts = [leg.merge("text" => localized_text(text, locale))] if leg
            end
          end
          if TransportJourneyQuestion.accessibility_requested?(entities)
            facts.first["text"] += " #{I18n.t("decidim_app.milica.directory_answers.transport_accessibility_unverified", locale:)}" if facts.first
            query_warnings += ["accessibility_unverified"]
          end
          if /\b(?:uzivo|kasni|kasnjenje|live|delay\w*)\b/.match?(Decidim::Bih::Text.fold(entities["query"].to_s))
            facts.first["text"] += " #{I18n.t("decidim.bih.dialogue.transport_live_status_unavailable", locale:)}" if facts.first
            query_warnings += ["transport_live_status_unavailable"]
          end
          service_day = transport_query_value(query, :service_date, nil) || window.requested_day.iso8601
          result(
            "ok",
            facts:,
            source: sources,
            checked_at: safe_time(check.checked_at, context.now),
            coverage: {
              **query_coverage,
              "origin" => query.origin, "destination" => query.destination, "service_day" => service_day,
              "requested_service_day" => window.requested_day.iso8601, "origin_query" => origin, "destination_query" => entities["area_query"],
              "destination_scope" => transport_query_value(query, :destination_scope, "area"),
              "origin_street" => street&.fetch("label"), "options" => transport_query_value(query, :options, [query.itinerary]).size
            }.compact,
            validity: {
              "timetable_snapshot" => true, "live_vehicle_status" => false, "conditional_calendar_kind" => calendar_kind,
              **transport_search_limits,
              "departures_after" => time_value(window.earliest_after), "historical" => (true if window.historical),
              "rolled_over" => (true if transport_query_value(query, :rolled_over, false))
            }.compact,
            warnings: query_warnings
          )
        end

        # These data sources describe planned departures and approximate stops.
        # A capability question needs neither a new origin nor a timetable query.
        def transport_calendar_read(entities:, context:, locale:)
          # The literal question selected a line calendar, not a journey.
          # Model place slots must not survive as invented calendar endpoints.
          selection = TransportJourneyQuestion.calendar_entities(entities.except("stop", "area_query", "via_stop", "transfer_mode"), now: context.now)
          coverage = { "transport_query_scope" => "calendar",
                       "transport_query_invalidated_entities" => %w(stop area_query via_stop transfer_mode),
                       "transport_query_entities" => selection.entities.slice("date", "time_expression", "route") }
          return result("ambiguous", coverage:, warnings: [selection.warning]) if selection.warning

          entities = selection.entities
          kind = transport_calendar_kind(entities)
          return result("ambiguous", coverage:, warnings: ["transport_calendar_date_required"]) if kind && entities["date"].blank?

          check = source_checker.check(keys: ["public_transport"], max_items: CityServiceSourceCheckStore::MAX_ITEMS, deadline: context.deadline).first
          return source_check_failure(check, context.now).with(coverage:) unless check && [:ok, :empty].include?(check.status)

          notices = check.notices.select { |notice| approved_source_url?(notice.url, notice.source_key) }
          return result("empty", coverage:, warnings: ["no_reviewed_timetable_source"]) if notices.empty?

          day = transport_calendar_day(entities, context)
          at = ActiveSupport::TimeZone[TransportJourneyQuestion::SERVICE_TIME_ZONE].local(day.year, day.month, day.day)
          answer = timetable.calendar_query(notices:, requested_at: at, route_code: entities["route"], service_day_kind: kind, deadline: context.deadline)
          facts = answer.fetch(:directions).map do |direction|
            text = "#{day.iso8601}, #{direction.fetch("route")}, #{direction.fetch("direction")}: " \
                   "objavljeni polasci sa početnog stajališta #{direction.fetch("departures").join(", ")}. Ovo je red vožnje, bez praćenja uživo."
            text = localized_text(text, locale)
            url = direction.fetch("source_url")
            identity = Digest::SHA256.hexdigest([day.iso8601, direction.fetch("route"), direction.fetch("direction"), url].join("|"))[0, 16]
            { "id" => "transport_calendar:#{identity}", "kind" => "transport_calendar", "text" => bounded_text(text),
              "source_id" => source_id(url), "source_label" => "#{direction.fetch("route")} — objavljeni red vožnje",
              "source_url" => url, "checked_at" => time_value(safe_time(check.checked_at, context.now)),
              "service_day" => day.iso8601, "coverage" => { "direction" => direction.fetch("direction"), "route" => direction.fetch("route") } }
          end
          result(answer.fetch(:status), facts:, coverage:, source: source_reference("public_transport"), checked_at: safe_time(check.checked_at, context.now),
                                        warnings: answer.fetch(:warnings))
        end

        def transport_calendar_day(entities, context)
          entities["date"].present? ? Date.iso8601(entities["date"]) : context.now.in_time_zone(TransportJourneyQuestion::SERVICE_TIME_ZONE).to_date
        end

        def transport_capability_warning(text)
          query = Decidim::Bih::Text.fold(text.to_s)
          return unless query.length.between?(1, 1_000)
          return "transport_live_status_unavailable" if query.match?(/\A(?:razlikujes li|imas li|postoji li)\b.*\b(?:uzivo|pracenj\w*|live)\b/)
          return unless transport_capability_question?(query)

          return "transport_live_status_unavailable" if /\b(?:uzivo|kasni|kasnjenje|live|delay\w*)\b/.match?(query)

          "transport_accessibility_unverified" if /\b(?:prilagodjen\w*|pristupac\w*|accessible)\b/.match?(query)
        end

        def transport_capability_question?(query)
          return false unless /\A(?:a\s+)?(?:mozes\s+li|mozete\s+li|da\s+li|jesu\s+li|je\s+li|kasni\s+li|can\s+you|is|are|does)\b/.match?(query)
          return false if /\b(?:gdje|gde|where|kada|when|koliko|ne)\b/.match?(query)
          return false unless /\b(?:autobus\w*|stajal\w*|bus|buses|vehicle|stop)\b/.match?(query)
          return false if /\b(?:prijav\w*|nego|ali|instead|report)\b/.match?(query)
          return false if /\b(?:od|iz|from)\b.+\b(?:do|to)\b/.match?(query)

          true
        end

        def transport_search_limits
          { "maximum_transfers" => 1,
            "minimum_transfer_minutes" => PublicTransportTimetable::TRANSFER_BUFFER_SECONDS / 60,
            "maximum_transfer_wait_minutes" => PublicTransportTimetable::MAX_TRANSFER_WAIT_SECONDS / 60 }
        end

        def transport_nearest_stop_read(entities:, location:, context:, locale:)
          place = TransportJourneyQuestion.nearest_place(entities)
          place = transport_origin({ "stop" => place })
          query, place, stop_required = nearest_stop_query(entities:, location:, context:, place:)
          return result("ambiguous", warnings: ["transport_navigation_stop_required"]) if stop_required

          coverage = place.present? ? { "transport_query_entities" => { "stop" => place } } : {}
          return result(query.status.to_s, coverage:, candidates: query.candidates, warnings: query.warnings) unless query.status == :ok

          fact, stop = transport_navigation_fact(query, entities:, locale:)
          warnings = fact.fetch("warning_codes")
          result("ok", facts: [fact], source: { "id" => fact.fetch("source_id"), "label" => fact.fetch("source_label") },
                       coverage: coverage.merge("origin" => query.origin, "coordinate_accuracy" => stop.dig("coverage", "coordinate_accuracy")),
                       validity: { "live_vehicle_status" => false, "accessibility_verified" => false }, warnings:)
        end

        def selectable_navigation_stop?(query)
          query.status == :ok || (query.status == :ambiguous && query.candidates.any?)
        end

        def nearest_stop_query(entities:, location:, context:, place:)
          street = transport_street_origin(place) if location.nil? && place.present?
          location ||= street&.fetch("location")
          if entities["category"] == "stop_navigation" && place.blank?
            query = timetable.nearest_stop(location: nil, place: entities["query"], deadline: context.deadline)
            return [query, place, true] unless selectable_navigation_stop?(query)

            place = query.origin.presence || entities["query"]
          else
            query = timetable.nearest_stop(location:, place:, locality: TransportJourneyQuestion.nearest_locality(entities), deadline: context.deadline)
          end
          [query, place, false]
        end

        def transport_navigation_fact(query, entities:, locale:)
          stop = query.boarding_stop
          accessibility = TransportJourneyQuestion.accessibility_requested?(entities)
          text = localized_text(stop.fetch("text"), locale)
          text += " #{I18n.t("decidim_app.milica.directory_answers.transport_accessibility_unverified", locale:)}" if accessibility
          text += "\n#{stop.fetch("destination")}"
          warnings = query.warnings + (accessibility ? ["accessibility_unverified"] : [])
          fact = stop.merge("kind" => "transport_navigation", "text" => text, "warning_codes" => warnings)
          fact.merge!(transport_navigation_presentation(stop, locale:, accessibility:))
          [fact, stop]
        end

        def transport_navigation_presentation(stop, locale:, accessibility:)
          parts = stop["navigation_presentation"]
          return {} unless parts.is_a?(Hash)

          localized = parts.transform_values { |value| localized_text(value, locale) }
          localized["caveat"] = accessibility ? " #{I18n.t("decidim_app.milica.directory_answers.transport_accessibility_unverified", locale:)}" : ""
          { "navigation_presentation" => localized }
        end

        def transport_timetable_query(origin:, entities:, notices:, location:, window:, context:, calendar_options:) # rubocop:disable Metrics/ParameterLists
          timetable.query(
            origin:,
            destination: entities.fetch("area_query"),
            requested_at: window.earliest_after,
            route_code: entities["route"],
            notices:,
            location:,
            deadline: context.deadline,
            mode: window.mode,
            roll_over: true,
            options: window.options,
            strict: window.strict,
            **calendar_options
          )
        end

        # Test doubles and older query shapes may lack the journey fields.
        def transport_query_value(query, name, default)
          return default unless query.respond_to?(name)

          value = query.public_send(name)
          value.nil? ? default : value
        end

        # A street is not a stop. Resolve an unambiguous Bijeljina street
        # through the reviewed street geometry to a point and let the
        # timetable board at the nearest reviewed stop, walking link included.
        # Anything ambiguous leaves the citizen asked for a stop instead.
        def transport_street_origin(origin)
          return if origin.blank? || !DecidimApp::Bijeljina.const_defined?(:LocalStreetRegistry)

          street = transport_street_candidates(origin)
          return unless street

          { "label" => street.fetch(:name), "settlement" => street[:settlement],
            "location" => { "latitude" => street.fetch(:lat), "longitude" => street.fetch(:lon) } }
        rescue StandardError => e
          raise if e.is_a?(CityServiceNoticeCollector::DeadlineExceeded)

          log_failure(e, "transport_street_origin")
          nil
        end

        # The same street appears in Latin and Cyrillic across GIS layers:
        # one street, Bijeljina first, complete geometry first. Two different
        # streets stay ambiguous, and the citizen is asked for a stop instead.
        def transport_street_candidates(origin)
          candidates = street_registry_matches(origin).select { |candidate| candidate[:lat].is_a?(Numeric) && candidate[:lon].is_a?(Numeric) }
          local = candidates.select { |candidate| Decidim::Bih::Text.fold(candidate[:settlement].to_s) == "bijeljina" }
          chosen = unique_streets(local.presence || candidates)
          chosen.first if chosen.one?
        end

        def street_registry_matches(origin)
          registry = LocalStreetRegistry.new(organization:)
          ParkingZones.name_forms(origin).lazy.map { |form| registry.search(query: form) }.find(&:any?) || []
        end

        def unique_streets(candidates)
          candidates.sort_by { |candidate| candidate[:complete] ? 0 : 1 }
                    .uniq { |candidate| [candidate[:name], candidate[:settlement]].map { |value| Decidim::Bih::Text.fold(value.to_s) } }
        end

        def transport_journey_facts(query, check:, locale:, now:, window:, street:) # rubocop:disable Metrics/ParameterLists
          legs = query.itinerary.legs.first(MAX_FACTS)
          alternatives = transport_query_value(query, :alternatives, [])
          facts = legs.each_with_index.map do |leg, index|
            prefix = transport_journey_note(query, window:, street:, now:) if index.zero?
            if index.positive?
              previous = legs[index - 1]
              waiting = ((leg.departure_at - previous.arrival_at) / 60).round
              prefix = "Presjedanje na #{leg.origin_label}; čekanje #{waiting} minuta."
            end
            suffix = transport_alternatives_note(alternatives, leg) if index == legs.size - 1
            transport_leg_fact(leg, query, index, check, locale, now, prefix:, suffix:)
          end
          sources = query.sources.map { |url| { "id" => source_id(url), "url" => safe_source_url(url, "public_transport") } }
          walking = transport_walking_fact(query.boarding_stop, locale:) if query.respond_to?(:boarding_stop)
          if walking && facts.length < MAX_FACTS
            facts << walking
            sources << { "id" => walking.fetch("source_id"), "label" => walking.fetch("source_label") }
          end
          [facts, sources]
        end

        TRANSPORT_ZONE = "Europe/Sarajevo"
        TRANSPORT_WEEKDAYS = %w(nedjelja ponedjeljak utorak srijeda četvrtak petak subota).freeze
        TRANSPORT_WEEKDAYS_ON = %w(nedjelju ponedjeljak utorak srijedu četvrtak petak subotu).freeze

        # What must be said aloud beside the departure: a street boarded at
        # the nearest stop, a window kept in the past on purpose, a past clock
        # moved to tomorrow, and a roll to the next service day. Serbian Latin
        # here; the fact text is localized once, with the leg.
        def transport_journey_note(query, window:, street:, now:)
          notes = []
          notes << "Ulica #{street.fetch("label")} nije stajalište; za traženi pravac polazak je sa stajališta #{query.origin}." if street
          notes << transport_boarding_note(query)
          if window.historical
            from = window.past_clock || window.earliest_after.in_time_zone(TRANSPORT_ZONE).strftime("%H:%M")
            notes << "Traženo vrijeme je već prošlo; prikazujem polaske od #{from}, a ne sljedeći polazak."
          elsif window.rolled_clock
            notes << "Traženo vrijeme #{window.past_clock} je danas već prošlo, pa prikazujem sutrašnji polazak."
          elsif window.past_clock
            notes << "Polazak u #{window.past_clock} je već prošao; prikazujem sljedeći polazak od sada."
          end
          notes << transport_rollover_note(query, now) if transport_query_value(query, :rolled_over, false)
          notes.compact.presence&.join(" ")
        end

        def transport_boarding_note(query)
          nearest = transport_query_value(query, :candidates, []).first
          return unless nearest && nearest["text"] != query.origin

          "Za ovaj pravac polazak je sa #{query.origin}; najbliže fizičko stajalište ne mora služiti traženoj liniji."
        end

        def transport_rollover_note(query, now)
          today = now.in_time_zone(TRANSPORT_ZONE).to_date
          requested = Date.iso8601(query.requested_service_date)
          service = Date.iso8601(query.service_date)
          unpublished = query.warnings.include?("no_departures_published_for_service_day")
          lead = if requested == today
                   unpublished ? "Danas (#{TRANSPORT_WEEKDAYS[today.wday]}) nema objavljenih polazaka za ovaj pravac" : "Danas više nema polazaka za ovaj pravac"
                 else
                   published = unpublished ? "nema objavljenih polazaka" : "nema više polazaka"
                   "Za traženi dan (#{transport_day(requested)}) #{published}"
                 end
          following = service == today + 1 ? "sutra (#{transport_day(service)})" : "u #{TRANSPORT_WEEKDAYS_ON[service.wday]} #{service.strftime("%-d.%-m.%Y")}"
          "#{lead}; prvi sljedeći koji čitam je #{following}."
        end

        def transport_day(date)
          "#{TRANSPORT_WEEKDAYS[date.wday]} #{date.strftime("%-d.%-m.%Y")}"
        end

        def transport_alternatives_note(alternatives, leg)
          return if alternatives.blank?

          first_date = leg.departure_at.in_time_zone(TRANSPORT_ZONE).to_date
          items = alternatives.map do |itinerary|
            start = itinerary.legs.first
            departure = start.departure_at.in_time_zone(TRANSPORT_ZONE)
            parts = [departure.strftime("%H:%M")]
            parts << "(#{departure.strftime("%-d.%-m.")})" if departure.to_date != first_date
            parts << "sa #{start.origin_label}" if start.origin_label != leg.origin_label
            parts << "(#{start.route_code})" if start.route_code != leg.route_code
            parts << "s presjedanjem" if itinerary.legs.size > 1
            parts.join(" ")
          end
          "Sljedeći polazak: #{items.join("; ")}."
        end

        def transport_calendar_kind(entities)
          text = Decidim::Bih::Text.fold([entities["time_expression"], entities["query"]].compact.join(" "))
          return "school_break" if text.match?(/\b(?:raspust\w*|school break)\b/)
          return "school_day" if text.match?(/\b(?:skolsk\w* dan\w*|nastavn\w* dan\w*|school day)\b/)

          "holiday" if text.match?(/\b(?:prazni\w*|blagdan\w*|holiday\w*)\b/)
        end

        def transport_walking_fact(stop, locale:)
          return unless stop

          accuracy = stop.fetch("coverage").fetch("coordinate_accuracy")
          return unless %w(verified provided assumed).include?(accuracy)

          text = I18n.t("decidim_app.milica.directory_answers.transport_walk_#{accuracy}", stop: localized_text(stop.fetch("text"), locale), locale:)
          # Keep navigation visible alongside the distinct source URL. The
          # generic fact renderer otherwise chooses only the provenance URL.
          stop.merge("kind" => "transport_navigation", "text" => "#{text}\n#{stop.fetch("destination")}")
        end

        def transport_origin_required?(entities, location)
          transport_origin(entities).blank? && location.nil?
        end

        # "From here" is not a stop name and never supplies coordinates or
        # consent. A nil origin lets the timetable use validated current-turn
        # coordinates; without them the pre-source guard asks for a start.
        def transport_origin(entities)
          origin = entities["stop"]
          reference = Decidim::Bih::Text.fold(origin).sub(/\A(?:s|sa|od|iz|from) /, "")
          return if TRANSPORT_CURRENT_ORIGINS.include?(reference)

          origin
        end

        def transport_place_key(value)
          Decidim::Bih::Text.fold(value).split.map do |token|
            token.length > 4 ? token.sub(/(ima|om|em|u|a|e|i)\z/, "") : token
          end
        end

        def source_check_failure(check, now)
          return result("unavailable", source: source_reference("public_transport"), warnings: ["source_check_missing"]) unless check

          status = check.status == :unreviewed ? "unreviewed" : "unavailable"
          result(status, source: source_reference(check.source_key), checked_at: safe_time(check.checked_at, now), warnings: [check.error_code || "source_not_reviewed"])
        end

        def neighborhood_read(entities:, context:, locale:, location:)
          return denied_neighborhood_access("neighborhood_membership_required").result unless context.allows?("neighborhood_reads")

          area = resolve_area(entities:, location:)
          return area.result if area.result

          area = resolve_assigned_area(context) if area.slugs.empty? && !explicit_area_or_location?(entities:, location:)
          return result("ambiguous", candidates: [], warnings: ["area_required"]) if area.slugs.empty?

          access = neighborhood_access(area, context)
          return access.result if access.result

          posts = neighborhood_posts(access.profile, context.deadline)
          coverage = { "organization_id" => organization.id, "area_slugs" => [access.profile.komsiluk.slug],
                       "area_labels" => public_area_label_names([access.profile.komsiluk.slug]).presence, "visibility" => "member_board" }.compact
          return result("empty", coverage:, warnings: ["no_visible_matching_board_posts"]) if posts.empty?

          facts = posts.map { |post| board_fact(post, access.profile.komsiluk, locale:) }
          result("ok", facts:, source: { "id" => "komsiluk_board" }, coverage:, warnings: [])
        end

        NeighborhoodAccess = Struct.new(:profile, :result)

        def neighborhood_access(area, context)
          return denied_neighborhood_access("neighborhood_membership_required") unless context.allows?("neighborhood_reads")

          actor = actor_for!(context)
          return denied_neighborhood_access("verified_actor_required") unless actor

          profile = read_query(context.deadline) do
            Decidim::Bih::CitizenProfile.find_by(
              decidim_organization_id: organization.id,
              decidim_user_id: actor.id
            )
          end
          return denied_neighborhood_access("assigned_neighborhood_required") unless profile&.assigned?
          return denied_neighborhood_access("assigned_area_scope_mismatch") unless assigned_area?(profile.komsiluk)
          return denied_neighborhood_access("requested_area_not_assigned") unless area.slugs.include?(profile.komsiluk.slug)

          NeighborhoodAccess.new(profile, nil)
        end

        def resolve_assigned_area(context)
          return AreaOutcome.new([], :trusted_profile, nil) unless context.allows?("neighborhood_reads")

          actor = actor_for!(context)
          return AreaOutcome.new([], :trusted_profile, nil) unless actor

          profile = read_query(context.deadline) do
            Decidim::Bih::CitizenProfile.find_by(
              decidim_organization_id: organization.id,
              decidim_user_id: actor.id
            )
          end
          area = profile&.komsiluk
          return AreaOutcome.new([area], :trusted_profile, nil) if profile&.assigned? && assigned_area?(area)

          AreaOutcome.new([], :trusted_profile, nil)
        end

        def denied_neighborhood_access(warning)
          NeighborhoodAccess.new(nil, result("not_authorized", warnings: [warning]))
        end

        def neighborhood_posts(profile, deadline)
          read_query(deadline) do
            Decidim::Bih::KomsilukPost
              .where(decidim_organization_id: organization.id)
              .visible
              .for_komsiluk(profile.komsiluk_id)
              .order(created_at: :desc, id: :desc)
              .limit(BOARD_LIMIT)
              .to_a
          end
        end

        def public_place_required?(capability, entities, location)
          %w(area mz_contact public_activity).include?(capability) && !explicit_area_or_location?(entities:, location:)
        end

        def validate_public_place_kind!(capability, place_kind)
          return if place_kind.nil?
          raise contracts::Invalid, "Invalid public place kind" unless %w(mz komsiluk).include?(place_kind)
          raise contracts::Invalid, "Place kind only applies to area readers" unless %w(area mz_contact).include?(capability)
        end

        def resolve_public_area(entities:, context:, location:, place_kind:)
          area = resolve_area(entities:, location:, place_kind:)
          place_kind == "komsiluk" ? area : public_mz_fallback(area, entities:, context:, location:)
        end

        def area_read(entities:, context:, locale:, location:, place_kind: nil)
          return result("not_authorized", warnings: ["public_reads_not_allowed"]) unless context.allows?("public_reads")
          return mz_contact_read(entities:, context:, locale:, location:, place_kind:) if Decidim::Bih::Concierge::Dialogue::CivicQuestion.mz_contact?(entities["query"])

          area = resolve_public_area(entities:, context:, location:, place_kind:)
          return area.result if area.result

          area = resolve_assigned_area(context) if place_kind.nil? && area.areas.empty? && !explicit_area_or_location?(entities:, location:)
          return result("ambiguous", warnings: ["area_required"]) if area.areas.empty?

          facts = area.areas.first(MAX_FACTS).map { |candidate| public_area_fact(candidate, area.source, locale:) }
          coverage = { "organization_id" => organization.id, "area_slugs" => area.slugs, "area_labels" => public_area_label_names(area.slugs).presence }.compact
          result("ok", facts:, source: { "id" => "local_area_registry" }, coverage:, warnings: ["area_selection_grants_no_membership"])
        end

        def mz_contact_read(entities:, context:, locale:, location:, place_kind: nil)
          area = resolve_public_area(entities:, context:, location:, place_kind:)
          return area.result if area.result

          area = trusted_profile_mz_area(area, entities:, context:, location:)
          matches = area.areas.select { |candidate| candidate.kind == "mz" && candidate.decidim_organization_id == organization.id }
          return result("ambiguous", warnings: ["area_required"]) unless matches.one?

          fact = MzContactAnswer.call(area: matches.first, query: entities["query"], locale:)
          result("ok", facts: [fact], source: source_hash(fact),
                       coverage: { "organization_id" => organization.id, "area_slugs" => [matches.first.slug],
                                   "area_labels" => public_area_label_names([matches.first.slug]).presence, "scope" => "public_mz_directory" }.compact,
                       warnings: ["public_directory_contact_not_live_verified"])
        end

        def trusted_profile_mz_area(area, entities:, context:, location:)
          if area.areas.empty? && !explicit_area_or_location?(entities:, location:) && context.allows?("neighborhood_reads")
            actor = actor_for!(context)
            profile = read_query(context.deadline) do
              Decidim::Bih::CitizenProfile.find_by(decidim_organization_id: organization.id, decidim_user_id: actor.id) if actor
            end
            # Independent MZ association: a komsiluk is not an MZ identity.
            area = AreaOutcome.new([profile.mz].compact, :trusted_profile_mz, nil) if profile
          end
          area
        end

        # Fallback must preserve explicit-name, location, stable-slug and ambiguity guards.
        # rubocop:disable Metrics/CyclomaticComplexity
        def public_mz_fallback(area, entities:, context:, location:)
          return area unless area.result&.status == "empty" && area.source == :explicit_name
          return area if location || entities["area_slug"].present?

          query = entities["area_query"].to_s.strip
          return area unless query.match?(/\A[\p{L}\p{M}\p{N} -]{1,160}\z/u)

          name = public_mz_name(query)
          return area if name.blank?

          matches = matching_public_mz(name, context.deadline)
          return area if matches.empty?
          return AreaOutcome.new(matches, :public_mz_name, nil) if matches.one?

          AreaOutcome.new([], :public_mz_name, result("ambiguous", warnings: ["area_name_ambiguous"]))
        end
        # rubocop:enable Metrics/CyclomaticComplexity

        def matching_public_mz(name, deadline)
          read_query(deadline) do
            Decidim::Bih::LocalArea.where(decidim_organization_id: organization.id, kind: "mz").to_a.select do |candidate|
              Array(candidate.name.is_a?(Hash) ? candidate.name.values : candidate.name).any? { |value| public_mz_name(value) == name }
            end
          end
        end

        def public_mz_name(value)
          Decidim::Bih::Text.fold(value.to_s).sub(/\A(?:mz|mjesna zajednica|mesna zajednica) /, "")
        end

        def public_area_fact(area, resolution_source, locale:)
          fact = area_fact(area, resolution_source, locale:)
          return fact unless area.kind == "mz" && area.decidim_organization_id == organization.id

          has_map = area.slug.to_s.match?(/\Amz-[a-z0-9]+(?:-[a-z0-9]+)*\z/) && area.boundary.present?
          key = has_map ? "public_mz_map" : "public_mz_no_map"
          fact["text"] = I18n.t("decidim_app.milica.directory_answers.#{key}", name: localized_area_name(area, locale), locale:)
          fact["destination"] = Decidim::Bih.public_path("mjesne-zajednice/#{area.slug}") if has_map
          fact
        end

        def report_status(entities:, context:, locale:)
          return result("not_authorized", warnings: ["own_report_reads_not_allowed"]) unless context.allows?("own_report_reads")

          actor = actor_for!(context)
          return result("not_authorized", warnings: ["verified_actor_required"]) unless actor

          reference = entities["reference"].to_s.upcase
          if reference.blank?
            limit = Decidim::Bih::Concierge::Dialogue::OwnReportQuestion.limit(entities["query"])
            return recent_report_status(actor:, context:, locale:, limit:) if limit

            return result("ambiguous", warnings: ["report_reference_required"])
          end

          report = read_query(context.deadline) do
            Decidim::Bih::Report.find_by(
              decidim_organization_id: organization.id,
              decidim_user_id: actor.id,
              reference:
            )
          end
          return result("empty", warnings: ["owned_report_not_found"]) unless report

          fact = report_status_fact(report, locale:)
          result(
            "ok",
            facts: [fact],
            source: { "id" => "report:#{report.reference}", "url" => fact.fetch("destination") },
            checked_at: safe_time(report.updated_at, context.now),
            coverage: { "organization_id" => organization.id, "ownership" => "actor" },
            validity: { "status_as_of" => time_value(report.updated_at) }
          )
        end

        def recent_report_status(actor:, context:, locale:, limit:)
          reports = read_query(context.deadline) do
            Decidim::Bih::Report
              .where(decidim_organization_id: organization.id, decidim_user_id: actor.id)
              .select(:id, :reference, :status, :duplicate_of_report_id, :review_state, :reviewed_at, :last_citizen_reply_at, :created_at, :updated_at)
              .order(created_at: :desc, id: :desc)
              .limit(limit)
              .to_a
          end
          coverage = { "organization_id" => organization.id, "ownership" => "actor", "scope" => "most_recent_owned_reports", "limit" => limit }
          return result("empty", coverage:, warnings: ["no_owned_reports"]) if reports.empty?

          facts = reports.map { |report| report_status_fact(report, locale:) }
          result("ok", facts:, source: { "id" => "owned_reports" }, checked_at: context.now, coverage:,
                       warnings: limit > 1 ? ["bounded_recent_report_list"] : [])
        end

        def nearby_reports(entities:, context:, locale:, location:)
          return result("not_authorized", warnings: ["report_guidance_not_allowed"]) unless
            context.allows?("report_guidance") || context.allows?("public_reads")
          return result("ambiguous", warnings: ["current_turn_location_required_for_duplicate_check"]) unless location

          category = entities["category"].presence
          reports = read_query(context.deadline) do
            duplicate_finder.matches(
              organization:,
              latitude: location.fetch("latitude"),
              longitude: location.fetch("longitude"),
              category:
            ).first(REPORT_LIMIT)
          end
          coverage = {
            "organization_id" => organization.id,
            "radius_meters" => Decidim::Bih::DuplicateFinder::DEFAULT_RADIUS_METERS.to_i,
            "location_accuracy_meters" => location.fetch("accuracy")
          }
          return result("empty", coverage:, warnings: ["no_public_nearby_match_in_reviewed_scope"]) if reports.empty?

          facts = reports.map { |report| duplicate_fact(report, locale:) }
          result("ok", facts:, source: { "id" => "public_reports" }, coverage:, warnings: ["nearby_match_is_not_citywide_completeness"])
        end

        def resolve_area(entities:, location:, place_kind: nil)
          options = { area_slug: entities["area_slug"], area_query: entities["area_query"], location: }
          options[:place_kind] = place_kind if place_kind
          resolution = area_matcher.resolve(**options)
          return AreaOutcome.new(resolution.areas, resolution.source, nil) if resolution.status == :ok

          candidates = resolution.areas.first(MAX_FACTS).map { |area| area_fact(area, resolution.source, locale: I18n.locale.to_s) }
          status = resolution.status == :ambiguous ? "ambiguous" : "empty"
          outcome = result(status, candidates:, warnings: [resolution.warning || "area_not_found"])
          AreaOutcome.new([], resolution.source, outcome)
        end

        def explicit_area_or_location?(entities:, location:)
          return true if location

          # The current question is not an explicit location. Only real area
          # slots or consented coordinates may override the trusted profile.
          %w(area_slug area_query street address).any? { |key| entities[key].to_s.strip.present? }
        end

        # +coverage+ and +warnings+ carry what the read must SAY about how the
        # area was arrived at (citywide because the citizen named the city; a
        # street we cannot map to an area). Callers built before them pass
        # three arguments and get nil for both.
        AreaOutcome = Struct.new(:areas, :source, :result, :coverage, :warnings) do
          def slugs = areas.map(&:slug)

          def scope_coverage = coverage || {}

          def scope_warnings = Array(warnings)
        end

        def time_window(entities, now, announcement: false)
          requested_at, warning = requested_time(entities, now)
          return [nil, nil, warning] if warning

          part = DAY_PARTS[Decidim::Bih::Text.fold(entities["time_expression"].to_s.strip)]
          return day_part_window(requested_at, part) if part
          return [now, now + forward_window(announcement), nil] unless requested_calendar_day?(entities)

          date = requested_at.in_time_zone("Europe/Sarajevo").to_date
          zone = ActiveSupport::TimeZone["Europe/Sarajevo"]
          next_date = date.next_day
          [zone.local(date.year, date.month, date.day), zone.local(next_date.year, next_date.month, next_date.day), nil]
        end

        # A "now" word asks about the present and keeps the forward window; it
        # is not a request for a calendar day.
        def requested_calendar_day?(entities)
          return true if entities["date"].present?

          expression = Decidim::Bih::Text.fold(entities["time_expression"].to_s.strip)
          expression.present? && CURRENT_EXPRESSIONS.exclude?(expression)
        end

        def forward_window(announcement)
          announcement ? ANNOUNCEMENT_WINDOW : CityServiceEventFeed::CURRENT_WINDOW
        end

        def day_part_window(requested_at, part)
          zone = ActiveSupport::TimeZone["Europe/Sarajevo"]
          date = requested_at.in_time_zone(zone).to_date
          midnight = zone.local(date.year, date.month, date.day)
          [midnight + part.fetch(:from).hours, midnight + part.fetch(:to).hours, nil]
        end

        def requested_time(entities, now)
          raw_expression = entities["time_expression"].to_s.strip
          clock = requested_clock_time(raw_expression, entities["date"], now)
          return [clock, nil] if clock
          return [nil, "unsupported_time_expression"] if raw_expression.match?(/\d/)

          expression = Decidim::Bih::Text.fold(raw_expression)
          relative = RELATIVE_DAYS[expression]
          return [now.in_time_zone("Europe/Sarajevo") + relative.days, nil] if relative
          return [parse_date(entities.fetch("date"), now), nil] if entities["date"].present?
          return [now, nil] if expression.blank? || CURRENT_EXPRESSIONS.include?(expression)

          named = named_day_time(expression, now)
          named ? [named, nil] : [nil, "unsupported_time_expression"]
        rescue ArgumentError
          [nil, "invalid_date"]
        end

        WEEKDAYS = { "ponedjeljak" => 1, "ponedeljak" => 1, "utorak" => 2, "srijeda" => 3, "sredu" => 3,
                     "srijedu" => 3, "cetvrtak" => 4, "petak" => 5, "subota" => 6, "subotu" => 6, "subotom" => 6,
                     "nedjelja" => 0, "nedjelju" => 0, "nedelja" => 0, "nedelju" => 0 }.freeze

        # A named part of a day and a weekday name both resolve to a day. The
        # part narrows the window afterwards, in +day_part_window+.
        def named_day_time(expression, now)
          local = now.in_time_zone("Europe/Sarajevo")
          part = DAY_PARTS[expression]
          return local + part.fetch(:day).days if part

          weekday = WEEKDAYS[expression.delete_prefix("u ")]
          weekday ? local + ((weekday - local.wday) % 7).days : nil
        end

        def requested_clock_time(expression, date_value, now)
          # Exact named noon is a clock, not an unspecified part of the day.
          # Keep the existing service timezone, trusted relative day and DST
          # validation; do not turn "before/after noon" into an exact time.
          noon = Decidim::Bih::Text.fold(expression).match(/\A(?:(?<day>danas|sutra|today|tomorrow) )?(?:(?:u|oko|at|around) )?(?:podne|noon)\z/)
          expression = [noon[:day], "u 12:00"].compact.join(" ") if noon
          clock = expression.match(/\A(?<label>[\p{L}\p{M}\s]*?)(?<hour>\d{1,2})(?::(?<minute>\d{2}))?\s*\z/u)
          return unless clock

          label = Decidim::Bih::Text.fold(clock[:label])
          prefix = label.match(/\A(?:(?<day>danas|sutra|today|tomorrow)(?: (?:u|oko|at|around))?|u|oko|at|around)?\z/)
          return unless prefix

          zone = ActiveSupport::TimeZone["Europe/Sarajevo"]
          date = if prefix[:day]
                   now.in_time_zone(zone).to_date + RELATIVE_DAYS.fetch(prefix[:day])
                 elsif date_value.present?
                   Date.iso8601(date_value.to_s)
                 else
                   now.in_time_zone(zone).to_date
                 end
          hour = clock[:hour].to_i
          minute = clock[:minute].to_i
          raise ArgumentError, "Invalid local clock" unless hour.between?(0, 23) && minute.between?(0, 59)

          # Service timezone is fixed; do not guess through a DST gap or overlap.
          wall_time = Time.utc(date.year, date.month, date.day, hour, minute)
          raise ArgumentError, "Ambiguous local clock" unless zone.tzinfo.periods_for_local(wall_time).length == 1

          zone.local(date.year, date.month, date.day, hour, minute)
        end

        def parse_date(value, now)
          date = Date.iso8601(value.to_s)
          local_now = now.in_time_zone("Europe/Sarajevo")
          ActiveSupport::TimeZone["Europe/Sarajevo"].local(date.year, date.month, date.day, local_now.hour, local_now.min)
        end

        def directory_entry(topic, entities)
          key = DIRECTORY_TOPIC_KEYS[topic]
          return directory.find(key) if key

          query = entities["query"].presence
          query ? directory.search(query, limit: 1).first : nil
        end

        def event_fact(event, locale:, now:, requested_area_slugs: [])
          checked_at = safe_time(event.fetched_at, now)
          coverage, partial, overlap_only = event_coverage(event, requested_area_slugs)
          date_only = event.extraction_metadata["operator_review"].blank? && event.extraction_metadata["temporal_precision"] == "day"
          warnings = event_warnings(event, checked_at, now)
          warnings << "source_time_is_date_only" if date_only
          warnings << "partial_geographic_coverage" if partial
          warnings << "possible_geographic_overlap" if overlap_only
          warnings << "place_name_context_not_service_coverage" if CityServicePlaceContext.places(event).any?
          text = event_evidence_text(event, locale, partial, overlap_only)
          fact = {
            "id" => "service_event:#{event.id}",
            "kind" => "city_service_event",
            "text" => bounded_text(localized_text(text, locale)),
            "source_id" => event.source_key,
            "source_label" => event.source_label_text,
            "source_url" => safe_source_url(event.source_url, event.source_key),
            "checked_at" => time_value(checked_at),
            "source_published_at" => time_value(event.source_published_at),
            "source_updated_at" => time_value(event.source_updated_at),
            "content_version" => event.content_version,
            "lifecycle" => event.lifecycle,
            "starts_at" => date_only ? nil : time_value(event.starts_at),
            "ends_at" => date_only ? nil : time_value(event.ends_at),
            "validity" => { "precision" => event_time_precision(event, date_only), "date" => event_local_date(event) },
            "coverage" => coverage,
            "warning_codes" => warnings
          }
          presentation = EventAnswer.call(event:, locale:, warning_codes: warnings)
          presentation ? fact.merge(presentation) : fact
        end

        def event_time_precision(event, date_only)
          return "unknown" if event.starts_at.nil? || event.ends_at.nil?

          date_only ? "day" : "minute"
        end

        def event_coverage(event, requested_area_slugs)
          extracted = event.extraction_metadata.fetch("coverage", {})
          relations = Array(extracted["affected_places"]).first(20)
          overlap_only = CityServicePlaceContext.overlap_only?(extracted, requested_area_slugs, relations:)
          partial = CityServicePlaceContext.partial_coverage?(extracted, relations:)
          context = CityServicePlaceContext.places(event)
          relation = requested_event_relation(event, requested_area_slugs, relations:, partial:, overlap_only:)
          names = public_area_names(event.area_slugs | relations.map { |item| item["slug"] } | Array(requested_area_slugs))
          coverage = { "area_slugs" => event.area_slugs, "targeting_level" => event.targeting_level,
                       # Slugs stay for machines; the public name travels beside
                       # them so no renderer has to invent one from "mz-dasnica".
                       "affected_areas" => public_area_labels(event.area_slugs),
                       "requested_areas" => public_area_labels(requested_area_slugs),
                       "status" => extracted.fetch("status", "unknown"),
                       "affected_relations" => relations.map { |item| item.slice("slug", "kind", "relation").merge("name" => names[item["slug"]]).compact },
                       # A place the notice named but we could not map, and a
                       # name that matched two places, are evidence. Dropping
                       # them here is what turns "somewhere we could not place"
                       # into "nowhere", so they travel with the answer.
                       "unresolved_places" => Array(extracted["unresolved_places"]).first(10).presence,
                       "ambiguous_places" => Array(extracted["ambiguous_places"]).first(10).presence,
                       "contextual_places" => context,
                       "requested_relation" => relation }.compact
          [coverage, partial, overlap_only]
        end

        # Both helpers degrade to slug-only rather than raising: an injected
        # test double or a future matcher without the lookup must not be able
        # to take a citizen answer down, and a missing name is honest.
        def public_area_labels(slugs)
          return area_matcher.public_places(slugs) if area_matcher.respond_to?(:public_places)

          Array(slugs).map { |slug| { "slug" => slug.to_s } }
        rescue StandardError
          Array(slugs).map { |slug| { "slug" => slug.to_s } }
        end

        def public_area_names(slugs)
          return {} unless area_matcher.respond_to?(:display_names)

          area_matcher.display_names(slugs)
        rescue StandardError
          {}
        end

        def public_area_label_names(slugs)
          names = public_area_names(slugs)
          Array(slugs).map { |slug| names[slug.to_s] }.compact
        end

        def requested_event_relation(event, requested_slugs, relations:, partial:, overlap_only:)
          relation = partial ? "part" : "whole"
          relation = "possible_overlap" if overlap_only
          relation = "unknown" if unconfirmed_requested_area?(event, requested_slugs, relations)
          confirmed_slugs = event.area_slugs | relations.map { |place| place["slug"] }
          context = CityServicePlaceContext.places(event)
          relation = "context_only" if !requested_slugs.intersect?(confirmed_slugs) && requested_slugs.intersect?(context.map { |place| place["slug"] })
          relation
        end

        def unconfirmed_requested_area?(event, requested_slugs, relations)
          event.targeting_level == "unknown" && !requested_slugs.intersect?(relations.map { |item| item["slug"] })
        end

        def unconfirmed_event_warnings(event)
          warnings = []
          warnings << "source_facts_unconfirmed" unless event.facts_confirmed?
          warnings << "geographic_scope_unconfirmed" if event.targeting_level == "unknown"
          warnings << "event_time_unconfirmed" if event.starts_at.nil? || event.ends_at.nil?
          warnings
        end

        def event_warnings(event, checked_at, now)
          warnings = []
          warnings.concat(unconfirmed_event_warnings(event))
          warnings << "operator_reviewed_correction" if event.extraction_metadata["operator_review"].present?
          warnings << "check_time_unavailable" unless checked_at
          warnings << "planned_end_not_confirmed_restoration" if event.ends_at && event.ends_at <= now && event.lifecycle != "resolved"
          warnings
        end

        def event_evidence_text(event, locale, partial, overlap_only)
          text = [event.title, event.summary].compact_blank.join(": ")
          text = "#{I18n.t("decidim_app.city_service_events.bot.unconfirmed_facts", locale:)} #{text}" unless event.facts_confirmed?
          text += " #{I18n.t("decidim_app.city_service_events.bot.unconfirmed_area", locale:)}" if event.targeting_level == "unknown"
          text += " #{I18n.t("decidim_app.city_service_events.bot.unconfirmed_time", locale:)}" if event.starts_at.nil? || event.ends_at.nil?
          text += " #{I18n.t("decidim_app.city_service_events.bot.partial_coverage", locale:)}" if partial
          text += " #{I18n.t("decidim_app.city_service_events.bot.possible_overlap", locale:)}" if overlap_only
          text += " #{CityServicePlaceContext.notice(event, locale:)}" if CityServicePlaceContext.places(event).any?
          text
        end

        def event_local_date(event)
          return unless event.starts_at

          event.starts_at.in_time_zone("Europe/Sarajevo").to_date.iso8601
        end

        def transport_leg_fact(leg, query, index, check, locale, now, prefix: nil, suffix: nil) # rubocop:disable Metrics/ParameterLists
          calendar = leg.respond_to?(:calendar) ? leg.calendar : nil
          source_url = calendar&.fetch("source_url", nil) || query.sources.find { |url| url.to_s.match?(/#{Regexp.escape(leg.route_code.to_s)}/i) } || query.sources.first
          checked_at = safe_time(check.checked_at, now)
          departure = leg.departure_at.in_time_zone("Europe/Sarajevo").strftime("%Y-%m-%d %H:%M")
          arrival = leg.arrival_at.in_time_zone("Europe/Sarajevo").strftime("%Y-%m-%d %H:%M")
          text = [prefix, "#{leg.route_code} (smjer #{leg.direction_label}): #{leg.origin_label} #{departure} → #{leg.destination_label} #{arrival}", suffix].compact.join(" ")
          {
            "id" => "transport_leg:#{index}:#{leg.route_code}:#{leg.departure_at.to_i}",
            "kind" => "transport_leg",
            "text" => bounded_text(localized_text(text, locale)),
            "source_id" => source_id(source_url),
            "source_label" => leg.route_title,
            "source_url" => source_url,
            "checked_at" => time_value(checked_at),
            "starts_at" => time_value(leg.departure_at),
            "ends_at" => time_value(leg.arrival_at),
            "coverage" => { "origin" => leg.origin_label, "destination" => leg.destination_label, "direction" => leg.direction_label },
            "calendar" => leg.respond_to?(:calendar) ? leg.calendar : nil,
            "warning_codes" => query.warnings + (checked_at ? [] : ["check_time_unavailable"])
          }
        end

        def area_fact(area, resolution_source, locale:)
          {
            "id" => "area:#{area.kind}:#{area.slug}",
            "kind" => "local_area",
            "text" => localized_area_name(area, locale),
            "source_id" => "local_area:#{area.id}",
            "source_label" => "Reviewed Bijeljina area registry",
            "area_slug" => area.slug,
            "area_kind" => area.kind,
            "coverage" => { "organization_id" => organization.id, "resolution_source" => resolution_source.to_s },
            "warning_codes" => ["area_selection_grants_no_membership"]
          }
        end

        def board_fact(post, area, locale:)
          category = I18n.t("decidim.bih.komsiluk_board.categories.#{post.category}", locale:, default: post.category)
          text = [category, ActionController::Base.helpers.strip_tags(post.title.to_s), post.sanitized_body].compact_blank.join(": ")
          {
            "id" => "komsiluk_post:#{post.id}",
            "kind" => "neighborhood_post",
            "text" => bounded_text(text),
            "source_id" => "komsiluk_post:#{post.id}",
            "source_label" => "Komšiluk board",
            "area_slug" => area.slug,
            "area_kind" => "komsiluk",
            "category" => post.category,
            "status" => post.status,
            "observed_at" => time_value(post.created_at),
            "valid_until" => time_value(post.expires_at),
            "destination" => Decidim::Bih::Engine.routes.url_helpers.komsiluk_board_path(post, script_name: Decidim::Bih.normalized_public_mount_path),
            "warning_codes" => []
          }
        end

        def report_status_fact(report, locale:)
          label = Decidim::Bih::ReportStatusPresenter.label(report, locale:)
          {
            "id" => "report:#{report.reference}:status",
            "kind" => "own_report_status",
            "text" => localized_text("Prijava #{report.reference}: #{label}", locale),
            "source_id" => "report:#{report.reference}",
            "source_label" => "MI report record",
            "reference" => report.reference,
            "status" => Decidim::Bih::ReportStatusPresenter.status_key(report),
            "observed_at" => time_value(report.updated_at),
            "destination" => Decidim::Bih::Engine.routes.url_helpers.report_path(reference: report.reference),
            "warning_codes" => []
          }
        end

        def duplicate_fact(report, locale:)
          label = Decidim::Bih::ReportStatusPresenter.label(report, locale:)
          {
            "id" => "public_report:#{report.reference}",
            "kind" => "nearby_public_report",
            "text" => localized_text("Moguća slična prijava #{report.reference}: #{label}", locale),
            "source_id" => "report:#{report.reference}",
            "source_label" => "MI public report",
            "reference" => report.reference,
            "status" => Decidim::Bih::ReportStatusPresenter.status_key(report),
            "category" => report.category,
            "observed_at" => time_value(report.created_at),
            "destination" => Decidim::Bih::Engine.routes.url_helpers.report_path(reference: report.reference),
            "warning_codes" => ["possible_match_not_confirmed_duplicate"]
          }
        end

        def validate_context!(context)
          raise contracts::Invalid, "Trusted context required" unless context.is_a?(contracts::TrustedContext)
          raise contracts::Invalid, "Organization scope mismatch" unless context.organization_id == organization.id

          actor_for!(context) if context.actor_id
        end

        def actor_for!(context)
          return nil unless context.actor_id

          actor = read_query(context.deadline) do
            Decidim::User.find_by(id: context.actor_id, organization:)
          end
          raise contracts::Invalid, "Actor scope mismatch" unless actor

          actor
        end

        def normalize_entities(entities)
          raise contracts::Invalid, "Entities must be a hash" unless entities.is_a?(Hash)

          normalized = entities.transform_keys(&:to_s)
          raise contracts::Invalid, "Duplicate entity keys" unless normalized.size == entities.size
          raise contracts::Invalid, "Unsupported entity" if (normalized.keys - contracts::ENTITY_KEYS).any?

          normalized.to_h do |key, value|
            [key, contracts.text!(value.to_s, limit: %w(query description).include?(key) ? 1_000 : 160)]
          end
        end

        def normalize_location(location)
          return nil if location.nil?
          raise contracts::Invalid, "Location must be a hash" unless location.is_a?(Hash)

          value = location.transform_keys(&:to_s)
          required = %w(latitude longitude accuracy purpose consent provenance)
          raise contracts::Invalid, "Incomplete current-turn location" unless (required - value.keys).empty?
          raise contracts::Invalid, "Location consent required" unless value["consent"] == true

          {
            "latitude" => finite_number(value["latitude"], -90, 90),
            "longitude" => finite_number(value["longitude"], -180, 180),
            "accuracy" => location_accuracy(value["accuracy"]),
            "purpose" => location_label(value["purpose"], LOCATION_PURPOSES, "purpose"),
            "consent" => true,
            "provenance" => location_label(value["provenance"], LOCATION_PROVENANCES, "provenance")
          }
        end

        def self_referential_area_query?(value)
          folded = Decidim::Bih::Text.fold(Decidim::Bih::Transliterator.to_latin(value.to_s))
          folded.match?(/\A(?:(?:u|na|za)\s+)?(?:(?:mom|mojem|mojoj|moj|moja|my|our)\s+)?(?:komsiluk\w*|naselj\w*|lokacij\w*|blizin\w*|ovdje|here)\z/)
        end

        def location_accuracy(value)
          value.nil? ? nil : finite_number(value, 0, MAX_LOCATION_ACCURACY_METERS)
        end

        def location_label(value, allowed, name)
          label = contracts.text!(value.to_s, limit: 80)
          raise contracts::Invalid, "Location #{name} required" if label.empty?
          raise contracts::Invalid, "Unsupported location #{name}" unless allowed.include?(label)

          label
        end

        def finite_number(value, minimum, maximum)
          number = Float(value)
          raise contracts::Invalid, "Invalid location number" unless number.finite? && number.between?(minimum, maximum)

          number
        rescue ArgumentError, TypeError
          raise contracts::Invalid, "Invalid location number"
        end

        def within_deadline(deadline, &)
          CityServiceNoticeCollector.send(:within_deadline, deadline, &)
        end

        # Select the most specific supplied place. A citywide area must not
        # mask an explicit street, while a natural-language question is not a
        # place unless the reviewed schedule can resolve it as one.
        def waste_schedule_query(entities)
          named = %w(address street).filter_map { |key| entities[key].to_s.strip.presence }
          query = entities["query"].to_s.strip
          specific = named.first
          specific = resolved_waste_schedule_place(specific, query)

          area = entities["area_query"].to_s.strip.presence
          return "#{specific}, #{area}" if specific.present? && area.present? && Decidim::Bih::Text.fold(specific).exclude?(Decidim::Bih::Text.fold(area))

          specific || area || query.presence
        end

        def resolved_waste_schedule_place(specific, query)
          if specific.blank? && query.present? && waste_schedule.respond_to?(:resolution_for)
            resolution = waste_schedule.resolution_for(query)
            specific = query if resolution[:status] == :ok || Array(resolution[:candidates]).any?
          end
          specific
        end

        # The place names AS THE SCHEDULE SPELLS THEM, used to label the answer
        # instead of echoing the query. The query is the citizen's (or the
        # model's) typing: echoing it printed "Bijelina, Dvorovi" — a misspelt
        # municipality and a settlement — as though that were the entry read.
        # The reply's own transliteration step puts them in the citizen's script.
        def waste_schedule_places(resolution)
          values = Array(resolution && resolution[:places]) + Array(resolution && resolution[:settlements]).reject do |settlement|
            Decidim::Bih::Text.fold(settlement.to_s) == "bijeljina"
          end
          values.map { |place| place.to_s.strip }.reject(&:empty?).uniq
        end

        def waste_schedule_gap(query)
          return unless waste_schedule.respond_to?(:partial_coverage_gap_for)

          gap = waste_schedule.partial_coverage_gap_for(query)
          gap if gap.is_a?(Hash) && Array(gap[:districts]).any?
        end

        def waste_schedule_capture_date
          value = waste_schedule.source_checked_at if waste_schedule.respond_to?(:source_checked_at)
          value = value.to_date if value.respond_to?(:to_date)
          value if value.is_a?(Date)
        rescue StandardError
          nil
        end

        def waste_schedule_year
          return waste_schedule.data_year.to_i if waste_schedule.respond_to?(:data_year) && waste_schedule.data_year.to_i.positive?

          return DecidimApp::Bijeljina::WasteSchedule::DATA_YEAR if @bundled_waste_schedule

          nil
        end

        def requested_waste_year(entities)
          value = entities["date"].to_s
          return if value.empty?

          Date.iso8601(value).year
        rescue Date::Error
          nil
        end

        def waste_schedule_source
          source = CityServiceSources.fetch("waste_schedule")
          schedule_url = waste_schedule.source_url if waste_schedule.respond_to?(:source_url)
          url = safe_source_url(schedule_url, "waste_schedule") || source.fetch(:source_url)
          {
            "id" => "source:waste_schedule",
            "label" => source.fetch(:label),
            "url" => url
          }
        rescue KeyError
          { "id" => "source:waste_schedule" }
        end

        def read_query(deadline, &)
          seconds = CityServiceNoticeCollector.send(:remaining_seconds, deadline)
          return yield if seconds.nil?
          raise CityServiceNoticeCollector::DeadlineExceeded, "read deadline expired" if seconds <= 0

          connection = ActiveRecord::Base.connection
          milliseconds = [(seconds * 1_000).floor, 1].max
          connection.transaction(requires_new: true) do
            connection.execute("SET LOCAL statement_timeout = #{milliseconds}")
            yield
          end
        end

        def result(status, facts: [], source: nil, checked_at: nil, coverage: nil, validity: nil, candidates: [], warnings: []) # rubocop:disable Metrics/ParameterLists
          contracts::ReadResult.new(
            status:,
            facts: facts.first(MAX_FACTS),
            source:,
            checked_at: checked_at && time_object(checked_at),
            coverage:,
            validity:,
            candidates: candidates.first(MAX_FACTS),
            warnings: Array(warnings).compact_blank.map(&:to_s).uniq
          )
        end

        def source_hash(fact)
          { "id" => fact["source_id"], "label" => fact["source_label"], "url" => fact["source_url"] }.compact
        end

        def source_reference(source_key)
          source = CityServiceSources.fetch(source_key.to_s)
          {
            "id" => "source:#{source.fetch(:key)}",
            "label" => source.fetch(:label),
            "url" => safe_source_url(source.fetch(:source_url), source.fetch(:key))
          }
        rescue KeyError, URI::InvalidURIError
          { "id" => "source:#{source_key}" }
        end

        def approved_source_url?(value, source_key)
          candidate = URI.parse(value.to_s)
          configured = URI.parse(CityServiceSources.fetch(source_key.to_s).fetch(:source_url).to_s)
          approved_origin?(candidate, configured)
        rescue KeyError, URI::InvalidURIError
          false
        end

        def safe_source_url(value, source_key = nil)
          return value.to_s if source_key && approved_source_url?(value, source_key)
          return value.to_s if source_key.nil? && generic_source_host?(value)

          source = source_key && CityServiceSources.fetch(source_key.to_s)
          source ? source.fetch(:source_url).to_s : nil
        rescue KeyError, URI::InvalidURIError
          nil
        end

        def generic_source_host?(value)
          return true if DirectoryServiceFacts.reviewed_source_url?(value)

          candidate = URI.parse(value.to_s)

          CityServiceSources.all.any? do |source|
            configured = URI.parse(source.fetch(:source_url).to_s)
            approved_origin?(candidate, configured)
          end
        rescue URI::InvalidURIError
          false
        end

        def approved_origin?(candidate, configured)
          %w(http https).include?(candidate.scheme) &&
            candidate.scheme == configured.scheme &&
            candidate.host.present? &&
            candidate.userinfo.nil? &&
            same_source_host?(candidate.host, configured.host) &&
            candidate.port == configured.port
        end

        def assigned_area?(area)
          area&.decidim_organization_id == organization.id && area.kind == "komsiluk"
        end

        def same_source_host?(left, right)
          [left, right].all?(&:present?) && [left, right].map { |host| host.to_s.downcase.sub(/\Awww\./, "") }.uniq.one?
        end

        def aggregate_sources(facts)
          facts.map { |fact| source_hash(fact) }.uniq
        end

        # "area_labels" is not decoration. Its absence is what let an internal
        # slug ("mz-dasnica") reach a citizen: the summary renderer falls back
        # to the slug list when no labels are supplied. Names are emitted for
        # every area we can name, and the key is omitted rather than filled
        # with a prettified guess when we cannot.
        def query_coverage(area_slugs, starts_at, ends_at)
          labels = public_area_label_names(area_slugs)
          { "organization_id" => organization.id, "area_slugs" => Array(area_slugs), "area_labels" => labels.presence,
            "starts_at" => time_value(starts_at), "ends_at" => time_value(ends_at) }.compact
        end

        def latest_fact_time(facts, key)
          facts.filter_map { |fact| parse_time_value(fact[key]) }.max
        end

        def safe_time(value, now)
          time = time_object(value)
          time unless time && time > time_object(now)
        rescue StandardError
          nil
        end

        def time_value(value)
          time_object(value)&.iso8601(6)
        rescue StandardError
          nil
        end

        def time_object(value)
          return nil if value.nil?

          value.respond_to?(:to_time) ? value.to_time.utc : Time.iso8601(value.to_s).utc
        end

        def parse_time_value(value)
          value.present? ? Time.iso8601(value.to_s) : nil
        rescue ArgumentError
          nil
        end

        def source_id(url)
          "url:#{Digest::SHA256.hexdigest(url.to_s)[0, 16]}"
        end

        def localized_area_name(area, locale)
          PlaceAliasRegistry.display_name(I18n.with_locale(locale) { area.translated_name })
        end

        def localized_text(text, locale)
          Decidim::Bih::Transliterator.localize(text.to_s, locale:)
        end

        # The canonical collection days rendered for the reply's language. The
        # parser already normalised whatever the programme PDF spelled into
        # WEEK_ORDER's seven Latin tokens, and localized_text transliterates
        # them for sr-Cyrl; TimeText adds the English rendering and leaves
        # every other locale exactly as it was. The day is our vocabulary, not
        # a quotation from the source, so it follows the reply — unlike the
        # notice bodies, which stay in the source's language.
        def day_names(days, locale:)
          Decidim::Bih::Concierge::Dialogue::TimeText.day_names(days, locale:)
        end

        def bounded_text(value)
          value.to_s.squish.first(MAX_TEXT_LENGTH)
        end

        def contract_enum!(value, allowed)
          contracts.enum!(value.to_s, allowed)
        end

        def contracts
          Decidim::Bih::Concierge::Dialogue::Contracts
        end

        def log_failure(error, action)
          if defined?(Rails.logger)
            Rails.logger.warn(
              "[Milica::ReadPort] read failed error_class=#{error.class.name} action=#{action.to_s.first(40)}"
            )
          end
        end
      end
    end
  end
end
