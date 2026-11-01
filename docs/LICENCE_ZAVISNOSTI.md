# Licence zavisnosti

Projektni kod koristi [AGPL-3.0-or-later](../LICENSE-AGPLv3.txt). Zavisnosti zadržavaju svoje licence i autorske napomene. Ruby i npm paketi se instaliraju prema `Gemfile.lock` i `package-lock.json`; projektna licenca ne zamjenjuje njihove uslove.

Četiri Ruby paketa u pregledanom zaključanom skupu nemaju popunjeno polje `licenses` u gemspec metapodacima. Njihov distribuirani tekst je pronađen u samom paketu i sačuvan ovdje:

| Paket | Pronađeni tekst | Sačuvana napomena |
|---|---|---|
| active_link_to 1.0.5 | MIT tekst u LICENSE; Oleg Khabarov | [LICENSE](licences/active_link_to-1.0.5.txt) |
| smart_properties 1.17.0 | MIT tekst u LICENSE; Konstantin Tennhard | [LICENSE](licences/smart_properties-1.17.0.txt) |
| w3c_validators 1.3.7 | Izvorni LICENSE nudi GPL ili navedene alternativne uslove; čuvamo puni tekst, bez izmišljanja SPDX verzije | [LICENSE](licences/w3c_validators-1.3.7.txt) |
| w3c_rspec_validators 0.3.0 | MIT tekst u odjeljku „Licence“ u README-u | [Odjeljak Licence](licences/w3c_rspec_validators-0.3.0.txt) |

Originalni paketi dostupni su preko RubyGems stranica za [active_link_to](https://rubygems.org/gems/active_link_to/versions/1.0.5), [smart_properties](https://rubygems.org/gems/smart_properties/versions/1.17.0), [w3c_validators](https://rubygems.org/gems/w3c_validators/versions/1.3.7) i [w3c_rspec_validators](https://rubygems.org/gems/w3c_rspec_validators/versions/0.3.0). Sačuvane napomene potiču iz navedenih distribuiranih verzija.

Ova tabela objašnjava nedostajuće metapodatke za ova četiri paketa; nije potpuni registar svih tranzitivnih zavisnosti. Pri njihovoj nadogradnji provjerite tekst nove verzije. Kada distribuirate paket zavisnosti ili kontejnersku sliku, sačuvajte njegove izvorne autorske napomene, licence i odgovarajući izvorni kod prema primjenjivim uslovima.

Za direktno uključene biblioteke, fontove i grafiku pogledajte [napomene o javnim assetima](../public/ASSET_NOTICE.md). Lokalna CommonJS adaptacija decode-uri-component 0.5.1 ima [MIT licencu](../vendor/javascript/decode-uri-component/LICENSE) i [porijeklo i opis izmjene](../vendor/javascript/decode-uri-component/UPSTREAM.json).

## Paketi sa dodatnim uslovima

Više licenci u gemspec-u ne znači automatski da se sve primjenjuju zajedno. Pregledajte tekst konkretne verzije. Za neizmijenjene pakete zadržavaju se izvorne napomene; sljedeći izbori odnose se na alternative koje njihovi tekstovi izričito nude:

| Paket | Tekst i postupanje |
|---|---|
| icalendar 2.12.4 | LICENSE izričito nudi izbor GPL, BSD ili navedenih Ruby uslova; koristi se BSD alternativa. |
| ttfunk 1.7.0 | COPYING i LICENSE nude Ruby, GPLv2 ili GPLv3; koristi se Ruby alternativa. |
| rdoc 8.0.0 | LICENSE.rdoc nudi Ruby ili GPL-2.0-only; koristi se Ruby alternativa. |
| HexaPDF 1.1.1 | AGPLv3 uz dodatne napomene u LICENSE. Zadržati obavezni Producer zapis u svakom PDF-u koji biblioteka kreira ili mijenja; ne uklanjati ga pri naknadnoj obradi. Standardni HexaPDF writer ga postavlja. Njegova komercijalna licenca je odvojena alternativa. |
| Sidekiq 7.3.10 | LGPLv3; zadržati njegovu licencu i izvor prema primjenjivim uslovima ako se sam paket dalje distribuira. Pro/Enterprise nisu uključeni ovom zavisnošću. |
| axe-core 4.12.0 | MPL-2.0, sa zasebnim LICENSE-3RD-PARTY.txt; sačuvati oba teksta i ispuniti obaveze za izvor pokrivenih fajlova pri distribuciji. |
| caniuse-lite / spdx-exceptions | Podaci pod CC-BY-4.0 / CC-BY-3.0. Sačuvati pripisivanje autorstva i link licence pri daljoj distribuciji tih podataka; ne preimenovati ih u projektni AGPL kod. |

Za biblioteku argparse 2.0.1 sačuvati cijeli distribuirani LICENSE, koji sadrži istoriju Python licenci. Za MIT/ISC/BSD/Apache komponente sačuvati njihove autorske napomene i eventualni NOTICE. Za pakete koji nude alternativu MIT, BSD ili Apache koristiti odgovarajuću ponuđenu alternativu uz njen tekst; proizvoljno preoznačavanje licence nije dozvoljeno.

## Brakeman kao odvojeni razvojni alat

Brakeman 7.0.2 je u razvojnoj/test grupi Gemfile-a. Nije dio aplikacionog izvornog koda koji ovaj projekat relicencira. Ima [Brakeman Public Use License](https://github.com/presidentbeef/brakeman/blob/v7.0.2/LICENSE.md), a ne MIT licencu za cijelu sadašnju verziju. Upstream navodi analizu sopstvenog softvera među primjerima koji nisu komercijalna upotreba. Za ponudu skeniranja drugima, komercijalni servis zasnovan na samom alatu ili njegovu komercijalnu redistribuciju provjerite posebne uslove i eventualnu komercijalnu licencu. Ponuda hostinga platforme ne uključuje automatski takvu ponudu skeniranja.

## Distribucija i nadogradnje

Repozitorijumi ne sadrže instalirane Ruby/npm pakete ili gotovu kontejnersku sliku. Installer preuzima zavisnosti iz navedenih izvora. To ne zamjenjuje obaveze ako dalje distribuirate njihove bajtove, uključujući browser bundle: čuvajte odgovarajuće licence, autorske napomene i potreban izvor. Poslije promjene lockfile-a ponovo pregledajte licence i stvarno uključene biblioteke; ova bilješka nije trajna potvrda za buduće verzije.

Za biblioteke stvarno pronađene u referentnom JavaScript/CSS build-u čuvaju se [zbirne napomene](../public/mi/licenses/BROWSER_THIRD_PARTY_NOTICES.txt) i [manifest tačnih verzija/izvora](../public/mi/licenses/browser-packages.json). Banner u generisanim chunk-ovima upućuje na te tekstove; ne uklanjajte tu putanju pri hostovanju. Za axe-core 4.12.0 dodat je link punog izvora po tačnom npm gitHead-u. Source Sans Pro koji Decidim uključuje pri kompajliranju ima zasebnu [Adobe/OFL napomenu](../public/mi/fonts/SOURCE-SANS-PRO-OFL.txt).
