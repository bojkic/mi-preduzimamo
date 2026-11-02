# Instalacija i početno podešavanje

Novi instalacioni paket je kandidat za provjeru. Njegova čista Docker instalacija, javni VPS/TLS, reboot i restore još nisu potvrđeni. Istorijski patchovani WSL rezultat ne potvrđuje ovaj kandidat.

1. Za izmišljenu lokalnu zajednicu slijedite [lokalni Compose vodič](../installation/LOKALNO.md), uključujući pripremu Linux/WSL2 sistema, portove, opcione demo naloge i nastavak poslije greške.
2. Za novu stvarnu zajednicu koristite [zaseban VPS profil](../installation/PRODUKCIJA.md). Lokalni HTTP/capture dodaci nisu dio produkcionog image-a.
3. Za nezavisno testiranje koristite [WSL2 postupak i granice dokaza](../installation/PROVJERA_WSL2.md).
4. Zatim izaberite potrebne oblasti iz [FUNKCIONALNOSTI.md](FUNKCIONALNOSTI.md). Spoljni provider nalog nije uslov za osnovno pokretanje; aktivacija zahtijeva sopstvenu konfiguraciju i zasebnu provjeru.

Referentni alati kandidata su Ruby 3.4.12, Rails 8.1.4, Decidim 0.32.2, Node 22.23.4 i npm 10.9.9. Lockfile čuva puni engine SHA. Ne generišite nove tajne pri nastavku, restore-u ili nadogradnji postojeće instalacije. Ne pokrećite new-install komande nad bazom postojeće zajednice.

## Pravni dokumenti vaše zajednice

Javni izvoz ne sadrži bijeljinske uslove, politiku privatnosti, rokove ili kontakte rukovaoca podacima. `LegalPagesSetup` ostaje alat za unos/ažuriranje četiri stranice, sa sažecima, footer temom i svim dogovorenim jezicima. Bez eksplicitne konfiguracije odbija rad prije upisa bilo koje stranice.

Pripremite sopstvene lokalno pregledane tekstove i podesite `MI_LEGAL_PAGES_PATH` na JSON datoteku izvan javnog repozitorijuma. Obavezna polja su `topic_title`, `topic_description`, `contact_email`, `contact_domain` i `pages`. `pages` mora sadržati `terms-of-service`, `privacy-policy`, `cookie-policy` i `data-processing`; svaka stavka ima `title`, `summary`, nenegativni cijeli `weight`, ISO datum `updated_on` i niz `sections`. Svaka sekcija je par `[naslov, [pasus, ...]]`. Pasusi su običan tekst; alat ih HTML-escapuje i dodaje linkove samo za vaš zadati kontakt/domenu. E-mail i domen ostaju nepromijenjeni i u ćiriličnom prikazu.

Kada administrator odabere organizaciju i tekstovi su spremni za objavu, može pozvati `DecidimApp::Bijeljina::LegalPagesSetup.call(organization: organization)` iz namijenjenog Rails administrativnog procesa. Alat provjerava oblik konfiguracije i datume, a ne pravnu ispravnost ili saglasnost vaših tekstova sa propisima. Testni primjer `test/support/synthetic_legal_pages.rb` je izmišljen sadržaj za testove, ne politika koju treba objaviti.

Referentni kandidat pinovan je na PostgreSQL 18.6 i Redis 8.0.5. Native backend provjere koriste Ruby 3.4.12 i odvojene testne resurse; kompletan novi Docker build sa Node 22.23.4/npm 10.9.9 i čista instalacija još zahtijevaju svoju probu. Konfiguraciju zajednice, spoljne usluge i VPS/TLS put provjerite zasebno. [Backup i odvojena proba oporavka](../installation/OPORAVAK.md).

### Pregledane činjenice imenika

Za pojedinačno citirane kontakte i radno vrijeme podesite `MI_DIRECTORY_FACTS_PATH` na svoj pregledani YAML, a `MI_DIRECTORY_FACTS_REVIEWED_HOSTS` na zarezima odvojene izvorne hostove (bez šeme ili putanje). Podrazumijevano nema činjenica ni odobrenih hostova. Izvori moraju biti HTTPS, bez korisničkih podataka u URL-u, na portu 443 i na tačno navedenom hostu; poddomeni se ne odobravaju automatski. Unos zahtijeva identitet/verziju činjenice, dokument i izdavaoca, SHA-256 izvornog dokumenta, predmet, tip činjenice, tekst, izvorni URL, datum pregleda, stanje pregleda i mjesto u dokumentu. Sintetički oblik je prikazan u `test/support/synthetic_service_directory.rb`. Nepregledani, budući i istekli zapisi ne koriste se kao pregledane činjenice. Ne unosite privatne kontakte građana; sami provjerite prava, tačnost i rok važenja javnih službenih podataka.

Bez uključenog izvora čitač javnih opažanja vraća nedostupnost prije čitanja njegovih pripremljenih podataka. Eksplicitno uključivanje izvora ne proizvodi opažanja: potrebno je zasebno prikupljanje i pregled. Indeks glasnika bez datuma pregleda ostaje nedostupan; pregledan indeks i dalje podliježe provjeri zastarjelosti.

### Izričito uključivanje referentnog web razgovora

Referentni adapter `DecidimApp::Bijeljina::WebConcierge` ostaje isključen. Ako želite da koristite taj adapter, nakon pregleda njegovih lokalnih pretpostavki i podešavanja svojih podataka postavite `MI_ENABLE_REFERENCE_CONCIERGE=true` pri pokretanju aplikacije. Rezolver se učitava lijeno; ova postavka sama ne pravi nalog, ne šalje poruke i ne dodaje podatke. Za model-led razgovor dodatno se koriste `MILICA_DIALOGUE_ENABLED=true`, `MILICA_CONVERSATION_ARCHITECTURE=model_led` i `MILICA_CONVERSATIONAL_WRITES_ENABLED=false`, uz vaše pristupne podatke i pravila obrade kod AI provajdera. `DECIDIM_CONCIERGE_ORG_HOST` bira vašu organizaciju; obavezan je kada postoji više organizacija. Chat predaja prijave ima zaseban `MILICA_REPORT_CHAT_SUBMISSION_ENABLED` prekidač i ostaje isključena u primjeru. Ponovo pokrenite aplikaciju nakon promjene runtime konfiguracije. Testni provajder uključuje i vraća rezolver samo unutar svog testa; to nije produkciona konfiguracija.

