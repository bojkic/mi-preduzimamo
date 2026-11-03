# Backup i izolovana proba oporavka

**Status kandidata:** postoje komande i ciljane provjere. Stvarni native PostgreSQL 18.6/filesystem eksperiment prošao je sa drugom praznom bazom: upoređene su 232 tabele, 230 sekvenci i pet fajlova; vraćeni proces i fotografija su pročitani, a novi upis prošao je nalogom bez superuser prava. Kontrolisane izmjene podataka i fotografije prepoznate su kao razlika. Ovo nije potvrda Docker image importa, container volumena, TLS-a, reboot-a ili VPS prihvatanja novog izdanja.


Prema nezavisnom rc5 izvještaju, stvarni Docker backup (91 s), restore (77 s) i restore-inspect (76 s) prošli su na istom novom daemon-u u drugom projektu/praznim volumenima: 232 tabele, 230 sekvenci i šest storage fajlova bez razlika, očuvani ključevi i novi upis kao mi_app bez superuser prava. Cilj je ostao u karantinu. Tačan image već je postojao na tom daemon-u: hladni import na drugom praznom daemon-u i off-site oporavak nisu dokazani. To je rezultat rc5, ne nove izmijenjene verzije.

## Napravite kopiju

Iz dovršene, pokrenute instalacije:

```sh
./script/mi_install backup
```

Za sopstveno odredište prvo pripremite privatni direktorijum sa pravima 0700, pa navedite novo, nepostojeće odredište unutar njega:

```sh
./script/mi_install backup --output /privatne-kopije/izabrana-kopija
```

Zamijenite putanju stvarnim privatnim odredištem. Alat odbija postojeći direktorijum kopije, tuđe/nedostajuće volumene i unos kopije u izvorni kod. Podrazumijevano odredište je `.mi-install/backups/<vrijeme>-<identitet>`.

Planirajte prekid dostupnosti: alat šalje worker-u TSTP, čeka drain, zaustavlja web/worker, pravi čitljivi otisak baze i fotografija, upisuje neautentifikacionu kontrolnu oznaku za taj snapshot, snima Redis i zaustavlja ga. Zatim strimuje DB dump, storage/Redis arhivu i tačan aplikacioni image direktno u privatne fajlove. Kopira potrebne env tajne i konfiguraciju, upisuje checksum manifest i ponovo pokreće servise. DB i Rails/JWT ključevi se ne generišu ponovo. Demo plaintext credential fajl nije dio kopije fotografija niti ovog backup paketa.

Obezbijedite prostor za logički dump, cijeli nekompresovani image i storage/Redis arhivu, uključujući rast podataka i privremeni `.part` fajl. Ne čistite tuđe Docker resurse da napravite prostor. Ako korak padne, aplikacija ostaje zaustavljena kada je to potrebno za dosljedan nastavak:

```sh
./script/mi_install resume
```

Sačuvajte privatni zapis i djelimične fajlove. Nastavak koristi iste tajne i dovršene arhive; ne pokrećite novi `install`. Uspješan checksum i završena kopija još ne dokazuju oporavak. Kopiju prenesite i na zasebnu kontrolisanu lokaciju uz ograničen pristup, zaštitu pri prenosu i čuvanju i sopstvenu politiku zadržavanja. Alat ne briše stare kopije automatski.

## Vratite kopiju u novi izolovani cilj

Koristite sopstvenu provjerenu kopiju i drugi, čist checkout **istog app/engine/lockfile para**. Sačuvani image sadrži tačan runtime; ne zamjenjujte ga novim build-om sa drugačijim APT paketima. Operaterski/runtime UID mora odgovarati izvornom. Cilj može biti drugi daemon/server ili drugi projekt na istom računaru, uz slobodne loopback portove.

```sh
./script/mi_install restore --backup /privatne-kopije/izabrana-kopija --web-port 3200 --mail-port 8225
./script/mi_install restore-inspect
```

Alat provjerava checksum-e prije rada, odbija postojeći `.mi-install`, pravi novo project ime i zasebne volumene, a čuva aplikacione tajne i DB identitet. Uvozi image, storage/Redis i dump. PostgreSQL bootstrap zadržava potrebne ekstenzije; tabele se vraćaju kao konačni aplikacioni nalog `mi_app`, bez trajnih superuser prava. Nepodržana dodatna ekstenzija traži pregled bootstrap-a; ne preskače se tiho.

