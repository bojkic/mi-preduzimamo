# frozen_string_literal: true
require "test_helper"

class PublicTransportDefaultsTest < ActiveSupport::TestCase
  Timetables = DecidimApp::Bijeljina::ReviewedTransportTimetables
  Places = DecidimApp::Bijeljina::PublicTransportPlaces
  Crosswalk = DecidimApp::Bijeljina::CityServiceAreaCrosswalk

  def setup
    @previous_cache = {}
    %i(@manifest @stop_locations).each do |name|
      next unless Timetables.instance_variable_defined?(name)

      @previous_cache[name] = Timetables.remove_instance_variable(name)
    end
  end

  def teardown
    %i(@manifest @stop_locations).each do |name|
      Timetables.remove_instance_variable(name) if Timetables.instance_variable_defined?(name)
    end
    @previous_cache.each { |name, value| Timetables.instance_variable_set(name, value) }
  end

  def with_constant(owner, name, value)
    original = owner.const_get(name)
    owner.send(:remove_const, name)
    owner.const_set(name, value)
    yield
  ensure
    owner.send(:remove_const, name)
    owner.const_set(name, original)
  end

  def test_no_dataset_cannot_produce_routes_stops_calendars_or_containment
    assert_empty Timetables.manifest.fetch("routes")
    assert_empty Timetables.stop_locations
    assert_nil Timetables.entry_for("https://community.example.invalid/timetable")
    assert_nil Timetables.asset_for("https://community.example.invalid/map")
    assert_equal "unreviewed", Timetables.calendar_kind(Date.new(2040, 4, 9))
    assert_empty Places.entries
    assert_empty Crosswalk.load_config.fetch("places")
    assert_empty Crosswalk.load_config.fetch("sources")
  end

  def test_missing_explicit_paths_are_rejected
    Dir.mktmpdir("public-transport-") do |directory|
      missing = File.join(directory, "missing")
      with_constant(Timetables, :DATA_PATH, missing) { assert_raises(Errno::ENOENT) { Timetables.manifest } }
      with_constant(Places, :DATA_PATH, missing) { assert_raises(Errno::ENOENT) { Places.entries } }
      with_constant(Crosswalk, :CONFIG_PATH, missing) { assert_raises(Errno::ENOENT) { Crosswalk.load_config } }
    end
  end

  def test_synthetic_reviewed_calendar_preserves_boundaries_and_service_days
    Dir.mktmpdir("synthetic-calendar-") do |directory|
      day = (Date.new(2040, 4, 1)..Date.new(2040, 4, 7)).find(&:monday?)
      holiday = day + 1
      calendar = { "reviewed_until" => "2040-12-31", "unsupported_dates" => [holiday.iso8601],
                   "school_day_ranges" => [["2040-01-01", "2040-06-30"], ["2040-09-01", "2040-12-31"]],
                   "school_break_ranges" => [["2040-07-01", "2040-08-31"]] }
      manifest = { "routes" => [], "effective_from" => "2040-01-01", "calendar" => calendar }
      File.write(File.join(directory, "manifest.json"), JSON.generate(manifest))
      with_constant(Timetables, :DATA_PATH, directory) do
        assert_equal "school_day", Timetables.calendar_kind(day)
        assert_equal "holiday", Timetables.calendar_kind(holiday)
        assert_equal "saturday", Timetables.calendar_kind(day + 5)
        assert_equal "sunday", Timetables.calendar_kind(day + 6)
        summer = (Date.new(2040, 7, 1)..Date.new(2040, 7, 7)).find(&:monday?)
        assert_equal "school_break", Timetables.calendar_kind(summer)
        assert_equal "unreviewed", Timetables.calendar_kind(Date.new(2039, 12, 31))
        assert_equal "unreviewed", Timetables.calendar_kind(Date.new(2041, 1, 1))
      end
    end
  end

  def test_synthetic_stop_data_is_available_only_with_matching_checksum
    Dir.mktmpdir("synthetic-stops-") do |directory|
      rows = [{ "line" => "TEST-1", "direction" => "A", "label" => "Izmišljeno stajalište" }]
      bytes = JSON.generate("rows" => rows)
      File.write(File.join(directory, "stops.json"), bytes)
      asset = { "file" => "stops.json", "sha256" => Digest::SHA256.hexdigest(bytes) }
      File.write(File.join(directory, "manifest.json"), JSON.generate("routes" => [], "stop_locations" => asset))
      with_constant(Timetables, :DATA_PATH, directory) { assert_equal rows, Timetables.stop_locations }
    end
  end

  def test_timetable_reader_uses_explicit_community_stop_registry_without_fetching
    original = ENV["MI_TRANSPORT_STOPS_PATH"]
    Dir.mktmpdir("synthetic-reader-stops-") do |directory|
      path = File.join(directory, "stops.yml")
      File.write(path, { "stops" => [{ "label" => "Izmišljeno stajalište", "latitude" => 0.001, "longitude" => 0.001,
                                      "source" => "https://community.example.invalid/map", "accuracy" => "assumed" }] }.to_yaml)
      ENV["MI_TRANSPORT_STOPS_PATH"] = path
      reader = DecidimApp::Bijeljina::PublicTransportTimetable.new(cache: false, fetcher: ->(*) { flunk "registry lookup must not fetch" })
      answer = reader.nearest_stop(location: { latitude: 0, longitude: 0 })
      assert_equal :ok, answer.status
      assert_equal "Izmišljeno stajalište", answer.origin
      assert_includes answer.warnings, "assumed_stop_coordinates"
      assert_not_includes URI.parse(answer.boarding_stop.fetch("destination")).query, "origin="
      ENV["MI_TRANSPORT_STOPS_PATH"] = File.join(directory, "missing.yml")
      assert_raises(Errno::ENOENT) { DecidimApp::Bijeljina::PublicTransportTimetable.new(cache: false) }
      File.write(path, "stops: [invalid")
      ENV["MI_TRANSPORT_STOPS_PATH"] = path
      assert_raises(ArgumentError) { DecidimApp::Bijeljina::PublicTransportTimetable.new(cache: false) }
    end
  ensure
    original.nil? ? ENV.delete("MI_TRANSPORT_STOPS_PATH") : ENV["MI_TRANSPORT_STOPS_PATH"] = original
  end

  def test_configured_reviewed_asset_still_requires_its_checksum
    Dir.mktmpdir("synthetic-transport-") do |directory|
      File.write(File.join(directory, "stops.json"), JSON.generate("rows" => []))
      File.write(File.join(directory, "manifest.json"), JSON.generate("routes" => [], "stop_locations" => { "file" => "stops.json", "sha256" => "0" * 64 }))
      with_constant(Timetables, :DATA_PATH, directory) do
        error = assert_raises(ArgumentError) { Timetables.stop_locations }
        assert_match "checksum mismatch", error.message
      end
    ensure
      %i(@manifest @stop_locations).each { |name| Timetables.remove_instance_variable(name) if Timetables.instance_variable_defined?(name) }
    end
  end
end
