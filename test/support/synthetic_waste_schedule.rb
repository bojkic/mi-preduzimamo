# frozen_string_literal: true
require "tmpdir"
require "fileutils"
require "json"

# Independent authored text table and household registry. No copied municipal
# programme, personal conversation or actual collection-day advice.
module SyntheticWasteSchedule
  def install_synthetic_waste_schedule
    host = DecidimApp::Bijeljina::WasteSchedule
    @synthetic_waste_constants = []
    @synthetic_waste_cache = [host.instance_variable_defined?(:@default), host.instance_variable_get(:@default)]
    host.remove_instance_variable(:@default) if host.instance_variable_defined?(:@default)
    @synthetic_waste_env = ENV["MI_WASTE_SOURCE_URL"]
    ENV.delete("MI_WASTE_SOURCE_URL")
    @synthetic_waste_root = Dir.mktmpdir("synthetic-waste-")
    text_path = File.join(@synthetic_waste_root, "schedule.txt")
    headers = %w(Понедјељак Уторак Сриједа Четвртак Петак)
    # Deliberate wide columns exercise the real text parser's offset grammar.
    text = "ИЗМИШЉЕНИ РАСПОРЕД — није стварно упутство.\nРејон 5\n" + headers.map { |v| v.ljust(30) }.join.rstrip + "\n"
    text += ["Измишљено поље", "", "", "", "Измишљена ливада"].map { |v| v.ljust(30) }.join.rstrip + "\n"
    File.write(text_path, text)
    specs = [
      ["Измишљена липа", 1, 2, nil, 2], ["Измишљена липа", 3, 3, nil, 4],
      ["Измишљена бреза", 2, 1, nil, 3], ["Измишљени јавор", 3, 4, nil, 4],
      ["Измишљени бор", 4, 3, nil, 5], ["Измишљени багрем", 2, 1, nil, 3],
      ["Измишљени багрем", 3, 3, nil, 4], ["Измишљени храст", 5, 2, "Измишљено поље", 6]
    ]
    rows = specs.each_with_index.map do |(place, district, weekday, settlement, page), i|
      { "id" => "authored-route-#{i}", "place" => place, "district" => district, "weekday" => weekday,
        "settlement" => settlement, "aliases" => [], "scope" => "household", "route_kind" => "household", "source_pdf_page" => page }
    end
    registry_path = File.join(@synthetic_waste_root, "routes.json")
    File.write(registry_path, JSON.generate("captured_on" => "2040-09-14", "valid_from" => "2040-01-01", "valid_until" => "2040-12-31",
      "timezone" => "Europe/Sarajevo", "rows" => rows, "exceptions" => []))
    { BUNDLED_TEXT_PATH: text_path, ROUTE_REGISTRY_PATH: registry_path, DATA_YEAR: 2040,
      SOURCE_CAPTURED_ON: Date.new(2040, 9, 14), DEFAULT_SCHEDULE_URL: "https://community.example.invalid/authored-waste.pdf" }.each do |name, value|
      @synthetic_waste_constants << [name, host.const_get(name, false)]
      host.send(:remove_const, name)
      host.const_set(name, value)
    end
  rescue StandardError
    restore_synthetic_waste_schedule
    raise
  end

  def restore_synthetic_waste_schedule
    return unless @synthetic_waste_constants
    host = DecidimApp::Bijeljina::WasteSchedule
    @synthetic_waste_constants.reverse_each do |name, prior|
      host.send(:remove_const, name)
      host.const_set(name, prior)
    end
    host.remove_instance_variable(:@default) if host.instance_variable_defined?(:@default)
    host.instance_variable_set(:@default, @synthetic_waste_cache.last) if @synthetic_waste_cache.first
    @synthetic_waste_env.nil? ? ENV.delete("MI_WASTE_SOURCE_URL") : ENV["MI_WASTE_SOURCE_URL"] = @synthetic_waste_env
    FileUtils.remove_entry_secure(@synthetic_waste_root) if @synthetic_waste_root && File.directory?(@synthetic_waste_root)
    @synthetic_waste_constants = nil
  end
end
