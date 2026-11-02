# Produkcioni profil na novom Linux VPS-u

**Status:** konfiguracija je pripremljena za zasebnu probu. Javni TLS, obnova sertifikata, reboot VPS-a i stvarni restore ovog kandidata nisu potvrđeni. Lokalni WSL PASS se ne prenosi u taj status.

Koristite novi Linux x86_64 server i sopstveni testni domen prije javnog otvaranja zajednice. Sistemske pretpostavke i priprema Docker-a opisani su u [lokalnom vodiču](LOKALNO.md). Kapacitet diska, memoriju, veličinu baze i fotografija izmjerite na svom serveru; instalaciona zaštitna granica nije garantovan produkcioni minimum. Zadržite SSH pristup ograničen na operatere i rezervne kopije izvan tog servera.

## Instalacija i konfiguracija

Klonirajte izabrani javni tag kao svoj namjenski operaterski Linux nalog, npr. `mi`, u `/srv/mi`. Taj nalog mora imati svjesno dodijeljen pristup lokalnom Docker socket-u. Ne koristite produkcione tajne druge zajednice.

```sh
./script/mi_install install --profile production --domain community.example.org
./script/mi_install verify
```

Zamijenite `community.example.org` svojim domenom. Profil koristi runtime image bez demo initializer-a, bez Mailpit-a i bez simuliranog telefona. HTTP aplikacije vezan je samo za `127.0.0.1:3100`, namijenjen TLS proxy-ju. PostgreSQL i Redis nemaju objavljene portove. Produkciona mreža omogućava izlaz: odobrite samo integracije koje zajednica zaista koristi; instalacija sama ne dokazuje njihov rad.

Installer stvara nezavisne Rails/JWT, aplikacionu DB i administratorsku DB tajnu. PostgreSQL bootstrap kreira `mi_app` sa NOSUPERUSER, NOCREATEDB i NOCREATEROLE, bazu u njegovom vlasništvu i potrebne `ltree`/`pg_trgm` ekstenzije. Aplikacioni `db:prepare` koristi konačni `mi_app`, ne administratorski nalog. Bootstrap tajna se ne predaje web/worker procesu. Stvarni prolaz migracija tim nalogom mora se potvrditi novom instalacijom; greška se ne rješava trajnim superuser pravima.

Za branding i SMTP napravite privatni `.mi-install/operator.env` sa pravima 0600 i samo željenim ključevima, po jedan `KEY=VALUE` u redu. Podržani su `DECIDIM_APPLICATION_NAME`, `DECIDIM_MAILER_SENDER`, `SMTP_ADDRESS`, `SMTP_PORT`, `SMTP_DOMAIN`, `SMTP_STARTTLS_AUTO`, `SMTP_OPENSSL_VERIFY_MODE`, `SMTP_AUTHENTICATION`, `SMTP_USERNAME`, `SMTP_PASSWORD`. Vrijednosti su literalne: ne dodajte shell navodnike i ne koristite `source`. Znakovi dolara i backtick-a u lozinci ostaju podaci.

```sh
./script/mi_install configure --env-file .mi-install/operator.env
./script/mi_install restart
```

Ova komanda čuva osnovne generisane tajne i ne mijenja profil, domen, endpoint ili DB odredište. Unos podešavanja nije dokaz SMTP dostave. Privatni ulazni fajl poslije unosa uklonite ili čuvajte u svom upravljaču tajnama; nije potreban za normalan start. Ne uređujte `app.env` ručno: instalacioni zapis provjerava njegov hash i ima oporavak za prekinutu `configure` komandu.

## DNS i javni TLS

Podesite A/AAAA domenu na adresu novog VPS-a, uključujući uklanjanje pogrešnog AAAA zapisa ako server nema odgovarajući IPv6. Samo javni proxy treba da sluša 80/443; app port ostaje na loopback-u.

