# frozen_string_literal: true
require "tmpdir"
require "fileutils"
require "yaml"
require "json"

# Twenty-one independent text documents, not transformed provider PDF captures.
module SyntheticPreparedTransportCorpus
  def install_authored_transport_corpus
    @authored_transport_root = Dir.mktmpdir("authored-transport-corpus-")
    sources = DecidimApp::Bijeljina::CityServiceSources
    @authored_transport_prior_sources = sources::SOURCES
    descriptor = sources::REFERENCE_SOURCES.find { |row| row.fetch(:key) == "public_transport" }
      .deep_dup.merge(enabled: true, provider: "Izmišljeni prevoznik", source_url: "https://community.example.invalid/authored/transport")
    sources.send(:remove_const, :SOURCES)
    sources.const_set(:SOURCES, [descriptor].freeze)
    registry = { "Primjergrad (sud)" => [0.5, 0.5] }
    documents = (1..21).map do |index|
      origin = "Primjergrad (sud)"
      middle = index == 1 ? "Primjergrad (centar)" : "Autorsko stajalište #{index}"
      destination = index == 1 ? "Primjerpolje (škola)" : "Izmišljeni terminal #{index}"
      registry[middle] = [0.53 + index * 0.002, 0.53]
      registry[destination] = [0.54 + index * 0.002, 0.54]
      minutes = index == 1 ? [491, 701, 981] : [420 + index, 600 + index, 840 + index]
      times = ->(offset) { minutes.map { |value| format("%02d:%02d", (value + offset) / 60, (value + offset) % 60) }.join(" ") }
      rows = [
        ["Radni dan Smjer A", "Smjer B"],
        ["#{origin}  2,13  #{times.call(0)}", "#{destination}  2,13  #{times.call(40)}"],
        ["#{middle}  3,24  #{times.call(6)}", "#{middle}  3,24  #{times.call(52)}"],
        ["#{destination}  4,31  #{times.call(18)}", "#{origin}  4,31  #{times.call(58)}"],
        ["Subota Smjer A", "Smjer B"],
        ["#{origin}  2,13  12:16 15:16", "#{destination}  2,13  13:01 16:01"],
        ["#{middle}  3,24  12:22 15:22", "#{middle}  3,24  13:13 16:13"],
        ["#{destination}  4,31  12:34 15:34", "#{origin}  4,31  13:19 16:19"],
        ["Nedjelja Smjer A", "Smjer B"],
        ["#{origin}  2,13", "#{destination}  2,13"],
        ["#{middle}  3,24", "#{middle}  3,24"],
        ["#{destination}  4,31", "#{origin}  4,31"]
      ]
      fixture = "authored-p#{index}"
      text = ["P#{index} — IZMIŠLJENI TEST", *rows.map { |left, right| left.ljust(90) + right }].join("\n")
      File.write(File.join(@authored_transport_root, "#{fixture}.txt"), text)
      { "fixture" => fixture, "title" => "P#{index} — IZMIŠLJENI TEST", "url" => "https://community.example.invalid/authored/p#{index}.pdf" }
    end
    File.write(File.join(@authored_transport_root, "sources.json"), JSON.generate(documents))
    File.write(File.join(@authored_transport_root, "stops.yml"), YAML.dump("stops" => registry.map do |label, (latitude, longitude)|
      { "label" => label, "latitude" => latitude, "longitude" => longitude, "accuracy" => "assumed",
        "source" => "https://community.example.invalid/authored/stop-map", "confidence" => "authored_not_surveyed" }
    end))
  rescue StandardError
    restore_authored_transport_corpus
    raise
  end

  def restore_authored_transport_corpus
    if @authored_transport_prior_sources
      owner = DecidimApp::Bijeljina::CityServiceSources
      owner.send(:remove_const, :SOURCES)
      owner.const_set(:SOURCES, @authored_transport_prior_sources)
    end
    FileUtils.remove_entry_secure(@authored_transport_root) if @authored_transport_root && File.directory?(@authored_transport_root)
  end
end
