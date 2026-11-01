# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "json"
require "yaml"
require "digest"
require "zlib"
require_relative "../../app/services/decidim_app/bijeljina/public_transport_places"

# Authored toy network, not a transformation of the excluded local corpus.
# Named city/landmark labels exercise fixed reference-adapter identity keys.
# Every time, point, image, calendar and other place below is invented.
module SyntheticTransportNetwork
  def install_synthetic_transport
    @synthetic_transport_root = Dir.mktmpdir("synthetic-reviewed-transport-")
    reviewed = DecidimApp::Bijeljina::ReviewedTransportTimetables
    places = DecidimApp::Bijeljina::PublicTransportPlaces
    @synthetic_transport_prior_constants = [[reviewed, :DATA_PATH, reviewed::DATA_PATH],
      [reviewed, :CALENDAR_ID, reviewed::CALENDAR_ID], [places, :DATA_PATH, places::DATA_PATH]]
    @synthetic_transport_prior_cache = {}
    %i(@manifest @stop_locations @stop_location_index).each do |name|
      @synthetic_transport_prior_cache[name] = reviewed.remove_instance_variable(name) if reviewed.instance_variable_defined?(name)
    end
    write_synthetic_transport_pack(@synthetic_transport_root)
    @synthetic_transport_prior_constants.each do |owner, key, _value|
      owner.send(:remove_const, key)
      value = key == :CALENDAR_ID ? "synthetic-calendar-v1" : (owner == reviewed ? @synthetic_transport_root : File.join(@synthetic_transport_root, "places.yml"))
      owner.const_set(key, value)
    end
    sources = DecidimApp::Bijeljina::CityServiceSources
    @synthetic_transport_prior_sources = sources::SOURCES
    source = sources::REFERENCE_SOURCES.find { |row| row.fetch(:key) == "public_transport" }
      .deep_dup.merge(enabled: true, label: "Izmišljeni javni prevoz", provider: "Izmišljeni prevoznik",
                      source_url: "https://community.example.invalid/synthetic/transport")
    sources.send(:remove_const, :SOURCES)
    sources.const_set(:SOURCES, [source].freeze)
    @synthetic_transport_old_stops = ENV["MI_TRANSPORT_STOPS_PATH"]
    ENV["MI_TRANSPORT_STOPS_PATH"] = File.join(@synthetic_transport_root, "stop-registry.yml")
  end

  def restore_synthetic_transport
    reviewed = DecidimApp::Bijeljina::ReviewedTransportTimetables
    %i(@manifest @stop_locations @stop_location_index).each do |name|
      reviewed.remove_instance_variable(name) if reviewed.instance_variable_defined?(name)
    end
    @synthetic_transport_prior_cache&.each { |name, value| reviewed.instance_variable_set(name, value) }
    @synthetic_transport_prior_constants&.each do |owner, key, value|
      owner.send(:remove_const, key)
      owner.const_set(key, value)
    end
    if defined?(@synthetic_transport_prior_sources)
      sources = DecidimApp::Bijeljina::CityServiceSources
      sources.send(:remove_const, :SOURCES)
      sources.const_set(:SOURCES, @synthetic_transport_prior_sources)
    end
    @synthetic_transport_old_stops.nil? ? ENV.delete("MI_TRANSPORT_STOPS_PATH") : ENV["MI_TRANSPORT_STOPS_PATH"] = @synthetic_transport_old_stops
    FileUtils.remove_entry_secure(@synthetic_transport_root) if @synthetic_transport_root && File.directory?(@synthetic_transport_root)
  end

  def write_synthetic_transport_pack(root)
    nas = "Bijeljina (NAS)"
    # label order and columns are deliberate: G1 is circular and P13 has
    # non-boardable NAS cells while the same trip column continues elsewhere.
    specs = {
      "G1" => { "A" => [[nas, %w(06:30 08:30 10:30 12:30 14:30 16:30 18:30)],
        ["Izmišljena ulica", %w(06:34 08:34 10:34 12:34 14:34 16:34 18:34)],
        ["Bijeljina (spomenik)", %w(06:37 08:37 10:37 12:37 14:37 16:37 18:37)],
        ["Primjerpark", %w(06:40 08:40 10:40 12:40 14:40 16:40 18:40)],
        ["Primjer (AMD)", %w(06:48 08:48 10:48 12:48 14:48 16:48 18:48)],
        [nas, %w(07:05 09:05 11:05 13:05 15:05 17:05 19:05)]],
        "B" => [["Primjerpark", %w(21:30)], ["Bijeljina (spomenik)", %w(21:35)], ["Izmišljena ulica", %w(21:40)], [nas, %w(21:45)]] },
      "G2" => { "A" => [[nas, %w(07:25 09:55 12:55 15:55)], ["Bijeljina (spomenik)", %w(07:30 10:00 13:00 16:00)], ["Bijeljina (bolnica)", %w(07:35 10:05 13:05 16:05)], ["ATC", %w(07:45 10:15 13:15 16:15)]],
        "B" => [["ATC", %w(08:00 10:30 13:30 16:30)], ["Bijeljina (bolnica)", %w(08:10 10:40 13:40 16:40)], ["Bijeljina (spomenik)", %w(08:15 10:45 13:45 16:45)], [nas, %w(08:20 10:50 13:50 16:50)]] },
      "P1" => { "A" => [[nas, %w(06:30 08:30 12:30 16:30)], ["Bijeljina (spomenik)", %w(06:35 08:35 12:35 16:35)], ["Primjervrt (CSP)", %w(06:50 08:50 12:50 16:50)],
        ["Primjervrt (škola)", %w(06:55 08:55 12:55 16:55)]],
        "B" => [["Primjervrt (škola)", %w(06:00 08:00 12:00 16:00)], ["Primjervrt (CSP)", %w(06:05 08:05 12:05 16:05)],
        ["Bijeljina (spomenik)", %w(06:20 08:20 12:20 16:20)], [nas, %w(06:25 08:25 12:25 16:25)]] },
      "P2" => { "A" => [[nas, %w(06:50 11:40 16:50)], ["Primjerpolje (škola)", %w(07:25 12:15 17:25)]],
        "B" => [["Primjerpolje (škola)", %w(07:40 12:40 17:40)], [nas, %w(08:15 13:15 18:15)]] },
      "P3" => { "A" => [[nas, %w(07:00 11:00 15:00)], ["Primjerdalje (spomenik)", %w(07:40 11:40 15:40)]],
        "B" => [["Primjerdalje (spomenik)", %w(08:00 12:00 16:00)], [nas, %w(08:40 12:40 16:40)]] },
      "P6" => { "A" => [["Bijeljina (spomenik)", %w(12:10)], ["Bijeljina (bolnica)", %w(12:16)]],
        "B" => [["Bijeljina (bolnica)", %w(12:30)], ["Bijeljina (spomenik)", %w(12:36)]] },
      "P12" => { "A" => [[nas, %w(06:40 11:20 16:40)], ["Primjerpolje (centar)", %w(07:00 11:40 17:00)],
        ["Primjerpolje (škola)", %w(07:10 11:50 17:10)]],
        "B" => [["Primjerpolje (škola)", %w(07:30 12:30 17:30)], ["Primjerpolje (centar)", %w(07:40 12:40 17:40)],
        [nas, %w(08:00 13:00 18:00)]] },
      "P13" => { "A" => [[nas, ["07:10", nil, nil, "15:20"]], ["Primjerpolje (centar)", %w(07:35 09:45 12:05 15:45)],
        ["Primjerpolje (škola)", %w(07:45 09:55 12:15 15:55)]],
        "B" => [["Primjerpolje (škola)", %w(06:30 10:10 13:10 17:10)], ["Primjerpolje (centar)", %w(06:40 10:20 13:20 17:20)],
        [nas, %w(07:05 10:45 13:45 17:45)]] }
    }
    coordinates = { nas => [0.5000, 0.5000], "Izmišljena ulica" => [0.5000, 0.5020], "Primjerpark" => [0.5010, 0.5040], "Bijeljina (spomenik)" => [0.5000, 0.5040], "Bijeljina (bolnica)" => [0.5000, 0.5050], "Primjerdalje (spomenik)" => [0.5300, 0.5000],
      "Primjer (AMD)" => [0.5000, 0.5060], "ATC" => [0.5000, 0.5100], "Primjervrt (CSP)" => [0.5100, 0.5000],
      "Primjervrt (škola)" => [0.5120, 0.5000], "Primjerpolje (centar)" => [0.5200, 0.5000], "Primjerpolje (škola)" => [0.5220, 0.5000] }
    points = []
    routes = specs.each_with_index.map do |(code, directions), ordinal|
      assets = %w(timetable map).to_h do |kind|
        file = "#{code}-#{kind}.png"
        bytes = synthetic_transport_pixel
        File.binwrite(File.join(root, file), bytes)
        [kind, { "url" => "https://community.example.invalid/synthetic/transport/#{file}", "file" => file,
                   "sha256" => Digest::SHA256.hexdigest(bytes), "byte_size" => bytes.bytesize }]
      end
      rows = directions.flat_map do |name, stops|
        kinds = %w(school_day school_break)
        kinds << "saturday" if %w(G1 G2 P1).include?(code)
        kinds.map.with_index do |kind, section|
          timetable_stops = stops.map do |label, times|
            values = times
            { "label" => label, "times" => values }
          end
          # Index, rather than equal label, keeps both ends of a circular trip.
          if kind == "saturday" && code == "G1" && name == "A"
            timetable_stops.each_with_index { |stop, i| stop["times"] = [%w(10:10 10:14 10:17 10:20 10:28 10:45).fetch(i)] }
          end
          { "name" => name, "calendar" => kind, "source_heading" => {"school_day" => "Radni dan ŠKOLA", "school_break" => "Školski raspust", "saturday" => "Subota"}.fetch(kind),
            "source_table_index" => section, "stops" => timetable_stops }
        end
      end
      directions.each do |name, stops|
        stops.each do |label, _times|
          lat, lon = coordinates.fetch(label)
          lat += ordinal * 0.00005 if label == nas
          lon += ordinal * 0.00005 if label == nas
          points << { "line" => code, "direction" => name, "label" => label, "latitude" => lat, "longitude" => lon,
            "image_url" => assets.fetch("map").fetch("url"), "accuracy" => "assumed", "confidence" => "synthetic_not_surveyed" }
        end
      end
      data = JSON.generate("effective_from" => "2026-09-01", "directions" => rows)
      file = "#{code}.json"; File.write(File.join(root, file), data)
      { "code" => code, "title" => "Javni prevoz: #{code} — IZMIŠLJENI TEST", "data_file" => file,
        "data_sha256" => Digest::SHA256.hexdigest(data), **assets }
    end
    points.uniq! { |row| row.values_at("line", "direction", "label") }
    bytes = JSON.generate("rows" => points); File.write(File.join(root, "points.json"), bytes)
    manifest = { "routes" => routes, "effective_from" => "2026-09-01", "source_url" => "https://community.example.invalid/synthetic/transport",
      "stop_locations" => { "file" => "points.json", "sha256" => Digest::SHA256.hexdigest(bytes) },
      "calendar" => { "reviewed_until" => "2027-05-13", "unsupported_dates" => ["2026-11-21", "2027-01-01", "2027-01-07"],
        "school_day_ranges" => [["2026-09-01", "2026-12-23"], ["2027-01-13", "2027-05-13"]],
        "school_break_ranges" => [["2026-12-24", "2027-01-12"]],
        "sources" => [{ "url" => "https://community.example.invalid/synthetic/calendar", "title" => "Izmišljeni kalendar" }] } }
    File.write(File.join(root, "manifest.json"), JSON.generate(manifest))
    File.write(File.join(root, "stop-registry.yml"), YAML.dump("stops" => coordinates.map { |label, (lat, lon)| { "label" => label, "latitude" => lat, "longitude" => lon, "accuracy" => "assumed", "source" => points.find { |row| row.fetch("label") == label }.fetch("image_url"), "confidence" => "synthetic_not_surveyed" } }))
    places = [
      { "id" => "transport-place:synthetic-city", "name" => "Bijeljina", "aliases" => ["Bijeljine", "Bijeljinu", "Bijeljini", "NAS", "Nova AS", "nova autobuska stanica", "centar"], "default_label" => nas, "member_labels" => [nas, "Primjer (AMD)"], "assumption_reason" => "synthetic_reviewed_default" },
      { "id" => "transport-place:primjervrt", "name" => "Primjervrt", "aliases" => ["Primjervrta", "Primjervrtu"], "default_label" => "Primjervrt (CSP)", "member_labels" => ["Primjervrt (CSP)", "Primjervrt (škola)"], "assumption_reason" => "synthetic_reviewed_default" },
      { "id" => "transport-place:primjerpolje", "name" => "Primjerpolje", "aliases" => ["Primjerpolja", "Primjerpolju"], "default_label" => "Primjerpolje (centar)", "member_labels" => ["Primjerpolje (centar)", "Primjerpolje (škola)"], "assumption_reason" => "synthetic_reviewed_default" }
    ]
    File.write(File.join(root, "places.yml"), YAML.dump("places" => places))
  end

  def synthetic_transport_pixel
    chunk = ->(type, bytes) { [bytes.bytesize].pack("N") + type + bytes + [Zlib.crc32(type + bytes)].pack("N") }
    "\x89PNG\r\n\x1a\n".b + chunk.call("IHDR", [1, 1, 8, 2, 0, 0, 0].pack("NNCCCCC")) +
      chunk.call("IDAT", Zlib.deflate("\x00\x44\x88\xaa".b)) + chunk.call("IEND", "".b)
  end
end
