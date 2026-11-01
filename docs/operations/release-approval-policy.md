# Lokalna politika provjere izdanja

Zajednica određuje svoju politiku i odgovorne osobe. [Primjer politike](../../config/examples/release-approval-policy.example.yml) je početni oblik, a ne potvrda da su provjere izvršene. Kopirajte pregledani primjer u `docs/operations/release-approval-policy.yml` i prilagodite opsege svojim stvarnim lokalnim komandama.

Pripremite izolovanu testnu bazu i Redis prema [vodiču za provjere](../PROVJERE.md). `script/verify` provjerava stvarni app/engine par, bezbjednu testnu konfiguraciju, autoload i backend testove. Frontend se kompajlira i testira prema istom vodiču. Sačuvajte tačne commitove, hash politike, rezultate obaveznih opsega, podatke o izabranom Ruby/Node okruženju i razriješene nalaze. Potvrda za drugi par ili izmijenjenu politiku ne potvrđuje tekući kandidat.

Administratorski obrazac bilježi odluku i njen dokaz. Sam upis „approved“ ili „passed“ ne pokreće testove i ne potvrđuje neprovjeren deployment. Nedostajuća politika ostavlja odobrenje izdanja nedostupnim. Prije produkcione promjene odgovorna osoba provjerava konkretno izdanje, backup i mogućnost oporavka, migracije, rok za restart i provjere HTTP-a poslije promjene. Kod ne sadrži ovlašćenje Fondacije za tuđu instalaciju.

Ovaj vodič i primjer ne uvoze privatnu politiku ili rezultate LF Bijeljina. Interni postupak Fondacije i vaše sopstvene produkcione procedure ostaju zasebni. Ne unosite kredencijale, lične podatke ili privatne logove u odobrenje ili javni dokaz.