Početni restore ima internu mrežu, nema objavljene portove i ne pokreće web ni worker. Jednokratni aplikacioni proces provjerava izvor/build i poredi sadržaj baze, sekvence, fotografije i Redis kontrolnu oznaku sa kopijom. `restore-inspect` dodatno prikazuje broj i klase poslova, retry/scheduled/dead brojače, bez argumenata poslova, primaoca ili tijela poruka. To je inventar za pregled, ne dokaz da svaki posao smije ponovo da se izvrši.

Ako uvoz padne, koristite `resume` u istom ciljnom checkout-u. Ponavljanje DB uvoza smije očistiti i ponovo učitati isključivo taj novonapravljeni restore cilj. Izvorna instalacija i njeni volumeni ostaju odvojeni. Ne preusmjeravajte target zapis na postojeću bazu i ne pokrećite new-install generator nad vraćenim podacima.

Za običnu WSL probu ostavite kopiju u karantinu. Provjerite vraćeni sintetički proces, originalnu fotografiju i novi upis; sačuvajte rezultate odvojeno od lokalne instalacije. Ne aktivirajte kopiju sa stvarnim porukama dok izvorna instalacija i dalje radi.

## Aktiviranje poslije pregleda

Za stvarni oporavak operater prvo pregleda red poslova i spoljne integracije, uključujući mogućnost da su poslovi iz kopije u međuvremenu već izvršeni. Pripremi odgovarajući domen/TLS i spriječi paralelnu obradu izvorne instance. Poslije tog pregleda može izričito pokrenuti:

```sh
./script/mi_install activate-restored --queue-reviewed
```

Time se izlazi iz karantina i normalno pokreću web i worker. Zastavica bilježi operaterov izbor; sama nije dokaz ispravnosti reda ili stvarne dostave. Alat ne briše red automatski. Ako treba ukloniti/izmijeniti pojedine poslove, uradite to zasebnim pregledanim postupkom prije aktiviranja.

Poslije aktiviranja ponovite HTTP/TLS, prijavu, čitanje sadržaja/fotografija i kontrolisan worker posao. Za dokaz oporavka zabilježite stvarne app/engine SHA, image ID, profil, datum, gubitak podataka od trenutka kopije i izmjereno vrijeme vraćanja. Podatke, env, dump, image arhivu, OTP i privatne logove ne dodajte javnom izvještaju.

## Čuvanje i udaljena kopija

Prije javne upotrebe zapišite odgovornu osobu, dozvoljeni gubitak podataka (RPO), rok oporavka (RTO), raspored i budžet prostora. Kao početni prijedlog za malu zajednicu razmotrite dnevnu kopiju, sedam dnevnih i četiri sedmične kopije; stvarno zadržavanje prilagodite obimu i svojim obavezama. Ovo nije već aktiviran scheduler ili odluka o brisanju. Backup zaustavlja web/worker radi dosljednosti, pa raspored mora uključiti očekivani prekid.

Udaljeno odredište mora pripadati zajednici ili ugovorenom hostingu, imati ograničen pristup i šifrovano čuvanje. Prenesite cijeli dovršeni direktorijum preko provjerenog SSH kanala ili odobrenog backup servisa, zatim tamo uporedite manifest i svaki checksum. Ne šaljite kopije e-mailom i ne unosite ih u Git. Ključ za dešifrovanje mora biti dostupan operateru i kada izvorni server ne radi. Sam završen prenos nije dokaz oporavka.

Za konačno prihvatanje na drugom praznom daemon-u/serveru pribavite kod sačuvanog tačnog para, prenesite tu udaljenu kopiju i izvršite restore u karantinu. Zabilježite da image nije postojao prije probe, da je uvezen iz kopije, sadržajne hash-eve, fotografije, novi upis, očuvane ključeve i stvarni RPO/RTO. Brisanje starih kopija odložite dok posljednja provjerena udaljena kopija i politika zadržavanja nisu potvrđeni.
