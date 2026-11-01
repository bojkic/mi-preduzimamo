# frozen_string_literal: true

# Authored names and links, never transformed from a real GIS or area export.
module SyntheticPlaceAreas
  module_function

  def areas(area_class)
    definitions = [
      ["mz", "mz-vrt", "Vrt"], ["mz", "mz-lugovi", "Lugovi"],
      ["mz", "mz-novi-lugovi", "Novi Lugovi"], ["mz", "mz-novi", "Novi"],
      ["mz", "mz-srediste", "Središte"], ["mz", "mz-veliki-park", "Veliki Park"],
      ["mz", "mz-brijeg", "Brijeg"], ["mz", "mz-gaj-donji", "Gaj Donji"], ["mz", "mz-gaj-gornji", "Gaj Gornji"], ["mz", "mz-zorice", "Zorice"],
      ["komsiluk", "komsiluk-vrt", "Vrt", "mz-vrt"], ["komsiluk", "komsiluk-lugovi", "Lugovi", "mz-lugovi"],
      ["komsiluk", "komsiluk-rub", "Rub", "mz-novi-lugovi", %w(mz-vrt mz-lugovi)],
      ["komsiluk", "komsiluk-novi", "Novi", "mz-novi"],
      ["komsiluk", "komsiluk-srediste", "Središte", "mz-srediste"],
      ["komsiluk", "komsiluk-srediste-drugi", "Središte Drugi", "mz-srediste"],
      ["komsiluk", "komsiluk-park", "Veliki Park", "mz-veliki-park"],
      ["komsiluk", "komsiluk-park-drugi", "Veliki Park Drugi", "mz-veliki-park"],
      ["komsiluk", "komsiluk-brijeg", "Brijeg", "mz-brijeg"],
      ["komsiluk", "komsiluk-gaj-donji", "Gaj Donji", "mz-gaj-donji"],
      ["komsiluk", "komsiluk-gaj-gornji", "Gaj Gornji", "mz-gaj-gornji"],
      ["komsiluk", "komsiluk-zorice", "Zorice", "mz-zorice"]
    ]
    definitions.each_with_index.map do |(kind, slug, label, primary, overlaps), index|
      area_class.new(id: index + 1, kind:, slug:, name: { "sr" => "#{kind == 'mz' ? 'MZ' : 'Komšiluk'} #{label}" },
                     primary_mz_slug: primary, overlapping_mz_slugs: overlaps || [], boundary: nil)
    end
  end

  def aliases
    { "revision" => "synthetic-places-v1", "reviewed_on" => "2040-04-09", "inflections" => {
      "brijeg" => ["donji brijeg", "gornji brijeg"], "vrt" => ["vrtu"], "lugovi" => ["lugovima"], "srediste" => ["sredistu"], "zorice" => ["zorica"],
      "gaj donji" => ["donji gaj", "donjeg gaja"], "gaj gornji" => ["gornji gaj", "gornjeg gaja"]
    } }
  end
end