### Nazivi mjesta i padežni oblici

`MI_PLACE_ALIASES_PATH` označava YAML datoteku vaših pregledanih naziva. Bez nje se koriste nazivi iz vašeg registra područja; bijeljinski padežni oblici se ne nasljeđuju. `inflections` povezuje normalizovani naziv sa izričito pregledanim oblicima. Primjer je izmišljen i ne potvrđuje stvarno mjesto:

```yaml
revision: primjer-pregleda-v1
reviewed_on: "2026-01-01"
inflections:
  izmisljeno polje:
    - Izmišljenom polju
```

Zamijenite primjere svojim nazivima, revizijom i stvarnim datumom pregleda. Alias potvrđuje ime, a ne da usluga obuhvata cijelo područje, da stanica pripada komšiluku ili da građanin ima pristup privatnoj tabli. Ti zaključci imaju zasebne provjere.

Za indeks glasnika unesite sopstveni `MI_GAZETTE_DATA_PATH` i po potrebi `MI_GAZETTE_SOURCE_URL`. Bez eksplicitnog URL-a nema bijeljinske zamjenske adrese. Stari `BIJELJINA_GAZETTE_URL` važi samo ako ga sami postavite; novi ključ ima prednost.

Izbor projekata nakon Trke koristi potvrđeni poredak i nazive vaše organizacije/komšiluka. Javna referentna putanja procesa je `komsiluci-biraju`; nema ugrađenih lokalnih pobjednika. Opcioni prikaz budžeta postavlja se po organizaciji kroz `Decidim::Bih::Setting.put(organization, "race_projects", "project_budget_bam", "1234.50")` (izmišljen primjer, decimalna tačka). Bez postavke sadržaj upućuje na objavljena pravila procesa i ne obećava nagradu; postavka sama ne obezbjeđuje sredstva. Referentni engine kalendar izdanja Trke treba pregledati prije stvarne aktivacije.

### Kontakt vodovoda u odgovorima o vodi

Za svoju zajednicu dodajte unos `vodovod_servis` u imenik označen sa `MI_CITY_SERVICES_DATA_PATH`, sa pregledanim naslovom, tekstom, službenim `source_url` i stvarnim datumom pregleda `source_checked_on` u obliku YYYY-MM-DD. Datum ne smije biti u budućnosti. Izvorna adresa mora proći isti postupak odobravanja kao ostali servisni nastavci: njen origin mora biti u vašem katalogu `MI_CITY_SOURCES_PATH`, ili tačan URL mora biti izvor ispravno konfigurisanih činjenica imenika. Samo postavljanje `MI_DIRECTORY_FACTS_REVIEWED_HOSTS` ne dodaje izvor bez tih podataka. URL ne smije sadržati korisničko ime ili lozinku.

Pregledana službena stranica može služiti za upućivanje na kontakt i kada je njeno automatsko prikupljanje isključeno; to ne uključuje scraper, obavještenja ili slanje poruka. Povežite samo sopstveni izričito pregledani izvor i provjerite ga u izolovanoj instalaciji. Ne uključujte referentni bijeljinski izvor da biste omogućili kontakt.

Četiri odgovora — reklamacija računa, prijava kvara/kontakt, potvrda ranije prijave i pitanje o kvalitetu vode — koriste imenik konkretne organizacije i postojeće provjere dozvole čitanja, roka i porijekla izvora. Bez odgovarajućeg unosa nemaju naslijeđeni broj, mejl ili kontaktni URL. Odgovor tada objašnjava da kontakt nije podešen. Pregledana stranica nije potvrda dostupnosti telefona, prijema prijave, ličnog računa ili zdravstvene ispravnosti vode. Pojedinačni pregledani telefoni i druge činjenice ostaju zasebni podaci vašeg imenika; ovaj nastavak ih ne izvlači iz slobodnog teksta ili neprovjerenog broja.

### Donacije i Odoo proizvodi zajednice

Donacijski adapter je isključen dok ne obezbijedite sopstvenu kompletnu konfiguraciju. Podesite `MI_DONATIONS_CONFIG_PATH` ka JSON datoteci izvan javnog repozitorijuma. Zajedno su obavezni: `product_ids` (pozitivni cjelobrojni identifikatori vaših Odoo `product.template` proizvoda za donacije), `donate_url` (vaša HTTPS prodavnica bez korisničkog imena/lozinke u URL-u) i `organization_host` (tačan host vaše organizacije, bez šeme/putanje). Djelimična ili neispravna konfiguracija se odbija; prazan izostavljen adapter ne pozajmljuje proizvode, domen ili tenant druge zajednice. Promjene se učitavaju pri pokretanju aplikacije, pa nakon pregleda ponovo pokrenite svoje aplikacione procese.

Sljedeći oblik je izmišljen primjer. Brojevi901/902 nisu stvarni proizvodi koje treba koristiti; zamijenite ih sopstvenim pregledanim identifikatorima prije aktivacije:

```json
{
  "product_ids": [901, 902],
  "donate_url": "https://donations.example.invalid",
  "organization_host": "community.example.invalid",
  "cache_namespace": "moja-zajednica",
  "donation_presets": [10, 25, 50],
  "confirmed_states": ["sale", "done"],
  "date_from": null
}
```

Za čitanje Odoo podataka odvojeno podesite sopstvene `ODOO_URL`, `ODOO_DB`, `ODOO_LOGIN` i `ODOO_API_KEY` u runtime okruženju. Tajne i podatke donatora ne unosite u ovu JSON datoteku. `confirmed_states` određuje koja potvrđena stanja prodajnog naloga ulaze u zbir; opcioni `date_from` koristi YYYY-MM-DD. Zbir sabira izabrane stavke naloga i ne dokazuje pojedinačnu uplatu, identitet donatora ili bankovno poravnanje. Predloženi iznosi su prikaz za korisnika, a uplatu obrađuje vaša spoljna prodavnica.

