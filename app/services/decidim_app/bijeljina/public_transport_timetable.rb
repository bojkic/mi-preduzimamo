# frozen_string_literal: true

require "digest"
require "json"
require "net/http"
require "pdf/reader"
require "stringio"
require "uri"
require "yaml"
require_relative "transport_snapshot_builder"

module DecidimApp
  module Bijeljina
    # Reads the official public-transport route PDFs enough to answer concrete
    # "next bus" questions. It stays conservative: when the route/stop cannot be
    # inferred, callers fall back to the route-list answer.
    class PublicTransportTimetable
      DEFAULT_TIMEOUT = 4
      DEFAULT_MAX_BYTES = 1_500_000
      CACHE_TTL = 12.hours
      MATERIALIZATION_VERSION = "transport-matrix-v6"
      MATERIALIZATION_MAX_AGE = 14.days
      MAX_PREPARED_ROUTE_CACHE = 8
      # Process-local, bounded and immutable. Each Puma/Sidekiq worker owns its
      # copy; payload and source eligibility are still checked on every read.
      PREPARED_ROUTE_CACHE = { mutex: Mutex.new, entries: {} }.freeze
      SERVICE_TIME_ZONE = "Europe/Sarajevo"
      STOP_REGISTRY_PATH = "config/bijeljina/public_transport_stops.yml"
      GOOGLE_MAPS_DIRECTIONS_URL = "https://www.google.com/maps/dir/"
      ROUTE_CODE_PATTERN = /\b([GP])\s*(\d{1,2})\b/i
      TIME_PATTERN = /\b\d{1,2}:\d{2}\b/
      TRANSFER_BUFFER_SECONDS = 180
      MAX_TRANSFER_WAIT_SECONDS = 14_400
      # A journey read may look past a day with nothing left (or a Sunday with
      # no published departures) to the next service day, and says so. Two
      # departures are the most a citizen asked "when is the next bus" needs.
      MAX_ROLLOVER_DAYS = 3
      MAX_OPTIONS = 2
      WORKDAY_SECTION_END = /\b(?:Subota|Nedelja|Nedjelja|Praznik|Praznici)\b/i
      PDF_ROW_TOKEN = %r{/|\d{1,2}:\d{2}}
      CENTER_QUERY_TERMS = ["bijeljina", "bijeljine", "bijeljinu", "bijeljini", "centar", "centra", "centru", "nova as", "nas", "autobuska", "stanica"].freeze
      # "centar" means the town centre, not the first Bijeljina stop a line
      # touches on its way in. When a direction serves one of these, the
      # journey boards or alights there; otherwise any Bijeljina stop counts.
      CENTER_CORE_STOPS = ["bijeljina nas", "bijeljina spomenik", "bijeljina saborna crkva", "bijeljina sud"].freeze
      MORNING_HOUR = 5
      AFTERNOON_HOUR = 12
      EVENING_HOUR = 18
      QUERY_PHRASE_STOPWORDS = %w(
        autobusom
        busom
        danas
        gradskim
        jutro
        javnim
        kako
        navece
        navecer
        posle
        poslepodne
        poslijepodne
        podne
        popodne
        prevoz
        prevozom
        prije
        prijevoz
        prijevozom
        prijepodne
        prepodne
        rano
        stignem
        sutra
        ujutro
        ujutru
        vecer
        veceras
      ).freeze
      JOURNEY_TERMS = [
        "stignem",
        "dodjem",
        "dodem",
        "dođem",
        "ici",
        "idem",
        "javni prevoz",
        "javnim prevozom",
        "gradski prevoz",
        "gradskim prevozom",
        "prevozom",
        "autobusom",
        "busom"
      ].freeze
      HERE_ORIGIN_TERMS = [
        "odavde",
        "ovdje",
        "ovde",
        "ove lokacije",
        "ove lokacij",
        "trenutne lokacije",
        "trenutne lokacij"
      ].freeze
      LOCATION_REFERENCE_TERMS = (HERE_ORIGIN_TERMS + [
        "moja lokacija",
        "moja lokacij",
        "moju lokaciju",
        "moju lokacij",
        "ovu lokaciju",
        "ovu lokacij",
        "ovoj lokaciji",
        "ovoj lokacij",
        "trenutna lokacija",
        "trenutna lokacij",
        "tu"
      ]).freeze
      NEAREST_STOP_MAX_DISTANCE_METERS = 3_000
      NEAREST_STOP_PRIORITY_DISTANCE_DELTA_METERS = 100
      EARTH_RADIUS_METERS = 6_371_000

      # Internal query identity survives normalization and per-route matching.
      # String behavior keeps result metadata and adapter interfaces unchanged.
      class ExactStopPhrase < String; end

      # Probe tools bind a reviewed boarding-point ID, including its direction
      # coordinates. Normalization must never broaden that ID back to a label.
      class BoundStopPhrase < ExactStopPhrase
        attr_reader :stop_id, :stop_ids

        def initialize(label, stop_id, stop_ids: [stop_id])
          super(label)
          @stop_id = stop_id.dup.freeze
          @stop_ids = stop_ids.map { |id| id.dup.freeze }.freeze
          freeze
        end
      end

      Route = Struct.new(:code, :title, :directions, :source_url, :calendars, keyword_init: true)
      Direction = Struct.new(:route, :name, :stops, :calendar, keyword_init: true)
      PreparedNotice = Struct.new(:title, :url, keyword_init: true)
      StopRow = Struct.new(:label, :normalized_label, :times, :index, :latitude, :longitude, :coordinates_source, :coordinates_accuracy, keyword_init: true)
      StopAnchor = Struct.new(:label, :normalized_label, :latitude, :longitude, :source, :accuracy, :confidence, :nearest_priority, keyword_init: true)
      NearestStop = Struct.new(:label, :distance_meters, :source, :accuracy, :confidence, :latitude, :longitude, :nearest_priority, keyword_init: true)
      Leg = Struct.new(
        :route_code,
        :route_title,
        :source_url,
        :origin_label,
        :origin_stop,
        :destination_label,
        :destination_stop,
        :departure_at,
        :arrival_at,
        :direction_label,
        :calendar,
        keyword_init: true
      )
      Itinerary = Struct.new(:legs, keyword_init: true)

      class AnswerText < String
        attr_reader :quick_replies

        def initialize(text, quick_replies: [])
          super(text.to_s)
          @quick_replies = quick_replies
        end
      end

      Result = Struct.new(
        :route_code,
        :route_title,
        :origin_label,
        :destination_label,
        :departure_at,
        :departure_text,
        :arrival_text,
        :next_departures,
        :next_day,
        keyword_init: true
      )
      # `itinerary` is the first option; `alternatives` hold at most
      # MAX_OPTIONS - 1 further departures. `requested_service_date` is the
      # local day the citizen asked about, `service_date` the day of the first
      # departure; they differ exactly when `rolled_over` is true. `unmatched`
      # names the place(s) no reviewed stop label supports.
      StructuredQuery = Struct.new(
        :status,
        :itinerary,
        :sources,
        :warnings,
        :candidates,
        :boarding_stop,
        :origin,
        :destination,
        :destination_scope,
        :alternatives,
        :requested_service_date,
        :service_date,
        :rolled_over,
        :unmatched,
        :journey_metadata,
        :search_complete,
        :reason_code,
        :resolved_query,
        :assumptions,
        keyword_init: true
      ) do
        STATUSES = [:ok, :empty, :ambiguous, :unavailable, :unreviewed].freeze

        def initialize(**attributes)
          attributes[:status] = attributes.fetch(:status).to_sym
          raise ArgumentError, "unknown transport query status" unless STATUSES.include?(attributes[:status])

          attributes[:sources] = Array(attributes[:sources]).freeze
          attributes[:warnings] = Array(attributes[:warnings]).freeze
          attributes[:candidates] = Array(attributes[:candidates]).freeze
          attributes[:alternatives] = Array(attributes[:alternatives]).freeze
          attributes[:unmatched] = Array(attributes[:unmatched]).freeze
          attributes[:rolled_over] = attributes[:rolled_over] == true
          super
          freeze
        end

        def options
          [itinerary, *alternatives].compact
        end
      end

      def initialize(fetcher: nil, text_extractor: nil, clock: nil, cache: nil, source_validator: nil, **options) # rubocop:disable Metrics/ParameterLists
        @fetcher = fetcher || method(:fetch_pdf)
        @text_extractor = text_extractor || method(:extract_pdf_text)
        @clock = clock || -> { Time.zone.now }
        @cache = cache == false ? nil : (cache || (Rails.cache if defined?(Rails)))
        @source_validator = source_validator
        @prepared_only = options.fetch(:prepared_only, fetcher.nil?)
        @snapshot_store = options[:snapshot_store] || CityServiceSourceCheckStore.new
        @timeout = options.fetch(:timeout, DEFAULT_TIMEOUT)
        @use_map_coordinates = default_map_registry?(options)
        @stop_registry = if options.has_key?(:stop_registry)
                           normalize_stop_registry(options[:stop_registry])
                         else
                           load_stop_registry(options[:stop_registry_path])
                         end
      end

      def answer(text:, notices:, location: nil, deadline: nil)
        within_deadline(deadline) do
          folded = fold(text)
          if folded.match?(/\b(?:prazni\w*|blagdan\w*|holiday\w*|raspust\w*|school break|skolsk\w* dan\w*|nastavn\w* dan\w*|school day)\b/)
            return "Za praznike i školske dane nemam provjeren kalendar datuma; provjeri posebno objavljeni raspored prevoznika."
          end

          specific = specific_transport_answer(folded, notices, location:)
          return specific if specific.present?

          scheduled_departure_answer(folded, notices)
        end
      rescue CityServiceNoticeCollector::DeadlineExceeded, CityServiceNoticeCollector::InvalidDeadline
        raise
      rescue StandardError => e
        Rails.logger.warn("[PublicTransportTimetable] failed to read timetable (#{e.class}: #{e.message})") if defined?(Rails)
        nil
      end

      def matrix(notices:, deadline: nil)
        within_deadline(deadline) { build_matrix(notices, deadline:) }
      end

      # Probe-only public API. One prepared snapshot supplies both the rows and
      # their evidence revisions; resolving/planning never fetches a document.
      def prepared_tool_catalog(notices:, deadline: nil)
        raise ArgumentError, "Prepared reader and source validator required" unless prepared_tool_reader?

        within_deadline(deadline) do
          entries = Array(notices).select { |notice| notice.source_key == "public_transport" }.uniq(&:url).filter_map { |notice| prepared_tool_entry(notice) }
          routes = entries.map { |entry| entry.fetch(:route) }
          sources = entries.map { |entry| entry.fetch(:source) }
          rows = routes.flat_map { |route| route.directions.flat_map(&:stops) }
          revision = prepared_stop_revision(sources, rows)
          { routes: routes, sources: sources, rows: rows, revision: revision }
        end
      end

      def resolve_prepared_stops(query:, catalog:)
        matches = matching_stops(catalog.fetch(:rows), query).uniq { |row| transport_stop_id(row) }
        ranked = matches.sort_by { |row| row.normalized_label.match?(/\A(?:n n|nn)\b/) ? 1 : 0 }
        ranked.map { |row| { "id" => prepared_logical_station_id(row) || transport_stop_id(row), "label" => row.label } }.uniq { |stop| stop.fetch("id") }
      end

      def query_prepared_stops(origin_id:, destination_id:, catalog:, requested_at:, deadline:, mode: :next, options: 1, direct_only: false, route_code: nil) # rubocop:disable Metrics/ParameterLists
        routes = prepared_routes_for(catalog, route_code)
        bindings = [origin_id, destination_id].map do |id|
          prepared_stop_binding(id, catalog)
        end
        return StructuredQuery.new(status: :ambiguous, warnings: ["unknown_transport_stop_id"]) if bindings.any?(&:nil?)

        within_deadline(deadline) do
          structured_query(origin: bindings.first, destination: bindings.last, notices: [], requested_at: requested_at,
                           route_code: route_code, location: nil, deadline: deadline, service_day_kind: nil, mode: mode,
                           options: options, strict: true, prepared_routes: routes, direct_only: direct_only, same_day_only: true)
        end
      end

      # The v2 planner uses every eligible physical point represented by each
      # public stop/station ID. Coordinates are request-local and never cached.
      def query_fastest_prepared(origin_ids:, destination_ids:, catalog:, requested_at:, deadline:, mode: :fastest, options: 2, # rubocop:disable Metrics/ParameterLists
                                 direct_only: false, route_code: nil, origin_location: nil, destination_location: nil,
                                 origin_pinned: true, destination_pinned: true, direction: nil, strict: true, observer: nil)
        within_deadline(deadline) do
          routes = prepared_routes_for(catalog, route_code)
          return StructuredQuery.new(status: :unavailable, warnings: ["prepared_timetable_unavailable"], reason_code: "source_unavailable") if routes.empty?

          date = local_service_date(requested_at)
          calendar_status = service_calendar_status(routes, requested_at)
          if calendar_status
            return StructuredQuery.new(status: calendar_status.first, warnings: [calendar_status.last],
                                       reason_code: "unsupported_calendar", requested_service_date: date.iso8601,
                                       search_complete: false)
          end

          snapshot_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          snapshot = TransportSnapshotBuilder.call(catalog:, service_date: date)
          observe_routing_span(observer, "transport_snapshot", snapshot_started, trips: snapshot&.trips&.size, stops: snapshot&.stops&.size)
          return StructuredQuery.new(status: :unavailable, warnings: ["transport_snapshot_unavailable"], reason_code: "source_unavailable") unless snapshot

          starts = planner_candidates(snapshot, origin_ids, origin_location, access: true, pinned: origin_pinned)
          finishes = planner_candidates(snapshot, destination_ids, destination_location, access: false, pinned: destination_pinned)
          if starts.empty? || finishes.empty?
            return StructuredQuery.new(status: :ambiguous, warnings: ["unresolved_place"], reason_code: "unresolved_place",
                                       requested_service_date: date.iso8601, search_complete: false)
          end

          query = Decidim::Bih::Transport::JourneyQuery.new(starts:, finishes:, requested_at:, mode:, route_code:, direction:, direct_only:,
                                                             strict:, limit: options)
          search_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          calculation = Decidim::Bih::Transport::JourneyPlanner.new(snapshot).call(query)
          observe_routing_span(observer, "journey_search", search_started,
                               connections_considered: calculation.connections_considered,
                               combinations_considered: calculation.combinations_considered,
                               transfer_relaxations: calculation.transfer_relaxations,
                               transfer_comparisons: calculation.transfer_comparisons,
                               max_label_frontier: calculation.max_label_frontier,
                               final_label_frontier: calculation.final_label_frontier,
                               transfer_precheck_comparisons: calculation.respond_to?(:transfer_precheck_comparisons) ? calculation.transfer_precheck_comparisons : nil,
                               search_complete: calculation.search_complete)
          metadata = calculation.journeys.map { |journey| journey_metadata(journey, snapshot, mode) }
          itineraries = calculation.journeys.map { |journey| itinerary_from_journey(journey, snapshot) }
          warnings = %w(partial_reviewed_transport_network timetable_not_live_vehicle_status map_derived_walking_estimate)
          warnings << "incomplete_search" unless calculation.search_complete
          warnings << "map_derived_station_transfer" if calculation.journeys.any? { |journey| journey[:transfer_kind] == "map_derived_station_policy" }
          used_urls = itineraries.flat_map { |itinerary| itinerary.legs.map(&:source_url) }.uniq
          used_routes = routes.select { |route| used_urls.include?(route.source_url) }
          sources = used_routes.flat_map { |route| [route.source_url, ReviewedTransportTimetables.entry_for(route.source_url)&.dig("map", "url")] }.compact.uniq
          StructuredQuery.new(status: calculation.status, itinerary: itineraries.first, alternatives: itineraries.drop(1),
                              journey_metadata: metadata, search_complete: calculation.search_complete,
                              reason_code: calculation.reason, sources:, warnings:, requested_service_date: date.iso8601,
                              service_date: date.iso8601, resolved_query: {
                                "version" => 1, "origin_ids" => Array(origin_ids), "destination_ids" => Array(destination_ids),
                                "date" => date.iso8601, "after_time" => requested_at.strftime("%H:%M"),
                                "timezone" => SERVICE_TIME_ZONE, "mode" => mode.to_s, "route_code" => route_code, "direction" => direction,
                                "direct_only" => direct_only, "radius_meters" => 200,
                                "transfer_limit" => direct_only ? 0 : 1
                              }, destination_scope: "reviewed_stop_or_assumed_area", origin: starts.first[:stop_id], destination: finishes.first[:stop_id])
        end
      end

      def planner_candidates(snapshot, ids, location, access:, pinned:)
        if location
          return snapshot.nearby.within(location, radius_meters: 200).map do |stop, distance|
            { stop_id: stop.fetch(:id), walk_seconds: Decidim::Bih::Transport::WalkingEstimate.seconds(distance),
              boarding_margin_seconds: access ? Decidim::Bih::Transport::WalkingEstimate::BOARDING_MARGIN_SECONDS : 0,
              distance_meters: distance }
          end
        end

        anchors = Array(ids).flat_map { |id| snapshot.point_ids_for(id) }.uniq
        margin = access ? Decidim::Bih::Transport::WalkingEstimate::BOARDING_MARGIN_SECONDS : 0
        candidates = anchors.to_h { |id| [id, { stop_id: id, walk_seconds: 0, boarding_margin_seconds: margin, distance_meters: 0 }] }
        # An explicit stop is a boarding/alighting instruction, including when
        # its logical station ID covers several reviewed physical points.
        return candidates.values if pinned

        anchors.each do |id|
          point = snapshot.stops.fetch(id)
          next unless point[:latitude] && point[:longitude]

          snapshot.nearby.within(point, radius_meters: 200).each do |neighbor, distance|
            next if distance.zero? && candidates.key?(neighbor.fetch(:id))

            proposal = { stop_id: neighbor.fetch(:id), walk_seconds: Decidim::Bih::Transport::WalkingEstimate.seconds(distance),
                         boarding_margin_seconds: access ? Decidim::Bih::Transport::WalkingEstimate::BOARDING_MARGIN_SECONDS : 0,
                         distance_meters: distance }
            existing = candidates[neighbor.fetch(:id)]
            candidates[neighbor.fetch(:id)] = proposal if existing.nil? || proposal.fetch(:walk_seconds) < existing.fetch(:walk_seconds)
          end
        end
        candidates.values
      end

      def itinerary_from_journey(journey, snapshot)
        legs = journey.fetch(:legs).map do |entry|
          from = snapshot.stops.fetch(entry.fetch(:origin_stop_id))
          to = snapshot.stops.fetch(entry.fetch(:destination_stop_id))
          calendar = entry.fetch(:calendar)
          Leg.new(route_code: entry.fetch(:route_code), route_title: entry.fetch(:route_code), source_url: entry.fetch(:source_url),
                  origin_label: from.fetch(:label), origin_stop: row_from_point(from), destination_label: to.fetch(:label),
                  destination_stop: row_from_point(to), departure_at: entry.fetch(:departure_at), arrival_at: entry.fetch(:arrival_at),
                  direction_label: entry.fetch(:direction), calendar:)
        end
        Itinerary.new(legs:)
      end

      def row_from_point(point)
        StopRow.new(label: point.fetch(:label), normalized_label: normalized_text(point.fetch(:label)), times: [], index: 0,
                    latitude: point[:latitude], longitude: point[:longitude], coordinates_source: point[:coordinate_source],
                    coordinates_accuracy: point[:coordinate_accuracy])
      end

      def journey_metadata(journey, snapshot, mode)
        {
          "objective" => { fastest: "fastest_arrival", next: "first_departure", last: "last_departure" }.fetch(mode.to_sym),
          "estimated_arrival_at" => journey.fetch(:arrival_at).iso8601,
          "leave_at" => journey.fetch(:leave_at).iso8601,
          "first_departure_at" => journey.fetch(:first_departure_at).iso8601,
          "access_walk_seconds" => journey.fetch(:access_walk_seconds),
          "transfer_walk_seconds" => journey.fetch(:transfer_walk_seconds),
          "egress_walk_seconds" => journey.fetch(:egress_walk_seconds),
          "walking_seconds" => journey.fetch(:walking_seconds), "waiting_seconds" => journey.fetch(:waiting_seconds),
          "ride_seconds" => journey.fetch(:ride_seconds), "transfer_count" => journey.fetch(:transfer_count),
          "access_distance_meters" => journey.fetch(:access_distance_meters),
          "egress_distance_meters" => journey.fetch(:egress_distance_meters),
          "walking_estimate_kind" => "map_derived_straight_line_with_circuity_policy",
          "walking_estimate_range_seconds" => journey.fetch(:walking_estimate_range_seconds),
          "close_transfer_warning" => journey.fetch(:close_transfer_warning),
          "transfer_estimate_kind" => journey[:transfer_kind], "snapshot_revision" => snapshot.revision,
          "leg_provenance" => journey.fetch(:legs).map do |leg|
            { "trip_id" => leg.fetch(:trip_id), "source_column_index" => leg.fetch(:source_column_index),
              "source_row_from" => leg.fetch(:source_row_from), "source_row_to" => leg.fetch(:source_row_to) }
          end
        }
      end
      private :planner_candidates, :itinerary_from_journey, :row_from_point, :journey_metadata

      def prepared_stop_id(row)
        transport_stop_id(row)
      end

      # Expand only a source-bound published stop/station ID, never an arbitrary
      # label match. Used for topology reads which do not choose a service day.
      def prepared_physical_stop_ids(id:, catalog:)
        prepared_stop_binding(id, catalog)&.stop_ids || []
      end

      # The reviewed NAS timetable names one station. Map rows carry approximate
      # line-specific coordinates, not a surveyed platform registry. Group only
      # this reviewed identity; equal labels elsewhere are not sufficient proof.
      def prepared_logical_station_id(row)
        return unless row.normalized_label == "bijeljina nas"

        "transport_station:#{Digest::SHA256.hexdigest(row.normalized_label)[0, 12]}"
      end

      def prepared_stop_binding(id, catalog)
        rows = catalog.fetch(:rows)
        physical = rows.find { |row| transport_stop_id(row) == id }
        return BoundStopPhrase.new(physical.label, id) if physical

        members = rows.select { |row| prepared_logical_station_id(row) == id }
        return if members.empty?

        BoundStopPhrase.new(members.first.label, id, stop_ids: members.map { |row| transport_stop_id(row) }.uniq)
      end
      private :prepared_logical_station_id, :prepared_stop_binding

      def prepared_routes_for(catalog, route_code)
        return catalog.fetch(:routes) unless route_code
        raise ArgumentError, "Canonical route code required" unless route_code.is_a?(String) && route_code.match?(/\A[GP][1-9]\d?\z/)

        catalog.fetch(:routes).select { |route| route.code == route_code }
      end
      private :prepared_routes_for

      # Scheduled work only: fetch every document once, stage normalized rows,
      # validate, then promote atomically. No PDF/body is retained in citizen
      # caches. A failed document leaves its last-good version recoverable.
      def prepare(notices:, deadline: nil)
        deadline ||= SourceRefreshBudget.new(timeout: 120)
        Array(notices).select { |notice| notice.source_key == "public_transport" }.first(CityServiceSourceCheckStore::MAX_ITEMS).map do |notice|
          within_deadline(deadline) do
            @snapshot_store.with_refresh_lock(document_key(notice)) do
              prepare_document(notice, deadline:)
            end || { source_url: notice.url, status: :refresh_in_progress }
          end
        end
      end

      # Structured callers supply resolved origin/destination slots. This path
      # does not reparse a citizen sentence, and it preserves timetable and stop
      # provenance for the typed read adapter.
      #
      # `mode: :last` selects the latest departure still on the requested day;
      # `roll_over: true` looks up to MAX_ROLLOVER_DAYS ahead when nothing is
      # left (reported through `rolled_over`); `options` caps the departures
      # returned (1..MAX_OPTIONS); `strict: true` excludes a departure at
      # exactly `requested_at`. Defaults keep the original single-departure
      # contract for every existing caller.
      def query(origin:, destination:, notices:, requested_at: nil, route_code: nil, location: nil, deadline: nil, service_day_kind: nil, # rubocop:disable Metrics/ParameterLists
                mode: :next, roll_over: false, options: 1, strict: false)
        within_deadline(deadline) do
          structured_query(
            origin:,
            destination:,
            notices:,
            requested_at:,
            service_day_kind:,
            route_code:,
            location:,
            deadline:,
            mode:,
            roll_over:,
            options:,
            strict:
          )
        end
      rescue CityServiceNoticeCollector::DeadlineExceeded, CityServiceNoticeCollector::InvalidDeadline
        raise
      rescue StandardError => e
        Rails.logger.warn("[PublicTransportTimetable] structured query failed error_class=#{e.class.name}") if defined?(Rails.logger)
        StructuredQuery.new(status: :unavailable, warnings: ["timetable_query_failed"])
      end

      # The adapter validates current-turn consent/provenance before this
      # coordinate-only reader is called. Public stop facts never retain GPS.
      def nearest_stop(location:, place: nil, locality: nil, deadline: nil)
        within_deadline(deadline) do
          return named_nearest_stop(place, locality:) if location.nil? && place.present?

          candidates = nearest_stops_for(location)
          return StructuredQuery.new(status: :ambiguous, warnings: ["current_turn_location_required"]) if candidates == :location_required
          return StructuredQuery.new(status: :empty, warnings: ["reviewed_origin_stop_required"]) if candidates.empty?

          selected = candidates.min_by(&:distance_meters)
          fact = navigation_stop_fact(selected)
          return StructuredQuery.new(status: :unavailable, warnings: ["reviewed_stop_not_found"]) unless fact

          nearest_stop_presentation(fact,
                                    body: "#{nearest_stop_description(selected)}. Udaljenost je približna vazdušna udaljenost, ne dužina pješačkog puta.",
                                    route_guidance: " Za izbor polaznog stajališta i smjera napiši odredište.")
          StructuredQuery.new(status: :ok, boarding_stop: fact, origin: selected.label,
                              candidates: structured_stop_candidates(candidates), warnings: structured_transport_warnings(selected))
        end
      end

      # Re-read a public identity retained from our own earlier boarding fact.
      # No citizen location, model-supplied destination or PDF fetch is needed.
      def walking_directions(stop_id:, deadline: nil)
        within_deadline(deadline) do
          return unless stop_id.is_a?(String) && stop_id.match?(/\Atransport_stop:[a-f0-9]{12}\z/)

          matches = navigation_anchors.select { |stop| transport_stop_id(stop) == stop_id }
          matches = stop_registry.select { |stop| "transport_stop:#{Digest::SHA256.hexdigest(stop.label.to_s)[0, 12]}" == stop_id } if matches.empty?
          navigation_stop_fact(matches.first) if matches.one?
        end
      end

      # Read published direction calendars without inventing boarding places.
      # Source status is deliberately separate from physical service existence.
      def calendar_query(notices:, requested_at:, route_code: nil, service_day_kind: nil, deadline: nil)
        within_deadline(deadline) do
          scoped = Array(notices).select { |notice| notice.source_key == "public_transport" }
          code = route_code_from(route_code)
          scoped = scoped.select { |notice| route_code_for(notice) == code } if code
          routes = route_matrix(scoped, request: { earliest_after: requested_at }, deadline:)
          return { status: "unavailable", warnings: ["prepared_timetable_unavailable"], directions: [] } if routes.empty?

          kind = service_day_kind || calendar_kind_for_routes(routes, requested_at)
          return { status: "unreviewed", warnings: ["service_calendar_requires_review"], directions: [] } if kind == "unreviewed"

          override = reviewed_calendar_override_status(routes, service_day_kind, requested_at)
          status = override || service_calendar_status(routes, requested_at, kind)
          return { status: status.first.to_s, warnings: [status.last], directions: [] } if status

          directions = routes.flat_map do |route|
            route.directions.filter_map do |direction|
              next unless direction.calendar&.fetch("kind", nil) == kind

              departures = Array(direction.stops.first&.times).each_with_index.filter_map do |time, index|
                time if ReviewedTransportTimetables.trip_available?(direction.calendar, index, requested_at)
              end
              next if departures.empty?

              first_stop = direction.stops.first.label
              last_stop = direction.stops.last.label
              via = first_stop == last_stop && direction.stops[1] ? ", preko #{direction.stops[1].label}" : ""
              heading = "smjer #{direction.name}: #{first_stop} → #{last_stop}#{via}"
              { "route" => route.code, "direction" => heading, "source_url" => route.source_url, "departures" => departures }
            end
          end
          { status: directions.empty? ? "empty" : "ok", warnings: directions.empty? ? ["no_departures_published_for_service_day"] : [], directions: }
        end
      end

      private

      attr_reader :fetcher, :text_extractor, :clock, :cache, :timeout, :stop_registry, :source_validator

      def observe_routing_span(observer, phase, started, **counts)
        return unless observer

        duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round(3)
        observer.call(phase:, status: "ok", duration_ms:, **counts)
      rescue StandardError
        nil # Aggregate diagnostics must not affect route calculation.
      end

      def prepared_tool_reader?
        @prepared_only && source_validator.respond_to?(:call)
      end

      def prepared_stop_revision(sources, rows)
        identities = rows.map { |row| [transport_stop_id(row), row.label] }.uniq.sort
        Digest::SHA256.hexdigest(JSON.generate([sources, identities]))
      end

      def prepared_tool_entry(notice)
        return unless source_validator.call(notice.url, notice.source_key) == true

        reviewed = ReviewedTransportTimetables.entry_for(notice.url)
        payload = prepared_document(notice)
        return unless reviewed && payload && payload["content_hash"] == reviewed.dig("timetable", "sha256")

        observed = Time.iso8601(payload.fetch("checked_at"))
        return unless observed <= clock.call && observed >= clock.call - MATERIALIZATION_MAX_AGE

        revision = prepared_payload_revision(notice, payload)
        route = cached_reviewed_route(notice, payload, revision:)
        return if route.directions.empty?
        source = {
          "document_id" => document_key(notice),
          "revision" => revision,
          "source_url" => notice.url, "observed_at" => observed.iso8601,
          "review_expires_at" => (observed + MATERIALIZATION_MAX_AGE).iso8601, "route_code" => route.code
        }
        { route: route, source: source }
      end

      def structured_query(origin:, destination:, notices:, requested_at:, route_code:, location:, deadline:, service_day_kind:, # rubocop:disable Metrics/CyclomaticComplexity, Metrics/ParameterLists, Metrics/PerceivedComplexity
                           mode: :next, roll_over: false, options: 1, strict: false, prepared_routes: nil, direct_only: false, same_day_only: false)
        destination = canonical_stop_phrase(destination).presence
        return StructuredQuery.new(status: :ambiguous, warnings: ["transport_destination_required"]) unless destination

        requested_at = normalized_requested_at(requested_at)
        mode = mode.to_s == "last" ? :last : :next
        options = options.to_i.clamp(1, MAX_OPTIONS)
        if service_day_kind && !PublicTransportCalendar::LABELS.has_key?(service_day_kind.to_s)
          return StructuredQuery.new(status: :unavailable, warnings: ["unsupported_service_calendar"], destination:)
        end

        origin_candidates = nil
        origin = canonical_stop_phrase(origin).presence
        return StructuredQuery.new(status: :ambiguous, warnings: ["transport_same_stop"], origin:, destination:) if origin.present? && origin == destination

        if origin.nil?
          origin_candidates = nearest_stops_for(location)
          return StructuredQuery.new(status: :ambiguous, warnings: ["current_turn_location_required"], destination:) if origin_candidates == :location_required
          return StructuredQuery.new(status: :ambiguous, warnings: ["reviewed_origin_stop_required"], destination:) if origin_candidates.blank?

          origin = origin_candidates.first.label
        end

        scoped_notices = Array(notices).select { |notice| notice.source_key == "public_transport" }
        normalized_route = route_code_from(route_code)
        scoped_notices = scoped_notices.select { |notice| route_code_for(notice) == normalized_route } if normalized_route
        routes = prepared_routes || route_matrix(scoped_notices, request: { origin:, destination:, earliest_after: requested_at, service_day_kind: }, deadline:)
        return StructuredQuery.new(status: :unavailable, warnings: ["prepared_timetable_unavailable"], origin:, destination:) if routes.empty?

        origin = printed_endpoint_phrase(routes, origin)
        destination = printed_endpoint_phrase(routes, destination)

        override_status = reviewed_calendar_override_status(routes, service_day_kind, requested_at)
        return StructuredQuery.new(status: override_status.first, warnings: [override_status.last], origin:, destination:) if override_status

        if service_day_kind && routes.all? { |route| route.directions.empty? }
          calendar_status = service_calendar_status(routes, requested_at, service_day_kind)
          if calendar_status
            return StructuredQuery.new(status: calendar_status.first, warnings: [calendar_status.last], origin:, destination:,
                                       requested_service_date: local_service_date(requested_at).iso8601)
          end
        end

        requested_service_date = local_service_date(requested_at).iso8601
        # An explicit calendar kind has already filtered the directions; a
        # missing holiday section must read as an unsupported day, not as
        # unknown places.
        origin_phrase = origin_candidates ? nil : origin
        unmatched = service_day_kind ? [] : unmatched_places(routes, origin_phrase, destination)
        if unmatched.any?
          return StructuredQuery.new(status: :empty, warnings: ["no_reviewed_journey_match"] + unmatched.map { |place| "#{place}_not_in_reviewed_timetable" },
                                     origin:, destination:, unmatched:, requested_service_date:)
        end

        unless routes.any? { |route| route.directions.any? { |direction| direction.stops.any? { |stop| structured_destination_matches?(destination, stop.label) } } }
          return StructuredQuery.new(status: :ambiguous, warnings: ["transport_destination_required"], origin:, destination:, requested_service_date:)
        end

        ambiguity = endpoint_ambiguity(routes, origin_phrase, destination)
        if ambiguity
          endpoint, candidates = ambiguity
          return StructuredQuery.new(status: :ambiguous, warnings: ["transport_#{endpoint}_ambiguous"], candidates:,
                                     origin:, destination:, requested_service_date:)
        end

        if same_reviewed_endpoint?(routes, origin_phrase, destination)
          return StructuredQuery.new(status: :ambiguous, warnings: ["transport_same_stop"], origin:, destination:, requested_service_date:)
        end

        # The calendar gate is judged on the routes that actually serve the
        # requested places: one reviewed line elsewhere must not hide that
        # every line between them is still under review for the requested day.
        status_routes = routes.select do |route|
          route_serves?(route, destination) && (origin_phrase.nil? || route_serves?(route, origin_phrase))
        end.presence || routes
        earliest = requested_at
        rollover_warnings = []
        request = nil
        selection = []
        attempts = roll_over && service_day_kind.nil? ? MAX_ROLLOVER_DAYS : 1
        attempts.times do |attempt|
          last_attempt = attempt == attempts - 1
          calendar_status = service_calendar_status(status_routes, earliest, service_day_kind)
          if calendar_status
            # Only a day whose sections are published empty (a Sunday) is
            # skipped, and only while rolling over; an unreviewed or
            # unsupported day is reported, never stepped over.
            unless roll_over && calendar_status.first == :empty && !last_attempt
              return StructuredQuery.new(status: calendar_status.first, warnings: [calendar_status.last], origin:, destination:, requested_service_date:)
            end

            rollover_warnings << calendar_status.last
            earliest = next_service_day_start(earliest)
            next
          end

          request = {
            origin:,
            destination:,
            earliest_after: earliest,
            strict: strict && attempt.zero?,
            direct_only: direct_only,
            same_day_only: same_day_only,
            prefer_departure: origin_candidates.nil?,
            origin_candidates:,
            origin_location: (location_coordinates(location) if origin_candidates)
          }
          request = request_with_matched_origin(routes, request)
          if request[:clarification]
            if roll_over && !last_attempt
              earliest = next_service_day_start(earliest)
              next
            end
            return StructuredQuery.new(
              status: :ambiguous,
              warnings: ["origin_stop_not_in_reviewed_timetable"],
              candidates: structured_stop_candidates(origin_candidates),
              origin:,
              destination:,
              requested_service_date:
            )
          end

          selection = structured_selection(routes, request, mode:, options:, day: local_service_date(earliest))
          break if selection.any?

          earliest = next_service_day_start(earliest)
        end

        itinerary = selection.first
        unless itinerary
          expected = service_day_kind.to_s.presence || calendar_kind_for_routes(routes, requested_at)
          incomplete = routes.any? do |route|
            route.calendars && Array(route.calendars).none? do |entry|
              entry["kind"] == expected && %w(available no_departures_published).include?(entry["status"])
            end
          end
          return StructuredQuery.new(status: incomplete ? :unavailable : :empty,
                                     warnings: (incomplete ? ["partial_service_calendar_coverage"] : %w(no_reviewed_journey_match no_feasible_journey_within_transfer_limit)) +
                                       rollover_warnings,
                                     origin: request ? request[:origin] : origin, destination:, requested_service_date:)
        end
        unless structured_destination_matches?(destination, itinerary.legs.last.destination_label)
          return StructuredQuery.new(status: :ambiguous, warnings: ["transport_destination_required"], origin: request[:origin], destination:, requested_service_date:)
        end

        alternatives = selection.drop(1).select { |candidate| structured_destination_matches?(destination, candidate.legs.last.destination_label) }
        used_codes = [itinerary, *alternatives].flat_map { |candidate| candidate.legs.map(&:route_code) }.uniq
        used_routes = routes.select { |route| used_codes.include?(route.code) }
        sources = used_routes.flat_map { |route| [route.source_url, ReviewedTransportTimetables.entry_for(route.source_url)&.dig("map", "url")] }.compact.uniq
        selected_origin = Array(origin_candidates).find { |candidate| candidate.label == request[:origin] }
        warnings = structured_transport_warnings(selected_origin)
        warnings |= ["assumed_stop_coordinates"] if itinerary.legs.first.origin_stop&.coordinates_accuracy == "assumed"
        warnings << "service_calendar_date_not_verified" if service_day_kind && !reviewed_calendar?(routes)
        searched_day = itinerary.legs.first.departure_at
        expected_calendar = service_day_kind.to_s.presence || calendar_kind_for_routes(routes, searched_day)
        calendar_entries = routes.flat_map { |route| Array(route.calendars) }
        warnings << "partial_service_calendar_coverage" if calendar_entries.any? { |entry| entry["kind"] == expected_calendar && entry["status"] == "unreviewed" }
        service_date = local_service_date(searched_day).iso8601
        StructuredQuery.new(
          status: :ok,
          itinerary:,
          alternatives:,
          sources:,
          warnings: warnings + rollover_warnings,
          candidates: structured_stop_candidates(origin_candidates),
          boarding_stop: structured_boarding_stop(selected_origin, itinerary),
          origin: request[:origin],
          destination:,
          destination_scope: destination_scope(routes, destination),
          requested_service_date:,
          service_date:,
          rolled_over: service_date > requested_service_date
        )
      end

      # The single-departure path keeps its exact search count (a matched
      # nearest-stop origin reuses the itinerary found while ranking stops).
      # Two options or a last-departure request rank every supported
      # itinerary once, then choose from that list.
      def structured_selection(routes, request, mode:, options:, day:)
        if mode == :next && options == 1
          itinerary = request[:selected_itinerary] || best_itinerary(routes, request)
          return itinerary ? [itinerary] : []
        end

        ranked = ranked_itineraries(routes, request)
        return [] if ranked.empty?

        # Nothing left on the requested day falls through to the first
        # departure that exists, which the caller reports as rolled over.
        last = last_departure_of_day(ranked, day) if mode == :last
        last ? [last] : distinct_options(ranked, options)
      end

      def last_departure_of_day(ranked, day)
        same_day = ranked.select { |candidate| local_service_date(candidate.legs.first.departure_at) == day }
        same_day.max_by { |candidate| [candidate.legs.first.departure_at, -candidate.legs.last.arrival_at.to_i] }
      end

      # A second option boards where the first one does (a citizen stands at
      # one stop) and never repeats the same minute on another line.
      def distinct_options(ranked, options)
        first = ranked.first
        same_stop = ranked.select { |candidate| candidate.legs.first.origin_label == first.legs.first.origin_label }
        (same_stop.size > 1 ? same_stop : ranked).uniq { |candidate| candidate.legs.first.departure_at }.first(options)
      end

      # A locality can be a destination area, but cannot silently choose a
      # citizen's boarding point. Present distinct printed stops for selection.
      def endpoint_ambiguity(routes, origin, destination)
        rows = routes.flat_map { |route| route.directions.flat_map(&:stops) }
        { "origin" => origin, "destination" => destination }.each do |endpoint, phrase|
          next unless clarify_endpoint?(endpoint, phrase)

          stops = matching_stops(rows, phrase).uniq(&:normalized_label)
          next unless stops.size > 1

          # Named landmarks are useful discriminators; numbered anonymous
          # placeholders remain choices only after equally plausible named stops.
          stops = stops.each_with_index.sort_by { |stop, index| [stop.normalized_label.match?(/\A(?:n n|nn)\b/) ? 1 : 0, index] }.map(&:first)
          candidates = stops.first(5).map do |stop|
            { "id" => "transport_choice:#{Digest::SHA256.hexdigest(stop.label)[0, 12]}", "kind" => "transport_stop",
              "text" => stop.label, "coverage" => { "endpoint" => endpoint }, "source_label" => "Objavljena stajališta u redu vožnje" }
          end
          return [endpoint, candidates]
        end
        nil
      end

      # Inflected aliases can name one printed stop without being equal text.
      # Reject only unique, equal source identities; broad areas and GPS-derived
      # nearby origin candidates retain their separate planner semantics.
      def same_reviewed_endpoint?(routes, origin, destination)
        return false if origin.blank?

        stops = routes.flat_map { |route| route.directions.flat_map(&:stops) }
        origins = matching_stops(stops, origin).map(&:normalized_label).uniq
        destinations = matching_stops(stops, destination).map(&:normalized_label).uniq
        origins.one? && origins == destinations
      end

      def clarify_endpoint?(endpoint, phrase)
        phrase.present? && (endpoint == "origin" || normalized_text(phrase).match?(/\b(?:skola|stanica|crkva|spomenik|raskrsnica|most|ambulanta)\b/))
      end

      def destination_scope(routes, destination)
        stops = routes.flat_map { |route| route.directions.flat_map(&:stops) }
        matching_stops(stops, destination).map(&:normalized_label).uniq.one? ? "stop" : "area"
      end

      def unmatched_places(routes, origin, destination)
        stops = routes.flat_map { |route| route.directions.flat_map(&:stops) }
        places = []
        places << "origin" if origin && matching_stops(stops, origin).empty?
        places << "destination" if matching_stops(stops, destination).empty?
        places
      end

      def printed_endpoint_phrase(routes, phrase)
        return phrase if phrase.is_a?(BoundStopPhrase)

        normalized = normalized_text(phrase)
        stop = routes.lazy.flat_map(&:directions).flat_map(&:stops).find { |row| row.normalized_label == normalized }
        stop ? ExactStopPhrase.new(stop.label).freeze : phrase
      end

      def route_serves?(route, phrase)
        route.directions.any? { |direction| matching_stops(direction.stops, phrase).any? }
      end

      def local_service_date(time)
        time.in_time_zone(SERVICE_TIME_ZONE).to_date
      end

      def next_service_day_start(time)
        date = local_service_date(time) + 1
        ActiveSupport::TimeZone[SERVICE_TIME_ZONE].local(date.year, date.month, date.day)
      end

      def normalized_requested_at(value)
        return clock.call if value.nil?
        raise ArgumentError, "requested_at must be time-like" unless value.respond_to?(:to_time)

        value.to_time.in_time_zone
      end

      def structured_stop_candidates(candidates)
        Array(candidates).first(5).map do |candidate|
          {
            "id" => transport_stop_id(candidate),
            "kind" => "transport_stop",
            "text" => candidate.label,
            "source_label" => candidate.source,
            "coverage" => {
              "distance_meters" => candidate.distance_meters.round,
              "coordinate_accuracy" => candidate.accuracy
            },
            "warning_codes" => (candidate.accuracy == "assumed" ? ["assumed_stop_coordinates"] : [])
          }
        end
      end

      def structured_transport_warnings(origin)
        warnings = %w(timetable_not_live_vehicle_status provider_named_calendar_sections holiday_exceptions_unverified school_day_exceptions_unverified)
        expected = ReviewedTransportTimetables.stop_locations.map { |row| normalized_text(row.fetch("label")) }.uniq
        warnings << "stop_registry_partial" if (expected - stop_registry.map(&:normalized_label)).any?
        return warnings unless origin

        warnings << "walking_distance_is_approximate"
        warnings << "assumed_stop_coordinates" if origin.accuracy == "assumed"
        warnings
      end

      def structured_boarding_stop(stop, itinerary)
        stop = mapped_boarding_stop(itinerary.legs.first.origin_stop) || stop
        unless stop
          # Text-origin journeys still select a concrete public boarding row.
          # Only a unique exact registry label may supply its navigation; do
          # not guess a nearby stop or treat textual origin as citizen GPS.
          label = normalized_text(itinerary.legs.first.origin_label)
          matches = stop_registry.select { |anchor| anchor.normalized_label == label }
          stop = matches.first if matches.one?
        end
        return unless stop && normalized_text(stop.label) == normalized_text(itinerary.legs.first.origin_label)

        navigation_stop_fact(stop)
      end

      def mapped_boarding_stop(row)
        return unless @use_map_coordinates && row&.latitude && row.longitude

        StopAnchor.new(label: row.label, normalized_label: row.normalized_label, latitude: row.latitude, longitude: row.longitude,
                       source: row.coordinates_source, accuracy: row.coordinates_accuracy)
      end

      def structured_destination_matches?(destination, label)
        normalized = normalized_text(destination)
        return normalized_text(label) == normalized if exact_stop_label_query?(destination)
        return center_stop?(label) if CENTER_QUERY_TERMS.include?(normalized)

        # Existing search uses permissive token matching. Do not present its
        # selected row as an answer unless it supports the whole place query.
        terms = meaningful_terms(destination)
        label_terms = meaningful_terms(label)
        terms.any? && terms.all? do |term|
          label_terms.include?(term)
        end
      end

      def navigation_stop_fact(stop)
        return if stop&.source.blank?

        latitude = normalized_coordinate(stop.latitude, -90, 90)
        longitude = normalized_coordinate(stop.longitude, -180, 180)
        return if latitude.nil? || longitude.nil?

        # Only the public boarding point belongs in the link. Maps can request
        # a start location when opened; never retain the citizen's coordinates.
        query = URI.encode_www_form(api: "1", destination: coordinate_pair(latitude, longitude), travelmode: "walking")
        {
          "id" => transport_stop_id(stop), "kind" => "transport_stop", "text" => stop.label,
          "source_id" => "public_transport_stop_registry",
          "source_label" => "Registar stajališta javnog prevoza",
          "source_url" => stop.source,
          "coverage" => { "coordinate_accuracy" => stop.accuracy },
          "warning_codes" => (stop.accuracy == "assumed" ? ["assumed_stop_coordinates"] : []),
          "destination" => "#{GOOGLE_MAPS_DIRECTIONS_URL}?#{query}"
        }
      end

      def transport_stop_id(stop)
        identity = @use_map_coordinates && stop.latitude && stop.longitude ? [stop.label, coordinate_pair(stop.latitude, stop.longitude)].join("|") : stop.label.to_s
        "transport_stop:#{Digest::SHA256.hexdigest(identity)[0, 12]}"
      end

      def default_map_registry?(options)
        !options.has_key?(:stop_registry) && options[:stop_registry_path].blank?
      end

      def navigation_anchors
        return stop_registry unless @use_map_coordinates

        @navigation_anchors ||= (stop_registry + ReviewedTransportTimetables.stop_locations.map do |point|
          StopAnchor.new(label: point.fetch("label"), normalized_label: normalized_text(point.fetch("label")),
                         latitude: point.fetch("latitude"), longitude: point.fetch("longitude"), source: point.fetch("image_url"),
                         accuracy: point.fetch("accuracy"), confidence: point.fetch("confidence"), nearest_priority: registry_stop_for(point.fetch("label"))&.nearest_priority)
        end).uniq { |stop| [stop.label, coordinate_pair(stop.latitude, stop.longitude)] }
      end

      def specific_transport_answer(folded, notices, location:)
        nearest_stop_answer(folded, location) || journey_answer(folded, notices, location:)
      end

      def scheduled_departure_answer(folded, notices)
        return nil unless next_bus_intent?(folded)

        candidates = matching_notices(folded, notices)
        return nil if candidates.empty?

        results = candidates.first(4).filter_map { |notice| result_for_notice(notice, folded) }.sort_by(&:departure_at)
        return nil if results.empty?

        format_results(results.first(3))
      end

      def next_bus_intent?(folded)
        folded.match?(ROUTE_CODE_PATTERN) ||
          folded.include?("sljed") ||
          folded.include?("sledec") ||
          folded.include?("polazak") ||
          folded.include?("kada ide") ||
          folded.include?("kad ide") ||
          folded.include?("iz centra")
      end

      def nearest_stop_answer(folded, location)
        return nil unless nearest_stop_intent?(folded)

        candidates = nearest_stops_for(location)
        return location_required_answer if candidates == :location_required
        return stop_required_answer if candidates.blank?

        nearest = candidates.first
        text = "#{nearest_stop_kind(nearest).capitalize} stajalište koje trenutno mogu koristiti u redu vožnje je " \
               "#{nearest_stop_description(nearest)}. Smjer zavisi od odredišta; za rutu napiši odredište, " \
               "npr. kako odavde do Dvorova gradskim prevozom."
        answer_text(text, quick_replies: [walking_directions_chip(location_coordinates(location), nearest)].compact)
      end

      def nearest_stop_intent?(folded)
        location_reference?(folded) && stop_reference?(folded) && nearest_stop_action?(folded)
      end

      def location_reference?(folded)
        LOCATION_REFERENCE_TERMS.any? { |term| folded.include?(fold(term)) }
      end

      def stop_reference?(folded)
        folded.include?("stanic") ||
          folded.include?("stajalist") ||
          folded.include?("pocetn") ||
          folded.include?("polazn")
      end

      def nearest_stop_action?(folded)
        folded.include?("najbliz") ||
          folded.include?("predloz") ||
          folded.include?("koristi") ||
          folded.include?("odredi") ||
          folded.include?("nadji") ||
          folded.include?("pronadji") ||
          folded.include?("koja") ||
          folded.include?("pocetn") ||
          folded.include?("polazn")
      end

      def journey_answer(folded, notices, location:) # rubocop:disable Metrics/CyclomaticComplexity
        request = journey_request(folded, location:)
        return nil unless request
        return request_clarification(request) if request_clarification(request)

        scoped_notices = Array(notices).select { |notice| notice.source_key == "public_transport" }
        return nil if scoped_notices.empty?

        routes = route_matrix(scoped_notices, request:)
        return nil if routes.empty?
        return service_day_unavailable_answer if service_calendar_status(routes, request.fetch(:earliest_after))

        request = request_with_matched_origin(routes, request)
        return request_clarification(request) if request_clarification(request)

        itinerary = request[:selected_itinerary] || best_itinerary(routes, request)
        return nil unless itinerary

        format_itinerary(itinerary, request:)
      end

      def request_clarification(request)
        request[:clarification].presence
      end

      def best_itinerary(routes, request)
        ranked_itineraries(routes, request).first
      end

      # Direct connections first; transfers only when no direct leg exists.
      # The sort is stable so equal scores keep the timetable's route order.
      def ranked_itineraries(routes, request)
        itineraries = requested_day_itineraries(direct_itineraries(routes, request), request)
        itineraries = requested_day_itineraries(transfer_itineraries(routes, request), request) if itineraries.empty? && !request[:direct_only]
        itineraries.each_with_index.sort_by { |candidate, index| [itinerary_score(candidate, request:), index] }.map(&:first)
      end

      def requested_day_itineraries(itineraries, request)
        supported = supported_itineraries(itineraries)
        return supported unless request[:same_day_only]

        supported.select { |candidate| local_service_date(candidate.legs.first.departure_at) == local_service_date(request.fetch(:earliest_after)) }
      end

      def supported_itineraries(itineraries)
        itineraries.reject do |itinerary|
          itinerary.legs.any? { |leg| !PublicTransportCalendar.supports_date?(leg.calendar, leg.departure_at) }
        end
      end

      def journey_request(folded, location:)
        return nil unless journey_intent?(folded)

        origin, destination = origin_destination_from_patterns(folded)
        return nil unless origin && destination
        return nil if origin == destination

        origin_hint = nil
        candidates = nil
        if here_origin?(origin)
          candidates = nearest_stops_for(location)
          return { clarification: location_required_answer } if candidates == :location_required
          return { clarification: stop_required_answer } if candidates.blank?

          origin = candidates.first.label
          origin_hint = nearest_stop_hint(candidates.first)
        end

        {
          origin:,
          destination:,
          earliest_after: requested_earliest_after(folded),
          prefer_departure: next_journey_intent?(folded),
          origin_hint:,
          origin_candidates: candidates,
          origin_location: candidates ? location_coordinates(location) : nil
        }
      end

      def journey_intent?(folded)
        return false if folded.blank?

        origin_marker?(folded) && destination_marker?(folded) && journey_action?(folded)
      end

      def origin_marker?(folded)
        folded.include?(" od ") || folded.start_with?("od ") ||
          folded.include?(" iz ") || folded.start_with?("iz ") ||
          HERE_ORIGIN_TERMS.any? { |term| folded.include?(term) }
      end

      def destination_marker?(folded)
        folded.include?(" do ") || folded.include?(" u ") || folded.include?(" za ")
      end

      def journey_action?(folded)
        JOURNEY_TERMS.any? { |term| folded.include?(fold(term)) }
      end

      def next_journey_intent?(folded)
        folded.include?("sljed") ||
          folded.include?("sledec") ||
          folded.include?("kada") ||
          folded.include?("kad")
      end

      def origin_destination_from_patterns(folded)
        here_origin_destination_from_patterns(folded) ||
          explicit_origin_destination_from_patterns(folded) ||
          [nil, nil]
      end

      def here_origin_destination_from_patterns(folded)
        HERE_ORIGIN_TERMS.each do |term|
          normalized_term = normalized_text(term)
          destination = here_origin_destination(folded, normalized_term)
          return [normalized_term, destination] if destination
        end

        nil
      end

      def here_origin_destination(folded, normalized_term)
        here_origin_patterns(normalized_term).each do |pattern|
          next unless (match = folded.match(pattern))

          destination = clean_query_phrase(match[1])
          return destination if destination
        end

        nil
      end

      def here_origin_patterns(normalized_term)
        escaped = Regexp.escape(normalized_term)
        [
          /\b#{escaped}\s+do\s+(.+)\z/,
          /\b#{escaped}\s+(?:u|za)\s+(.+)\z/,
          /\b#{escaped}\b.+?\b(?:do|u|za)\s+(.+)\z/,
          /\bdo\s+(.+?)\s+#{escaped}\z/,
          /\b(?:u|za)\s+(.+?)\s+#{escaped}\z/
        ]
      end

      def explicit_origin_destination_from_patterns(folded)
        [
          /\bod\s+(.+?)\s+do\s+(.+)\z/,
          /\biz\s+(.+?)\s+(?:do|u|za)\s+(.+)\z/
        ].each do |pattern|
          next unless (match = folded.match(pattern))

          origin = clean_query_phrase(match[1])
          destination = clean_query_phrase(match[2])
          return [origin, destination] if origin && destination
        end

        [nil, nil]
      end

      def clean_query_phrase(value)
        normalized_text(value)
          .split
          .reject { |token| QUERY_PHRASE_STOPWORDS.include?(token) }
          .join(" ")
          .presence
      end

      def here_origin?(origin)
        normalized = normalized_text(origin)
        HERE_ORIGIN_TERMS.any? { |term| normalized.include?(normalized_text(term)) }
      end

      def nearest_stops_for(location)
        coordinates = location_coordinates(location)
        return :location_required unless coordinates
        return [] if stop_registry.empty?

        stops = navigation_anchors.map do |anchor|
          NearestStop.new(
            label: anchor.label,
            distance_meters: distance_meters(
              coordinates.fetch(:latitude),
              coordinates.fetch(:longitude),
              anchor.latitude,
              anchor.longitude
            ),
            source: anchor.source,
            accuracy: anchor.accuracy,
            confidence: anchor.confidence,
            latitude: anchor.latitude,
            longitude: anchor.longitude,
            nearest_priority: anchor.nearest_priority
          )
        end
        stops.select { |stop| stop.distance_meters <= NEAREST_STOP_MAX_DISTANCE_METERS }
             .sort_by(&:distance_meters)
             .uniq(&:label)
             .then { |sorted| prioritize_nearby_boarding_stop(sorted) }
      end

      def prioritize_nearby_boarding_stop(stops)
        return stops if stops.empty?

        nearest_distance = stops.first.distance_meters
        priority_band = stops.select do |stop|
          stop.distance_meters <= nearest_distance + NEAREST_STOP_PRIORITY_DISTANCE_DELTA_METERS
        end
        preferred = priority_band.max_by { |stop| [stop.nearest_priority.to_i, -stop.distance_meters] }
        return stops if preferred.nil? || preferred == stops.first

        [preferred] + (stops - [preferred])
      end

      def location_coordinates(location)
        return nil unless location.respond_to?(:[])

        latitude = coordinate_value(location, -90, 90, :latitude, :lat)
        longitude = coordinate_value(location, -180, 180, :longitude, :lon, :lng)
        return nil if latitude.nil? || longitude.nil?

        { latitude:, longitude: }
      end

      def coordinate_value(location, min, max, *keys)
        value = keys.filter_map { |key| location[key] || location[key.to_s] }.first
        numeric = Float(value)
        numeric.between?(min, max) ? numeric : nil
      rescue ArgumentError, TypeError
        nil
      end

      def distance_meters(lat1, lon1, lat2, lon2)
        phi1 = radians(lat1)
        phi2 = radians(lat2)
        delta_phi = radians(lat2 - lat1)
        delta_lambda = radians(lon2 - lon1)
        a = (Math.sin(delta_phi / 2)**2) +
            (Math.cos(phi1) * Math.cos(phi2) * (Math.sin(delta_lambda / 2)**2))
        EARTH_RADIUS_METERS * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a))
      end

      def radians(value)
        value.to_f * Math::PI / 180.0
      end

      def load_stop_registry(path)
        registry_path = path.presence || default_stop_registry_path
        return [] if registry_path.blank?

        payload = YAML.safe_load_file(registry_path, permitted_classes: [], aliases: false) || {}
        normalize_stop_registry(payload.fetch("stops", []))
      rescue Psych::Exception => e
        raise ArgumentError, "invalid community stop registry: #{e.class}"
      end

      def default_stop_registry_path
        ENV["MI_TRANSPORT_STOPS_PATH"].presence
      end

      def normalize_stop_registry(entries)
        Array(entries).filter_map do |entry|
          label = entry_value(entry, :label)
          latitude = normalized_coordinate(entry_value(entry, :latitude), -90, 90)
          longitude = normalized_coordinate(entry_value(entry, :longitude), -180, 180)
          next if label.blank? || latitude.nil? || longitude.nil?

          StopAnchor.new(
            label: label.to_s.squish,
            normalized_label: normalized_text(label),
            latitude:,
            longitude:,
            source: entry_value(entry, :source).presence,
            accuracy: normalized_accuracy(entry_value(entry, :accuracy)),
            confidence: entry_value(entry, :confidence).presence,
            nearest_priority: non_negative_integer(entry_value(entry, :nearest_priority))
          )
        end
      end

      def entry_value(entry, key)
        return entry.public_send(key) if entry.respond_to?(key)
        return nil unless entry.respond_to?(:[])

        entry[key] || entry[key.to_s]
      end

      def normalized_coordinate(value, min, max)
        numeric = Float(value)
        numeric.between?(min, max) ? numeric : nil
      rescue ArgumentError, TypeError
        nil
      end

      def normalized_accuracy(value)
        case value.to_s
        when "provided"
          "provided"
        when "assumed"
          "assumed"
        else
          "verified"
        end
      end

      def non_negative_integer(value)
        integer = Integer(value)
        integer.positive? ? integer : 0
      rescue ArgumentError, TypeError
        0
      end

      def registry_stop_for(label)
        normalized = normalized_text(label)
        stop_registry.find { |stop| stop.normalized_label == normalized }
      end

      def nearest_stop_hint(nearest)
        "Koristim #{nearest_stop_kind(nearest)} stajalište: #{nearest_stop_description(nearest)}."
      end

      def nearest_stop_description(nearest)
        "#{nearest.label} (#{nearest_distance_description(nearest)})"
      end

      def nearest_stop_kind(nearest)
        case nearest.accuracy
        when "assumed"
          "najbliže procijenjeno"
        when "provided"
          "najbliže mapirano"
        else
          "najbliže"
        end
      end

      def nearest_distance_description(nearest)
        prefix = nearest.accuracy == "assumed" ? "procijenjeno oko" : "oko"
        "#{prefix} #{nearest.distance_meters.round} m od poslane lokacije"
      end

      def location_required_answer
        "Mogu izračunati rutu odavde, ali treba mi lokacija za ovaj upit. Uključi lokaciju u chatu ili napiši najbliže stajalište/ulicu."
      end

      def stop_required_answer
        "Nemam provjerene koordinate stajališta za ovu lokaciju. Napiši najbliže stajalište ili ulicu, npr. Bijeljina (NAS), pa ću provjeriti vezu."
      end

      def requested_earliest_after(folded)
        now = clock.call.in_time_zone(SERVICE_TIME_ZONE)
        date = folded.include?("sutra") ? now.to_date + 1.day : now.to_date
        hour = requested_hour(folded)
        candidate = hour ? ActiveSupport::TimeZone[SERVICE_TIME_ZONE].local(date.year, date.month, date.day, hour, 0) : now

        if folded.exclude?("sutra") && hour && candidate < now
          candidate + 1.day
        else
          candidate
        end
      end

      def requested_hour(folded)
        normalized = normalized_text(folded)
        return MORNING_HOUR if normalized.match?(/\b(?:jutro|ujutro|ujutru|rano|prijepodne|prepodne)\b/)
        return AFTERNOON_HOUR if normalized.match?(/\b(?:popodne|poslijepodne|poslepodne)\b/)
        return EVENING_HOUR if normalized.match?(/\b(?:vecer|veceras|navece|navecer)\b/)

        nil
      end

      def route_matrix(notices, request:, deadline: nil)
        # A line title is not its stop list. Filtering on titles omits valid
        # transfer legs (ATC is a G2 stop but absent from its route title).
        routes = build_matrix(notices, deadline:)
        return routes unless request[:service_day_kind]

        routes.map do |route|
          selected = route.directions.select { |direction| direction.calendar&.fetch("kind", nil) == request[:service_day_kind].to_s }.map do |direction|
            Direction.new(**direction.to_h,
calendar: direction.calendar.merge("requested_service_date" => request.fetch(:earliest_after).in_time_zone(SERVICE_TIME_ZONE).to_date.iso8601))
          end
          Route.new(**route.to_h, directions: selected)
        end
      end

      def build_matrix(notices, deadline:)
        Array(notices)
          .select { |notice| notice.source_key == "public_transport" }
          .filter_map { |notice| route_from_notice(notice, deadline:) }
      end

      def request_with_matched_origin(routes, request)
        candidates = Array(request[:origin_candidates])
        return request if candidates.empty?

        # All origin candidates share these destination/time inputs. This cache
        # belongs only to this query, never to the reusable timetable instance.
        request = request.merge(transfer_invariants: {}, planner_cache: build_planner_cache)
        match = preferred_origin_candidate(routes, request, candidates)
        return request.merge(clarification: stop_required_answer) unless match

        request.merge(
          origin: match.label,
          origin_hint: nearest_stop_hint(match),
          origin_walking_directions_chip: walking_directions_chip(request[:origin_location], match)
        )
      end

      def preferred_origin_candidate(routes, request, candidates)
        viable_candidates = candidates.filter_map do |candidate|
          candidate_request = route_candidate_request(request, candidate)
          itinerary = best_itinerary(routes, candidate_request)
          next unless itinerary

          [candidate, origin_candidate_score(itinerary, candidate, request: candidate_request), itinerary]
        end

        selected = viable_candidates.min_by(&:second)
        request[:selected_itinerary] = selected&.fetch(2)
        selected&.first
      end

      def origin_candidate_score(itinerary, candidate, request:)
        score = itinerary_score(itinerary, request:)
        if request&.fetch(:prefer_departure, false)
          [score[0], score[1], score[2], candidate.distance_meters]
        else
          [score[0], score[1], candidate.distance_meters, score[2]]
        end
      end

      def route_candidate_request(request, candidate)
        request.merge(origin: candidate.label, origin_candidates: nil)
      end

      def exact_route_stop_index(routes, label)
        expected = normalized_text(label)
        indexes = routes.flat_map do |route|
          route.directions.flat_map do |direction|
            direction.stops.filter_map { |stop| stop.index if stop.normalized_label == expected }
          end
        end
        indexes.min
      end

      def route_has_exact_stop?(routes, label)
        exact_route_stop_index(routes, label).present?
      end

      def candidate_route_notices(notices, request)
        selected = notices.select do |notice|
          notice_matches_phrase?(notice, request.fetch(:origin)) ||
            notice_matches_phrase?(notice, request.fetch(:destination))
        end
        selected.presence || notices
      end

      def route_from_notice(notice, deadline: nil)
        return nil if source_validator && !source_validator.call(notice.url, notice.source_key)

        return route_from_prepared_document(notice) if @prepared_only

        cache_fetch("bijeljina/public-transport-matrix/#{Digest::SHA256.hexdigest(notice.url.to_s)}/#{stop_registry_fingerprint}") do
          text = text_extractor.call(call_fetcher(notice.url, deadline:))
          directions = route_directions_from_text(text, notice)
          next nil if directions.empty?

          Route.new(
            code: route_code_for(notice),
            title: clean_title(notice.title),
            directions:,
            source_url: notice.url
          )
        end
      rescue CityServiceNoticeCollector::DeadlineExceeded, CityServiceNoticeCollector::InvalidDeadline
        raise
      rescue StandardError => e
        Rails.logger.warn("[PublicTransportTimetable] failed to build route matrix for #{notice.url} (#{e.class}: #{e.message})") if defined?(Rails)
        nil
      end

      def stop_registry_fingerprint
        Digest::SHA256.hexdigest(
          stop_registry.map do |stop|
            [stop.normalized_label, stop.latitude, stop.longitude, stop.accuracy, stop.confidence, stop.nearest_priority, stop.source].join(":")
          end.join("|")
        )[0, 16]
      end

      def route_directions_from_text(text, notice, calendar: nil)
        rows = { "A" => [], "B" => [] }
        section = calendar ? text.to_s : workday_section(text)
        reverse_column = section.each_line.filter_map { |line| line.index(/Smjer\s+B\b/i) }.first
        section.each_line do |line|
          parsed_schedule_rows(line).each do |row|
            reverse = reverse_column ? row.fetch(:column) >= reverse_column : row.fetch(:direction_index).positive?
            direction_name = reverse ? "B" : "A"
            registry_stop = registry_stop_for(row.fetch(:label))
            rows.fetch(direction_name) << StopRow.new(
              label: row.fetch(:label),
              normalized_label: normalized_text(row.fetch(:label)),
              times: row.fetch(:times),
              index: rows.fetch(direction_name).size,
              latitude: registry_stop&.latitude,
              longitude: registry_stop&.longitude,
              coordinates_source: registry_stop&.source,
              coordinates_accuracy: registry_stop&.accuracy
            )
          end
        end

        rows.filter_map do |direction_name, stops|
          next if stops.size < 2

          Direction.new(route: notice, name: direction_name, stops:, calendar:)
        end
      end

      def workday_section(text)
        section = text.to_s.split(/\bRadni dan\b/i, 2).last || text.to_s
        section.split(WORKDAY_SECTION_END, 2).first.to_s
      end

      def parsed_schedule_rows(line)
        groups = schedule_groups(line)
        return [] if groups.empty?

        groups.filter_map.with_index do |group, index|
          segment_start = index.zero? ? 0 : groups[index - 1].fetch(:end)
          label = clean_stop_label(line[segment_start...group.fetch(:start)])
          next if label.blank?

          times = group.fetch(:tokens).map { |token| token == "/" ? nil : token }
          next if times.compact.empty?

          { label:, times:, direction_index: index, column: group.fetch(:start) }
        end
      end

      def schedule_groups(line)
        matches = []
        line.to_s.scan(PDF_ROW_TOKEN) do
          matches << {
            token: Regexp.last_match[0],
            start: Regexp.last_match.begin(0),
            end: Regexp.last_match.end(0)
          }
        end
        groups = []
        current = []
        matches.each do |match|
          if current.empty? || line[current.last.fetch(:end)...match.fetch(:start)].to_s.match?(/\A\s+\z/)
            current << match
          else
            groups << current
            current = [match]
          end
        end
        groups << current if current.any?
        groups.map do |group|
          {
            tokens: group.map { |match| match.fetch(:token) },
            start: group.first.fetch(:start),
            end: group.last.fetch(:end)
          }
        end
      end

      def clean_stop_label(segment)
        label = segment.to_s.squish
        label = label.sub(/\A(?:\d+,\d+\s+)+/, "").squish
        label = label.sub(/\s+\d+,\d+\z/, "").squish
        label = label.sub(/\A\d+\s+(?:vozilo|vozila)\s+/i, "").squish
        label = label.sub(/\AMINI\s+/i, "").squish
        label = label.sub(/\ASOLO\s+/i, "").squish
        return nil if label.blank?
        return nil if label.match?(/\A(?:Radni dan|Smjer|Subota|Nedelja|Nedjelja)\b/i)
        return nil unless label.match?(/[[:alpha:]]/)

        label
      end

      def direct_itineraries(routes, request)
        routes.flat_map do |route|
          route.directions.flat_map do |direction|
            leg_candidates(direction, request.fetch(:origin), request.fetch(:destination), earliest_after: request.fetch(:earliest_after),
                                                                                           strict: request[:strict] == true, planner_cache: request[:planner_cache]).map do |leg|
              Itinerary.new(legs: [leg])
            end
          end
        end
      end

      def transfer_itineraries(routes, request)
        invariants = request.fetch(:transfer_invariants, {})
        transfer_points = invariants[:transfer_points] ||= transfer_points_for_destination(routes, request.fetch(:destination))
        second_leg_index = invariants[:second_leg_index] ||= second_transfer_leg_index(routes, request.fetch(:destination), earliest_after: request.fetch(:earliest_after))
        first_legs = routes.flat_map do |route|
          route.directions.flat_map do |direction|
            leg_candidates(
              direction,
              request.fetch(:origin),
              nil,
              earliest_after: request.fetch(:earliest_after),
              destination_rows: cached_transfer_destination_rows(direction, transfer_points, request[:planner_cache]),
              strict: request[:strict] == true, planner_cache: request[:planner_cache]
            )
          end
        end
        first_legs.flat_map do |first_leg|
          transfer_after = first_leg.arrival_at + TRANSFER_BUFFER_SECONDS
          second_legs = second_transfer_legs_for(second_leg_index, first_leg.destination_label).select do |second_leg|
            next false if second_leg.departure_at < transfer_after

            (second_leg.departure_at - first_leg.arrival_at) <= MAX_TRANSFER_WAIT_SECONDS
          end
          second_legs.map { |second_leg| Itinerary.new(legs: [first_leg, second_leg]) }
        end
      end

      def second_transfer_leg_index(routes, destination_phrase, earliest_after:)
        second_transfer_leg_pool(routes, destination_phrase, earliest_after:).each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |leg, index|
          index[normalized_text(leg.origin_label)] << leg
        end
      end

      def second_transfer_legs_for(index, transfer_label)
        index[normalized_text(transfer_label)]
      end

      def second_transfer_leg_pool(routes, destination_phrase, earliest_after:)
        legs = routes.flat_map do |route|
          route.directions.flat_map do |direction|
            second_transfer_legs(direction, destination_phrase, earliest_after:)
          end
        end
        legs + legs.map { |leg| shift_leg(leg, 1.day) }
      end

      def second_transfer_legs(direction, destination_phrase, earliest_after:)
        matching_stops(direction.stops, destination_phrase).flat_map do |destination|
          direction.stops.select { |origin| origin.index < destination.index }.flat_map do |origin|
            legs_from_rows(direction, origin, destination, earliest_after:)
          end
        end
      end

      def shift_leg(leg, seconds)
        Leg.new(
          route_code: leg.route_code,
          route_title: leg.route_title,
          source_url: leg.source_url,
          origin_label: leg.origin_label,
          origin_stop: leg.origin_stop,
          destination_label: leg.destination_label,
          destination_stop: leg.destination_stop,
          departure_at: leg.departure_at + seconds,
          arrival_at: leg.arrival_at + seconds,
          direction_label: leg.direction_label,
          calendar: leg.calendar
        )
      end

      def transfer_points_for_destination(routes, destination_phrase)
        labels = []
        routes.each do |route|
          route.directions.each do |direction|
            matching_stops(direction.stops, destination_phrase).each do |destination|
              direction.stops.each do |stop|
                next unless stop.index < destination.index

                labels << normalized_text(stop.label)
              end
            end
          end
        end

        { labels: labels.uniq }
      end

      def transfer_destination_rows(direction, transfer_points)
        labels = transfer_points.fetch(:labels)
        direction.stops.select { |stop| labels.include?(normalized_text(stop.label)) }
      end

      def transfer_leg_candidates(direction, transfer_label, destination_phrase, earliest_after:)
        origin_rows = transfer_origin_stops(direction.stops, transfer_label)
        destination_rows = matching_stops(direction.stops, destination_phrase)
        origin_rows.product(destination_rows).flat_map do |origin, destination|
          next [] unless origin.index < destination.index
          next [] if normalized_text(origin.label) == normalized_text(destination.label)

          legs_from_rows(direction, origin, destination, earliest_after:)
        end
      end

      def transfer_origin_stops(stops, transfer_label)
        normalized_transfer_label = normalized_text(transfer_label)
        Array(stops).select { |stop| normalized_text(stop.label) == normalized_transfer_label }
      end

      # The cache is created for one nearby-origin search and passed explicitly.
      # Its inputs (route objects, destination, date and strictness) never escape
      # that search; concurrent calls on this reader cannot share derived rows.
      def build_planner_cache
        { phrases: {}, terms: {}, matches: {}, transfer_rows: {}.compare_by_identity }
      end

      def planner_matching_stops(stops, phrase, cache)
        return matching_stops(stops, phrase) unless cache

        # ExactStopPhrase has stronger identity semantics than the same String.
        phrase_key = [phrase.class, phrase, (phrase.stop_id if phrase.is_a?(BoundStopPhrase))]
        key = [stops.object_id, phrase_key]
        cache.fetch(:matches)[key] ||= begin
          details = cache.fetch(:phrases)[phrase_key] ||= stop_match_details(phrase)
          matching_stops_from_details(stops, details, term_cache: cache.fetch(:terms))
        end
      end

      def cached_transfer_destination_rows(direction, transfer_points, cache)
        return transfer_destination_rows(direction, transfer_points) unless cache

        cache.fetch(:transfer_rows)[direction] ||= transfer_destination_rows(direction, transfer_points)
      end

      def leg_candidates(direction, origin_phrase, destination_phrase, earliest_after:, destination_rows: nil, strict: false, planner_cache: nil) # rubocop:disable Metrics/ParameterLists
        origin_rows = planner_matching_stops(direction.stops, origin_phrase, planner_cache)
        destination_rows ||= destination_phrase.present? ? planner_matching_stops(direction.stops, destination_phrase, planner_cache) : direction.stops
        origin_rows.product(destination_rows).flat_map do |origin, destination|
          next [] unless origin.index < destination.index
          next [] if origin.normalized_label == destination.normalized_label

          legs_from_rows(direction, origin, destination, earliest_after:, strict:)
        end
      end

      def legs_from_rows(direction, origin, destination, earliest_after:, strict: false)
        origin.times.each_index.filter_map do |index|
          departure_text = origin.times[index]
          arrival_text = destination.times[index]
          next if departure_text.blank? || arrival_text.blank?

          departure_at = scheduled_time(departure_text, earliest_after, strict:)
          next unless PublicTransportCalendar.supports_date?(direction.calendar, departure_at)
          next unless ReviewedTransportTimetables.trip_available?(direction.calendar || {}, index, departure_at)

          arrival_at = scheduled_time(arrival_text, departure_at)
          arrival_at += 1.day if arrival_at < departure_at

          Leg.new(
            route_code: route_code_for(direction.route),
            route_title: clean_title(direction.route.title),
            source_url: direction.route.url,
            origin_label: origin.label,
            origin_stop: origin,
            destination_label: destination.label,
            destination_stop: destination,
            departure_at:,
            arrival_at:,
            direction_label: direction_label(direction),
            calendar: direction.calendar
          )
        end
      end

      def direction_label(direction)
        terminal = direction.stops.last&.label
        terminal.present? ? "prema #{terminal}" : direction.name
      end

      # `strict` excludes a departure at exactly `earliest_after`: a bus
      # leaving this minute is not the next one for a citizen asking now.
      def scheduled_time(text, earliest_after, strict: false)
        date = earliest_after.in_time_zone(SERVICE_TIME_ZONE).to_date
        hour, minute = text.to_s.split(":").map(&:to_i)
        candidate = ActiveSupport::TimeZone[SERVICE_TIME_ZONE].local(date.year, date.month, date.day, hour, minute)
        past = strict ? candidate <= earliest_after : candidate < earliest_after
        past ? candidate + 1.day : candidate
      end

      # Short printed stop names are identities, including their spoken case
      # suffix (NAS-a, ATC-u). Never broaden them to all city-centre stops.
      def named_nearest_stop(place, locality: nil)
        matches = matching_stops(stop_registry, canonical_stop_phrase(place))
        if locality.present?
          prefix = "#{normalized_text(locality)} "
          matches = matches.select { |stop| stop.normalized_label.start_with?(prefix) }
        end
        facts = matches.filter_map { |stop| navigation_stop_fact(stop) }
        return StructuredQuery.new(status: :empty, warnings: ["reviewed_origin_stop_required"]) if facts.empty?
        return StructuredQuery.new(status: :ambiguous, candidates: facts.first(5), warnings: ["transport_origin_ambiguous"]) if facts.size > 1

        fact = facts.first
        nearest_stop_presentation(fact,
                                  body: "Stajalište #{matches.first.label}. Položaj je približan; provjeri oznaku na licu mjesta. Za pješački put izaberi početak u mapi",
                                  route_guidance: ", a za izbor autobuske linije napiši odredište", ending: ".")
        StructuredQuery.new(status: :ok, boarding_stop: fact, origin: matches.first.label, warnings: fact.fetch("warning_codes"))
      end

      # Only this optional route-selection invitation may disappear on a
      # brevity request. Stop identity, map guidance and uncertainty stay in body.
      def nearest_stop_presentation(fact, body:, route_guidance:, ending: "")
        fact["navigation_presentation"] = { "body" => body, "route_guidance" => route_guidance, "ending" => ending, "caveat" => "" }
        fact["text"] = "#{body}#{route_guidance}#{ending}"
      end

      def canonical_stop_phrase(phrase)
        return phrase if phrase.is_a?(BoundStopPhrase)

        normalized = normalized_text(phrase)
        nas_name = /(?:nov(?:a|e|u|oj|om) (?:autobusk(?:a|e|u|oj|om)(?: stanic(?:a|e|u|i|om))?|stanic(?:a|e|u|i|om))|nova as|nas)/
        # A recognized full NAS alias may include its parenthesized acronym;
        # parentheses on all other qualified places retain exact-stop semantics.
        return "bijeljina nas" if normalized.match?(/\A(?:bijeljin[aeiu] )?#{nas_name}(?: (?:u )?bijeljin[aeiu])?(?: nas)?\z/)
        return ExactStopPhrase.new(normalized).freeze if exact_stop_label_query?(phrase)

        alias_key = normalized.sub(/\A(nas|atc|ssc)(?: [au])?\z/, '\\1')
        return normalized unless %w(nas atc ssc).include?(alias_key)
        return "bijeljina nas" if alias_key == "nas"

        matches = stop_registry.select do |stop|
          stop.normalized_label == alias_key || stop.normalized_label == "bijeljina #{alias_key}"
        end
        matches.one? ? matches.first.normalized_label : normalized
      end

      def matching_stops(stops, phrase)
        matching_stops_from_details(stops, stop_match_details(phrase))
      end

      def stop_match_details(phrase)
        phrase = canonical_stop_phrase(phrase)
        { normalized: normalized_text(phrase), exact: exact_stop_label_query?(phrase), ids: (phrase.stop_ids if phrase.is_a?(BoundStopPhrase)),
          center: center_query?(phrase), terms: meaningful_terms(phrase) }
      end

      def matching_stops_from_details(stops, details, term_cache: nil)
        # Exact identity is retained across routes, including printed labels
        # without parentheses. An absent exact row must not broaden to an area.
        exact = matching_identity_stops(stops, details)
        return exact if exact.any? || details.fetch(:exact)

        if details.fetch(:center)
          center = Array(stops).select { |stop| center_stop?(stop.label) }
          return center.select { |stop| CENTER_CORE_STOPS.include?(stop.normalized_label) }.presence || center
        end

        matching_stops_with_terms_cache(stops, details.fetch(:terms), term_cache)
      end

      def matching_identity_stops(stops, details)
        return Array(stops).select { |stop| details.fetch(:ids).include?(transport_stop_id(stop)) } if details[:ids]

        Array(stops).select { |stop| stop.normalized_label == details.fetch(:normalized) }
      end

      def matching_stops_with_terms_cache(stops, phrase_terms, term_cache)
        return [] if phrase_terms.empty?

        # Every supplied qualifier matters. Substring OR matching used to turn
        # "nova stanica" into Kojcinovac and discard Janja from "skola u Janji".
        Array(stops).filter_map do |stop|
          label_terms = term_cache ? (term_cache[stop.label] ||= meaningful_terms(stop.label)) : meaningful_terms(stop.label)
          next unless phrase_terms.all? { |term| label_terms.include?(term) }

          [stop, label_terms.size - phrase_terms.size]
        end.sort_by { |_stop, extra| extra }.map(&:first)
      end

      def matching_stops_by_terms(stops, phrase_terms)
        matching_stops_with_terms_cache(stops, phrase_terms, nil)
      end

      def stop_matches_phrase?(stop, phrase)
        details = stop_match_details(phrase)
        return stop.normalized_label == details.fetch(:normalized) if details.fetch(:exact)
        return center_stop?(stop.label) if details.fetch(:center)

        terms = details.fetch(:terms)
        terms.any? && terms.all? { |term| meaningful_terms(stop.label).include?(term) }
      end

      def notice_matches_phrase?(notice, phrase)
        return true if center_query?(phrase)

        phrase_terms = meaningful_terms(phrase)
        title_terms = meaningful_terms(notice.title)
        phrase_terms.any? do |phrase_term|
          title_terms.any? { |title_term| title_term.include?(phrase_term) || phrase_term.include?(title_term) }
        end
      end

      def center_query?(phrase)
        normalized = normalized_text(phrase)
        CENTER_QUERY_TERMS.include?(normalized)
      end

      def exact_stop_label_query?(phrase)
        return true if phrase.is_a?(ExactStopPhrase)

        normalized = normalized_text(phrase)
        return true if stop_registry.any? { |anchor| anchor.normalized_label == normalized }

        phrase.to_s.include?("(") && phrase.to_s.include?(")")
      end

      def center_stop?(label)
        normalized_text(label).start_with?("bijeljina")
      end

      def meaningful_terms(value)
        normalized_text(value)
          .split
          .select { |token| token.length >= 4 || %w(nas atc ssc csp).include?(token) || reviewed_short_stop_terms.include?(token) }
          .reject { |token| transport_stopword?(token) }
          .map { |token| stem(token) }
          .uniq
      end

      # Preserve short names actually present in reviewed stop identities (for
      # example Sud), using the same terms for query and cached row matching.
      # Inflected longer forms still pass through the existing stemmer.
      def reviewed_short_stop_terms
        @reviewed_short_stop_terms ||= stop_registry.flat_map { |stop| stop.normalized_label.split }
                                                   .select { |token| token.length == 3 && !transport_stopword?(token) }
                                                   .uniq.freeze
      end

      def itinerary_score(itinerary, request: nil)
        if request&.fetch(:prefer_departure, false)
          return [
            itinerary.legs.first.departure_at,
            itinerary.legs.last.arrival_at,
            transfer_wait_seconds(itinerary)
          ]
        end

        [
          itinerary.legs.last.arrival_at,
          transfer_wait_seconds(itinerary),
          itinerary.legs.first.departure_at
        ]
      end

      def transfer_wait_seconds(itinerary)
        return 0 if itinerary.legs.size < 2

        itinerary.legs.each_cons(2).sum { |first, second| second.departure_at - first.arrival_at }
      end

      def format_itinerary(itinerary, request: {})
        hint = request[:origin_hint].presence
        text = if itinerary.legs.one?
                 "Najranija direktna veza koju čitam: #{format_leg(itinerary.legs.first)}. " \
                   "Prema zvaničnom redu vožnje i odjeljku za traženi dan; izuzeci za praznike i školski kalendar nisu provjereni."
               else
                 "Najranija veza s presjedanjem koju čitam: #{format_leg(itinerary.legs.first)}; " \
                   "zatim #{format_leg(itinerary.legs.second)}. " \
                   "Presjedanje: #{itinerary.legs.first.destination_label}. " \
                   "Prema zvaničnim PDF redovima vožnje i odjeljcima za traženi dan; izuzeci za praznike i školski kalendar nisu provjereni."
               end
        walking_chip = walking_directions_chip(request[:origin_location], itinerary.legs.first.origin_stop) || request[:origin_walking_directions_chip]
        answer_text(
          [hint, text].compact.join(" "),
          quick_replies: [walking_chip].compact
        )
      end

      def answer_text(text, quick_replies: [])
        quick_replies = quick_replies.compact
        return text if quick_replies.empty?

        AnswerText.new(text, quick_replies:)
      end

      def walking_directions_chip(origin, stop)
        url = walking_directions_url(origin, stop)
        return nil if url.blank?

        { label: "Pješke do stajališta", url: }
      end

      def walking_directions_url(origin, stop)
        return nil unless origin.respond_to?(:[])
        return nil unless stop&.latitude && stop.longitude

        query = URI.encode_www_form(
          api: "1",
          origin: coordinate_pair(origin.fetch(:latitude), origin.fetch(:longitude)),
          destination: coordinate_pair(stop.latitude, stop.longitude),
          travelmode: "walking"
        )
        "#{GOOGLE_MAPS_DIRECTIONS_URL}?#{query}"
      rescue KeyError
        nil
      end

      def coordinate_pair(latitude, longitude)
        "#{format("%.6f", latitude)},#{format("%.6f", longitude)}"
      end

      def format_leg(leg)
        direction = leg.direction_label.present? ? " (smjer #{leg.direction_label})" : ""
        "#{leg.route_code} #{short_route_title(leg)}#{direction}: #{leg.origin_label} u #{display_time(leg.departure_at)} -> " \
          "#{leg.destination_label} oko #{display_time(leg.arrival_at)}"
      end

      def short_route_title(leg)
        leg.route_title.to_s.sub(/\A#{Regexp.escape(leg.route_code)}\s*/i, "").squish
      end

      def display_time(time)
        local_time = time.in_time_zone(SERVICE_TIME_ZONE)
        prefix = local_time.to_date > clock.call.in_time_zone(SERVICE_TIME_ZONE).to_date ? "sutra " : ""
        "#{prefix}#{local_time.strftime("%H:%M")}"
      end

      def matching_notices(folded, notices)
        route_code = route_code_from(folded)
        scoped = Array(notices).select { |notice| notice.source_key == "public_transport" }
        return scoped.select { |notice| route_code_for(notice) == route_code } if route_code

        scored = scoped.map { |notice| [notice, route_score(folded, notice)] }.select { |_notice, score| score.positive? }
        scored.sort_by { |_notice, score| -score }.map(&:first)
      end

      def route_score(folded, notice)
        title = fold(notice.title)
        query_terms(folded).sum do |term|
          route_term_score(title, term)
        end
      end

      def route_term_score(title, term)
        return 2 if title.include?(term)
        return 1 if title.include?(stem(term))

        0
      end

      def query_terms(folded)
        folded.split.select { |token| token.length >= 4 }.reject { |token| transport_stopword?(token) }
      end

      def transport_stopword?(token)
        %w(kada kad ide idu sljedeci sljeddeci sledeci autobus autobusi centra centar grada grad prevoz prijevoz vozni red polazak).include?(token)
      end

      def stem(token)
        token.sub(/(ima|om|em|u|a|e|i)\z/, "")
      end

      def result_for_notice(notice, folded)
        earliest = requested_earliest_after(folded).in_time_zone(SERVICE_TIME_ZONE)
        [earliest.to_date, earliest.to_date + 1.day].filter_map do |date|
          text = timetable_text(notice, at: date)
          next if text.blank?

          origin = row_for_labels(text, origin_labels(folded))
          next unless origin

          destination_options = destination_labels(folded)
          destination = row_for_labels(text, destination_options)
          next if destination_options.any? && destination.nil?

          departure = departures_for(origin.fetch(:times), date, next_day: date > earliest.to_date).find { |candidate| candidate.fetch(:at) >= earliest }
          next unless departure

          timetable_departure_result(notice, origin, destination, departure)
        end.min_by(&:departure_at)
      end

      def timetable_departure_result(notice, origin, destination, departure)
        Result.new(
          route_code: route_code_for(notice), route_title: clean_title(notice.title),
          origin_label: origin.fetch(:label), destination_label: destination&.fetch(:label),
          departure_at: departure.fetch(:at), departure_text: departure.fetch(:text),
          arrival_text: aligned_time(destination&.fetch(:times), departure.fetch(:index)),
          next_departures: following_departures(origin.fetch(:times), departure.fetch(:index)),
          next_day: departure.fetch(:next_day)
        )
      end

      def timetable_text(notice, at: clock.call)
        kind = PublicTransportCalendar.kind_for_date(at)
        if @prepared_only
          payload = prepared_document(notice)
          return ReviewedTransportTimetables.text_for(payload, at:) if payload&.dig("calendar", "reviewed_school_calendar")

          return payload&.dig("calendar_texts", kind)
        end

        text = cache_fetch("bijeljina/public-transport-timetable/#{Digest::SHA256.hexdigest(notice.url.to_s)}") do
          text_extractor.call(fetcher.call(notice.url))
        end
        sections = PublicTransportCalendar.sections(text, source_url: notice.url)
        return workday_section(text) if sections.empty? && kind == "workday"

        sections.find { |section| section["kind"] == kind && section["status"] == "available" }&.fetch("text")
      end

      def row_for_labels(text, labels)
        Array(labels).each do |label|
          row = row_for_label(text, label)
          return row if row
        end
        nil
      end

      def row_for_label(text, label)
        text.to_s.each_line do |line|
          next unless line.include?(label)

          times = schedule_times_after_label(line, label)
          return { label:, times: } if times.any?
        end
        nil
      end

      def schedule_times_after_label(line, label)
        tail = line[(line.index(label) + label.length)..].to_s
        started = false
        tail.split(/\s+/).each_with_object([]) do |token, times|
          if schedule_token?(token)
            started = true
            times << (token.match?(TIME_PATTERN) ? token : nil)
          elsif started
            break times
          end
        end
      end

      def schedule_token?(token)
        token == "/" || token.match?(TIME_PATTERN)
      end

      def departures_for(times, date, next_day:)
        Array(times).filter_map.with_index do |time, index|
          next if time.blank?

          hour, minute = time.split(":").map(&:to_i)
          { at: ActiveSupport::TimeZone[SERVICE_TIME_ZONE].local(date.year, date.month, date.day, hour, minute), text: time, index:, next_day: }
        end
      end

      def following_departures(times, index)
        Array(times)[(index + 1)..]&.compact&.first(2).to_a
      end

      def aligned_time(times, index)
        Array(times)[index]
      end

      def format_results(results)
        prefix = results.any?(&:next_day) ? "Danas više ne vidim polazak; prvi naredni koji čitam je" : "Sljedeći polazak koji čitam je"
        lines = results.map { |result| result_line(result) }

        "#{prefix}: #{lines.join("; ")}. Prema zvaničnom redu vožnje i odjeljku za traženi dan; izuzeci za praznike i školski kalendar nisu provjereni."
      end

      def result_line(result)
        arrival = result.arrival_text.present? && result.destination_label.present? ? ", #{result.destination_label} oko #{result.arrival_text}" : ""
        following = result.next_departures.any? ? " (naredni: #{result.next_departures.join(", ")})" : ""
        "#{result.route_code} #{result.origin_label} u #{result.departure_text}#{arrival}#{following}"
      end

      def origin_labels(folded)
        return ["Bijeljina (NAS)"] if folded.include?("nas") || folded.include?("autobuska")

        if folded.include?("centar") || folded.include?("centra")
          return center_to_dvorovi_origin_labels if folded.include?("dvorov")

          return [
            "Bijeljina (spomenik)",
            "Bijeljina (Saborna crkva)",
            "Bijeljina (sud)",
            "Bijeljina (SŠC)",
            "Bijeljina (bolnica)",
            "Bijeljina (NAS)"
          ]
        end

        ["Bijeljina (NAS)"]
      end

      def center_to_dvorovi_origin_labels
        [
          "Bijeljina (Saborna crkva)",
          "Bijeljina (sud)",
          "Bijeljina (SŠC)",
          "Bijeljina (NAS)",
          "Bijeljina (spomenik)"
        ]
      end

      def destination_labels(folded)
        return ["Dvorovi (CSP)", "Dvorovi (Globus)", "Dvorovi (škola)"] if folded.include?("dvorov")
        return ["Janja (centar)", "Janja (škola)"] if folded.include?("janj")

        []
      end

      def route_code_from(text)
        match = text.to_s.match(ROUTE_CODE_PATTERN)
        return unless match

        "#{match[1].upcase}#{match[2].to_i}"
      end

      def route_code_for(notice)
        route_code_from(notice.title)
      end

      def clean_title(title)
        title.to_s.sub(/\AJavni prevoz:\s*/i, "").squish
      end

      def cache_fetch(key, &)
        return yield unless cache

        cache.fetch(key, expires_in: CACHE_TTL, &)
      end

      def fetch_pdf(url, deadline: nil)
        uri = URI.parse(url)
        validate_pdf_uri!(uri)
        byte_limit = ReviewedTransportTimetables.asset_for(url)&.fetch("byte_size", nil) || DEFAULT_MAX_BYTES

        remaining = CityServiceNoticeCollector.send(:remaining_seconds, deadline)
        request_timeout = remaining ? [timeout.to_f, remaining].min : timeout
        raise CityServiceNoticeCollector::DeadlineExceeded if request_timeout <= 0

        within_deadline(deadline) do
          Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: request_timeout, read_timeout: request_timeout) do |http|
            request = Net::HTTP::Get.new(uri)
            request["User-Agent"] = CityServiceNoticeCollector::DEFAULT_USER_AGENT
            body = +""
            http.request(request) do |response|
              raise "route PDF returned HTTP #{response.code}" unless response.code.to_i.between?(200, 299)
              raise "route document exceeds byte limit" if response["Content-Length"].to_i > byte_limit

              response.read_body do |chunk|
                raise "route document exceeds byte limit" if body.bytesize + chunk.bytesize > byte_limit

                body << chunk
              end
            end
            raise "route PDF is empty" if body.blank?

            body
          end
        end
      end

      def validate_pdf_uri!(uri)
        official = URI.parse(CityServiceSources.fetch("public_transport").fetch(:source_url))
        raise ArgumentError, "unsupported PDF source" unless uri.scheme == "https" && uri.host == official.host &&
                                                             uri.port == 443 && uri.userinfo.nil? &&
                                                             (uri.path.downcase.end_with?(".pdf") || ReviewedTransportTimetables.asset_for(uri.to_s))
      end

      def document_key(notice)
        "transport:#{Digest::SHA256.hexdigest(notice.url.to_s)}"
      end

      def document_version(notice)
        Digest::SHA256.hexdigest([MATERIALIZATION_VERSION, stop_registry_fingerprint, notice.title, notice.url,
                                  @snapshot_store.version_for(CityServiceSources.fetch("public_transport")),
                                  ReviewedTransportTimetables.entry_for(notice.url)&.fetch("data_sha256"),
                                  ReviewedTransportTimetables.manifest.dig("stop_locations", "sha256")].join("|"))
      end

      def prepare_document(notice, deadline:)
        raise ArgumentError, "unapproved timetable source" if source_validator && !source_validator.call(notice.url, notice.source_key)

        body = within_deadline(deadline) { call_fetcher(notice.url, deadline:) }
        raise ArgumentError, "oversized timetable document" if body.to_s.bytesize > DEFAULT_MAX_BYTES

        content_hash = Digest::SHA256.hexdigest(body)
        reviewed_entry = ReviewedTransportTimetables.entry_for(notice.url)
        return prepare_reviewed_document(notice, reviewed_entry, content_hash, deadline:) if reviewed_entry

        previous = @snapshot_store.snapshot(source_key: document_key(notice))
        return refresh_unchanged_document(previous, notice, content_hash) if reusable_document?(previous, notice, content_hash)

        text = within_deadline(deadline) { text_extractor.call(body) }
        raise ArgumentError, "oversized timetable text" if text.to_s.bytesize > DEFAULT_MAX_BYTES

        sections = PublicTransportCalendar.sections(text, source_url: notice.url)
        raise ArgumentError, "timetable has no named calendar sections" if sections.empty?

        directions = prepared_directions(sections, notice)

        checked_at = clock.call
        payload = prepared_document_payload(notice, content_hash, checked_at, text, sections, directions)
        @snapshot_store.promote(source_key: document_key(notice), source_version: document_version(notice), payload:,
                                success: true, attempted_at: checked_at, checked_at:, content_hash:)
        { source_url: notice.url, status: :ok, checked_at:, content_hash: }
      rescue CityServiceNoticeCollector::DeadlineExceeded, CityServiceNoticeCollector::InvalidDeadline
        raise
      rescue StandardError => e
        @snapshot_store.promote(source_key: document_key(notice), source_version: document_version(notice),
                                payload: { "status" => "unavailable", "error_code" => "timetable_refresh_failed" },
                                success: false, attempted_at: clock.call)
        { source_url: notice.url, status: :unavailable, error_code: e.class.name }
      end

      def prepare_reviewed_document(notice, entry, content_hash, deadline:)
        raise ArgumentError, "published timetable image changed; review required" unless content_hash == entry.dig("timetable", "sha256")

        map_body = within_deadline(deadline) { call_fetcher(entry.dig("map", "url"), deadline:) }
        raise ArgumentError, "published stop map changed; review required" unless Digest::SHA256.hexdigest(map_body) == entry.dig("map", "sha256")

        data = ReviewedTransportTimetables.data_for(entry)
        directions = data.fetch("directions").map do |direction|
          calendar = ReviewedTransportTimetables.calendar_metadata(direction, entry)
          stops = direction.fetch("stops").each_with_index.map do |row, index|
            point = ReviewedTransportTimetables.stop_location_for(entry.fetch("code"), direction.fetch("name"), row.fetch("label"))
            StopRow.new(label: row.fetch("label"), normalized_label: normalized_text(row.fetch("label")), times: row.fetch("times"), index:,
                        latitude: point.fetch("latitude"), longitude: point.fetch("longitude"),
                        coordinates_source: point.fetch("image_url"), coordinates_accuracy: point.fetch("accuracy"))
          end
          { "name" => direction.fetch("name"), "calendar" => calendar, "stops" => stops.map { |stop| stop.to_h.stringify_keys } }
        end
        checked_at = clock.call
        payload = {
          "status" => "ok", "checked_at" => checked_at.iso8601, "content_hash" => content_hash, "source_url" => notice.url,
          "source_map_url" => entry.dig("map", "url"), "directions" => directions,
          "calendars" => directions.map { |direction| direction.fetch("calendar") }.uniq { |calendar| calendar.fetch("kind") },
          "calendar" => { "timezone" => SERVICE_TIME_ZONE, "reviewed_school_calendar" => ReviewedTransportTimetables::CALENDAR_ID },
          "coverage" => { "stop_coordinates" => "all_published_stops_map_derived_order_inferred", "full_route_network" => false,
                          "effective_from" => data.fetch("effective_from"), "sunday_and_holidays" => "not_published" }
        }
        @snapshot_store.promote(source_key: document_key(notice), source_version: document_version(notice), payload:,
                                success: true, attempted_at: checked_at, checked_at:, content_hash:)
        { source_url: notice.url, status: :ok, checked_at:, content_hash: }
      end

      def calendar_kind_for_routes(routes, date)
        reviewed = routes.any? { |route| Array(route.calendars).any? { |calendar| calendar["reviewed_school_calendar"] } }
        reviewed ? ReviewedTransportTimetables.calendar_kind(date) : PublicTransportCalendar.kind_for_date(date)
      end

      def reusable_document?(previous, notice, content_hash)
        previous && previous.source_version == document_version(notice) && previous.content_hash == content_hash && previous.last_good_payload["directions"].present?
      end

      def refresh_unchanged_document(previous, notice, content_hash)
        checked_at = clock.call
        payload = previous.last_good_payload.merge("checked_at" => checked_at.iso8601)
        @snapshot_store.promote(source_key: document_key(notice), source_version: document_version(notice), payload:,
                                success: true, attempted_at: checked_at, checked_at:, content_hash:)
        { source_url: notice.url, status: :ok, checked_at:, content_hash:, parsed: false }
      end

      def prepared_directions(sections, notice)
        directions = sections.flat_map do |section|
          next [] unless section["status"] == "available"

          parsed = route_directions_from_text(section.fetch("text"), notice, calendar: section.except("text"))
          raise ArgumentError, "timetable section has no validated route rows" if parsed.empty?

          parsed
        end
        raise ArgumentError, "timetable has no validated route rows" if directions.empty?

        times = directions.flat_map { |direction| direction.stops.flat_map(&:times) }.compact
        raise ArgumentError, "invalid timetable clock" unless times.all? { |value| value.match?(/\A(?:[01]?\d|2[0-3]):[0-5]\d\z/) }

        directions
      end

      # Preparation carries the source and its bounded parsed payload together.
      def prepared_document_payload(notice, content_hash, checked_at, text, sections, directions) # rubocop:disable Metrics/ParameterLists
        {
          "status" => "ok", "checked_at" => checked_at.iso8601, "text" => text,
          "content_hash" => content_hash, "source_url" => notice.url,
          "calendars" => sections.map { |section| section.except("text") },
          "calendar_texts" => sections.select { |section| section["status"] == "available" }.to_h { |section| [section.fetch("kind"), section.fetch("text")] },
          "calendar" => { "timezone" => SERVICE_TIME_ZONE, "exception_dates_verified" => false },
          "coverage" => { "stop_coordinates" => "partial_provided_or_assumed_registry", "full_route_network" => false },
          "directions" => directions.map do |direction|
            { "name" => direction.name, "calendar" => direction.calendar, "stops" => direction.stops.map(&:to_h) }
          end
        }
      end

      def reviewed_calendar?(routes)
        routes.any? { |route| Array(route.calendars).any? { |entry| entry["reviewed_school_calendar"] } }
      end

      def reviewed_calendar_override_status(routes, requested_kind, date)
        return unless requested_kind && reviewed_calendar?(routes)

        actual = ReviewedTransportTimetables.calendar_kind(date)
        return [:unreviewed, "service_calendar_requires_review"] if actual == "unreviewed"
        return [:unavailable, "unsupported_service_day"] if actual == "holiday"
        return if actual == requested_kind

        [:ambiguous, "transport_calendar_date_conflict"]
      end

      def service_calendar_status(routes, date, kind = nil)
        expected = kind.to_s.presence || calendar_kind_for_routes(routes, date)
        entries = calendar_entries_for(routes, expected)
        return [:empty, "no_departures_published_for_service_day"] if reviewed_unpublished_sunday?(routes, expected)
        return if entries.any? { |entry| entry["status"] == "available" }
        return if injected_workday_calendar?(entries, routes, expected)
        return [:unreviewed, "service_calendar_requires_review"] if entries.any? { |entry| entry["status"] == "unreviewed" }
        return [:empty, "no_departures_published_for_service_day"] if published_empty_calendar?(entries, routes, expected)

        [:unavailable, "unsupported_service_day"]
      end

      def reviewed_unpublished_sunday?(routes, expected)
        expected == "sunday" && routes.all? { |route| Array(route.calendars).any? { |entry| entry["reviewed_school_calendar"] } }
      end

      def calendar_entries_for(routes, expected)
        routes.flat_map { |route| Array(route.calendars) }.select { |entry| entry["kind"] == expected }
      end

      def injected_workday_calendar?(entries, routes, expected)
        # Explicit injected parser fixtures have no prepared metadata.
        entries.empty? && routes.any? { |route| route.calendars.nil? } && expected == "workday"
      end

      def published_empty_calendar?(entries, routes, expected)
        entries.any? && entries.all? { |entry| entry["status"] == "no_departures_published" } &&
          routes.all? { |route| Array(route.calendars).any? { |entry| entry["kind"] == expected } }
      end

      def prepared_document(notice)
        # The legacy responder can retain this reader across requests. Always
        # read the promoted revision; do not accumulate process-local versions.
        key = document_key(notice)
        row = @snapshot_store.snapshot(source_key: key)
        return unless row && row.source_version == document_version(notice)
        return unless row.last_success_at && row.last_success_at <= clock.call && row.last_success_at >= clock.call - MATERIALIZATION_MAX_AGE
        return unless row.check_payload["status"] == "ok"

        row.last_good_payload
      rescue ActiveRecord::ActiveRecordError
        nil
      end

      def route_from_prepared_document(notice)
        payload = prepared_document(notice)
        return unless payload

        return route_from_payload(notice, payload) unless ReviewedTransportTimetables.entry_for(notice.url)

        cached_reviewed_route(notice, payload, revision: prepared_payload_revision(notice, payload))
      end

      def prepared_payload_revision(notice, payload)
        Digest::SHA256.hexdigest([document_version(notice), JSON.generate(payload)].join("|"))
      end

      def cached_reviewed_route(notice, payload, revision:)
        key = [notice.url.to_s, notice.title.to_s, revision].join("\0")
        cache = PREPARED_ROUTE_CACHE
        cached = cache[:mutex].synchronize { cache[:entries][key] }
        return cached if cached

        # Never retain an ActiveRecord notice in a shared route. Only the
        # public fields used by timetable rendering cross request boundaries.
        reference = PreparedNotice.new(title: notice.title.to_s.dup, url: notice.url.to_s.dup)
        route = deep_freeze_prepared_route(route_from_payload(reference, payload))
        cache[:mutex].synchronize do
          entries = cache[:entries]
          entries[key] ||= route
          entries.shift while entries.size > MAX_PREPARED_ROUTE_CACHE
          entries[key] || route
        end
      end

      def deep_freeze_prepared_route(value)
        case value
        when Array then value.each { |item| deep_freeze_prepared_route(item) }
        when Hash then value.each { |key, item| deep_freeze_prepared_route(key); deep_freeze_prepared_route(item) }
        when Struct then value.each_pair { |_key, item| deep_freeze_prepared_route(item) }
        end
        value.freeze
      end

      def route_from_payload(notice, payload)
        directions = Array(payload["directions"]).map do |attributes|
          stops = Array(attributes["stops"]).map { |stop| StopRow.new(**stop.symbolize_keys.slice(*StopRow.members)) }
          Direction.new(route: notice, name: attributes.fetch("name"), stops:, calendar: attributes["calendar"])
        end
        Route.new(code: route_code_for(notice), title: clean_title(notice.title), directions:, source_url: notice.url, calendars: payload["calendars"])
      end

      def call_fetcher(url, deadline:)
        return fetcher.call(url) unless fetcher_accepts_deadline?

        fetcher.call(url, deadline:)
      end

      def fetcher_accepts_deadline?
        fetcher.parameters.any? do |kind, name|
          kind == :keyrest || ([:key, :keyreq].include?(kind) && name == :deadline)
        end
      end

      def within_deadline(deadline, &)
        CityServiceNoticeCollector.send(:within_deadline, deadline, &)
      end

      def service_day_unavailable_answer
        "Za ovaj datum nemam provjeren odjeljak reda vožnje. Neću pretpostaviti radni-dan raspored; napiši drugi datum ili provjeri prevoznika."
      end

      def extract_pdf_text(body)
        PDF::Reader.new(StringIO.new(body.to_s)).pages.map(&:text).join("\n\f\n")
      end

      def fold(value)
        Decidim::Bih::Text.fold(value.to_s)
      end

      def normalized_text(value)
        fold(value).gsub(/[^a-z0-9]+/, " ").squish
      end
    end
  end
end
