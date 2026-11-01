# frozen_string_literal: true

require "date"

class CreateDecidimAppParkingZoneStreets < ActiveRecord::Migration[7.2]
  TABLE = :decidim_app_parking_zone_streets
  SOURCE_URL = "https://www.gradbijeljina.org/lat/1687.parking-servis.html"
  SOURCE_MAP_URL = "https://www.gradbijeljina.org/UcitaneSlike/admin/MAPA.jpg"
  SOURCE_CHECKED_ON = Date.new(2026, 6, 30)

  STREET_ROWS = [
    ["Kneginje Milice", "kneginje milice", ["kneginje milice"], "red", "označeni segment na službenoj mapi"],
    ["Njegoševa", "njegoseva", ["njegoseva"], "red", "označeni segment na službenoj mapi"],
    ["Miloša Selimovića", "milosa selimovica", ["milos selimovic", "milosa selimovica"], "red", "označeni segment na službenoj mapi"],
    ["Karađorđeva", "karadjordjeva", ["karadjordjeva", "karadordeva", "karadjordjeva ulica"], "red", "označeni istočni segment na službenoj mapi"],
    ["Gavrila Principa", "gavrila principa", ["gavrila principa"], "red", "označeni segment na službenoj mapi"],
    ["Nikole Tesle", "nikole tesle", ["nikole tesle"], "red", "označeni segment na službenoj mapi"],
    ["Atinska", "atinska", ["atinska"], "red", "označeni segment na službenoj mapi"],
    ["Nušićeva", "nusiceva", %w(nusic nusiceva), "blue", "označeni segment na službenoj mapi"],
    ["Majevicka", "majevicka", ["majevicka"], "blue", "označeni segment na službenoj mapi"],
    ["Miloša Obilića", "milosa obilica", ["milos obilic", "milosa obilica"], "blue", "označeni segment na službenoj mapi"],
    ["Svetog Save", "svetog save", ["svetog save"], "blue", "označeni segment na službenoj mapi"],
    ["Save Kovačevića", "save kovacevica", ["save kovacevica"], "blue", "označeni segment na službenoj mapi"],
    ["Žrtava fašističkog terora", "zrtava fasistickog terora", ["zrtava fasistickog terora"], "blue", "označeni segment uz Gradski park na službenoj mapi"],
    ["Potporučnika Smajića", "potporucnika smajica", ["potporucnika smajica"], "blue", "označeni segment uz Gradski park na službenoj mapi"],
    ["Drage Glišica", "drage glisica", ["drage glisica"], "blue", "označeni segment na službenoj mapi"],
    ["Vojvode Stepe", "vojvode stepe", ["vojvode stepe"], "blue", "označeni segment na službenoj mapi"],
    ["Neznanih junaka", "neznanih junaka", ["neznanih junaka"], "blue", "označeni segment na službenoj mapi"],
    [
      "Trg kralja Petra I Karađorđevića",
      "trg kralja petra i karadjordjevica",
      ["trg kralja petra", "trg kralja petra i karadjordjevica"],
      "white",
      "zona centar na službenoj mapi"
    ],
    ["Filipa Višnjića", "filipa visnjica", ["filipa visnjica"], "white", "zona centar na službenoj mapi"],
    ["Vuka Karadžića", "vuka karadzica", ["vuka karadzica"], "white", "zona centar na službenoj mapi"]
  ].freeze

  def up
    create_table TABLE do |t|
      t.string :street_name, null: false
      t.string :normalized_street_name, null: false
      t.jsonb :aliases, null: false, default: []
      t.string :zone, null: false
      t.text :segment_note
      t.string :source_url, null: false
      t.string :source_map_url, null: false
      t.date :source_checked_on, null: false
      t.boolean :active, null: false, default: true

      t.timestamps
    end

    add_index TABLE, :normalized_street_name, unique: true, name: "idx_app_parking_zone_streets_normalized"
    add_index TABLE, :zone, name: "idx_app_parking_zone_streets_zone"
    add_index TABLE, :active, name: "idx_app_parking_zone_streets_active"

    seed_initial_rows
  end

  def down
    drop_table TABLE
  end

  private

  def seed_initial_rows
    now = Time.current
    # Static public seed rows; validations are unavailable inside this anonymous
    # migration model.
    # rubocop:disable Rails/SkipsModelValidations
    migration_model.insert_all(
      STREET_ROWS.map do |street_name, normalized_street_name, aliases, zone, segment_note|
        {
          street_name:,
          normalized_street_name:,
          aliases:,
          zone:,
          segment_note:,
          source_url: SOURCE_URL,
          source_map_url: SOURCE_MAP_URL,
          source_checked_on: SOURCE_CHECKED_ON,
          active: true,
          created_at: now,
          updated_at: now
        }
      end
    )
    # rubocop:enable Rails/SkipsModelValidations
  end

  def migration_model
    table_name = TABLE.to_s
    @migration_model ||= Class.new(ActiveRecord::Base).tap do |model|
      model.table_name = table_name
    end
  end
end