Instalirajte Caddy prema [zvaničnom postupku za Ubuntu](https://caddyserver.com/docs/install#debian-ubuntu-raspbian). Prilagodite [Caddyfile.example](Caddyfile.example), pregledajte ga i postavite kao `/etc/caddy/Caddyfile` sa svojim domenom i web portom. Caddy automatski pribavlja i obnavlja javni TLS kada DNS i mrežni uslovi to dozvoljavaju; sačuvajte njegov trajni data direktorijum. [Uslovi automatskog HTTPS-a](https://caddyserver.com/docs/automatic-https).

```sh
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
curl --fail --show-error --silent https://community.example.org/up
```

Provjerite HTTP preusmjeravanje, važeći lanac sertifikata, stvarni datum isteka i obnovu. Pregledajte login cookie za Secure/HttpOnly, host i HTTPS linkove u porukama. Caddy postavlja proxy zaglavlja, a Rails produkcioni profil zadržava force_ssl. Ne uključujte demo HTTP override da biste zaobišli proxy grešku.

## Administrator i lokalni sadržaj

Nakon TLS podešavanja:

```sh
./script/mi_install admin
```

Interaktivno pripremite sopstvenog sistemskog administratora, otvorite `https://community.example.org/system` i napravite organizaciju sa tim istim hostom, jezicima i stvarnim administratorskim pozivom. Demo provisioning je odbijen u produkcionom profilu. Pripremite sopstvene pravne tekstove, kontakte, geografiju i izvore prije otvaranja registracije. [Detaljna konfiguracija funkcionalnosti](../docs/FUNKCIONALNOSTI.md) u javnom izdanju opisuje opcione adaptere. Ne unosite podatke Bijeljine kao zamjenu za svoju zajednicu.

## Automatski start i nadzor

Prilagodite [mi-community.service.example](mi-community.service.example) stvarnom nalogu i apsolutnom checkout-u. Instalaciju prvo dovršite ručno; tek zatim kopirajte pregledani unit u `/etc/systemd/system/mi-community.service`.

```sh
sudo systemctl daemon-reload
sudo systemctl enable docker mi-community
sudo systemctl start mi-community
sudo systemctl status mi-community
```

Compose servisi imaju restart politiku; oneshot unit upravlja start/stop redoslijedom i ne predstavlja kontinuirani zdravstveni nadzor. Poslije izričito odobrenog reboot-a VPS-a provjerite sa drugog računara HTTPS, prijavu, fotografije i izvršen testni worker posao. Sam `active` ili `/up` nisu dokaz cijelog toka. Worker quiet/drain ima 150 sekundi, TERM grace 90, a systemd Stop rok 360 sekundi.

Nadzirite web, worker proces/heartbeat, starost i veličinu reda, neuspjele poslove, disk, PostgreSQL/Redis i datum isteka TLS sertifikata. Podesite lokalnu politiku rotacije journald/proxy logova. Compose aplikacioni i PostgreSQL logovi su ograničeni na 3 × 10 MB po kontejneru; i ostale servise treba obuhvatiti rotacijom. Ne objavljujte logove sa ličnim podacima. Broj uspješno izvršenih testnih poslova vodite odvojeno od dostupnosti weba.

## Backup, restore i nadogradnja — otvorena verifikacija

Komande za backup i izolovani restore opisane su u [OPORAVAK.md](OPORAVAK.md), sa odvojenim native dokazom i otvorenom Docker/VPS provjerom. Postupak nadogradnje i oporavak poslije migracione greške opisani su u [NADOGRADNJA.md](NADOGRADNJA.md), uz još otvorenu stvarnu Docker probu. Do odgovarajuće stvarne probe ne koristiti ovaj kandidat kao jedini produkcioni primjerak podataka. `stop/start`, trajni volumen i lista arhive nisu dokaz oporavka.

Potrebno je sačuvati DB, fotografije, potrebnu Redis/queue politiku, trajne tajne, konfiguraciju i tačan par image-a/host/engine koda. Demo credential fajl ostaje odvojen od foto kopije. Kopije moraju imati ograničen pristup, dogovoreno čuvanje i zasebnu lokaciju. Restore proba ide u drugo prazno izolovano okruženje sa stvarnim sintetičkim sadržajem i fotografijama, istim potrebnim ključevima i blokiranim spoljnim slanjem. Pregledajte vraćeni red prije worker starta; ne šaljite ponovo stare poruke.

Ne koristite novi `install` nad postojećim ili vraćenim podacima, ne radite neplanirani PostgreSQL major upgrade i ne mijenjajte engine pin nezavisno od host lockfile-a. Nadogradnja mora imati backup prije migracija i dokumentovan rollback ili forward repair; code rollback ne poništava migracije. Ovaj odjeljak ostaje otvoren dok se komande i stvarni rezultati ne dopune.

Za stvarni SMTP pripremite sopstveni nalog i provjerite DNS autentikaciju i dostavu na dogovorenu adresu. SMS/Viber, AI i naplata ostaju opcioni i imaju zasebne naloge, privatne konfiguracije i konkretno odobrene probe. Lokalna simulacija nije zamjena za njih.
