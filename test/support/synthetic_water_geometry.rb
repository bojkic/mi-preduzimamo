# frozen_string_literal: true
require "digest"
require "json"

# Independent rectangles/lines in a toy coordinate system; no municipal GIS.
module SyntheticWaterGeometry
  def water_rectangle(left, right)
    { "type" => "Polygon", "coordinates" => [[[left, 0], [right, 0], [right, 1], [left, 1], [left, 0]]] }
  end

  def water_geometry_digest(geometry)
    Digest::SHA256.hexdigest("#{geometry.fetch('type')}|#{geometry.fetch('coordinates').to_json}")
  end

  def authored_water_areas(area_class)
    rows = (0...8).map { |index| area_class.new("komsiluk-#{('a'.ord + index).chr}", "komsiluk", water_rectangle(index, index + 1)) }
    rows << area_class.new("mz-authored", "mz", water_rectangle(0, 8))
    rows
  end

  def authored_water_streets
    specs = [
      ["Izmišljena lipa", "Izmišljeni grad", 0.2, 0.8],
      ["Izmišljena breza", "Nova Luka", 1.2, 2.8],
      ["Izmišljeni javor", "Nova Luka", 2.2, 2.8],
      ["Izmišljeni hrast", "Nova Luka", 2.3, 2.7],
      ["Izmišljeni bor", "Izmišljeni grad", 0.3, 0.7],
      ["Izmišljena bukva", "Nova Luka", 1.3, 1.7]
    ]
    { "features" => specs.each_with_index.map do |(name, settlement, left, right), index|
      { "type" => "Feature", "geometry" => { "type" => "LineString", "coordinates" => [[left, 0.5], [right, 0.5]] },
        "properties" => { "name" => name, "settlement" => settlement, "geometry_complete" => true,
          "source_url" => "https://community.example.invalid/authored-street/#{index}",
          "source_object_ids" => ["authored-street-#{index}"], "retrieved_at" => "2040-01-01" } }
    end }
  end

  def authored_water_settlements(areas)
    specs = [["Nova Luka", 1.05, 7.95], ["Testna dolina", 0.05, 7.95],
      ["Vrt", 3.1, 3.9], ["Lug", 4.1, 4.9], ["Gaj", 6.1, 6.9]]
    features = specs.map.with_index do |(name, left, right), index|
      geometry = water_rectangle(left, right)
      slugs = areas.select do |area|
        xs = area.boundary.fetch("coordinates").flatten(1).map(&:first)
        xs.min < right && xs.max > left
      end.map(&:slug)
      { "type" => "Feature", "geometry" => geometry, "properties" => { "name" => name,
        "aliases" => [], "place_type" => "settlement", "geometry_complete" => true,
        "geometry_sha256" => water_geometry_digest(geometry), "area_slugs" => slugs,
        "source_url" => "https://community.example.invalid/authored-settlement/#{index}",
        "source_settlement_id" => "authored-#{index}", "source_snapshot_sha256" => Digest::SHA256.hexdigest("authored-water-settlements-v1") } }
    end
    { "features" => features, "boundary_sha256" => areas.to_h { |area| [area.slug, water_geometry_digest(area.boundary)] } }
  end
end
