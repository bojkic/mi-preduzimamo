# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/synthetic_source_documents"

module DecidimApp
  module Bijeljina
    class CityServiceSourceShapeTest < ActiveSupport::TestCase
      setup do
        @matcher = RecordingMatcher.new
        @now = Time.find_zone!("Europe/Sarajevo").parse("2026-09-09 07:00")
      end

      # Invented long list exercises word-boundary shortening.
      test "outage title and viber line shorten on a word and drop the source's place label" do
        affected = "Naseljena mjesta: Primjer Prvi, Primjer Drugi, Primjer Treći, Primjer Četvrti, Primjer Peti, Primjer Šesti, Primjer Sedmi"
        title = ElectricityOutageParser.citizen_title(affected)
        viber = ElectricityOutageParser.viber_text(affected:, date: Date.new(2026, 9, 23), from: "08:00", to: "16:00")

        assert_operator title.length, :<=, "Planirano isključenje struje: ".length + 80
        assert_equal "Planirano isključenje struje: Primjer Prvi, Primjer Drugi, Primjer Treći, Primjer Četvrti, Primjer Peti…", title
        assert_equal "Primjer Prvi, Primjer Drugi, Primjer Treći, Primjer Četvrti…: planirano isključenje struje 23.09. od 08:00 do 16:00.", viber
        assert_equal "Planirano isključenje struje: Izmišljeni vrh, Izmišljeni vrt",
                     ElectricityOutageParser.citizen_title("Naseljena mjesta: Izmišljeni vrh, Izmišljeni vrt")
        assert_equal "Planirano isključenje struje: Ulice: Izmišljena cesta", ElectricityOutageParser.citizen_title("Ulice: Izmišljena cesta")
        assert_equal "Planirano isključenje struje: 1 NN izlaz", ElectricityOutageParser.citizen_title("1 NN izlaz")
      end

      test "invented electricity page produces ten distinct rows under three date headings" do
        events = electricity(SyntheticSourceDocuments.electricity_page)

        assert_equal 10, events.size
        assert_equal({ Date.new(2026, 9, 9) => 4, Date.new(2026, 9, 16) => 1, Date.new(2026, 9, 23) => 5 }, events.group_by do |event|
          event.starts_at.to_date
        end.transform_values(&:size))
        assert_equal "TS IZMIŠLJENI KRUG 6", events.first.extraction_metadata.fetch("feeder")
        assert_equal "1 NN izlaz", events.first.affected_text
        assert_equal "09:00", events.first.starts_at.strftime("%H:%M")
        assert_equal "14:00", events.first.ends_at.strftime("%H:%M")
        assert(events.all? { |event| event.ends_at > event.starts_at })
        assert(events.none? { |event| event.affected_text.match?(/\A\(Srijeda\)\z/) })
        assert_equal "unknown", events.first.targeting_level
        assert_not_includes @matcher.inputs.first, "IZMIŠLJENI KRUG"
        # The feeder is retained as operator evidence (asserted above) and kept
        # OUT of what a resident reads: "TS IZMIŠLJENI KRUG 6" names a circuit, not a
        # place anyone lives. The date, which a board carrying several days
        # cannot do without, is there instead.
        assert_not_includes events.first.summary, "TS IZMIŠLJENI KRUG 6"
        assert_includes events.first.summary, "09.09.2026."
      end

      test "invalid and absent table dates never inherit a previous date or become times" do
        html = "<p>09-09-2026 (Srijeda)</p><table></table><p>31-09-2026 (Četvrtak)</p>#{table_row}"
        assert_unresolved electricity(html)
        assert_empty electricity("<table><tr><td>09-09-2026 (Srijeda)</td></tr></table>")
        assert_empty electricity("<p>09-09-2026</p><table><tr><td>missing cells</td></tr></table>")
      end

      test "overnight is accepted only with explicit source support and invalid clocks are rejected" do
        ordinary = "<p>09-09-2026</p>#{table_row(from: "22:00", to: "02:00")}"
        assert_unresolved electricity(ordinary)
        event = electricity(ordinary.sub("Radovi", "Noćni radovi preko ponoći")).sole
        assert_equal Date.new(2026, 9, 10), event.ends_at.to_date
        assert_unresolved electricity("<p>09-09-2026</p>#{table_row(from: "29:00")}")
        assert_unresolved electricity("<p>09-09-2026</p>#{table_row(to: "14:99")}")
      end

      test "same feeder occurrence keeps identity while a corrected time changes content version" do
        html = "<p>09-09-2026</p>#{table_row}"
        original = electricity(html).sole
        repeated = electricity(html).sole
        corrected = electricity(html.sub("14:00", "15:00")).sole
        assert_equal original.source_occurrence_id, repeated.source_occurrence_id
        assert_equal original.content_version, repeated.content_version
        assert_equal original.source_occurrence_id, corrected.source_occurrence_id
        assert_not_equal original.content_version, corrected.content_version
      end

      test "water primary article keeps both affected groups and excludes related normal-service text" do
        events = official(SyntheticSourceDocuments.water_page, now: @now - 1.day)
        assert_equal 2, events.size
        assert_equal(["08:00", "06:00"], events.map { |event| event.starts_at.strftime("%H:%M") })
        assert_equal(["14:30", "23:00"], events.map { |event| event.ends_at.strftime("%H:%M") })
        assert_equal [Date.new(2026, 9, 8)], events.map { |event| event.starts_at.to_date }.uniq
        assert_includes events.first.affected_text, "Измишљена улица"
        assert_includes events.last.affected_text, "izmisljenom polju"
        assert_not_includes events.last.affected_text, "130 metara"
        assert(events.all? { |event| event.targeting_level == "unknown" })
        assert(@matcher.inputs.none? { |text| CityServiceTime.fold(text).match?(/uredno|ostalim|u gradu/) })
        assert_equal Time.iso8601("2026-09-08T07:53:03+02:00"), events.first.source_published_at
      end

      test "a partial listing does not turn missing location bullets into a definite event" do
        html = "<article><p>08. septembra 2026. od 08:00 do 14:30 moguć je prekid vodosnabdijevanja na sljedećoj lokaciji:</p></article>"
        assert_empty official(html, now: @now - 1.day)
        assert_empty official(html.sub("lokaciji:", "lokaciji…"), now: @now - 1.day)
      end

      test "water same URL time correction is a version change without changed occurrence" do
        html = SyntheticSourceDocuments.water_page
        original = official(html, now: @now - 1.day)
        corrected = official(html.sub("14:30", "15:30"), now: @now - 1.day)
        assert_equal original.map(&:source_occurrence_id), corrected.map(&:source_occurrence_id)
        assert_not_equal original.first.content_version, corrected.first.content_version
      end

      test "date without clock range has half-open day query bounds and explicit day precision" do
        event = official("<article><p>09-09-2026 obustava vodosnabdijevanja u Izmišljenom vrtu zbog radova.</p></article>").sole
        assert_equal "00:00", event.starts_at.strftime("%H:%M")
        assert_equal "00:00", event.ends_at.strftime("%H:%M")
        assert_equal event.starts_at.to_date + 1, event.ends_at.to_date
        assert_equal "day", event.extraction_metadata.fetch("temporal_precision")
      end

      test "street spraying is classified as spraying instead of road closure" do
        event = official("<article><p>09.09.2026. od 20:00 do 23:00 zaprašivanje komaraca u ulici Izmišljenog drveta.</p></article>", key: "city_official_notices").sole
        assert_equal "mosquito_spraying", event.event_type
      end

      test "September ninth publication retains September twelfth overnight effective dates" do
        html = '<article><time datetime="2026-09-09T07:53:00+02:00"></time><p>' \
               "12.09.2026. od 23:00 do 02:00 narednog dana prekid vodosnabdijevanja u Izmišljenom vrtu zbog noćnih radova.</p></article>"
        event = official(html, now: @now + 2.hours).sole
        assert_equal Time.iso8601("2026-09-09T07:53:00+02:00"), event.source_published_at
        assert_equal Time.iso8601("2026-09-12T23:00:00+02:00"), event.starts_at
        assert_equal Time.iso8601("2026-09-13T02:00:00+02:00"), event.ends_at
        assert_equal 3.hours, event.ends_at - event.starts_at
        assert_equal "scheduled", event.lifecycle
      end

      test "cancelled road works mentioning a street cannot become an active road closure" do
        html = "<article><p>12.09.2026. od 08:00 do 14:00 otkazani su radovi i obustava saobraćaja u ulici Izmišljenog drveta.</p></article>"
        event = official(html, key: "city_official_notices").sole
        assert_equal "cancellation_update", event.event_type
        assert_equal "cancelled", event.lifecycle
        assert_not_equal "road_closure", event.event_type
        assert_empty official("<article><p>12.09.2026. od 08:00 do 14:00 neće biti obustave saobraćaja u ulici Izmišljenog drveta.</p></article>", key: "city_official_notices")
      end

      test "negated interruption is excluded and a cancellation has cancelled lifecycle" do
        assert_empty official("<article><p>09.09.2026. od 08:00 do 14:00 neće biti prekida vodosnabdijevanja u Izmišljenom vrtu.</p></article>")
        event = official("<article><p>09.09.2026. otkazuje se najavljeni prekid vodosnabdijevanja u Izmišljenom vrtu.</p></article>").sole
        assert_equal "cancellation_update", event.event_type
        assert_equal "cancelled", event.lifecycle
      end

      test "expected restoration is not a statement that service was restored" do
        event = official("<article><p>09.09.2026. zbog kvara prekid vodosnabdijevanja u Izmišljenom vrtu, očekuje se normalizacija.</p></article>").sole
        assert_equal "unplanned_interruption", event.event_type
        restored = official("<article><p>09.09.2026. vodosnabdijevanje je normalizovano u Izmišljenom vrtu.</p></article>").sole
        assert_equal "resolved", restored.lifecycle
      end

      test "separate dated windows retain their own locations and relative date uses publication" do
        html = '<html><head><meta property="article:published_time" content="2026-09-09T07:00:00+02:00"></head><body><article><p>' \
               "Danas od 08:00 do 10:00 prekid vodosnabdijevanja u Izmišljenom vrtu.</p><p>" \
               "10.09.2026. od 12:00 do 14:00 prekid vodosnabdijevanja u Izmišljenom polju.</p></article></body></html>"
        events = official(html)
        assert_equal 2, events.size
        assert_equal([9, 10], events.map { |event| event.starts_at.day })
        assert_equal ["izmisljenom vrtu.", "izmisljenom polju."], events.map(&:affected_text)
        assert_equal 1, official(html, now: @now + 1.day).size
      end

      test "a mixed paragraph keeps outage facts while removing reassurance for other locations" do
        html = "<article><p>09.09.2026. od 08:00 do 14:00 prekid vodosnabdijevanja u Izmišljenom vrtu. Na svim ostalim lokacijama u gradu vodosnabdijevanje će biti uredno.</p></article>"
        event = official(html).sole
        assert_equal "izmisljenom vrtu", event.affected_text
        assert_not_includes event.summary, "uredno"
      end

      test "two ranges in one paragraph retain each explicit date" do
        html = "<article><p>09.09.2026. od 08:00 do 10:00 prekid vodosnabdijevanja u Izmišljenom vrtu; 10.09.2026. od 12:00 do 14:00 prekid vodosnabdijevanja u Izmišljenom polju.</p></article>"
        events = official(html)
        assert_equal([9, 10], events.map { |event| event.starts_at.day })
        assert_equal(["08:00", "12:00"], events.map { |event| event.starts_at.strftime("%H:%M") })
      end

      test "truncated primary article is incomplete and spring daylight saving gaps are rejected" do
        assert_empty official("<article><p>09.09.2026. od 08:00 do 14:00 prekid vodosnabdijevanja u Izmišljenom vrtu.")
        assert_nil CityServiceTime.clock(Date.new(2026, 3, 29), "02:30")
        assert_equal 3600, CityServiceTime.clock(Date.new(2026, 1, 9), "09:00").utc_offset
        assert_equal 7200, CityServiceTime.clock(Date.new(2026, 9, 9), "09:00").utc_offset
      end

      test "three-day works yield separate daily shifts with source evidence and no overnight outage" do
        html = SyntheticSourceDocuments.daily_works_page
        events = official(html)
        assert_equal([9, 10, 11], events.map { |event| event.starts_at.day })
        assert_equal ["08:00"], events.map { |event| event.starts_at.strftime("%H:%M") }.uniq
        assert_equal ["14:00"], events.map { |event| event.ends_at.strftime("%H:%M") }.uniq
        assert(events.all? { |event| event.starts_at.to_date == event.ends_at.to_date })
        assert_equal 3, events.map(&:source_occurrence_id).uniq.size
        assert(events.all? { |event| event.extraction_metadata["recurrence"] == "daily" })
        assert(events.all? { |event| event.extraction_metadata["temporal_evidence"].include?("11.09.2026") })
        assert(events.all? { |event| event.affected_text == "Dio Ulice Izmišljenog vrta" })
        reread = official(html, now: @now + 1.day)
        assert_equal events.drop(1).map(&:source_occurrence_id), reread.map(&:source_occurrence_id)
        assert_unresolved official(html.sub("svakog dana ", ""))
      end

      test "short named date spans and bounded daily duration expand while unbounded schedules stay unresolved" do
        prefix = "<article><p>"
        suffix = " od 08:00 do 14:00 prekid vodosnabdijevanja u Izmišljenom vrtu.</p></article>"
        events = official("#{prefix}Od 9. do 11. septembra 2026. svakog dana#{suffix}")
        assert_equal([9, 10, 11], events.map { |event| event.starts_at.day })
        duration = official("#{prefix}09.09.2026. naredna tri dana svakodnevno#{suffix}")
        assert_equal([9, 10, 11], duration.map { |event| event.starts_at.day })
        assert_unresolved official("#{prefix}09.09.2026. svakodnevno#{suffix}")
        assert_unresolved official("#{prefix}Od 09.09.2026. do 11.11.2026. svakog dana#{suffix}")
        assert_unresolved official("#{prefix}Od 11.09.2026. do 09.09.2026. svakog dana#{suffix}")
      end

      test "explicit continuous cross-date clocks require source wording and keep their actual endpoints" do
        html = "<article><p>Neprekidno od 09.09.2026. u 08:00 do 11.09.2026. u 14:00 prekid vodosnabdijevanja u Izmišljenom vrtu.</p></article>"
        event = official(html).sole
        assert_equal Date.new(2026, 9, 9), event.starts_at.to_date
        assert_equal Date.new(2026, 9, 11), event.ends_at.to_date
        assert_equal "continuous", event.extraction_metadata["recurrence"]
        assert_unresolved official(html.sub("Neprekidno ", ""))
      end

      test "tomorrow is anchored to December publication and a January reread cannot manufacture another outage" do
        html = '<article><time datetime="2026-12-31T15:00:00+01:00"></time><p>Sutra od 08:00 do 14:00 prekid vodosnabdijevanja u Izmišljenom vrtu.</p></article>'
        event = official(html, now: Time.iso8601("2026-12-31T16:00:00+01:00")).sole
        assert_equal Date.new(2027, 1, 1), event.starts_at.to_date
        assert_empty official(html, now: Time.iso8601("2027-01-02T07:00:00+01:00"))
        assert_equal Date.new(2027, 1, 1), CityServiceTime.date("sutra", reference: event.source_published_at)
      end

      test "ambiguous autumn clocks stay unresolved but intervals spanning the fold preserve actual elapsed time" do
        assert_nil CityServiceTime.clock(Date.new(2026, 10, 25), "02:30")
        interval = CityServiceTime.window(Date.new(2026, 10, 25), from: "01:30", to: "03:30")
        assert_equal 3.hours, interval[:ends_at] - interval[:starts_at]
        assert_empty CityServiceTime.schedule("Od 28.03.2026. do 30.03.2026. svakog dana", date: Date.new(2026, 3, 28),
                                                                                           reference: nil, from: "02:30", to: "04:00")
      end

      private

      def assert_unresolved(events)
        event = events.sole
        assert_equal false, event.extraction_metadata["complete"]
        assert_equal "unknown", event.extraction_metadata["temporal_precision"]
        assert event.extraction_metadata["temporal_status"].present?
      end

      class RecordingMatcher
        attr_reader :inputs

        Match = Struct.new(:targeting_level, :slugs, keyword_init: true) do
          def unknown? = targeting_level == "unknown"
        end
        def initialize = @inputs = []

        def match(text)
          @inputs << text
          Match.new(targeting_level: "unknown", slugs: [])
        end
      end

      def electricity(html)
        ElectricityOutageParser.new(organization: nil, source: SyntheticSourceDocuments.source("electricity_outages"), area_matcher: @matcher).call(html:, fetched_at: @now)
      end

      def official(html, key: "water_service", now: @now)
        CityServiceOfficialPostParser.new(organization: nil, source: SyntheticSourceDocuments.source(key), area_matcher: @matcher).call(html:, fetched_at: now)
      end

      def table_row(from: "09:00", to: "14:00")
        "<table><tr><td>Izmišljeni distrikt</td><td>TS 1</td><td>1 NN izlaz</td><td>Radovi</td><td>#{from}</td><td>#{to}</td></tr></table>"
      end
    end
  end
end
