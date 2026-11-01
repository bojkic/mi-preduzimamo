# MI preduzimamo — aplikacija zajednice

Otvorena platforma za lokalne zajednice u Bosni i Hercegovini, zasnovana na Decidim-u. Ovaj repozitorijum je referentna aplikacija; zajednički engine donosi funkcionalnosti platforme.

MI preduzimamo is a Decidim-based civic platform for communities in Bosnia and Herzegovina. This repository contains the community host application; the paired engine supplies reusable features.


<details>
<summary>Prikaz referentne aplikacije</summary>

![Stranica Otvoreni kod sa uputstvima za zajednicu](docs/images/otvoreni-kod-test.png)

Snimak stranice Otvoreni kod u izmišljenoj testnoj organizaciji. Ilustruje referentnu aplikaciju; ne prikazuje podatke stvarnih građana niti potvrđuje podešenost neke zajednice.

</details>

Decidim name and logo is a registered trademark of the Associació de Software Lliure Decidim. [Politika upotrebe žiga](https://decidim.org/trademark-policy/).

## Funkcionalnosti i priprema

Platforma obuhvata učešće građana, prijave problema, komšiluke, volontiranje, projekte, nenovčanu pomoć, donacije, bodove angažmana, lokalna obavještenja, poruke i asistentkinju Milicu. Kod svih funkcionalnosti je u obuhvatu izdanja; pojedine zahtijevaju lokalne podatke, administratorsko podešavanje ili spoljnu uslugu. Bijeljinski produkcioni podaci nisu dio distribucije.

Aplikacija koristi zajednički engine sa tačnim Git commitom u Gemfile.lock. Instalacija zahtijeva Ruby 3.4.12, Node prema .node-version, PostgreSQL, Redis i sistemske biblioteke navedene u konfiguraciji zavisnosti. Koristite odvojene razvojne, testne i produkcione resurse.

Početni koraci i sistemski administrator: [INSTALACIJA.md](docs/INSTALACIJA.md).

Detaljan pregled zahtjeva svake oblasti: [FUNKCIONALNOSTI.md](docs/FUNKCIONALNOSTI.md).

## Početno podešavanje

1. Klonirajte aplikaciju i instalirajte zavisnosti: `bundle install` i `npm ci` uz Node 22.22.1 (npm 10.9.4) iz .node-version.
2. Koristite [.env.example](.env.example) kao spisak razvojnih podešavanja. U okruženju podesite pristup razvojnoj bazi, odvojeni Redis i lokalne tajne. Rails ne učitava automatski .env; promjenljive treba predati procesu kroz lokalni upravljač okruženjem.
3. Pripremite bazu komandom `bin/rails db:prepare`. Prije pokretanja provjerite da DATABASE_URL označava namijenjenu razvojnu bazu.
4. Pokrenite `bin/rails server -b 127.0.0.1 -p 3000`, `bin/shakapacker --watch` i `bundle exec sidekiq -C config/sidekiq.yml` u odvojenim procesima. Uredite organizaciju, domen, administratore i lokalne podatke prije otvaranja registracije.

Za produkciju obezbijedite TLS, ograničen administratorski pristup, bezbjedno čuvanje tajni, rezervne kopije i provjeru vraćanja, nadzor poslova i lokalno odobrene uslove privatnosti. Ne koristite produkcione pristupne podatke u testovima.

## Spoljne usluge i privatnost

AI i komunikacione usluge nisu potrebne samo za čitanje izvornog koda. Njihovo uključivanje može slati sadržaj razgovora ili poruka i kontaktne podatke spoljnim pružaocima. Prije aktiviranja provjerite tokove podataka, ugovore, saglasnosti, rokove čuvanja i potrebne pristupne podatke. Lokalni adapteri zahtijevaju eksplicitno povezivanje sa izvorima vaše zajednice. Ne koristite kontakt Fondacije kao podrazumijevanu adresu za prijave građana druge zajednice.

## Održavanje i pomoć

Održavalac: Bojan Stojanović, za Lokalnu fondaciju Bijeljina. Projektni kontakt i privatne bezbjednosne prijave: bojan@fondacijabijeljina.com. Osjetljive nalaze nemojte objavljivati u javnim issues.

Fondacija nudi objedinjenu uslugu hostinga, konfiguracije, obuke i podrške. Za ponudu pišite na office@fondacijabijeljina.com. [Pregled pomoći i dogovora o usluzi](docs/POMOC_FONDACIJE.md) opisuje pripremu, odgovornosti i predaju. Plaćena pomoć nije uslov za korišćenje softvera prema licenci. Naziv MI preduzimamo možete koristiti uz naziv svog grada ili zajednice.

## Dokumentacija

[Puni indeks vodiča](docs/README.md) povezuje javna instalaciona, razvojna i operaterska uputstva.

## Licenca

AGPL-3.0-or-later; puni tekst je u LICENSE-AGPLv3.txt. Sačuvajte obavezne licence i tuđe autorske napomene. Identitet održavaoca ne znači da Fondacija vodi svaku instalaciju.