Javni initializer povezuje adapter tek kada je konfiguracija potpuna. Bez proizvoda engine ne šalje Odoo upit niti zakazuje osvježavanje iz prikaza. Svoj namespace keša dopunjavajte po instalaciji; host zajednice je automatski dio agregatnog ključa, a projektni ključevi dodatno sadrže organizaciju i kampanju. Projektne donacije i dalje zahtijevaju odobrenu vezu projekta i postojeću aktivnu Odoo UTM kampanju, uz postojeće provjere vidljivosti i tenant-a. UTM izvor je vaš konfigurisani host; nema rezervnog bijeljinskog checkout linka. Prije produkcije provjerite konfiguraciju, zbir, osvježavanje, kampanju i prikaz uz presretanje spoljnih zahtjeva u izolovanoj instalaciji.

Prikaz donacija razlikuje nedostupan zbir od izmjerenog0. Bez upotrebljivog datuma opažanja ne prikazuje iznos ni broj donacija; projekti i navigacija ostaju dostupni. Iznos projekta ima sopstveni datum, a neraspoređeni iznos se prikazuje samo kada su pripremljeni ukupni i svi uključeni projektni zbirovi. To ne zamjenjuje provjeru datuma, obuhvata i usaglašavanja sa vašim izvorom.

### Izričito pregledani kontaktni detalji službe

Odgovori o novim građevinskim dozvolama, socijalnoj zaštiti, otpadu i vodi mogu navesti pregledani telefon, javni službeni e-mail, adresu, radno vrijeme ili obrazac. Ove činjenice pripremite u sopstvenom YAML imeniku kroz već opisane `MI_DIRECTORY_FACTS_PATH` i `MI_DIRECTORY_FACTS_REVIEWED_HOSTS`, uz ispravan unos iste službe u `MI_CITY_SERVICES_DATA_PATH`. Kontaktni podaci se ne izvlače iz cijena, SMS kodova ili slobodnog teksta druge službe.

Za ove referentne odgovore `subject_id` označava tačno određenu javnu ulogu:

| Ključ imenika | `subject_id` |
|---|---|
| `gradjevinske_dozvole_legalizacija` | `building_permit_office` |
| `socijalna_zastita` | `social_work_office` |
| `otpad` | `waste_service` |
| `vodovod_servis` | `water_service` |

`predicate` je `phone`, `email`, `address`, `hours` ili `form`; `text` sadrži javni službeni podatak koji ste pregledali. Zadržite identitet/verziju činjenice, dokument/izdavaoca, SHA-256 dokumenta, izvorni URL i mjesto u dokumentu, datum i stanje pregleda. Svaki detalj ima sopstveni citat; nepregledani, budući ili zapisi izvan datuma važenja se izostavljaju. Oznaka uloge ne daje pravo na objavu privatnog broja ili mejla neke osobe: koristite samo odgovarajuće javne službene kontakte i provjerite prava na sadržaj.

Uloga drugog ureda ne koristi se kao zamjena, čak ni kada je označena kao podrazumijevana. Odobrena administratorska kartica ne nasljeđuje ove isporučene činjenice. Ako nedostaje neki detalj, preostali pregledani podaci mogu ostati korisni uz poruku da svi detalji nisu dostupni. Zbog ograničenja odgovora cijela grupa činjenica jednog detalja može biti izostavljena; ne prikazuje se djelimičan skup kao kompletan. Bez odgovarajućeg unosa nema naslijeđenog lokalnog kontakta. Primjer oblika je u `test/support/synthetic_civic_contacts.rb`; tamošnji sadržaj je izmišljen i ne smije se predstavljati kao stvarna služba.

Podaci opisuju pregledani izvor i ne potvrđuju da služba upravo prima pozive, da je termin slobodan, da je pomoć odobrena, da je prijava poslata ili da je najavljena nova akcija odvoza. Prije upotrebe provjerite tačnu ulogu, izvor, datum i prikaz u izolovanoj instalaciji.


### Pregledane najave odvoza kabastog otpada

Početni odgovor može navesti pregledanu najavu, njen izvor, period i obuhvat za vašu zajednicu. Ne nasljeđuje bijeljinsku kampanju ili kontakt. Postavite `MI_BULKY_WASTE_CAMPAIGNS_PATH` ka sopstvenoj JSON datoteci izvan repozitorijuma. `organization_host` mora odgovarati hostu organizacije, a host svakog izvora mora biti izričito pregledan kroz `MI_CIVIC_REVIEWED_HOSTS` (zarezom odvojeni hostovi, bez šeme/putanje). Čitač ne preuzima URL i ne uključuje slanje poruka ili scraper. Izmjene datoteke čitaju se pri sljedećem upitu; promjena varijabli okruženja zahtijeva ponovno pokretanje aplikacionih procesa.

Sljedeći JSON je šablon oblika, a ne gotova konfiguracija. Zamijenite primjer domena, tekstove i sve `YYYY-MM-DD` datume svojim dokazanim vrijednostima. Oba datuma perioda su obavezna; ne izmišljajte ih ako najava nema potvrđen period.

```json
{
  "format": 1,
  "organization_host": "community.example.invalid",
  "campaigns": [{
    "id": "pregledana-najava-1",
    "text": "Sadržaj najave koji je operater pregledao.",
    "coverage_text": "Tačan obuhvat i uslovi iz najave; ne pretpostavljajte cijelu zajednicu.",
    "source_url": "https://community.example.invalid/najave/primjer",
    "source_on": "YYYY-MM-DD",
    "reviewed_on": "YYYY-MM-DD",
    "review_valid_until": "YYYY-MM-DD",
    "starts_on": "YYYY-MM-DD",
    "ends_on": "YYYY-MM-DD",
    "review_state": "reviewed",
    "publishable": true
  }]
}
```

