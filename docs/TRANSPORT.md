# Podešavanje pregledanog reda vožnje

Transportni kalkulator koristi pregledane izvore i pripremljene podatke. Bez konfigurisanih lokalnih podataka nema podrazumijevanog reda vožnje, stajališta ili kalendara. Skupovi Bijeljine nisu dio javnog izvoza.

## Podešavanja zajednice

- `MI_REVIEWED_TRANSPORT_PATH`: direktorijum vašeg pregledanog paketa sa `manifest.json`, JSON tabelama, izvornim dokumentima i pregledanim koordinatama.
- `MI_TRANSPORT_CALENDAR_ID`: identitet vaše verzije kalendara. Promijenite ga kada pregled promijeni pravila kalendara.
- `MI_TRANSPORT_STOPS_PATH`: YAML javnih stajališta (`stops`, sa `label`, `latitude`, `longitude` i opisom tačnosti).
- `MI_TRANSPORT_PLACES_PATH`: YAML sa `places`, javnim nazivima i aliasima, `member_labels`, izričitim `default_label`, stabilnim `id` i `assumption_reason`. Podrazumijevano stajalište područja je pretpostavka koja mora biti prikazana korisniku.
- `MI_CITY_SOURCES_PATH`: izričito uključite svoj izvor `public_transport`; nemojte nasljeđivati tuđi domen ili koristiti stvarne kanale u testovima.

Promjenljive predajte procesu kroz sopstveni upravljač okruženjem. Eksplicitno zadat neispravan fajl je greška konfiguracije; ne smije biti zamijenjen izmišljenim uspješnim rezultatom.

## Sadržaj paketa

`manifest.json` sadrži `routes`, `effective_from`, `source_url`, `stop_locations` i `calendar`. Svaka ruta ima `code`, `title`, `data_file`, `data_sha256`, `timetable` i `map`. Opis izvornog dokumenta ima `url`, lokalni `file`, `sha256` i veličinu `byte_size`. `stop_locations` pokazuje na JSON sa `rows`; svaka tačka navodi liniju, smjer, oznaku stajališta, koordinate, izvorni `image_url`, `accuracy` i `confidence`.

JSON rute ima `effective_from` i `directions`. Smjer sadrži `name`, `calendar`, tačan `source_heading`, `source_table_index` i `stops`. Za svako stajalište sačuvajte `label` i niz `times` iste kolone izvora. Prazna ćelija ostaje `null`: ne prepisujte vrijeme iz susjedne kolone i ne izmišljajte polazak na početnom stajalištu.

Kalendar navodi `reviewed_until`, `unsupported_dates`, `school_day_ranges`, `school_break_ranges` i pregledane javne `sources`. Ne zaključujte rad praznikom ili nedjeljom iz radnog dana. Sezonske kolone moraju imati posebno pregledano pravilo. Kontrolne sume vežu podatke za pregledane dokumente; sama kontrolna suma ne dokazuje tačnost prepisa, pravo redistribucije ili aktuelnu uslugu.

Galerija koristi putanje slika navedene u manifestu i njihove direktorijume. Stranica na tačnom `source_url` tretira se kao podešena galerija i ako sve slike nestanu: nedostajući ili novi prilog u njenim direktorijumima zahtijeva novi pregled. Nepovezani logotipi i ostale slike stranice ne ulaze u ovu provjeru. Datum u opisu prikupljenog reda vožnje dolazi iz `effective_from`, a ne iz lokalnog datuma ugrađenog u kod.

## Granice referentnog adaptera

Nazivi linija i prepoznavanje centralne stanice/gradskih izraza u `PublicTransportTimetable` još imaju referentna pravila za Bijeljinu. Druga zajednica treba da prilagodi te interfejse svojoj mreži; v0.1 ne obećava potpuno automatski uvoz svakog prevoznika. Zadržite provjere tačnog dokumenta, revizije, kalendara, smjera i istog broja kolone. Ne predstavljajte približnu tačku sa mape kao pregledan peron, a raspored kao potvrdu trenutne vožnje.

`test/support/synthetic_transport_network.rb` pravi autorsku izmišljenu mrežu za testove. Njene slike su strukturni testni primjeri, a koordinate i vremena su izmišljeni. Referentne oznake centralne stanice i gradskih orijentira koriste se za provjeru postojećeg adaptera. Taj paket nije red vožnje stvarne zajednice i ne treba ga objaviti kao stvarnu uslugu.
