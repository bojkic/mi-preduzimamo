# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/synthetic_transport_network"

module DecidimApp
  module Bijeljina
    class ReviewedTransportTimetablesTest < ActiveSupport::TestCase
      include SyntheticTransportNetwork
      Data = ReviewedTransportTimetables

      setup do
        install_synthetic_transport
        configure_synthetic_reviewed_pack
        DecidimApp::CityServiceSourceSnapshot.delete_all
        @now = Time.utc(2026, 9, 14, 3)
        @store = CityServiceSourceCheckStore.new(clock: -> { @now })
        @notices = Data.manifest.fetch("routes").map do |entry|
          CityServiceNoticeCollector::Notice.new(source_key: "public_transport", title: "Javni prevoz: #{entry.fetch("title")}",
                                                 url: entry.dig("timetable", "url"), fetched_at: @now)
        end
        @writer = PublicTransportTimetable.new(fetcher: ->(url) { image_body(url) }, clock: -> { @now }, snapshot_store: @store, prepared_only: true, cache: false)
      end

      teardown { restore_synthetic_transport }

      test "all authored lines retain both synthetic images and rectangular chronological tables" do
        entries = Data.manifest.fetch("routes")
        assert_equal %w(G1 G2 P1 P2 P3 P6 P12 P13), entries.map { |entry| entry.fetch("code") }
        entries.each do |entry|
          %w(timetable map).each do |kind|
            asset = entry.fetch(kind)
            assert_equal asset.fetch("sha256"), Digest::SHA256.file(File.join(Data::DATA_PATH, asset.fetch("file"))).hexdigest
          end
          directions = Data.data_for(entry).fetch("directions")
          assert_equal(%w(G1 G2 P1).include?(entry.fetch("code")) ? %w(school_day school_break saturday) : %w(school_day school_break), directions.map { |direction| direction.fetch("calendar") }.uniq)
          directions.each do |direction|
            rows = direction.fetch("stops")
            assert_operator rows.size, :>=, 2
            rows.each { |row| assert_equal direction.fetch("trip_columns"), row.fetch("times").size }
            rows.map { |row| row.fetch("times") }.transpose.each do |trip|
              minutes = trip.compact.map do |time|
                assert_match(/\A(?:[01]?\d|2[0-3]):[0-5]\d\z/, time)
                hour, minute = time.split(":").map(&:to_i)
                (hour * 60) + minute
              end
              assert_operator minutes.size, :>=, 2
              assert_equal minutes.sort, minutes, entry.fetch("code")
            end
          end
        end
      end

      test "every authored stop is tied to its synthetic map pixel and reproducible transform" do
        rows = Data.stop_locations
        assert_equal 49, rows.size
        assert_equal 12, rows.pluck("label").uniq.size
        assert_equal rows.size, rows.map { |row| row.values_at("line", "direction", "label") }.uniq.size
        registration = JSON.parse(File.read(File.join(Data::DATA_PATH, "georeference.json")))
        reference = registration.fetch("reference")
        extent = reference.fetch("extent")
        Data.manifest.fetch("routes").each do |entry|
          data = Data.data_for(entry)
          data.fetch("directions").each do |direction|
            direction.fetch("stops").each do |stop|
              point = Data.stop_location_for(entry.fetch("code"), direction.fetch("name"), stop.fetch("label"))
              assert_equal entry.dig("map", "url"), point.fetch("image_url")
              assert_equal entry.dig("map", "sha256"), point.fetch("image_sha256")
              assert_equal "assumed", point.fetch("accuracy")
              assert_equal "synthetic_map_transform", point.fetch("review_status")
              transform = registration.fetch("maps").fetch(entry.fetch("code").downcase).fetch("to_esri")
              pixel = point.fetch("pixel") + [1]
              u, v = transform.map { |axis| axis.zip(pixel).sum { |coefficient, value| coefficient * value } }
              meters_x = extent.fetch("xmin") + (u / reference.fetch("width") * (extent.fetch("xmax") - extent.fetch("xmin")))
              meters_y = extent.fetch("ymax") - (v / reference.fetch("height") * (extent.fetch("ymax") - extent.fetch("ymin")))
              longitude = meters_x / 6_378_137 * 180 / Math::PI
              latitude = ((2 * Math.atan(Math.exp(meters_y / 6_378_137))) - (Math::PI / 2)) * 180 / Math::PI
              assert_in_delta latitude, point.fetch("latitude"), 0.000003
              assert_in_delta longitude, point.fetch("longitude"), 0.000003
            end
          end
        end
      end

      test "every prepared row has a map coordinate and no published stop is missing" do
        @writer.prepare(notices: @notices)
        audit = PublicTransportDataAudit.call(notices: @notices, timetable: @writer, registry_path: ENV.fetch("MI_TRANSPORT_STOPS_PATH"))
        assert_equal 12, audit.summary.fetch(:unique_stops)
        assert_equal 0, audit.summary.fetch(:missing_coordinates)
        assert_equal 0, audit.summary.fetch(:invalid_registry_entries)
        assert_equal 0, audit.summary.fetch(:unused_registry_entries)
        assert_equal 12, audit.summary.fetch(:assumed_coordinates)
        assert(@writer.matrix(notices: @notices).all? { |route| route.directions.all? { |direction| direction.stops.all? { |stop| stop.latitude && stop.longitude } } })
      end

      test "walking navigation follows the selected line and direction instead of the generic same-name location" do
        prepare_line("G1")
        prepare_line("P1")
        point = Data.stop_location_for("G1", "A", "Bijeljina (NAS)")
        generic = @writer.send(:registry_stop_for, "Bijeljina (NAS)")
        assert_operator (point.fetch("longitude") - generic.longitude).abs, :>, 0.001
        result = query_at("G1", "Primjerpark", "2026-09-15 05:00")
        assert_includes result.boarding_stop.fetch("destination"), URI.encode_www_form_component(format("%.6f,%.6f", point.fetch("latitude"), point.fetch("longitude")))
        assert_includes result.warnings, "assumed_stop_coordinates"
        assert_not_includes result.warnings, "stop_registry_partial"
        a = Data.stop_location_for("P1", "A", "Primjervrt (škola)")
        b = Data.stop_location_for("P1", "B", "Primjervrt (škola)")
        assert_operator (a.fetch("latitude") - b.fetch("latitude")).abs, :>, 0.01
        result = @writer.query(origin: "Primjervrt (škola)", destination: "Bijeljina (NAS)", route_code: "P1", notices: @notices, requested_at: @now)
        assert_equal :ok, result.status
        assert_includes result.boarding_stop.fetch("destination"), URI.encode_www_form_component(format("%.6f,%.6f", b.fetch("latitude"), b.fetch("longitude")))
        retained = @writer.walking_directions(stop_id: result.boarding_stop.fetch("id"))
        assert_equal result.boarding_stop.fetch("destination"), retained.fetch("destination"), "public stop identity retains the selected direction"
        nearest = @writer.send(:nearest_stops_for, latitude: b.fetch("latitude"), longitude: b.fetch("longitude")).find { |stop| stop.label == "Primjervrt (škola)" }
        assert_in_delta 0, nearest.distance_meters, 1
      end

      test "a changed upstream map with unchanged timetable blocks the prepared line" do
        notice = prepare_line("G1")
        map_url = Data.entry_for(notice.url).dig("map", "url")
        previous = @store.snapshot(source_key: @writer.send(:document_key, notice)).last_good_payload
        @writer.instance_variable_set(:@fetcher, ->(url) { url == map_url ? "changed stop map" : image_body(url) })
        assert_equal :unavailable, @writer.prepare(notices: [notice]).first.fetch(:status)
        assert_equal previous, @store.snapshot(source_key: @writer.send(:document_key, notice)).last_good_payload
        assert_empty @writer.matrix(notices: [notice])
      end

      test "published gallery yields every line and rejects a missing or new attachment" do
        images = Data.manifest.fetch("routes").flat_map { |entry| %w(timetable map).map { |kind| entry.dig(kind, "url") } }
        document = Nokogiri::HTML(images.map { |url| "<img src='#{url}'>" }.join)
        assert_equal 8, Data.gallery_entries(document).size
        notices = CityServiceNoticeCollector.send(:public_transport_notices, CityServiceSources.fetch("public_transport"), document,
                                                  Data.manifest.fetch("source_url"), max_items: 30, now: @now)
        assert_equal @notices.map(&:url), notices.map(&:url)
        assert_includes notices.first.body, Data.manifest.fetch("routes").first.dig("map", "url")
        document.at_css("img").add_previous_sibling("<img src='https://community.example.invalid/unrelated/logo.png'>")
        document.at_css("img").add_previous_sibling("<img src='data:image/png;base64,AAAA'><img src='http://['>")
        assert_equal 8, Data.gallery_entries(document).size, "unrelated page imagery is not a transport asset"
        extra = "<img src='https://community.example.invalid/synthetic/transport/new-map.png'>"
        document.at_css("img").add_previous_sibling(extra)
        assert_raises(ArgumentError) { Data.gallery_entries(document) }
        document.css("img").find { |node| node["src"].end_with?("new-map.png") }.remove
        document.css("img").find { |node| node["src"] == images.first }.remove
        assert_raises(ArgumentError) { Data.gallery_entries(document) }
        assert_raises(ArgumentError) do
          CityServiceNoticeCollector.send(:public_transport_notices, CityServiceSources.fetch("public_transport"), Nokogiri::HTML("<p>empty gallery</p>"),
                                          Data.manifest.fetch("source_url"), max_items: 30, now: @now)
        end
      end

      test "all reviewed images prepare for a new reader without citizen-time network calls" do
        prepared = @writer.prepare(notices: @notices)
        assert_equal 8, prepared.size
        assert prepared.all? { |row| row.fetch(:status) == :ok }, prepared.inspect
        reader = PublicTransportTimetable.new(fetcher: ->(*) { flunk "citizen read fetched a timetable" }, prepared_only: true,
                                              clock: -> { @now }, snapshot_store: @store, cache: false)
        assert_equal 8, reader.matrix(notices: @notices).size
        result = reader.query(origin: "Bijeljina (NAS)", destination: "Primjerpark", notices: @notices, route_code: "G1", requested_at: @now)
        assert_equal :ok, result.status
        assert_equal "06:30", result.itinerary.legs.first.departure_at.in_time_zone("Europe/Sarajevo").strftime("%H:%M")
        assert_includes result.sources, Data.manifest.fetch("routes").first.dig("map", "url")
      end

      test "school weekdays breaks and Saturdays use their own columns and unsupported dates stay unknown" do
        prepare_line("G1")
        assert_equal "18:30", departure("G1", "Primjerpark", "2026-09-14 17:00"), "school evening service"
        winter = query_at("G1", "Primjerpark", "2027-01-11 17:00")
        assert_equal "2027-01-12", winter.service_date, "winter break rolls to the next morning"
        assert_equal true, winter.rolled_over
        assert_equal "06:30", departure("G1", "Primjerpark", "2027-01-11 17:00")
        assert_equal "10:10", departure("G1", "Primjerpark", "2026-09-19 05:00")
        assert_equal "school_break", Data.calendar_kind(Time.zone.parse("2027-01-11"))
        sunday = @writer.query(origin: "Bijeljina (NAS)", destination: "Primjerpark", notices: @notices,
                               route_code: "G1", requested_at: Time.find_zone!("Europe/Sarajevo").parse("2026-09-13 05:00"))
        assert_equal :empty, sunday.status
        assert_includes sunday.warnings, "no_departures_published_for_service_day"
        assert_empty sunday.options

        ["2026-11-21", "2027-01-07", "2027-06-14", "2026-08-31"].each do |date|
          result = @writer.query(origin: "Bijeljina (NAS)", destination: "Primjerpark", notices: @notices,
                                 route_code: "G1", requested_at: Time.find_zone!("Europe/Sarajevo").parse("#{date} 05:00"))
          assert_equal :unavailable, result.status, date
          assert_empty result.options
        end
      end

      test "authored seasonal columns cannot leak January trips into September" do
        prepare_line("G2")
        prepare_line("P1")
        assert_equal "13:10", departure("G2", "ATC", "2026-09-14 12:00")
        assert_equal "12:10", departure("G2", "ATC", "2027-01-25 12:00")
        assert_equal "13:10", departure("P1", "Primjervrt (škola)", "2026-09-14 12:00")
        assert_equal "12:10", departure("P1", "Primjervrt (škola)", "2027-01-25 12:00")
      end

      test "changed upstream image preserves prior payload but blocks its use until reviewed" do
        notice = prepare_line("G1")
        key = @writer.send(:document_key, notice)
        previous = @store.snapshot(source_key: key).last_good_payload
        @writer.instance_variable_set(:@fetcher, ->(*) { "replacement image" })
        assert_equal :unavailable, @writer.prepare(notices: [notice]).first.fetch(:status)
        assert_equal previous, @store.snapshot(source_key: key).last_good_payload
        assert_empty @writer.matrix(notices: [notice])
      end

      test "tampered authored route data is rejected before it can be prepared" do
        entry = Data.manifest.fetch("routes").first
        path = File.join(Data::DATA_PATH, entry.fetch("data_file"))
        File.write(path, File.read(path) + " ")
        error = assert_raises(ArgumentError) { Data.data_for(entry) }
        assert_includes error.message, "checksum mismatch"
      end

      test "tampered authored coordinate data is rejected before it can be used" do
        entry = Data.manifest.fetch("stop_locations")
        path = File.join(Data::DATA_PATH, entry.fetch("file"))
        File.write(path, File.read(path) + " ")
        error = assert_raises(ArgumentError) { Data.stop_locations }
        assert_includes error.message, "checksum mismatch"
      end

      private

      # These invented review records exercise integrity and consistency, not
      # surveying or the accuracy/rights of any real-world transport dataset.
      def configure_synthetic_reviewed_pack
        root = @synthetic_transport_root
        manifest = JSON.parse(File.read(File.join(root, "manifest.json")))
        points = JSON.parse(File.read(File.join(root, "points.json"))).fetch("rows")
        points.each do |point|
          point["longitude"] += 0.003 if point.values_at("line", "direction", "label") == ["G1", "A", "Bijeljina (NAS)"]
          point["latitude"] += 0.012 if point.values_at("line", "direction", "label") == ["P1", "B", "Primjervrt (škola)"]
        end
        maximum = 6_378_137 * Math::PI / 180
        ymax = 6_378_137 * Math.log(Math.tan((Math::PI / 4) + (Math::PI / 360)))
        registration = { "reference" => { "width" => 1024, "height" => 1024,
          "extent" => { "xmin" => 0, "xmax" => maximum, "ymin" => 0, "ymax" => ymax } }, "maps" => {} }
        manifest.fetch("routes").each do |entry|
          registration.fetch("maps")[entry.fetch("code").downcase] = { "to_esri" => [[1, 0, 0], [0, 1, 0]] }
          asset = entry.fetch("map")
          image = synthetic_map_png
          File.binwrite(File.join(root, asset.fetch("file")), image)
          asset["sha256"] = Digest::SHA256.hexdigest(image)
          asset["byte_size"] = image.bytesize
          points.select { |point| point.fetch("line") == entry.fetch("code") }.each do |point|
            x = point.fetch("longitude") * Math::PI / 180 * 6_378_137
            y = 6_378_137 * Math.log(Math.tan((Math::PI / 4) + (point.fetch("latitude") * Math::PI / 360)))
            point["pixel"] = [x / maximum * 1024, (ymax - y) / ymax * 1024]
            point["image_sha256"] = asset.fetch("sha256")
            point["review_status"] = "synthetic_map_transform"
          end
          path = File.join(root, entry.fetch("data_file"))
          data = JSON.parse(File.read(path))
          data.fetch("directions").each do |direction|
            if entry.fetch("code") == "G1" && direction.values_at("name", "calendar") == ["A", "school_break"]
              direction.fetch("stops").each { |stop| stop["times"] = [stop.fetch("times").first] }
            end
            if %w(G2 P1).include?(entry.fetch("code")) && direction.values_at("name", "calendar") == ["A", "school_day"]
              direction.fetch("stops").each_with_index do |stop, i|
                stop["times"] = [format("12:%02d", 10 + i * 5), format("13:%02d", 10 + i * 5)]
              end
              direction["seasonal_columns"] = { "0" => { "from" => "01-13", "through" => "02-15" } }
            end
            direction["trip_columns"] = direction.fetch("stops").first.fetch("times").size
          end
          bytes = JSON.generate(data); File.write(path, bytes)
          entry["data_sha256"] = Digest::SHA256.hexdigest(bytes)
        end
        bytes = JSON.generate("rows" => points); File.write(File.join(root, "points.json"), bytes)
        manifest.fetch("stop_locations")["sha256"] = Digest::SHA256.hexdigest(bytes)
        File.write(File.join(root, "manifest.json"), JSON.generate(manifest))
        File.write(File.join(root, "georeference.json"), JSON.generate(registration))
      end

      def synthetic_map_png
        chunk = ->(type, bytes) { [bytes.bytesize].pack("N") + type + bytes + [Zlib.crc32(type + bytes)].pack("N") }
        row = "\x00".b + ("\x44\x88\xaa".b * 1024)
        "\x89PNG\r\n\x1a\n".b + chunk.call("IHDR", [1024, 1024, 8, 2, 0, 0, 0].pack("NNCCCCC")) +
          chunk.call("IDAT", Zlib.deflate(row * 1024)) + chunk.call("IEND", "".b)
      end

      def image_body(url)
        File.binread(File.join(Data::DATA_PATH, Data.asset_for(url).fetch("file")))
      end

      def prepare_line(code)
        notice = @notices.find { |item| item.url == Data.manifest.fetch("routes").find { |entry| entry.fetch("code") == code }.dig("timetable", "url") }
        assert_equal :ok, @writer.prepare(notices: [notice]).first.fetch(:status)
        notice
      end

      def query_at(code, destination, time)
        @writer.query(origin: "Bijeljina (NAS)", destination:, notices: @notices, route_code: code,
                      requested_at: Time.find_zone!("Europe/Sarajevo").parse(time))
      end

      def departure(code, destination, time)
        itinerary = query_at(code, destination, time).itinerary
        return unless itinerary

        itinerary.legs.first.departure_at.in_time_zone("Europe/Sarajevo").strftime("%H:%M")
      end
    end
  end
end