`source_on` je datum izvora, `reviewed_on` datum stvarnog pregleda, a `review_valid_until` posljednji dan do kog operater dopušta korišćenje tog pregleda. Pregled u budućnosti, istekao pregled, `pending`/`rejected` ili `publishable: false` ne daju javnu činjenicu. Datum izvora ne smije biti nakon pregleda; period i rok pregleda ne smiju biti obrnuti. Podaci imaju najviše osam jedinstvenih najava i ukupno64 KiB; neispravan dokument se odbija u cijelosti, bez djelimičnog odgovora. Izvori moraju koristiti HTTPS/443, bez korisničkog imena ili lozinke. Ne stavljajte tajne ili lične podatke u ovu datoteku.

Datumi se porede prema zoni Europe/Sarajevo. Odgovor razlikuje prošli, budući i tekući objavljeni period, navodi datum pregleda i obuhvat; nijedan od njih ne dokazuje da odvoz upravo traje ili da konkretna adresa ispunjava uslove. Prikazane najave nisu tvrdnja da nema novije objave. Ako pregled nije dostupan, odgovor to kaže i može prikazati vaše odvojeno pregledane kontakte službe `otpad` iz imenika. Redovni raspored kućnog otpada ne potvrđuje odvoz namještaja. Za konfiguraciju kontakata važe zasebna pravila imenika iz prethodnog odjeljka.


### Rokovi poljoprivrednih javnih poziva

Odgovor o tome da li je poljoprivredni poziv otvoren i nastavak o rokovima/obrascima koriste pripremljeni pregled `PublicCallsPreparation`, kroz vaš izričito konfigurisan i aktiviran `city_official_notices` izvor. Podaci se ne preuzimaju tokom građanskog razgovora. Bez aktivnog izvora, pripreme za istu organizaciju, odgovarajuće verzije i dovoljno svježeg uspješnog snimka nema zamjenskog bijeljinskog poziva ili ugrađenih rokova.

Ovo je referentni adapter za određeni oblik službenih HTML objava, a ne univerzalni čitač svakog sajta. Pregledajte `PublicCallsPreparation` i `CityNoticeDiscovery` prije uključivanja za svoju zajednicu; po potrebi implementirajte adapter koji čuva ugovor pripremljenog snimka. Ne uključujte bijeljinski izvor da biste nadomjestili nedostajuću konfiguraciju. Katalog izvora, geografski obuhvat, pravila datuma i pozadinsko prikupljanje ostaju zasebni preduslovi.

Postojeći javni pregled otvorenih poziva zadržava dosadašnji vremenski filter. Fiksni poljoprivredni upit o rokovima može dodatno opisati objavljen budući ili već zatvoren period, uz jasnu oznaku. Datum objave, početak podnošenja, rok podnošenja, tačan sat roka, period ocjenjivanja i obrazac nisu ista stvar. Za različite kategorije podrške sa različitim rokovima obezbijedite zasebne ispravno pripremljene stavke i dokaz iz izvora; jedna agregatna stavka nije potvrda da su sve kategorije otvorene. Ako nema datuma početka, sam budući rok ne znači da je poziv otvoren. Poništeni/nepoznati/neobjavljeni periodi se ne predstavljaju kao otvoreni.

Svaki prikazani poziv zadržava svoj rok i službeni URL, a dostupna stranica podnošenja/prilozi navode se iz tog istog zapisa. Nastavak razgovora ponovo čita pripremljeni pregled i ne garantuje da je njegov izbor potpun ili identičan ranijem izboru. Provjerite konkretan dokument, obuhvat, uslove i vrstu podrške. Preuzimanje obrasca nije predaja, prihvatljivost, odobrenje ili potvrda isplate; lični dokumenti ne šalju se u chat. Zona za rokove je Europe/Sarajevo. Izmjena izvora/verzije ili zastario/neuspješan snimak zahtijeva novu uspješnu pripremu, ne nasljeđivanje starog roka.


### Javni pozivi za udruženja

Upit za udruženja koristi isti izričito konfigurisan `city_official_notices` izvor i pripremljeni snimak vaše organizacije. Ne bira Bijeljinu kao podrazumijevano područje i ne nasljeđuje lokalni URL. Izbor po temi udruženja radi prije ograničenja broja rezultata, da nepovezani pozivi ne potisnu odgovarajući zapis. Geografska podobnost i pravo na podršku i dalje se provjeravaju u samom pozivu; odsustvo naziva područja nije potvrda da svi stanovnici ili sva udruženja ispunjavaju uslove.

Početni upit i nastavak o uslovima ponovo čitaju pripremljeni pregled. Zatvoren, zastario, nepregledan ili snimak druge organizacije ne održava raniju tvrdnju o otvorenom pozivu. Bez potvrđenog početka sam budući rok ne dokazuje da je poziv otvoren. Bez izvora/pripreme odgovor objašnjava ograničenje, bez prekida razgovora ili poziva na bijeljinski servis. Lista nije potpuna evidencija i ništa nije predato ili odobreno kroz ovaj informativni odgovor.

Opcioni link službenog pregleda može upućivati na vašu konfiguriranu službenu stranicu i kada snimak trenutno nije upotrebljiv; to nije potvrda aktuelnosti njegovog sadržaja niti aktivacija prikupljanja. Link mora koristiti HTTPS, port 443 i ne smije sadržati korisničko ime/lozinku; neispravan link se izostavlja. Izričito odbijeno pravo javnog čitanja ne daje ni podatke poziva ni link iz ove grane. Podešavanje izvora i poštovanje njegovog referentnog HTML ugovora opisani su u prethodnom odjeljku o poljoprivrednim pozivima.


### Pregledani postupci i izvori

Postavite `MI_SERVICE_PROCEDURES_PATH` ka svom JSON dokumentu sa nizom `procedures`, izvan javnog repozitorijuma. Bez njega je katalog prazan. Posebno zadajte `MI_SERVICE_PROCEDURES_REVIEWED_HOSTS` kao zarezom odvojene pregledane hostove, bez šeme ili putanje. Postupak i opcioni obrazac mogu navesti samo izričito odobrene HTTPS/443 izvore bez korisničkog imena/lozinke. Podaci i lista hostova učitavaju se pri pokretanju procesa; nakon izmjena ponovo pokrenite aplikaciju. Samo postavljanje putanje ili hosta nije potvrda sadržaja ili važećeg prava.

