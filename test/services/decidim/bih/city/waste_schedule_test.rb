# frozen_string_literal: true

require "test_helper"
require "webmock/minitest"

module Decidim
  module Bih
    module City
      # Exercises the GENERIC Komunalac-format parser against a SYNTHETIC
      # fixture (fictional area names — no Bijeljina data). The real Bijeljina
      # snapshot is held by the host app and tested in
      # DecidimApp::Bijeljina::WasteScheduleTest.
      #
      # The engine class is referenced via the normal autoloaded constant, so
      # the test does not depend on any sibling filesystem path.
      class WasteScheduleTest < ActiveSupport::TestCase
        SCHEDULE_URL = "https://example.test/waste/schedule.pdf"

        setup do
          WebMock.disable_net_connect!(allow_localhost: true)
          @text = file_fixture("komunalac_waste_schedule_synthetic.txt").read
          @schedule = WasteSchedule.from_text(@text)
        end

        teardown do
          WebMock.reset!
          WebMock.allow_net_connect!
        end

        test "parsing the fixture yields a non-empty area-to-days map" do
          assert_kind_of Hash, @schedule.schedule
          assert_not_empty @schedule.schedule
          assert_not_empty @schedule.areas

          @schedule.schedule.each_value do |days|
            assert_not_empty days
            days.each { |day| assert_includes WasteSchedule::WEEK_ORDER, day }
          end
        end

        test "raw extracted text is exposed" do
          assert_equal @text, @schedule.raw_text
        end

        test "collection_days_for a known area returns its day" do
          days = @schedule.collection_days_for("Виноградска")

          assert_not_nil days
          assert_includes days, "ponedjeljak"
        end

        test "days are returned in calendar order" do
          # Виноградска is collected on Понедељак and Петак in the fixture.
          days = @schedule.collection_days_for("Виноградска")

          assert_equal %w(ponedjeljak petak), days
          assert_equal(days, days.sort_by { |d| WasteSchedule::WEEK_ORDER.index(d) })
        end

        test "lookup is diacritic and script insensitive" do
          assert_equal @schedule.collection_days_for("Чаршија"),
                       @schedule.collection_days_for("carsija")
          assert_not_nil @schedule.collection_days_for("carsija")
        end

        test "lookup does partial contains matching" do
          assert_equal @schedule.collection_days_for("Виноградска"),
                       @schedule.collection_days_for("vinograd")
          assert_not_nil @schedule.collection_days_for("vinograd")
        end

        test "unknown area returns nil" do
          assert_nil @schedule.collection_days_for("Atlantida")
          assert_nil @schedule.collection_days_for("")
          assert_nil @schedule.collection_days_for(nil)
        end

        test "an exact area match is not polluted by a superstring area's days" do
          # "Дворови" (Mon) and "Нови Дворови" (Tue) — querying the shorter name
          # must NOT also return the longer street's day via substring matching.
          text = <<~TXT
            Рејон 1


                     Понедељак         Уторак         Сриједа
             РБ
                        Село            Село            Село

              1. Дворови           Нови Дворови     Тестово
          TXT
          schedule = WasteSchedule.from_text(text)

          assert_equal %w(ponedjeljak), schedule.collection_days_for("Дворови")
          assert_equal %w(utorak), schedule.collection_days_for("Нови Дворови")
        end

        test "municipality structural labels are host configurable" do
          text = <<~TXT
            Рејон 1


                     Понедељак         Уторак         Сриједа
             РБ
                        Село            Село            Село

              1. Главни град       Тестово         Другово
          TXT

          generic = WasteSchedule.from_text(text)
          filtered = WasteSchedule.from_text(
            text,
            structural_labels: WasteSchedule::STRUCTURAL_LABELS + ["Главни град"]
          )

          assert_includes generic.areas, "Главни град"
          assert_not_includes filtered.areas, "Главни град"
          assert_nil filtered.collection_days_for("Главни град")
        end

        test "areas lists known places" do
          assert(@schedule.areas.any? { |a| a.include?("Виноградска") })
        end

        test "a freshly constructed schedule has no data until something is loaded" do
          assert_empty WasteSchedule.new.schedule
          assert_empty WasteSchedule.new.areas
        end

        test "fetch downloads and parses the live PDF from the given url" do
          stub_request(:get, SCHEDULE_URL)
            .to_return(status: 200, body: minimal_pdf, headers: { "Content-Type" => "application/pdf" })

          schedule = WasteSchedule.new(schedule_url: SCHEDULE_URL).fetch

          assert_not_empty schedule.raw_text
        end

        test "fetch raises on transport failure" do
          stub_request(:get, SCHEDULE_URL).to_return(status: 502)

          assert_raises(WasteScheduleError) do
            WasteSchedule.new(schedule_url: SCHEDULE_URL).fetch
          end
        end

        test "fetch raises when no url is configured" do
          assert_raises(WasteScheduleError) { WasteSchedule.new.fetch }
        end

        private

        # Minimal single-page PDF carrying one extractable ASCII line, enough to
        # exercise the download + pdf-reader transport path.
        def minimal_pdf
          content = "BT /F1 12 Tf 72 720 Td (waste schedule stub) Tj ET"
          objects = []
          objects << "1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj"
          objects << "2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj"
          objects << "3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 612 792]" \
                     "/Resources<</Font<</F1 5 0 R>>>>/Contents 4 0 R>>endobj"
          objects << "4 0 obj<</Length #{content.bytesize}>>stream\n#{content}\nendstream endobj"
          objects << "5 0 obj<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>endobj"
          header = "%PDF-1.4\n"
          body = +""
          offsets = []
          objects.each do |obj|
            offsets << (header.bytesize + body.bytesize)
            body << obj << "\n"
          end
          xref_pos = header.bytesize + body.bytesize
          xref = "xref\n0 #{objects.size + 1}\n0000000000 65535 f \n"
          offsets.each { |off| xref << format("%010d 00000 n \n", off) }
          trailer = "trailer<</Size #{objects.size + 1}/Root 1 0 R>>\n" \
                    "startxref\n#{xref_pos}\n%%EOF"
          header + body + xref + trailer
        end
      end
    end
  end
end
