# frozen_string_literal: true

require "date"
require "digest"
require "json"
require "decidim/bih/transliterator"
require_relative "../public_transport_places"
require_relative "../place_alias_registry"

module DecidimApp
  module Bijeljina
    module Milica
      # Shared public read catalog. No runtime router, model,
      # request-local identity, source refresh or sentence parser lives here.
      class TransportTools
        Dialogue = Decidim::Bih::Concierge::Dialogue
        STOP_DOCUMENT = "transport:stop_catalog"
        MAX_CANDIDATES = 20
        Notice = Data.define(:source_key, :url, :title)

        def initialize(organization_id:, registry_epoch:, timetable:, notices:, location: nil, observer: nil)
          raise ArgumentError, "Positive organization required" unless organization_id.is_a?(Integer) && organization_id.positive?
          raise ArgumentError, "Registry epoch required" unless registry_epoch.is_a?(String) && registry_epoch.size.between?(1, 128)
          raise ArgumentError, "Bounded reviewed notices required" unless notices.is_a?(Array) && notices.size <= 80

          @organization_id = organization_id
          @registry_epoch = registry_epoch.dup.freeze
          @timetable = timetable
          @location = location&.deep_dup&.freeze
          @observer = observer
          @notices = notices.map do |notice|
            Notice.new(*[:source_key, :url, :title].map { |field| notice.public_send(field).to_s.dup.freeze })
          end.freeze
        end

        def definitions
          [
            definition("resolve_stops", "Identify stops only: candidates expose selection_key for stop-ID arguments; id is citation only. No departure evidence: resolving stops alone never proves that no bus departs. " \
                                        "For travel between named places use resolve_and_plan_journey, which also returns ambiguity choices. " \
                                        "Set prefer_area only when the citizen explicitly describes the query as an area, settlement, village or neighborhood. " \
                                        "A resolved destination does not supply a missing origin; starts-here journeys use plan_journey_from_current_location.",
                       { "query" => string_schema(200), "prefer_area" => { "type" => "boolean" } }, %w(query), method(:resolve_stops)),
            definition("published_boarding_points", "Read published route membership between named origin and destination only. Both stops must share a source table, forward direction and a nonempty trip column. No date, departure, nearest-stop, walking or accessibility inference. Results are partial candidates, never a guaranteed current service.",
                       { "origin_query" => string_schema(200), "destination_query" => string_schema(200) },
                       %w(origin_query destination_query), method(:published_boarding_points)),
            definition("plan_journey", "Calculate from bound stop IDs/date strictly after local time. Optional route_code restricts all legs to that line. When the reviewed fastest-arrival planner is enabled, it compares reachable boarding points and walking estimates. No live vehicle status.",
                       planning_properties.merge("origin_id" => string_schema(80), "destination_id" => string_schema(80),
                                                 "origin_ids" => { "type" => "array", "items" => string_schema(80), "minItems" => 2, "maxItems" => 4 },
                                                 "destination_ids" => { "type" => "array", "items" => string_schema(80), "minItems" => 2, "maxItems" => 4 }),
                       %w(origin_id destination_id date after_time), method(:plan_journey)),
            definition("resolve_and_plan_journey", "Find departures or connections between named places on a date/time, resolving names in this call. " \
                                                   "Use for journey questions without known stop IDs; supports transfers unless direct_only. " \
                                                   "For a recognized area, disclose its assumed published stop and allow another stop correction. Returns choices for genuinely different places. route_code restricts all legs.",
                       planning_properties.merge("origin_query" => string_schema(200), "destination_query" => string_schema(200)),
                       %w(origin_query destination_query date after_time), method(:resolve_and_plan_journey)),
            definition("plan_exact_route", "Find the first or last reviewed timetable trip for exact printed stops on one named line and direction. " \
                                            "The route, direction, date and both stop names must come from the citizen; ambiguous physical stop identities remain unresolved.",
                       planning_properties.merge("origin_label" => string_schema(120), "destination_label" => string_schema(120),
                                                 "direction" => { "type" => "string", "enum" => %w(A B), "maxLength" => 1 },
                                                 "mode" => { "type" => "string", "enum" => %w(next last), "maxLength" => 4 }),
                       %w(origin_label destination_label route_code direction date after_time mode), method(:plan_exact_route)),
            definition("plan_journey_from_current_location", "Plan from the consented current-turn location using reviewed nearby boarding points in one read when the journey planner is enabled. " \
                                                              "#{current_location_coordinates ? 'VALID CONSENTED CURRENT-TURN LOCATION IS AVAILABLE; no origin name is required.' : 'No consented current-turn location is available; do not infer it from history.'} " \
                                                              "Use only when the citizen starts here; named origins use resolve_and_plan_journey. " \
                                                              "After the citizen selects a destination, call this same tool again with that destination and retained date/time. " \
                                                              "Destination ambiguity does not mean the supplied origin is missing. Walking times are map-derived estimates and accessibility is unverified.",
                       planning_properties.merge("destination_query" => string_schema(200)),
                       %w(destination_query date after_time), method(:plan_journey_from_current_location)),
            definition("service_calendar", "Read published days (school, break, Saturday) and calendar limits for a line. No endpoints needed; not live service confirmation.",
                       { "line" => string_schema(12), "date" => string_schema(10) }, %w(line), method(:service_calendar)),
            definition("inspect_timetable_trip", "Answer a same-bus timetable-cell question by anchoring the named stop/time on the requested line/date. " \
                                                   "This is not a journey search. The anchor time belongs only to its stop; null cells mean no published time there. " \
                                                   "Never infer departure at a blank stop from another stop, another column, or a separate planned journey.",
                       { "line" => string_schema(3), "date" => string_schema(10), "stop_query" => string_schema(200), "at_time" => string_schema(5) },
                       %w(line date stop_query at_time), method(:inspect_timetable_trip)),
            definition("resolve_walking_directions", "Resolve a named stop and return current map evidence in one read. Station-wide maps are approximate, not physical platforms.",
                       { "query" => string_schema(200) }, %w(query), method(:resolve_walking_directions)),
            definition("nearest_stop", "Find a reviewed nearby stop. When a consented location is available, the server binds this read to that location and ignores model-supplied coordinates. Distance is straight-line, not walking distance.",
                       { "latitude" => { "type" => "number", "minimum" => -90, "maximum" => 90 },
                         "longitude" => { "type" => "number", "minimum" => -180, "maximum" => 180 } },
                       current_location_coordinates ? [] : %w(latitude longitude), method(:nearest_stop)),
            definition("walking_directions", "Return a map link to a previously bound reviewed stop ID. No verified walking distance, travel time or safe-path promise.",
                       { "stop_id" => string_schema(80) }, %w(stop_id), method(:walking_directions))
          ]
        end

        def resolve_stops(arguments:, context:)
          trusted!(context)
          catalog = @timetable.prepared_tool_catalog(notices: @notices, deadline: context.deadline)
          scope = { "operation" => "resolve_stops", "source_ids" => source_ids(catalog) }
          return envelope(status: "unavailable", warnings: ["prepared_timetable_unavailable"], query_scope: scope) if catalog.fetch(:routes).empty?

          prefer_area = arguments.fetch("prefer_area", false)
          raise Dialogue::Contracts::Invalid, "prefer_area must be boolean" unless [true, false].include?(prefer_area)

          matches = resolve_named_stop(arguments.fetch("query"), catalog, prefer_area:)
          candidates = matches.first(MAX_CANDIDATES).map do |stop|
            { "id" => stop.fetch("id"), "label" => candidate_label(stop, matches, catalog),
              "document_id" => STOP_DOCUMENT, "revision" => catalog.fetch(:revision) }
          end
          assumption = matches.one? ? matches.first["assumption"] : nil
          evidence = assumption ? [area_default_record(assumption, matches.first, catalog)] : []
          warnings = ["partial_reviewed_transport_network"]
          warnings << "assumed_area_stop" if matches.any? { |stop| stop["assumption"] }
          warnings << "transport_candidates_truncated" if matches.size > MAX_CANDIDATES
          warnings << "stop_not_in_reviewed_snapshot" if candidates.empty?
          status = if candidates.empty?
                     "unsupported"
                   else
                     candidates.one? ? "ok" : "ambiguous"
                   end
          envelope(status: status, evidence:, candidates:, warnings:, query_scope: scope)
        end

        def published_boarding_points(arguments:, context:)
          trusted!(context)
          catalog = @timetable.prepared_tool_catalog(notices: @notices, deadline: context.deadline)
          scope = { "operation" => "published_boarding_points", "source_ids" => source_ids(catalog) }
          if catalog.fetch(:routes).empty?
            return envelope(status: "unavailable", warnings: ["prepared_timetable_unavailable"], query_scope: scope)
          end
          matches = { "origin" => published_boarding_matches(arguments.fetch("origin_query"), catalog),
                      "destination" => published_boarding_matches(arguments.fetch("destination_query"), catalog) }
          if matches.values.flatten.any? { |row| row["ambiguous_place"] }
            return envelope(status: "ambiguous", candidates: unresolved_candidates(matches, catalog).first(MAX_CANDIDATES),
              warnings: ["published_boarding_places_ambiguous", "partial_reviewed_transport_network"], query_scope: scope)
          end
          if matches.values.any?(&:empty?) || matches.values.any? { |rows| rows.size > MAX_CANDIDATES }
            return envelope(status: matches.values.any?(&:empty?) ? "unsupported" : "ambiguous",
              candidates: unresolved_candidates(matches, catalog).first(MAX_CANDIDATES),
              warnings: ["published_boarding_endpoints_unresolved", "partial_reviewed_transport_network"], query_scope: scope)
          end
          ids = matches.transform_values do |rows|
            rows.flat_map do |row|
              selected = Array(row["stop_ids"] || row.fetch("id"))
              selected.flat_map { |id| @timetable.prepared_physical_stop_ids(id:, catalog:) }
            end.uniq
          end
          if (ids.fetch("origin") & ids.fetch("destination")).any?
            return envelope(status: "ambiguous", candidates: unresolved_candidates(matches, catalog).first(MAX_CANDIDATES),
              warnings: ["published_boarding_endpoints_overlap"], query_scope: scope)
          end
          records = []
          catch(:published_boarding_limit) do
            catalog.fetch(:routes).each do |route|
              source = catalog.fetch(:sources).find { |entry| entry.fetch("source_url") == route.source_url }
              raise Dialogue::Contracts::Invalid, "Published route source missing" unless source

              route.directions.each do |direction|
                direction.stops.each_with_index do |origin, origin_index|
                  trusted!(context)
                  next unless ids.fetch("origin").include?(@timetable.prepared_stop_id(origin))

                  direction.stops.each_with_index do |destination, destination_index|
                    next unless destination_index > origin_index && ids.fetch("destination").include?(@timetable.prepared_stop_id(destination))

                    column = origin.times.zip(destination.times).index { |from, to| from && to }
                    next if column.nil?

                    records << published_boarding_record(route:, direction:, origin:, destination:,
                      origin_index:, destination_index:, column:, source:)
                    throw :published_boarding_limit if records.size > 8
                  end
                end
              end
            end
          end
          trusted!(context)
          current = @timetable.prepared_tool_catalog(notices: @notices, deadline: context.deadline)
          if current.fetch(:routes).empty? || current.fetch(:revision) != catalog.fetch(:revision) || current.fetch(:sources) != catalog.fetch(:sources)
            return envelope(status: "unavailable", warnings: ["prepared_timetable_changed_during_search"], query_scope: scope)
          end
          warnings = %w(partial_reviewed_transport_network published_membership_not_departure service_date_not_selected walking_path_not_verified boarding_side_not_verified)
          warnings << "published_boarding_records_truncated" if records.size > 8
          warnings << "configured_area_stop_assumption" if matches.values.flatten.any? { |row| row["assumption"] }
          warnings << "no_shared_trip_column_in_reviewed_scope" if records.empty?
          envelope(status: records.empty? ? "unsupported" : "ok", evidence: records.first(8), warnings:, query_scope: scope)
        end

        def plan_journey(arguments:, context:)
          trusted!(context)
          arguments = canonical_transport_arguments(arguments)
          requested_at = requested_time(arguments)
          catalog = @timetable.prepared_tool_catalog(notices: @notices, deadline: context.deadline)
          if catalog.fetch(:routes).any?
            validate_same_label_set!(arguments, catalog, role: "origin") if arguments.key?("origin_ids")
            validate_same_label_set!(arguments, catalog, role: "destination") if arguments.key?("destination_ids")
          end
          planned_envelope(arguments, context, catalog, requested_at)
        end

        def validate_same_label_set!(arguments, catalog, role:)
          ids = arguments.fetch("#{role}_ids")
          error = "invalid_transport_#{role}_set"
          raise Dialogue::Contracts::Invalid, error unless journey_planner_enabled? &&
            ids.is_a?(Array) && ids.length.between?(2, 4) && ids.uniq == ids && ids.first == arguments.fetch("#{role}_id")

          labels = catalog.fetch(:rows).filter_map do |row|
            row.label if ids.include?(@timetable.prepared_stop_id(row))
          end.uniq
          resolved_ids = catalog.fetch(:rows).filter_map { |row| @timetable.prepared_stop_id(row) if labels.include?(row.label) }.uniq
          raise Dialogue::Contracts::Invalid, error unless labels.one? && (ids - resolved_ids).empty?
        end

        # One read round can answer uniquely resolved names using exactly the
        # same resolver/calculator as the two-step path. Genuine ambiguity is
        # retained even when only one of the candidate pairs has a journey.
        def resolve_and_plan_journey(arguments:, context:)
          trusted!(context)
          arguments = canonical_transport_arguments(arguments)
          requested_at = requested_time(arguments)
          catalog = @timetable.prepared_tool_catalog(notices: @notices, deadline: context.deadline)
          matches = %w(origin destination).index_with do |role|
            resolve_named_stop(arguments.fetch("#{role}_query"), catalog, route_code: arguments["route_code"])
          end
          return unresolved_endpoints(matches, catalog, arguments) unless matches.values.all?(&:one?)

          bound = arguments.except("origin_query", "destination_query").merge(
            "origin_id" => matches.fetch("origin").first.fetch("id"), "destination_id" => matches.fetch("destination").first.fetch("id")
          )
          # NAS resolves through a place ID to bind all published boarding
          # sides. An explicitly named station is still a fixed origin, not a
          # neighborhood from which to walk to a different stop.
          bound["pin_origin_stop"] = true if explicit_nas_origin?(arguments.fetch("origin_query"))
          planned_envelope(bound, context, catalog, requested_at)
        end

        def plan_exact_route(arguments:, context:)
          trusted!(context)
          arguments = canonical_transport_arguments(arguments)
          raise Dialogue::Contracts::Invalid, "Exact route direction required" unless %w(A B).include?(arguments["direction"])
          raise Dialogue::Contracts::Invalid, "Exact departure objective required" unless %w(next last).include?(arguments["mode"])
          requested_at = requested_time(arguments)
          catalog = @timetable.prepared_tool_catalog(notices: @notices, deadline: context.deadline)
          return envelope(status: "unavailable", warnings: ["prepared_timetable_unavailable"],
                          query_scope: { "operation" => "plan_exact_route", "source_ids" => source_ids(catalog), "date" => arguments.fetch("date") }) if catalog.fetch(:routes).empty?

          route = catalog.fetch(:routes).find { |entry| entry.code == arguments.fetch("route_code") }
          direction = route&.directions&.find { |entry| entry.name == arguments.fetch("direction") }
          unless direction
            return envelope(status: "unsupported", warnings: %w(route_direction_not_in_reviewed_snapshot partial_reviewed_transport_network),
                            query_scope: { "operation" => "plan_exact_route", "source_ids" => source_ids(catalog), "date" => arguments.fetch("date") })
          end

          matches = { "origin" => exact_direction_stops(direction, arguments.fetch("origin_label")),
                      "destination" => exact_direction_stops(direction, arguments.fetch("destination_label")) }
          return unresolved_endpoints(matches, catalog, arguments) unless matches.values.all?(&:one?)

          bound = arguments.except("origin_label", "destination_label").merge(
            "origin_id" => matches.fetch("origin").first.fetch("id"),
            "destination_id" => matches.fetch("destination").first.fetch("id"),
            "direct_only" => true, "options" => 1
          )
          planned_envelope(bound, context, catalog, requested_at, force_planner: true)
        end

        def plan_journey_from_current_location(arguments:, context:)
          trusted!(context)
          arguments = canonical_transport_arguments(arguments)
          requested_at = requested_time(arguments)
          scope = navigation_scope("plan_journey_from_current_location").merge("date" => arguments.fetch("date"))
          coordinates = current_location_coordinates
          return envelope(status: "ambiguous", warnings: ["current_turn_location_required"], query_scope: scope) unless coordinates

          catalog = @timetable.prepared_tool_catalog(notices: @notices, deadline: context.deadline)
          return envelope(status: "unavailable", warnings: ["prepared_timetable_unavailable"], query_scope: scope) if catalog.fetch(:routes).empty?

          if journey_planner_enabled?
            destinations = resolve_named_stop(arguments.fetch("destination_query"), catalog, route_code: arguments["route_code"])
            return unresolved_endpoints({ "destination" => destinations }, catalog, arguments, origin_location: coordinates) unless destinations.one?

            bound = arguments.except("destination_query").merge("destination_id" => destinations.first.fetch("id"))
            return planned_envelope(bound, context, catalog, requested_at, origin_location: coordinates)
          end

          nearest = @timetable.nearest_stop(location: coordinates, deadline: context.deadline)
          unless nearest.status == :ok && nearest.boarding_stop
            return envelope(status: "unsupported", warnings: nearest.warnings + ["partial_reviewed_transport_network"], query_scope: scope)
          end

          matches = { "origin" => @timetable.resolve_prepared_stops(query: nearest.origin, catalog:),
                      "destination" => resolve_named_stop(arguments.fetch("destination_query"), catalog) }
          result = if matches.values.all?(&:one?)
                     bound = arguments.except("destination_query").merge("origin_id" => matches.fetch("origin").first.fetch("id"),
                                                                        "destination_id" => matches.fetch("destination").first.fetch("id"))
                     planned_envelope(bound, context, catalog, requested_at)
                   else
                     unresolved_endpoints(matches, catalog, arguments)
                   end
          stop = nearest.boarding_stop
          candidate = Array(nearest.candidates).find { |item| item.fetch("id") == stop.fetch("id") }
          navigation = navigation_record(stop, catalog, label: nearest.origin,
                                         extra_facts: { "distance_meters" => candidate&.dig("coverage", "distance_meters"),
                                                        "distance_kind" => "straight_line", "origin_selection" => "nearest_reviewed_stop_only",
                                                        "nearby_alternative_stops_checked" => false, "walking_time_included" => false })
          warnings = (result.warnings + navigation.fetch("limitations") + %w(current_turn_location_available origin_from_current_location nearest_stop_only_not_all_nearby_stops walking_arrival_time_unverified)).uniq
          # A disambiguation/unsupported envelope cannot assert successful
          # evidence. Keep its candidate choices and scope; attach navigation
          # only when the combined read has usable journey/calendar evidence.
          evidence = %w(ok conflicting).include?(result.status) ? [navigation] + result.evidence : []
          envelope(status: result.status, evidence:, candidates: result.candidates, warnings:,
                   query_scope: result.query_scope.merge("operation" => "plan_journey_from_current_location"))
        end

        def service_calendar(arguments:, context:)
          trusted!(context)
          catalog = @timetable.prepared_tool_catalog(notices: @notices, deadline: context.deadline)
          line = canonical_route_code!(arguments.fetch("line"), allow_unknown: true)
          routes = catalog.fetch(:routes).select { |route| route.code == line }
          sources = catalog.fetch(:sources).select { |source| source.fetch("route_code") == line }
          scope = { "operation" => "service_calendar", "subject_ids" => [line], "source_ids" => sources.map { |source| source.fetch("document_id") } }
          return envelope(status: "unavailable", warnings: ["prepared_timetable_unavailable"], query_scope: scope) if catalog.fetch(:routes).empty?
          return envelope(status: "unsupported", warnings: %w(line_not_in_reviewed_snapshot partial_reviewed_transport_network), query_scope: scope) if routes.empty?

          limitations = %w(published_calendar_not_date_specific_confirmation holiday_exceptions_unverified timetable_not_live_vehicle_status partial_reviewed_transport_network)
          evidence = routes.map { |route| calendar_record(route, sources, limitations, date: arguments["date"]) }
          envelope(status: "ok", evidence: evidence, warnings: limitations, query_scope: scope)
        end

        def nearest_stop(arguments:, context:)
          trusted!(context)
          catalog = @timetable.prepared_tool_catalog(notices: @notices, deadline: context.deadline)
          scope = navigation_scope("nearest_stop")
          return envelope(status: "unavailable", warnings: ["prepared_timetable_unavailable"], query_scope: scope) if catalog.fetch(:routes).empty?

          # The provider must not choose another point when the host has a
          # consented current or retained location for this conversation.
          coordinates = current_location_coordinates || arguments.slice("latitude", "longitude")
          result = @timetable.nearest_stop(location: coordinates, deadline: context.deadline)
          unless result.status == :ok && result.boarding_stop
            return envelope(status: "unsupported", warnings: result.warnings + ["partial_reviewed_transport_network"], query_scope: scope)
          end

          stop = result.boarding_stop
          candidate = Array(result.candidates).find { |item| item.fetch("id") == stop.fetch("id") }
          # The timetable reader has already measured and bounded these map
          # points. Reuse its small candidate set; do not issue one read per stop.
          nearby = Array(result.candidates).filter_map do |item|
            distance = item.dig("coverage", "distance_meters")
            next if item["id"] == stop.fetch("id") || !distance.is_a?(Numeric) || !distance.finite? || !distance.between?(0, 200)

            { "stop_label" => item.fetch("text"), "distance_meters" => distance }
          end.first(4)
          facts = { "distance_meters" => candidate&.dig("coverage", "distance_meters"), "distance_kind" => "straight_line",
                    "nearby_radius_meters" => 200, "nearby_alternatives" => nearby }
          record = navigation_record(stop, catalog, label: result.origin, extra_facts: facts)
          envelope(status: "ok", evidence: [record], warnings: record.fetch("limitations"), query_scope: scope)
        end

        def walking_directions(arguments:, context:)
          trusted!(context)
          catalog = @timetable.prepared_tool_catalog(notices: @notices, deadline: context.deadline)
          scope = navigation_scope("walking_directions").merge("subject_ids" => [arguments.fetch("stop_id")])
          return envelope(status: "unavailable", warnings: ["prepared_timetable_unavailable"], query_scope: scope) if catalog.fetch(:routes).empty?

          stop = @timetable.walking_directions(stop_id: arguments.fetch("stop_id"), deadline: context.deadline)
          return envelope(status: "unsupported", warnings: ["reviewed_stop_not_found"], query_scope: scope) unless stop

          record = navigation_record(stop, catalog, label: stop.fetch("text"))
          envelope(status: "ok", evidence: [record], warnings: record.fetch("limitations"), query_scope: scope)
        end

        def resolve_walking_directions(arguments:, context:)
          trusted!(context)
          catalog = @timetable.prepared_tool_catalog(notices: @notices, deadline: context.deadline)
          matches = @timetable.resolve_prepared_stops(query: arguments.fetch("query"), catalog:)
          return resolve_stops(arguments:, context:) unless matches.one?

          stop = matches.first
          return station_map_envelope(stop, catalog) if stop.fetch("id").start_with?("transport_station:")

          walking_directions(arguments: { "stop_id" => stop.fetch("id") }, context:)
        end

        def inspect_timetable_trip(arguments:, context:) # rubocop:disable Metrics/CyclomaticComplexity -- explicit source/ambiguity boundaries
          trusted!(context)
          at = requested_time({ "date" => arguments.fetch("date"), "after_time" => arguments.fetch("at_time") })
          catalog = @timetable.prepared_tool_catalog(notices: @notices, deadline: context.deadline)
          line = canonical_route_code!(arguments.fetch("line"), allow_unknown: true)
          routes = catalog.fetch(:routes).select { |route| route.code == line }
          scope = { "operation" => "inspect_timetable_trip", "subject_ids" => [line], "date" => arguments.fetch("date"), "source_ids" => source_ids(catalog) }
          return envelope(status: "unavailable", warnings: ["prepared_timetable_unavailable"], query_scope: scope) if catalog.fetch(:routes).empty?

          rows = routes.flat_map { |route| route.directions.flat_map(&:stops) }
          matched = @timetable.resolve_prepared_stops(query: arguments.fetch("stop_query"), catalog: catalog.merge(rows:))
          unless matched.one?
            warnings = [matched.empty? ? "stop_not_in_reviewed_line" : "transport_stop_ambiguous"]
            candidates = matched.first(MAX_CANDIDATES).map { |row| row.merge("document_id" => STOP_DOCUMENT, "revision" => catalog.fetch(:revision)) }
            return envelope(status: matched.empty? ? "unsupported" : "ambiguous", candidates:, warnings:, query_scope: scope)
          end

          evidence = trip_records(routes, matched.first, catalog, at, arguments.fetch("at_time"))
          return envelope(status: "unsupported", warnings: %w(no_matching_reviewed_trip_cell partial_reviewed_transport_network), query_scope: scope) if evidence.empty?

          envelope(status: "ok", evidence:, warnings: %w(blank_cell_not_interpolated same_trip_column_only partial_reviewed_transport_network), query_scope: scope)
        end

        private

        def exact_direction_stops(direction, label)
          requested = normalized_stop_label(label)
          direction.stops.filter_map do |row|
            { "id" => @timetable.prepared_stop_id(row), "label" => row.label } if normalized_stop_label(row.label) == requested
          end.uniq { |stop| stop.fetch("id") }
        end

        def normalized_stop_label(value)
          Decidim::Bih::Text.fold(value)
        end

        def current_location_coordinates
          return unless @location.is_a?(Hash)

          location = @location.stringify_keys
          return unless location["consent"] == true && location["purpose"] == "current_location"
          return unless %w(browser_geolocation legacy_explicit_location retained_consent).include?(location["provenance"])

          latitude, longitude = location.values_at("latitude", "longitude")
          return unless [latitude, longitude].all? { |value| value.is_a?(Numeric) && value.finite? }
          return unless latitude.between?(-90, 90) && longitude.between?(-180, 180)

          { latitude:, longitude: }
        end

        def calendar_date_facts(date)
          parsed = Date.iso8601(date)
          raise ArgumentError unless parsed.iso8601 == date

          manifest = ReviewedTransportTimetables.manifest
          calendar = manifest.fetch("calendar")
          kind = ReviewedTransportTimetables.calendar_kind(ActiveSupport::TimeZone[PublicTransportTimetable::SERVICE_TIME_ZONE].local(parsed.year, parsed.month, parsed.day, 12))
          reason = if date < manifest.fetch("effective_from") || date > calendar.fetch("reviewed_until")
                     "outside_reviewed_calendar_range"
                   elsif calendar.fetch("unsupported_dates").include?(date)
                     "holiday_or_exception_not_reviewed"
                   elsif parsed.sunday?
                     "sunday_timetable_not_published"
                   elsif kind == "unreviewed"
                     "service_date_not_reviewed"
                   else
                     "reviewed_calendar_kind"
                   end
          { "requested_service_date" => date, "calendar_kind" => kind, "calendar_date_status" => reason }
        rescue ArgumentError
          raise Dialogue::Contracts::Invalid, "Explicit valid service date required"
        end

        def station_map_envelope(stop, catalog)
          sources = catalog.fetch(:sources)
          facts = { "station_id" => stop.fetch("id"), "station_label" => stop.fetch("label"),
                    "map_scope" => "logical_station_not_platform", "coordinates_surveyed" => false,
                    "physical_platform_assignment_verified" => false, "coordinate_accuracy" => "approximate_map_derived" }
          manifest = ReviewedTransportTimetables.manifest
          codes = catalog.fetch(:routes).map(&:code)
          available = manifest.fetch("routes").select { |route| codes.include?(route.fetch("code")) }
          facts["source_maps"] = available.filter_map { |route| route.dig("map", "url") }.uniq
          record = { "id" => "transport-station-map:#{Digest::SHA256.hexdigest(JSON.generate([catalog.fetch(:revision), facts]))}",
                     "document_id" => STOP_DOCUMENT, "revision" => catalog.fetch(:revision), "text" => "Reviewed logical station map coverage; no surveyed platform assignment.",
                     "facts" => facts, "observed_at" => sources.map { |source| source.fetch("observed_at") }.min,
                     "review_expires_at" => sources.map { |source| source.fetch("review_expires_at") }.min,
                     "limitations" => %w(approximate_map_not_surveyed platform_assignment_not_reviewed) }
          envelope(status: "ok", evidence: [record], warnings: record.fetch("limitations"), query_scope: navigation_scope("resolve_walking_directions"))
        end

        def trip_records(routes, selected, catalog, at, at_time) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity -- preserve same-column source traversal
          kind = ReviewedTransportTimetables.calendar_kind(at)
          routes.flat_map do |route|
            route.directions.flat_map do |direction|
              next [] unless direction.calendar.fetch("kind") == kind

              anchors = direction.stops.select { |row| row.label == selected.fetch("label") }
              indexes = anchors.flat_map { |row| row.times.each_index.select { |index| row.times[index].to_s.rjust(5, "0") == at_time } }.uniq
              indexes.filter_map do |index|
                next unless ReviewedTransportTimetables.trip_available?(direction.calendar, index, at)

                source = catalog.fetch(:sources).find { |row| row.fetch("source_url") == route.source_url }
                cells = direction.stops.map do |row|
                  value = row.times[index]
                  { "stop_id" => @timetable.prepared_stop_id(row), "stop_label" => row.label, "time" => value,
                    "time_status" => value.present? ? "published_at_this_stop" : "not_published_at_this_stop" }
                end
                unknown_stops = cells.select { |cell| cell.fetch("time_status") == "not_published_at_this_stop" }.map { |cell| cell.fetch("stop_label") }
                facts = { "evidence_purpose" => "inspect_one_same_trip_column_not_plan_a_journey",
                          "route_code" => route.code, "direction" => direction.name, "service_date" => at.to_date.iso8601,
                          "calendar_kind" => kind, "trip_column_index" => index,
                          "anchor_stop_label" => selected.fetch("label"), "anchor_stop_time" => at_time,
                          "stops_without_published_time" => unknown_stops,
                          "blank_cell_meaning" => "No published boarding or arrival time at that stop for this column; do not infer one.",
                          "cells" => cells }
                source.slice("document_id", "revision", "source_url", "observed_at", "review_expires_at").merge(
                  "id" => "transport-trip:#{Digest::SHA256.hexdigest(JSON.generate([source, facts]))}",
                  "text" => "#{route.code} #{at.to_date.iso8601} direction #{direction.name}, column #{index}: " \
                            "anchor #{selected.fetch("label")} at #{at_time}. " \
                            "No time is published in this column for: #{unknown_stops.any? ? unknown_stops.join('; ') : 'none of the listed stops'}. " \
                            "Other journey results do not fill these blank cells.",
                  "facts" => facts, "limitations" => %w(blank_cell_not_interpolated same_trip_column_only timetable_not_live_vehicle_status)
                )
              end
            end
          end.first(8)
        end

        def navigation_scope(operation)
          { "operation" => operation, "source_ids" => [STOP_DOCUMENT] }
        end

        def navigation_record(stop, catalog, label:, extra_facts: {})
          sources = catalog.fetch(:sources)
          facts = { "stop_id" => stop.fetch("id"), "stop_label" => label, "walking_map_url" => stop.fetch("destination"),
                    "coordinate_accuracy" => stop.fetch("coverage").fetch("coordinate_accuracy") }.merge(extra_facts)
          limitations = (stop.fetch("warning_codes") + %w(straight_line_distance_not_walking_route walking_route_not_verified partial_reviewed_transport_network)).uniq
          { "id" => "transport-navigation:#{Digest::SHA256.hexdigest(JSON.generate([catalog.fetch(:revision), facts]))}",
            "document_id" => STOP_DOCUMENT, "revision" => catalog.fetch(:revision), "source_url" => stop.fetch("source_url"),
            "observed_at" => sources.map { |source| source.fetch("observed_at") }.min,
            "review_expires_at" => sources.map { |source| source.fetch("review_expires_at") }.min,
            "text" => "#{label}: #{stop.fetch("destination")}. Map link only; walking distance, duration and safe path are not verified.",
            "facts" => facts, "limitations" => limitations }
        end

        def area_default_record(assumption, stop, catalog)
          facts = { "kind" => "assumed_area_stop", "place_id" => assumption.fetch("place_id"),
                    "selected_stop" => assumption.fetch("selected_stop"), "stop_id" => stop.fetch("id"),
                    "alternative_stops" => assumption.fetch("alternative_stops") }
          { "id" => "transport-area-default:#{Digest::SHA256.hexdigest(JSON.generate([catalog.fetch(:revision), facts]))}",
            "document_id" => STOP_DOCUMENT, "revision" => catalog.fetch(:revision),
            "text" => "Reviewed area default: #{facts.fetch('selected_stop')}.", "facts" => facts,
            "limitations" => %w(assumed_area_stop partial_reviewed_transport_network) }
        end

        def calendar_record(route, sources, limitations, date: nil)
          source = sources.find { |item| item.fetch("source_url") == route.source_url }
          raise Dialogue::Contracts::Invalid, "Calendar source missing" unless source

          sections = route.directions.group_by { |direction| direction.calendar.fetch("kind") }.map do |kind, directions|
            { "kind" => kind, "source_headings" => directions.map { |direction| direction.calendar.fetch("source_heading") }.uniq,
              "directions" => directions.map(&:name).uniq }
          end
          manifest = ReviewedTransportTimetables.manifest
          calendar = manifest.fetch("calendar")
          facts = { "route_code" => route.code, "published_sections" => sections, "effective_from" => manifest.fetch("effective_from"),
                    "reviewed_until" => calendar.fetch("reviewed_until"), "unsupported_dates" => calendar.fetch("unsupported_dates"),
                    "school_day_ranges" => calendar.fetch("school_day_ranges"), "school_break_ranges" => calendar.fetch("school_break_ranges") }
          facts.merge!(calendar_date_facts(date)) if date
          headings = sections.flat_map { |section| section.fetch("source_headings") }.uniq.join("; ")
          source.slice("document_id", "revision", "source_url", "observed_at", "review_expires_at").merge(
            "id" => "transport-calendar:#{Digest::SHA256.hexdigest(JSON.generate([source, facts]))}",
            "text" => "#{route.code}: published timetable sections: #{headings}. Reviewed calendar: #{facts.fetch("effective_from")}–#{facts.fetch("reviewed_until")}.",
            "facts" => facts, "limitations" => limitations
          )
        end

        def planned_envelope(arguments, context, catalog, requested_at, origin_location: nil, force_planner: false)
          # The model may supply midnight or an earlier clock for an undated
          # "next" request. A live journey must never send someone to a stop
          # for a bus that has already left.
          if arguments.fetch("date") == context.now.in_time_zone(PublicTransportTimetable::SERVICE_TIME_ZONE).to_date.iso8601 &&
             requested_at < context.now
            requested_at = context.now
          end
          use_planner = journey_planner_enabled? || force_planner
          scope = { "operation" => "plan_journey", "subject_ids" => (Array(arguments["origin_ids"] || arguments["origin_id"]) + Array(arguments["destination_ids"] || arguments["destination_id"]) + route_subject(arguments)).uniq,
                    "source_ids" => source_ids(catalog), "date" => arguments.fetch("date"), "window_start" => requested_at.iso8601,
                    "window_end" => requested_at.next_day.beginning_of_day.iso8601 }
          if use_planner
            scope["resolved_query"] = normalized_request(arguments, requested_at, origin_location:,
                                                           origin_ids: arguments["origin_ids"],
                                                           destination_ids: arguments["destination_ids"] || Array(arguments["destination_id"]))
            scope["search_complete"] = false
          end
          if catalog.fetch(:routes).empty?
            scope["reason_code"] = "source_unavailable" if use_planner
            return envelope(status: "unavailable", warnings: ["prepared_timetable_unavailable"], query_scope: scope)
          end

          if arguments["route_code"] && catalog.fetch(:routes).none? { |route| route.code == arguments.fetch("route_code") }
            scope["reason_code"] = "unresolved_place" if use_planner
            return envelope(status: "unsupported", warnings: %w(line_not_in_reviewed_snapshot partial_reviewed_transport_network), query_scope: scope)
          end

          result = if use_planner
                     origin_ids = if origin_location
                                    []
                                  else
                                    arguments["origin_ids"] || PublicTransportPlaces.selection_stop_ids(catalog, arguments.fetch("origin_id"),
                                                                                                         stop_id: @timetable.method(:prepared_stop_id), route_code: arguments["route_code"])
                                  end
                     destination_ids = arguments["destination_ids"] || PublicTransportPlaces.selection_stop_ids(catalog, arguments.fetch("destination_id"),
                                                                                                                  stop_id: @timetable.method(:prepared_stop_id), route_code: arguments["route_code"])
                     origin_pinned = !origin_location && (arguments["pin_origin_stop"] == true ||
                       !arguments.fetch("origin_id", "").start_with?("transport-place:"))
                     destination_pinned = !arguments.fetch("destination_id", "").start_with?("transport-place:")
                     planner_options = { origin_ids:, destination_ids:, catalog:, requested_at:,
                                                       deadline: context.deadline, mode: arguments.fetch("mode", "fastest").to_sym,
                                                       options: arguments.fetch("options", 2), direct_only: arguments.fetch("direct_only", false),
                                                       route_code: arguments["route_code"], direction: arguments["direction"], origin_location:,
                                                       origin_pinned:, destination_pinned:, strict: true }
                     planner_options[:observer] = @observer if @observer && @timetable.is_a?(PublicTransportTimetable)
                     @timetable.query_fastest_prepared(**planner_options)
                   else
                     @timetable.query_prepared_stops(origin_id: arguments.fetch("origin_id"), destination_id: arguments.fetch("destination_id"),
                                                     catalog: catalog, requested_at: requested_at, deadline: context.deadline,
                                                     mode: arguments.fetch("mode", "next").to_sym, options: arguments.fetch("options", 1),
                                                     direct_only: arguments.fetch("direct_only", false), route_code: arguments["route_code"])
                   end
          if use_planner
            # Source authorization is cheap relative to an incorrect answer.
            # A changed or revoked prepared revision invalidates this result.
            current = @timetable.prepared_tool_catalog(notices: @notices, deadline: context.deadline)
            if current.fetch(:revision) != catalog.fetch(:revision) || current.fetch(:routes).empty?
              return envelope(status: "unavailable", warnings: ["prepared_timetable_changed_during_search"],
                              query_scope: scope.merge("reason_code" => "source_unavailable", "search_complete" => false))
            end
            scope["reason_code"] = result.reason_code if result.reason_code
            scope["search_complete"] = result.search_complete == true
            if result.resolved_query
              scope["resolved_query"] = result.resolved_query.merge(
                "origin_resolution" => origin_location ? "consented_current_location" : (arguments.fetch("origin_id", "").start_with?("transport-place:") && arguments["pin_origin_stop"] != true ? "assumed_area" : "supplied_stop"),
                "destination_resolution" => arguments.fetch("destination_id", "").start_with?("transport-place:") ? "assumed_area" : "supplied_stop"
              )
            end
          end
          # A prepared subset is not proof of a complete network-wide negative.
          status = result.status == :empty ? "unsupported" : result.status.to_s
          status, records = planned_records(status, result, catalog, arguments, resolved_query: scope["resolved_query"])
          candidates = status == "ok" ? [] : assumption_candidates(arguments, catalog)
          warnings = result.warnings + ["partial_reviewed_transport_network"]
          warnings << "assumed_area_stop" if candidates.any?
          envelope(status: status, evidence: records, candidates:, warnings: warnings.uniq, query_scope: scope)
        end

        def planned_records(status, result, catalog, arguments, resolved_query: nil)
          records = status == "ok" ? journey_records(result, catalog, arguments, resolved_query:) : []
          constraints = { "mode" => journey_planner_enabled? ? "fastest" : "next", "direct_only" => false }.merge(arguments.slice("origin_id", "origin_ids", "destination_id", "destination_ids", "date", "after_time", "mode", "direct_only", "route_code", "direction"))
          records = records.map do |record|
            record.merge("id" => "transport-leg:#{Digest::SHA256.hexdigest(JSON.generate([record, constraints]))}",
                         "facts" => record.fetch("facts").merge("requested_constraints" => constraints))
          end
          if %w(unsupported unavailable).include?(status) && result.warnings.include?("unsupported_service_day")
            records = [calendar_boundary_record(catalog, arguments, constraints, result.warnings)]
            status = "ok" # The reviewed calendar boundary is known; no journey is asserted.
          end
          [status, records]
        end

        def calendar_boundary_record(catalog, arguments, constraints, warnings)
          manifest = ReviewedTransportTimetables.manifest
          calendar = manifest.fetch("calendar")
          facts = calendar_date_facts(arguments.fetch("date")).merge(
            "journey_status" => "unsupported", "requested_constraints" => constraints,
            "effective_from" => manifest.fetch("effective_from"), "reviewed_until" => calendar.fetch("reviewed_until"),
            "unsupported_dates" => calendar.fetch("unsupported_dates"), "calendar_source_documents" => calendar.fetch("sources").map { |row| row.slice("url", "sha256") },
            "scope" => "reviewed_calendar_coverage_not_proof_of_no_service"
          )
          revision = Digest::SHA256.hexdigest(JSON.generate([manifest.fetch("calendar"), manifest.fetch("effective_from"), catalog.fetch(:revision)]))
          sources = catalog.fetch(:sources)
          { "id" => "transport-calendar-boundary:#{Digest::SHA256.hexdigest(JSON.generate([revision, facts]))}",
            "document_id" => "transport:calendar:#{ReviewedTransportTimetables::CALENDAR_ID}", "revision" => revision,
            "source_url" => manifest.fetch("source_url"), "source_locator" => { "calendar_id" => ReviewedTransportTimetables::CALENDAR_ID },
            "observed_at" => sources.map { |source| source.fetch("observed_at") }.min,
            "review_expires_at" => sources.map { |source| source.fetch("review_expires_at") }.min,
            "text" => "Requested date #{arguments.fetch("date")}: #{facts.fetch("calendar_date_status")}. This does not prove no transport service.",
            "facts" => facts, "limitations" => (warnings + ["partial_reviewed_transport_network"]).uniq }
        end

        def assumption_candidates(arguments, catalog)
          %w(origin_id destination_id).filter_map do |role|
            assumption = PublicTransportPlaces.assumption(catalog, arguments[role], stop_id: @timetable.method(:prepared_stop_id),
                                                         route_code: arguments["route_code"]) if arguments[role]
            next unless assumption

            { "id" => assumption.fetch("place_id"), "document_id" => STOP_DOCUMENT,
              "revision" => catalog.fetch(:revision), "label" => "#{role}: #{assumption.fetch('selected_stop')} (pretpostavljeno)"[0, 160] }
          end
        end

        def unresolved_endpoints(matches, catalog, arguments, origin_location: nil)
          scope = { "operation" => "resolve_and_plan_journey", "source_ids" => source_ids(catalog), "date" => arguments.fetch("date") }
          scope["subject_ids"] = route_subject(arguments) if arguments["route_code"]
          if journey_planner_enabled?
            scope["resolved_query"] = normalized_request(arguments, requested_time(arguments), origin_location:,
                                                         origin_ids: matches.fetch("origin", []).map { |row| row.fetch("id") },
                                                         destination_ids: matches.fetch("destination", []).map { |row| row.fetch("id") })
            scope["search_complete"] = false
            scope["reason_code"] = catalog.fetch(:routes).empty? ? "source_unavailable" : "unresolved_place"
          end
          return envelope(status: "unavailable", warnings: ["prepared_timetable_unavailable"], query_scope: scope) if catalog.fetch(:routes).empty?

          unresolved = matches.reject { |_, stops| stops.one? }
          warnings = unresolved.map { |role, stops| "transport_#{role}_#{stops.empty? ? "not_in_reviewed_snapshot" : "ambiguous"}" }
          candidates = unresolved_candidates(unresolved, catalog)
          warnings << "transport_candidates_truncated" if candidates.size > MAX_CANDIDATES
          status = unresolved.values.any?(&:empty?) ? "unsupported" : "ambiguous"
          envelope(status: status, candidates: candidates.first(MAX_CANDIDATES), warnings: warnings + ["partial_reviewed_transport_network"], query_scope: scope)
        end

        def unresolved_candidates(unresolved, catalog)
          unresolved.flat_map do |role, stops|
            stops.map do |stop|
              { "id" => stop.fetch("id"), "document_id" => STOP_DOCUMENT, "revision" => catalog.fetch(:revision),
                "label" => "#{role}: #{candidate_label(stop, stops, catalog)}"[0, 160] }
            end
          end
        end

        def planning_properties
          { "date" => string_schema(10).merge("description" => "Citizen-requested service date YYYY-MM-DD. On corrections retain the earlier citizen date. If an interrupted prior request was not retained, ask for its missing date instead of assuming today."),
            "after_time" => string_schema(5).merge("description" => "Citizen-requested lower time bound HH:MM. On endpoint corrections retain the earlier bound. Use the current clock only when the citizen requests travel from now; a server clock is not a supplied bound."), "route_code" => string_schema(3),
            "mode" => { "type" => "string", "enum" => %w(fastest next last), "maxLength" => 7 },
            "options" => { "type" => "integer", "minimum" => 1, "maximum" => 2 }, "direct_only" => { "type" => "boolean" } }
        end

        def normalized_request(arguments, requested_at, origin_location: nil, origin_ids: nil, destination_ids: nil)
          origin_ids ||= Array(arguments["origin_id"])
          destination_ids ||= Array(arguments["destination_id"])
          {
            "version" => 1, "origin_ids" => origin_ids.first(20), "destination_ids" => destination_ids.first(20),
            "date" => arguments.fetch("date"), "after_time" => arguments.fetch("after_time"),
            "timezone" => PublicTransportTimetable::SERVICE_TIME_ZONE,
            "mode" => arguments.fetch("mode", "fastest"), "route_code" => arguments["route_code"], "direction" => arguments["direction"],
            "direct_only" => arguments.fetch("direct_only", false), "radius_meters" => 200,
            "transfer_limit" => arguments.fetch("direct_only", false) ? 0 : 1,
            "origin_resolution" => origin_location ? "consented_current_location" : (origin_ids.any? { |id| id.start_with?("transport-place:") } && arguments["pin_origin_stop"] != true ? "assumed_area" : "supplied_stop"),
            "destination_resolution" => destination_ids.any? { |id| id.start_with?("transport-place:") } ? "assumed_area" : "supplied_stop"
          }
        end

        def canonical_transport_arguments(arguments)
          return arguments unless arguments.has_key?("route_code")

          arguments.merge("route_code" => canonical_route_code!(arguments.fetch("route_code")))
        end

        def canonical_route_code!(value, allow_unknown: false)
          latin = Decidim::Bih::Transliterator.to_latin(value.to_s).tr("ＰＧｐｇ", "PGpg")
          canonical = latin.upcase.gsub(/\s+/, "")
          return canonical if canonical.match?(/\A[GP][1-9]\d?\z/)
          return canonical if allow_unknown && canonical.match?(/\A[A-Z][1-9]\d?\z/)

          raise Dialogue::Contracts::Invalid, "invalid_transport_route_code"
        end

        def journey_planner_enabled?
          ENV["MILICA_JOURNEY_PLANNER_V2_ENABLED"] == "true"
        end

        def area_defaults_enabled?
          ENV["MILICA_AREA_DEFAULT_STOPS_ENABLED"] == "true"
        end

        def resolve_named_stop(query, catalog, route_code: nil, prefer_area: false)
          return @timetable.resolve_prepared_stops(query:, catalog:) unless area_defaults_enabled?

          # The printed NAS label has several physical boarding sides. Use the
          # reviewed station place so the timetable can choose the right side
          # for the requested route instead of asking which duplicate ID was
          # meant by the same public stop name.
          folded = PlaceAliasRegistry.normalize(query)
          query = "NAS" if folded.match?(/\A(?:bijeljina )?nas(?: a| u| om)?\z/)
          result = PublicTransportPlaces.resolver(catalog, stop_id: @timetable.method(:prepared_stop_id), route_code:).resolve(query, prefer_place: prefer_area)
          return @timetable.resolve_prepared_stops(query:, catalog:) if result.status == :unsupported

          Array(result.candidates).map do |candidate|
            row = candidate.transform_keys(&:to_s)
            row["assumption"] = {
              "place_id" => result.place_id, "selected_stop" => row.fetch("label"),
              "reason" => result.assumption_reason.to_s,
              "alternative_stops" => result.alternatives.map { |other| other.fetch(:label) }.uniq.first(6)
            } if result.place_id
            row
          end
        end

        def explicit_nas_origin?(query)
          folded = PlaceAliasRegistry.normalize(query)
          folded.match?(/\A(?:bijeljina )?nas(?: a| u| om)?\z/) ||
            folded.match?(/\A(?:nov[a-z]* )?autobusk[a-z]* stanic[a-z]*(?: u bijeljini| bijeljina)?\z/)
        end

        def route_subject(arguments)
          arguments["route_code"] ? ["transport-route:#{arguments.fetch("route_code")}"] : []
        end

        def trusted!(context)
          valid = context.is_a?(Dialogue::Contracts::TrustedContext) && context.organization_id == @organization_id && context.allows?("public_reads")
          raise Dialogue::Contracts::Invalid, "Trusted public transport scope required" unless valid
          raise Dialogue::Contracts::Invalid, "Transport deadline required" unless context.deadline && !context.deadline.expired?
        end

        def requested_time(arguments)
          date_text = arguments.fetch("date")
          time_text = arguments.fetch("after_time")
          raise ArgumentError unless date_text.match?(/\A\d{4}-\d{2}-\d{2}\z/) && time_text.match?(/\A(?:[01]\d|2[0-3]):[0-5]\d\z/)

          date = Date.iso8601(date_text)
          hour, minute = time_text.split(":").map(&:to_i)
          ActiveSupport::TimeZone[PublicTransportTimetable::SERVICE_TIME_ZONE].local(date.year, date.month, date.day, hour, minute)
        rescue ArgumentError
          raise Dialogue::Contracts::Invalid, "Explicit valid service date and local time required"
        end

        def published_boarding_matches(query, catalog)
          # This generic operation must not call the reference reader's local
          # center/origin shortcuts. Areas require explicit operator mappings
          # and the area-default switch; printed stop names remain usable.
          resolver = if area_defaults_enabled?
                       PublicTransportPlaces.resolver(catalog, stop_id: @timetable.method(:prepared_stop_id))
                     else
                       stops = catalog.fetch(:rows).map { |row| { id: @timetable.prepared_stop_id(row), label: row.label } }.uniq { |row| row.fetch(:id) }
                       Decidim::Bih::Transport::StopResolver.new(stops:)
                     end
          result = resolver.resolve(query)
          return [] if result.status == :unsupported

          Array(result.candidates).map do |candidate|
            row = candidate.transform_keys(&:to_s)
            if row.key?("member_stop_ids")
              { "id" => row.fetch("id"), "label" => row.fetch("name"), "ambiguous_place" => true }
            else
              row["assumption"] = { "place_id" => result.place_id, "reason" => result.assumption_reason.to_s } if result.place_id
              row
            end
          end
        end

        def published_boarding_record(route:, direction:, origin:, destination:, origin_index:, destination_index:, column:, source:)
          facts = { "kind" => "published_boarding_point", "evidence_purpose" => "published_same_trip_column_membership_not_departure",
            "origin_id" => @timetable.prepared_stop_id(origin), "origin_label" => origin.label,
            "destination_id" => @timetable.prepared_stop_id(destination), "destination_label" => destination.label,
            "route_code" => route.code, "published_direction" => direction.name,
            "source_calendar_heading" => direction.calendar&.fetch("source_heading", nil),
            "source_row_from" => origin_index, "source_row_to" => destination_index, "source_column_index" => column,
            "service_date_selected" => false, "departure_confirmed" => false, "walking_path_verified" => false }
          { "id" => "published-boarding:#{Digest::SHA256.hexdigest(JSON.generate([source, facts]))}",
            "document_id" => source.fetch("document_id"), "revision" => source.fetch("revision"),
            "source_url" => source.fetch("source_url"), "observed_at" => source.fetch("observed_at"),
            "review_expires_at" => source.fetch("review_expires_at"),
            "text" => "Published route #{route.code}: #{origin.label} → #{destination.label}. No service day or departure is confirmed.",
            "facts" => facts, "limitations" => %w(partial_reviewed_transport_network published_membership_not_departure walking_path_not_verified boarding_side_not_verified) }
        end

        def journey_records(result, catalog, arguments = {}, resolved_query: nil)
          result.options.each_with_index.flat_map do |itinerary, journey_index|
            itinerary.legs.each_with_index.map do |leg, leg_index|
              source = catalog.fetch(:sources).find { |row| row.fetch("source_url") == leg.source_url }
              raise Dialogue::Contracts::Invalid, "Computed leg source missing" unless source

              facts = {
                "evidence_purpose" => "computed_journey_for_requested_endpoints_date_and_window",
                "tuple_rule" => "Keep this leg's origin, destination, route, service date, departure and arrival together; do not substitute another read's places or clocks.",
                "journey_origin_label" => itinerary.legs.first.origin_label,
                "journey_destination_label" => itinerary.legs.last.destination_label,
                "journey_index" => journey_index, "leg_index" => leg_index, "route_code" => leg.route_code,
                # A circular route's final stop does not describe this boarding leg.
                "direction" => "#{leg.origin_label} → #{leg.destination_label}", "direction_scope" => "boarding_to_alighting",
                "source_calendar_heading" => leg.calendar&.fetch("source_heading", nil),
                "published_direction" => leg.direction_label,
                "origin_id" => @timetable.prepared_stop_id(leg.origin_stop),
                "origin_label" => leg.origin_label, "destination_id" => @timetable.prepared_stop_id(leg.destination_stop),
                "destination_label" => leg.destination_label, "departure_at" => leg.departure_at.iso8601,
                "arrival_at" => leg.arrival_at.iso8601, "timezone" => PublicTransportTimetable::SERVICE_TIME_ZONE,
                "requested_service_date" => result.requested_service_date, "service_date" => result.service_date,
                "transfer_count" => itinerary.legs.size - 1,
                "wait_before_seconds" => leg_index.zero? ? 0 : (leg.departure_at - itinerary.legs[leg_index - 1].arrival_at).to_i
              }
              if result.journey_metadata
                facts.merge!(result.journey_metadata.fetch(journey_index))
                facts["search_complete"] = result.search_complete == true
                facts["resolved_query"] = resolved_query || result.resolved_query
                assumptions = %w(origin_id destination_id).filter_map do |role|
                  if arguments[role]
                    selected = PublicTransportPlaces.assumption(catalog, arguments[role], stop_id: @timetable.method(:prepared_stop_id),
                                                                route_code: arguments["route_code"])
                    if selected
                      # A reviewed area default is a search anchor. A nearby
                      # point may win; disclose the actual boarding/alighting
                      # stop instead of claiming the default was used.
                      actual = role == "origin_id" ? itinerary.legs.first.origin_label : itinerary.legs.last.destination_label
                      alternatives = ([selected.fetch("selected_stop")] + selected.fetch("alternative_stops")).uniq.reject { |name| name == actual }
                      selected.merge("role" => role, "anchor_stop" => selected.fetch("selected_stop"),
                                     "selected_stop" => actual, "alternative_stops" => alternatives)
                    end
                  end
                end
                facts["assumed_stop"] = assumptions if assumptions.any?
                facts["reason_code"] = result.reason_code if result.reason_code
              end
              { "id" => "transport-leg:#{Digest::SHA256.hexdigest(JSON.generate([source, facts]))}",
                "document_id" => source.fetch("document_id"), "revision" => source.fetch("revision"),
                "source_url" => source.fetch("source_url"), "observed_at" => source.fetch("observed_at"),
                "review_expires_at" => source.fetch("review_expires_at"),
                "text" => "#{leg.route_code}: #{leg.origin_label} #{leg.departure_at.iso8601} → #{leg.destination_label} #{leg.arrival_at.iso8601}",
                "facts" => facts, "limitations" => result.warnings }
            end
          end
        end

        def candidate_label(stop, matches, catalog)
          label = stop.fetch("label")
          return label if matches.count { |candidate| candidate.fetch("label") == label } == 1

          directions = catalog.fetch(:routes).flat_map do |route|
            route.directions.filter_map do |direction|
              next unless direction.stops.any? { |row| @timetable.prepared_stop_id(row) == stop.fetch("id") }

              "#{route.code} #{direction.name}"
            end
          end.uniq
          "#{label} (#{directions.join(", ")})"[0, 160]
        end

        def source_ids(catalog)
          catalog.fetch(:sources).map { |source| source.fetch("document_id") }
        end

        def envelope(**values)
          # Stop IDs are validated reader inputs, not citation handles.
          values[:candidates] = Array(values[:candidates]).map { |row| row.merge("selection_key" => row.fetch("id")) }
          Dialogue::EvidenceEnvelope.new(organization_id: @organization_id, registry_epoch: @registry_epoch, **values)
        end

        def string_schema(limit)
          { "type" => "string", "minLength" => 1, "maxLength" => limit }
        end

        def definition(name, description, properties, required, handler)
          { "name" => name, "description" => description,
            "parameters" => { "type" => "object", "properties" => properties, "required" => required, "additionalProperties" => false }, "handler" => handler }
        end
      end
    end
  end
end