Kartica postupka ima stabilan `key`, pregledane `title`, `owner`, `location_scope`, niz `steps`, `record_kind: "procedure"`, `review_status: "reviewed"`, `source_url`, `source_checked_on` u obliku YYYY-MM-DD i `reviewed_content_hash` kao SHA256 pregledanog dijela izvora. Hash je vezan za odgovarajući `source_fragment` i stvarni postupak pregleda, ne za izmišljeni primjer iz testa. Opcioni `effective_from`/`effective_until` su uključive granice važenja; obrnuti/neispravni datumi se odbijaju. Datum pregleda ne smije biti u budućnosti ili stariji od 365 dana prema datumu Europe/Sarajevo. Novi hash promijenjenog izvora zahtijeva novi pregled; ranija prepreka ostaje i nakon kasnijeg neuspješnog preuzimanja.

Nedostajuća taksa, dokumentacija i rok ostaju nepoznati. `fee.administrative_fee_bam` i `fee.postage_amount_bam` su odvojeni nenegativni konačni brojevi ili `null`; neispravna vrijednost nije nula. Nulta administrativna taksa ne dokazuje postojanje ili iznos poštarine. Podatak o poštarini koristi se samo uz izričito `fee.delivery_cost: "postage"`. Taksa i poštarina se ne sabiraju u izmišljenu ukupnu cijenu. Važenje online kanala ne potvrđuje uslove na šalteru; izdavanje elektronskog dokumenta i slanje uputstva elektronskom poštom nisu ista stvar.

Strukturisana polja `steps`, `required_documents`, `processing_time`, `channel`, `document_kind`, `delivery`, `fee_exemptions` i `form_download_url` čuvaju zaseban kontekst podataka. Kratak tekst može biti skraćen uz izričito upozorenje; strukturisani koraci ostaju dostupni i takav tekst se ne predstavlja kao potpuno uputstvo. Pregledana kartica ne podnosi obrazac, ne čita lični predmet i ne garantuje odobrenje ili dostavu. Autorski primjeri u `test/support/synthetic_procedures.rb` služe testovima i ne predstavljaju stvarne postupke, propise, kodove, dokumente ili cijene. Referentna polja postoje radi kompatibilnosti adaptera; svoju semantiku kanala/dostave treba eksplicitno pregledati prije povezivanja sa korisničkim odgovorima.


### Odgovori o izvodu iz matične knjige rođenih

Za automatski informativni odgovor kartica mora dodatno imati `document_kind: "birth_extract"`, `channel: "online"` ili `"counter"` i `organization_host` koji tačno odgovara hostu organizacije. Generička kartica matičara, kartica druge zajednice ili sam alias E-matičar ne određuje taksu, potrebne dokumente ili način dostave za ovaj izvod. Za jedan kanal držite jednu nedvosmislenu karticu; više kartica istog kanala blokira taj kanal, umjesto proizvoljnog izbora. Drugi izričito pregledan kanal može ostati dostupan.

Online i šalterski postupak su odvojene kartice sa sopstvenim izvorom, pregledom, periodom, koracima, dokumentima i cijenama. Bez izričito izabranog kanala odgovor ih može prikazati odvojeno. Izričit izbor kanala čuva se kroz nastavak razgovora, uz ponovno čitanje podataka pri svakom odgovoru. Ispravljeno pitanje koje navede drugi kanal mijenja izbor; sačuvani razgovor ne čuva odobrenje stare takse. Generički naziv matičarske službe ili nulta online taksa ne potvrđuje cijenu ili oslobađanje na šalteru.

Opcioni `delivery` je objekat sa poljima `document_method` (`postal`, `electronic`, `counter`, `unknown`), `instructions_method` (`email`, `portal`, `counter`, `unknown`) i pregledanim `delivery_time_text`. Dostava dokumenta i dostava uputstva se navode odvojeno. Uputstvo e-poštom samo po sebi ne znači da dokument stiže e-poštom. `fee_exemptions` je zaseban pregledani tekst uslova za taj kanal; bez njega su pravila oslobađanja nepoznata, čak i kada je administrativna taksa nula. `processing_time.text` može sadržati pregledani podatak o obradi, ali javni odgovor ne potvrđuje završetak, predaju, odobrenje, status ličnog predmeta ili stvarni dan dolaska.

`form_download_url` mora proći istu provjeru odobrenog HTTPS izvora. `required_documents` je niz pregledanih naziva dokumenata ili `null` za nepoznato; prazan niz se predstavlja kao prazan pregledani spisak, bez tvrdnje da nikada nije potreban dokument. Ne unosite lične identifikatore ili stvarne dokumente građana u kartice. Kartice sa neispravnim poljima, datumima, izvorom, stanjem pregleda ili isteklim važenjem ne daju raniju cijenu iz razgovora. Neispravan ili nečitljiv JSON katalog daje neosjetljivu grešku konfiguracije, ne sadržaj datoteke.

Za oblik podataka pogledajte isključivo izmišljene kartice i adapter testove u `test/support/synthetic_procedures.rb` i `test/services/decidim_app/bijeljina/milica/civic_contact_boundary_test.rb`. Zamijenite ih pregledanim podacima svog nadležnog organa; to nisu pravna uputstva za stvarni postupak. Ovi matičarski odgovori ne nasljeđuju bijeljinsko pravilo o taksi, iznos poštarine ili matičarski URL.


### Pozadinsko osvježavanje referentnih izvora

`CityReferenceRefresh` u javnoj verziji ne nasljeđuje gradski URL. Za arhivu postavite svoj pregledani `MI_GAZETTE_SOURCE_URL`; raniji `BIJELJINA_GAZETTE_URL` koristi se samo kada ga izričito postavite i moderni ključ nije zadat. Bez URL-a arhivska rutina vraća `disabled` prije zaključavanja, čitanja snimka ili mreže. URL se za pozadinski čitač uzima pri učitavanju procesa; nakon izmjene ponovo pokrenite svoje aplikacione procese. Sama postavka ne pokreće preuzimanje: potreban je vaš pozadinski posao ili izričit poziv rutine.

