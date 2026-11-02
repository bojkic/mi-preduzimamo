# Istorija izdanja

## v0.1.4-rc2 — kandidat za nezavisnu probu

Dopunjeni su prevodi pogođenih administratorskih tokova na sva četiri jezika, uz inventar ključeva i regresione provjere kalendara. Stranica otvorenog koda dobila je offline navigacionu rutu. Produkcioni build ne isporučuje source mape sa internim putanjama domaćina. Upozorenja o velikim paketima ostaju vidljiva. Ove native provjere ne potvrđuju novu čistu Docker/WSL instalaciju, Docker restore/nadogradnju ili VPS/TLS/reboot.

## v0.1.4-rc1 — Kandidat instalera i održavanje

Novi izolovani demo/VPS profili, privatni backup, karantinski restore i nastavak nadogradnje bez novih autentifikacionih ključeva. Node 22.23.4/npm 10.9.9; Ruby/Rails/Decidim ostaju 3.4.12/8.1.4/0.32.2. Dodati su sintetički worker probe i uputstva. Ciljane native provjere nisu dokaz nove čiste Docker/WSL ili VPS instalacije; to prihvatanje ostaje otvoreno.

## v0.1.3 — 2026-11-02

- Ispravljen poziv Decidim 0.32 komande za telefonsku i imenovanu/poštansku autorizaciju; privremeni host adapter nije potreban.
- Dodate ciljane provjere stvarnih OTP/link tokova, zaključavanja i konkurentnih potvrda. Ovo izdanje ne proglašava stari Docker put ili VPS instalaciju provjerenim.

## v0.1.2 — 2026-11-01

- Ispravljeni stilovi jezičkih putanja procesa i prikaz glavnog menija nakon prelaska na Decidim 0.32.
- Vraćeni istaknuti proces i aktivnosti uz postojeća pravila vidljivosti.
- Stranica o otvorenom kodu i podnožje dostupni su na sva četiri jezika platforme.

## v0.1.1

- BIH administracija koristi jezičke putanje Decidim-a 0.32; stari GET linkovi vode do dostupne stranice, a raniji POST/PATCH endpoint-i ostaju kompatibilni.
- Usklađene su provjere jezičkih putanja i linkova prijava, uz zadržanu provjeru obrade prijava i ovlašćenja.

## v0.1.0

Prvo javno izdanje referentne aplikacije MI preduzimamo za lokalne zajednice u Bosni i Hercegovini.

- Kod postojećih funkcionalnosti: učešće građana, prijave problema, komšiluci, volontiranje, projekti, nenovčana pomoć, donacije, bodovi, lokalna obavještenja, poruke i Milica. Zahtjevi i granice svake oblasti opisani su u [pregledu funkcionalnosti](docs/FUNKCIONALNOSTI.md).
- Zajednički engine je zaključan na tačan javni Git commit. Lokalni podaci, pristupni podaci i bijeljinski produkcioni sadržaj nisu dio izdanja; referentni adapteri traže izričitu konfiguraciju.
- Uključeni su srpska latinica, srpska ćirilica, bosanski i hrvatski. [Instalacioni vodič](docs/INSTALACIJA.md), [lokalne provjere](docs/PROVJERE.md) i sintetički primjeri služe samostalnom pokretanju.
- [AGPL-3.0-or-later](LICENSE-AGPLv3.txt), sačuvane tuđe licencne napomene i [postupak doprinosa](CONTRIBUTING.md) uz CLA. [Pomoć Fondacije](docs/POMOC_FONDACIJE.md) ugovara se zasebno.

Prisustvo koda ili prolaz lokalnih testova ne potvrđuje podešenost, isporuku poruka ili prihvatljivost spoljne usluge u vašoj zajednici. Javno izdanje ne predstavlja tvrdnju da je identično trenutno aktivnoj privatnoj instalaciji.
