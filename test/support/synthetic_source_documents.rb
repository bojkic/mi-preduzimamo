# frozen_string_literal: true

# Source grammar examples authored for public tests, never provider captures.
module SyntheticSourceDocuments
  module_function

  def source(key)
    template = DecidimApp::Bijeljina::CityServiceSources::REFERENCE_SOURCES.find { |row| row.fetch(:key) == key }
    raise KeyError, "Unknown reference adapter" unless template

    template.deep_dup.merge(label: "Izmišljeni izvor #{key}", provider: "Izmišljeni pružalac",
                            source_url: "https://community.example.invalid/#{key}", enabled: true)
  end

  def electricity_page
    [[9, 4], [16, 1], [23, 5]].map do |day, count|
      rows = Array.new(count) do |index|
        "<tr><td>Izmišljeni distrikt</td><td>TS IZMIŠLJENI KRUG #{index + 6}</td>" \
          "<td>#{index.zero? ? '1 NN izlaz' : "Izmišljeni potrošači #{index}"}</td><td>Radovi</td><td>09:00</td><td>14:00</td></tr>"
      end.join
      "<p>#{day}-09-2026 (Srijeda)</p><table>#{rows}</table>"
    end.join
  end

  def water_page
    '<html><head><meta property="article:published_time" content="2026-09-08T07:53:03+02:00"></head><body><article>' \
      '<p>08. septembra 2026. od 08:00 do 14:30 moguć je prekid vodosnabdijevanja na sljedećoj lokaciji:</p>' \
      '<ul><li>Измишљена улица</li></ul>' \
      '<p>08. septembra 2026. od 06:00 do 23:00 prekid vodosnabdijevanja u Izmišljenom polju zbog radova.</p>' \
      '</article><aside><p>U ostalim dijelovima grada uredno vodosnabdijevanje. Radovi dužine 130 metara.</p></aside></body></html>'
  end

  def daily_works_page
    '<article><p>Od 09.09.2026. do 11.09.2026. svakog dana od 08:00 do 14:00 prekid vodosnabdijevanja na sljedećoj lokaciji:</p>' \
      '<ul><li>Dio Ulice Izmišljenog vrta</li></ul></article>'
  end
end