Ovaj adapter trenutno priprema referentnu arhivu za 2026 i koristi postojeći format broja/godine iz HTML indeksa. Drugu godinu ili drugačiji izdavački format treba pregledati i prilagoditi kroz referentni interfejs; ovo nije univerzalni parser svakog sajta. Arhiva i njeni PDF linkovi moraju biti pregledani HTTPS/443 izvori bez korisničkog imena/lozinke; PDF-ovi ostaju na istom hostu kao konfigurisani indeks. Lokalni direktorijum Bijeljine i njeni hostovi nisu zamjenska vrijednost.

Rutina odbija pad ispod najvećeg poznatog broja izričito pregledanih stavki `GazetteData` ili prethodnog uspješnog snimka za tu godinu, uz minimum jednu stavku. Nema ugrađene pretpostavke o 12 izdanja. Bez sopstvene pregledane polazne evidencije prvi nepoznati djelimični indeks ne može sam dokazati punu godišnju pokrivenost: rezultat zato ne tvrdi `full_year_complete`. Dopunite svoju polaznu evidenciju kroz `MI_GAZETTE_DATA_PATH`. Promjena sadržaja PDF-a uklanja stare nepotvrđene sažetke/izvode umjesto njihovog preuzimanja kao da su još odobreni.

Postupci se zasebno osvježavaju samo prema vašim karticama i `MI_SERVICE_PROCEDURES_REVIEWED_HOSTS`. Neispravno podešena arhiva ne odobrava niti blokira posebno pregledan host postupka. Promjena izvora nije uredničko odobrenje novih pravila; prepreka za stari hash traje i nakon kasnijeg neuspješnog preuzimanja. Neuspjeh se bilježi unutar istog zaključavanja, uz stabilan identifikator postupka. Promjena autoriteta/putanje odgovora ili kredencijali u završnom URL-u se odbijaju. Prikaz snimka, HTTP uspjeh i hash nisu dokaz pravne tačnosti ili čitanja cijelog PDF-a.


### Identitet izdavača i keš glasnika

Arhivski snimak koji proizvede pozadinski čitač sada nosi `source_url` i `source_identity`, vezane za odobreni HTTPS indeks. Promjena hosta, putanje ili query parametara bira drugi izvor; razlika u velikim/malim slovima hosta, podrazumijevani port 443 ili fragment stranice ne predstavljaju drugog izdavača. Identitet služi povezivanju podataka, ne autentifikaciji izdavača ili pravnom odobrenju sadržaja.

Čitač prihvata pripremljeni `last_good` snimak samo kada verzija, URL i identitet odgovaraju trenutno izabranom izvoru. Memoizovani indeks, njegovi datumi i metapodaci ne prelaze na drugog izdavača. Neuspješno osvježavanje istog izvora može zadržati posljednji dobar indeks uz stari datum; novi HTTP pokušaj sam po sebi ne obnavlja njegovu svježinu. Stari snimci bez identiteta se ne pretpostavljaju odgovarajućim i zahtijevaju novo pravilno pripremanje. Promjena pravila čitanja ne zahtijeva ručno brisanje keša; novo uspješno osvježavanje zamjenjuje njegov pripremljeni sadržaj po postojećem postupku.

Ručni indeks `MI_GAZETTE_DATA_PATH` mora imati `source_url` koji odgovara izabranom indeksu, `source_checked_on` i pregledane `entries`. Ako mrežni URL nije postavljen, njegov vlastiti `source_url` može služiti za izričito odabran pregledani offline indeks; to ne uključuje pozadinsko preuzimanje. Ako je mrežni URL postavljen za drugog izdavača, ručni indeks prethodnog izdavača ne daje zamjenske stavke, sažetke, stranice ili datume. Izvor se mijenja zajedno sa pregledanim podacima, ne preimenovanjem tuđeg snimka. Nakon promjene konfiguracije ponovo pokrenite web i pozadinske procese da bi koristili isti izabrani izvor.

Ista granica važi za poznati broj izdanja i ponovno korišćenje sažetaka tokom pripreme: stari izdavač ne određuje minimum novog izdavača i ne potvrđuje njegov izvod, čak ni uz podudaran broj izdanja. Zdravlje izvora i operativni pregled prikazuju datum odgovarajućeg indeksa; svjež pokušaj nad drugim izvorom nije dokaz raspoloživih činjenica. Kompatibilni kodni naziv `bundled_gazette_index` u health rezultatu odnosi se na vaš pregledani konfiguracioni indeks, a ne na opštinske podatke isporučene u javnom repozitorijumu. Godina 2026 ostaje granica ovog referentnog adaptera.


### Zdravlje postupka i raspoloživost odgovora

Prikaz zdravlja postupka koristi istu `ProcedureRead.assessment` procjenu kao stvarni čitač: validnu karticu i pregled, odobren izvor/obrazac, hash prepreku, datum pregleda i efektivni period u zoni Europe/Sarajevo. Procjena koristi već pročitani snimak provjere; ne pokreće preuzimanje, novi upit bazi ili sastavljanje korisničkog odgovora. Polja posljednjeg pokušaja i posljednjeg uspjeha ostaju odvojena od statusa podobnosti kartice za čitanje. Uspješan HTTP pokušaj ne popravlja neodobrenu, nevažeću ili neispravno podešenu karticu.

Status `ok` znači da pregledana kartica može biti osnova za javno čitanje, a ne da sadrži odgovor na svako pitanje. Nepoznata taksa ostaje nepoznata; konkretan dokument, kanal, organizacija i uslovi imaju svoje provjere u odgovarajućem typed upitu. Ovo nije potvrda lične podobnosti, predaje ili odobrenja zahtjeva, dostave dokumenta ili pravne tačnosti sadržaja. Zdravlje ne objavljuje tekst, dokumente ili činjenice kartice; čuva samo potrebne statusne razloge i datume.

Upit o stajalištu bez datuma i vremena može dati samo kandidate iz pregledanih tabela. Za pitanje iz centra potrebno je da vaša konfiguracija mjesta eksplicitno prepoznaje „centar“; nijedno bijeljinsko stajalište nije zamjenska vrijednost tog odgovora. Mapa se čita zasebno za isti fizički ID stajališta. Više kandidata traži preciznije polazište, a mapa ne potvrđuje najbliže stajalište, bezbjednu pješačku putanju ili pristupačnost. Za konkretan polazak građanin treba da navede datum i vrijeme.

