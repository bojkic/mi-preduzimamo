# frozen_string_literal: true

require "bundler/setup"
require "minitest/autorun"
require "json"
require_relative "../support/synthetic_prepared_transport_corpus"
require "active_support"
require "active_support/time"
require "active_support/core_ext/object/blank"
require "active_support/core_ext/object/deep_dup"
require "active_support/core_ext/hash/keys"
require "active_support/core_ext/hash/slice"
require "active_support/core_ext/string/filters"
require "active_support/core_ext/string/exclude"
require "active_support/core_ext/array/access"
require "active_support/core_ext/enumerable"

engine_root = Gem.loaded_specs.fetch("decidim-bih").full_gem_path
require File.join(engine_root, "app/services/decidim/bih/text")
require_relative "../../app/services/decidim_app/bijeljina/city_service_sources"
require_relative "../../app/services/decidim_app/bijeljina/city_service_notice_collector"
require_relative "../../app/services/decidim_app/bijeljina/public_transport_calendar"
require_relative "../../app/services/decidim_app/bijeljina/reviewed_transport_timetables"
require_relative "../../app/services/decidim_app/bijeljina/public_transport_timetable"

# Independent authored21-document corpus and toy stop registry. Only snapshot
# persistence is replaced; no database, PDF/network fetch, Rails boot or model.
# MILICA_TRANSPORT_PROFILE=repeat prints three alternating CPU/wall comparisons;
# tests assert result equality and computation counts, never machine-speed limits.
class MilicaTransportMatchingTest < Minitest::Test
  include SyntheticPreparedTransportCorpus
  Timetable = DecidimApp::Bijeljina::PublicTransportTimetable
  Calendar = DecidimApp::Bijeljina::PublicTransportCalendar
  Notice = Data.define(:source_key, :url, :title)
  Row = Data.define(:source_version, :last_success_at, :check_payload, :last_good_payload)
  NOW = Time.utc(2026, 9, 9, 18)
  LOCATION = { latitude: 0.500001, longitude: 0.500002 }.freeze
  PROFILE_METHODS = [:normalized_text, :matching_stops, :scheduled_time, :route_from_prepared_document, :direct_itineraries, :transfer_itineraries, :stop_registry_fingerprint,
                     :route_code_for, :clean_title].freeze

  # Previous matching algorithm, retaining all deployed transfer/ranking logic.
  class UnoptimizedMatching < Timetable
    private

    def build_planner_cache = nil

    def matching_stops(stops, phrase)
      Array(stops).select { |stop| stop_matches_phrase?(stop, phrase) }
    end
  end

  class Snapshots
    attr_reader :rows

    def initialize
      @rows = {}
    end

    def snapshot(source_key:) = rows[source_key]

    def version_for(_source) = "authored-public-corpus-v1"
  end

  def setup
    install_authored_transport_corpus
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    @old_zone = Time.zone
    Time.zone = "Europe/Sarajevo" # rubocop:disable Rails/TimeZoneAssignment
    @store = Snapshots.new
    builder = reader
    @notices = JSON.parse(File.read(File.join(@authored_transport_root, "sources.json"))).map do |source|
      notice = Notice.new("public_transport", source.fetch("url"), source.fetch("title"))
      text = File.read(File.join(@authored_transport_root, "#{source.fetch("fixture")}.txt"))
      sections = Calendar.sections(text, source_url: notice.url)
      directions = builder.send(:prepared_directions, sections, notice)
      payload = builder.send(:prepared_document_payload, notice, Digest::SHA256.hexdigest(text), NOW, text, sections, directions)
      payload = JSON.parse(JSON.generate(payload))
      @store.rows[builder.send(:document_key, notice)] = Row.new(builder.send(:document_version, notice), NOW, { "status" => "ok" }, payload)
      notice
    end
    puts JSON.generate(setup_seconds: Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) if ENV["MILICA_TRANSPORT_PROFILE"]
  end

  def teardown
    restore_authored_transport_corpus
    Time.zone = @old_zone # rubocop:disable Rails/TimeZoneAssignment
  end

  def test_complete_prepared_query_is_unchanged_with_less_repeated_matching_work
    readers = { baseline: reader(UnoptimizedMatching), optimized: reader }
    rounds = ENV["MILICA_TRANSPORT_PROFILE"] == "repeat" ? 3 : 1
    rounds.times do |round|
      order = round.odd? ? [:optimized, :baseline] : [:baseline, :optimized]
      results = order.index_with { |key| measured_query(readers.fetch(key)) }
      expected, baseline = results.fetch(:baseline)
      actual, optimized = results.fetch(:optimized)
      assert_equal 21, @notices.size
      assert_equal :ok, expected.status
      assert_equal "Primjergrad (sud)", expected.origin
      assert_equal "P1", expected.itinerary.legs.first.route_code
      assert_equal "2026-09-10T11:41:00+02:00", expected.itinerary.legs.first.departure_at.iso8601
      assert_equal expected.to_h, actual.to_h
      puts JSON.generate(round: round + 1, order:, baseline:, optimized:, result_sha256: Digest::SHA256.hexdigest(Marshal.dump(actual.to_h))) if ENV["MILICA_TRANSPORT_PROFILE"]
    end
  end

  def test_match_branches_preserve_order_scripts_exact_labels_and_unmatched_inputs
    instance = reader
    baseline = reader(UnoptimizedMatching)
    checks = Hash.new(0)
    { optimized: instance, baseline: }.each do |name, timetable|
      timetable.define_singleton_method(:exact_stop_label_query?) do |phrase|
        checks[name] += 1
        super(phrase)
      end
    end
    labels = ["Primjergrad (sud)", "Primjergrad (NAS)", "Primjerpolje (CSP)", "Novo Primjerpolje", "Примјерпоље (школа)", "Izmišljeni gaj"]
    stops = labels.each_with_index.map { |label, index| Timetable::StopRow.new(label:, normalized_label: instance.send(:normalized_text, label), index:) }
    ["", nil, "Primjergrad", "Primjergrad (sud)", "Примјерград (суд)", "Primjerpolje", "Примјерпоље", "Novo Primjerpolje", "No match", "CSP", "centar"].each do |phrase|
      assert_equal baseline.send(:matching_stops, stops, phrase), instance.send(:matching_stops, stops, phrase), phrase.inspect
    end
    assert_operator checks.fetch(:optimized), :<, checks.fetch(:baseline)
  end

  private

  def reader(klass = Timetable)
    klass.new(clock: -> { NOW }, snapshot_store: @store, stop_registry_path: File.join(@authored_transport_root, "stops.yml"), cache: false,
              fetcher: ->(*) { raise "Unexpected external fetch" }, text_extractor: ->(*) { raise "Unexpected text extraction" }, prepared_only: true)
  end

  def query
    { origin: nil, destination: "Primjerpolje", requested_at: Time.zone.local(2026, 9, 10, 11), notices: @notices, location: LOCATION }
  end

  def measured_query(instance)
    profile = profile_methods(instance) if ENV["MILICA_TRANSPORT_PROFILE"] == "1"
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    cpu_started = Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID)
    answer = instance.query(**query)
    timing = { elapsed_seconds: Process.clock_gettime(Process::CLOCK_MONOTONIC) - started,
               cpu_seconds: Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID) - cpu_started, profile: }.compact
    [answer, timing]
  end

  def profile_methods(instance)
    totals = Hash.new { |hash, key| hash[key] = { calls: 0, seconds: 0.0 } }
    wrapper = Module.new
    PROFILE_METHODS.each do |name|
      wrapper.define_method(name) do |*args, **kwargs, &block|
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        super(*args, **kwargs, &block)
      ensure
        totals[name][:calls] += 1
        totals[name][:seconds] += Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      end
    end
    instance.singleton_class.prepend(wrapper)
    totals
  end
end