Za razrješavanje područja u operaciji `published_boarding_points` potrebni su sopstveni `MI_TRANSPORT_PLACES_PATH` i `MILICA_AREA_DEFAULT_STOPS_ENABLED=true`. Bez prekidača koriste se samo tačni ili normalizovani nazivi stajališta iz pregledane tabele. Nema povratka na lokalne prečice referentnog resolvera. Dvije konfiguracije koje isti pojam vežu za različita područja ostaju neodređene i traže pojašnjenje. Ovo pravilo opisuje ovu operaciju; ostali referentni transportni ulazi imaju zasebne uslove i ograničenja.

## Stranica otvorenog koda i pomoći pri pokretanju

Stranica je na `/otvoreni-kod`, sa linkom „Otvoreni kod“ u footeru. Tekst je na srpskoj latinici i objašnjava samostalno pokretanje, podešavanje zajednice i objedinjenu pomoć LF Bijeljina. Plaćena usluga nije uslov za korišćenje softvera prema licenci.

Podrazumijevano `MI_OPEN_SOURCE_PUBLISHED=false`: prikazuje se priprema izdanja, bez GitHub linkova. Nakon odobrene objave i provjere anonimnog pristupa oba repozitorijuma, održavalac može podesiti:

```text
MI_OPEN_SOURCE_PUBLISHED=true
MI_OPEN_SOURCE_APP_URL=https://github.com/bojkic/mi-preduzimamo
MI_OPEN_SOURCE_ENGINE_URL=https://github.com/bojkic/mi-preduzimamo-engine
```

Ovo su predložene adrese izdanja; prije uključivanja potvrditi stvarne objavljene adrese. Trenutni reader dopušta samo dvije različite HTTPS GitHub repo adrese naloga `bojkic`, bez query parametara, fragmenta ili pristupnih podataka. Nedostajuća ili neispravna adresa zadržava pripremni prikaz. Promjenljiva `true` je potvrda održavaoca, ne automatska provjera dostupnosti ili licence. Sama aplikacija ne kontaktira GitHub radi provjere i ne objavljuje kod.

Nakon promjene konfiguracije kroz sopstveni postupak isporuke provjerite stranicu i footer, oba repo linka i anonimni pristup. Javno izdanje može kasniti za privatnim razvojem; stranica ne tvrdi da je identično verziji koja trenutno radi. Promjena ovog prikaza ne daje odobrenje za objavu, deploy ili pravnu ispravnost ponude izvornog koda.

Upiti za objedinjenu uslugu idu na `office@fondacijabijeljina.com`; projektna pitanja i privatni bezbjednosni nalazi na `bojan@fondacijabijeljina.com`. Hostingom za ugovorenu uslugu upravlja Fondacija; obim, odgovornosti za podatke i naloge, održavanje, troškovi provajdera i predaja uređuju se ponudom i ugovorom. Stranica ne obećava unaprijed cijenu, vrijeme odziva ili nivo dostupnosti. Ovi kontakti za projekat/uslugu nisu podrazumijevana odredišta za prijave građana vaše instalacije.

## Potvrda pristupa AI modelu za obradu prijava

Opcioni report-case AI tok traži sopstveni dokaz za tačan model, endpoint i credential binding. Putanju privatnog receipt JSON fajla zadati kroz `REPORT_CASE_MODEL_ACCESS_RECEIPT`; bez nje pristup nije potvrđen. Javni kod ne traži dokaz na serverskoj putanji Fondacije. Postojeće provjere šeme, modela, datuma, veličine i zabrane symlink-a ostaju obavezne. Fajl i pristupni podaci ne pripadaju repozitorijumu.

Ručni `script/report_case_model_probe.rb` je odvojena operaterska radnja koja može kontaktirati i naplatiti AI provajdera kroz postojeći budžet. Samostalna instalacija, čitanje izvora i pokretanje testova ne zahtijevaju taj poziv. Prije stvarnog probe-a provjeriti sopstveni provajderski nalog, podešavanja, budžet i ovlašćenje; sintetički testovi koriste kontrolisani klijent bez stvarnih poziva. Receipt potvrđuje ograničenu provjeru modela, ne vlasništvo projekta, regionalnu obradu ili pravnu prihvatljivost toka podataka.

## Identitet kolektora pri čitanju lokalnih izvora

Referentni kolektor i provjera izvora koriste neutralni HTTP `User-Agent: MilicaSourceCollector/1.0 (public civic information)`. Ne predstavljaju se kao bijeljinska instalacija. Ako izvor treba kontakt operatera, eksplicitno podesite sopstveni `MI_SOURCE_CONTACT_EMAIL`. Adresa mora biti jedna važeća ASCII e-mail adresa do254 bajta, bez razmaka i kontrolnih znakova. Bez podešavanja ili uz neispravnu vrijednost `From` zaglavlje se izostavlja; kontakt Fondacije za projekat/uslugu nije zamjenska vrijednost.

Ovo je identitet izlaznog HTTP zahtjeva, ne adresa za prijave građana, SMTP pošiljalac ili dozvola za preuzimanje sadržaja. Aktivaciju sopstvenih izvora, robots pravila, ritam zahtjeva, backoff, prava na sadržaj i vremenske/veličinske limite treba urediti zasebno. Provjera izvora ostaje operaterska radnja; ove postavke same ne pokreću mrežne zahtjeve.

## Evidencija odobrenja izdanja

Administratorska stranica `/admin/bih/governance` čuva evidenciju pregleda i odobrenja. Za tok `release_restart` organizator definiše vlastitu politiku lokalnih provjera. Pregledajte `config/examples/release-approval-policy.example.yml`, prilagodite obuhvate svojim stvarnim komandama i sačuvajte politiku kao `docs/operations/release-approval-policy.yml` u svojoj instalaciji. Kreirajte direktorijum ako ne postoji. Primjer sadrži samo izmišljenu zajedničku strukturu; privatna bijeljinska politika i postupak deploya nisu dio javnog paketa.

Bez važeće politike obrazac odobrenja izdanja ostaje nedostupan. Obrazac bilježi tačne app/engine commitove, lokalni obuhvat, hash politike i rezultata, prozor restarta i dokaze o backup-u. Evidentiranje administratorske potvrde ne izvršava testove i ne dokazuje restore ili spremnost za deploy. Vaš postupak izdanja mora zasebno provjeriti autentičan rezultat za isti čisti par i sve tražene obuhvate; `script/verify` provjerava javni backend, a ne izvršava deploy. Ostale obavezne provjere ostaju opisane u `PROVJERE.md`.

## Provjera konfiguracije kanala

U svom konfigurisanom okruženju možete pokrenuti `RAILS_ENV=development script/mi_viber_launch_readiness_smoke` i `RAILS_ENV=development script/mi_city_service_viber_readiness_smoke`. Za provjeru produkcije izričito izaberite `RAILS_ENV=production`. Komande samo pregledaju konfiguraciju/spremnost; ne šalju poruke, ne objavljuju obavještenja i ne aktiviraju kanale. `FAIL_ON_WARN=1` daje neuspješan izlaz i za upozorenja. Izaberite organizaciju pomoću `DECIDIM_CONCIERGE_ORG_HOST` odnosno `MI_CITY_SERVICE_HEALTH_HOST` kada ih ima više. Rezultat sačuvajte lokalno: može sadržati host i operaterske podatke vaše instalacije. Ne prikazujte ga kao dokaz stvarne provider dostave.

### Granice geokoderske pretrage

`MI_GEOCODER_VIEWBOX` je opciona granica vaše zajednice u obliku `zapad,sjever,istok,jug`: longitude na zapadu/istoku i latitude na sjeveru/jugu. Izračunajte je iz sopstvenih pregledanih poligona, tako da obuhvati i udaljena naselja. Prazna vrijednost ne postavlja lokalnu granicu; u kodu nema bijeljinskih koordinata za ovu pretragu. Za namjerno ograničenje postavljaju se `bounded=1` i sloj adresa; provjera pripadnosti poligonu i dalje je zasebna. Države se navode u `MI_GEOCODER_COUNTRY_CODES`, podrazumijevano `ba` za BiH; više kodova razdvojite zarezom.

Pri uključenoj granici, neispravan format, nekonačne ili obrnute granice i neispravan format kodova zaustavljaju konfiguraciju umjesto slanja neograničenog zahtjeva. Poslije promjene ponovo pokrenite aplikaciju. Zadržite svoj `MI_GEOCODER_USER_AGENT` i izabrani endpoint prema prethodnim uputstvima. Parametri su opisani u [zvaničnoj Nominatim dokumentaciji](https://nominatim.org/release-docs/latest/api/Search/#result-restriction).

### Odredište za prijedloge

U administraciji napravite i objavite sopstveni participativni proces i u njemu komponentu za prijedloge. Postavite `MI_FLAGSHIP_PROCESS_SLUG` na slug tog procesa i ponovo pokrenite aplikaciju. Za asistenta i dalje važe prethodne izričite postavke njegovog referentnog adaptera.

Putanja se traži pri svakom upitu: objavljena komponenta ima prednost, a kada nje nema koristi se stranica procesa. Prazan ili nepodešen slug ne daje odredište; ne preuzima se proces druge zajednice. Slug i komponenta ne objavljuju građanski prijedlog i ne zamjenjuju provjeru da je proces vaše zajednice otvoren za prijem prijedloga.

### Slike asistenta

Host aplikacija uključuje lokalne slike `/mi/milica/wave.gif` i `/mi/milica/wave.jpg`. `MI_ASSISTANT_IMAGE_PATH` mijenja glavnu sliku, a `MI_ASSISTANT_STATIC_IMAGE_PATH` statičnu sliku za korisnike koji traže smanjeno kretanje. Pri zamjeni animacije obezbijedite i svoju statičnu sliku. Prazna glavna vrijednost skriva ilustraciju; razgovor ostaje dostupan. Zajednički engine nema pretpostavljene datoteke na hostu.

### Naziv zajednice i metapodaci

U administraciji organizacije postavite svoj naziv, npr. `MI preduzimamo — Vaša zajednica`, i svoj host. Naslov početne stranice, naziv pri dijeljenju i strukturirani podaci koriste tu organizaciju i njen javni host. Opis organizacije ima prednost nad neutralnim opisom platforme. U metapodacima izdavača nema naslijeđenog naziva ili URL-a Fondacije.

### Pregledani nazivi stanica

`MI_STATION_LABELS_PATH` opciono označava vaš YAML fajl sa mapom `labels`. Ključ je pregledani naziv stanice poslije uklanjanja prefiksa/napona i završnog broja, a vrijednost je tačan naziv vaše oblasti. Primjer izmišljenih podataka:

```yaml
labels:
  v park rub: veliki park
```

Bez fajla nema ugrađenih lokalnih naziva ili posebnih sufiksa. Za obične varijante imena koristite svoju konfiguraciju `MI_PLACE_ALIASES_PATH`. Pregledajte svaku vezu prema sopstvenom izvoru; ne širite nepoznat sufiks na cijelo mjesto. Ovo povezuje obavještenje s mogućim dijelom oblasti, ne dokazuje priključak svake kuće na mrežu.

Fajl se provjerava pri učitavanju: do 1 MiB, do 1000 veza i 256 bajta po nazivu, bez praznih ili duplih normalizovanih ključeva. Poslije promjene ponovo pokrenite aplikaciju. Revizija pravila uključuje hash mape, pa automatska priprema preispituje prethodne veze; postojeće operaterske odluke zadržavaju svoje zaštite.

Razvoj koristi praćenje i ponovno građenje fajlova (`bin/shakapacker --watch`), bez zasebnog HTTP/WebSocket servera za assete. Kompajler i Rails pokrećite samo sa razvojnim podacima i pristupnim podacima. Razvojni webpack server nije uključen u ovaj postupak zbog poznatih upozorenja njegovih zavisnosti. Produkcija koristi unaprijed izgrađene assete.
