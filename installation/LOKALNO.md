# Lokalna instalacija za izmišljenu zajednicu

**Status:** javni RC7 ima nezavisni lokalni install/upgrade prolaz, a pregledane engine dopunske ispravke zaseban1194/6787 prolaz. Dodatna native RC8 proba pokazala je još dva kvara: listu prijedloga i povratak na filtrirani administrativni spisak prijava. RC9 kandidat ih ispravlja, uz dopunjene prevode i stvarne četvorojezične editor/čuvanje/faze/objavljivanje provjere. Novi RC9 Docker image i završni install/upgrade/browser prihvat još nisu potvrđeni. Detalji su u [matrici](REZULTATI_PROVJERA.md) i [postupku provjere](PROVJERA_WSL2.md).

Ovo je jedini lokalni Compose put. `compose.yml` sa demo profilom pokreće web, worker, PostgreSQL, Redis, Mailpit i Nginx. Stari `docker-compose.yml` je uklonjen. Za javni server koristi se zaseban [produkcioni profil](PRODUKCIJA.md).

## Priprema računara

Obuhvat je Linux x86_64, uključujući WSL2. Za novi lokalni sistem izaberite Ubuntu 24.04 LTS, Git, Python 3.12+, Docker Engine i Compose 2.30+. Ruby i Node dolaze kroz image. Installer zahtijeva najmanje 15 GiB slobodnog prostora za build i 4 GiB RAM-a dodijeljenog Docker-u; to su početne zaštitne granice, još nisu izmjeren minimum ovog novog image-a. Obezbijedite dodatni prostor za slike, podatke i kopije. Nezavisna rc5 proba mjeri hladni install 658 s i glavni image oko 2,58 GiB. Više instalacija, build cache i četiri privatne kopije zajedno su zauzeli oko 27,42 GiB novog Linux filesystem-a; to nije veličina jedne instalacije. WSL je dijelio 7,59 GiB RAM-a, a uzorkovanje nije obuhvatilo cijeli BuildKit proces. Ovi podaci ne potvrđuju da je 4 GiB dovoljno za svaki build niti garantuju vrijeme instalacije. Ne mijenjajte globalna WSL podešavanja ili tuđe resurse radi prolaza.

Na Windows-u provjerite `wsl --list --verbose` u PowerShell-u. Ako WSL nije instaliran, [Microsoft postupak](https://learn.microsoft.com/en-us/windows/wsl/install) opisuje `wsl --install`, restart Windows-a i pripremu Linux naloga. Postojeću distribuciju nemojte brisati radi ove probe. Repozitorijum čuvajte u Linux home direktorijumu, npr. `~/mi-zajednica`, bez ličnih Windows putanja u izvještaju.

Unutar novog Ubuntu sistema:

```sh
sudo apt update
sudo apt install git python3 ca-certificates curl
```

Za **novi Ubuntu 24.04 x86_64 bez postojećeg Docker-a**, sljedeće komande dodaju zvanični repozitorijum i instaliraju Engine/Compose. Ovo je sistemska radnja operatera; installer platforme je ne izvršava. Prvo provjerite `cat /etc/os-release`, `uname -m` i `docker version`. Ako već koristite Docker Desktop kroz WSL ili drugi daemon, zadržite njega i preskočite instalaciju drugog Engine-a.

```sh
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null <<'EOF'
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: noble
Components: stable
Architectures: amd64
Signed-By: /etc/apt/keyrings/docker.asc
EOF
sudo apt update
sudo apt install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

Ovaj primjer bira Ubuntu 24.04 (`noble`) i `amd64`; ne kopirajte ga na drugu distribuciju/arhitekturu. Ako apt prijavi konflikt sa postojećim Docker/containerd paketima, zaustavite pripremu i pregledajte njihovu upotrebu prema zvaničnom vodiču. Ne uklanjajte ih automatski.

Instalirajte Engine i Compose iz [zvaničnog Docker apt repozitorijuma](https://docs.docker.com/engine/install/ubuntu/). Ako postoje drugi Docker/containerd paketi ili resursi, prvo procijenite konflikt; nemojte automatski uklanjati tuđe servise. Kada je Docker instaliran, uz systemd provjerite:

```sh
sudo systemctl start docker
sudo systemctl status docker
sudo docker version
sudo docker compose version --short
```

Za rad bez `sudo` izaberite svoj način lokalnog pristupa Docker socket-u. Ako koristite Docker grupu, operater mora svjesno odobriti privilegije tog naloga i ponovo se prijaviti. Pokrećite sve komande instalera kao isti Linux nalog. U WSL-u bez systemd-a koristite dokumentovani način pokretanja svog Docker okruženja; otvoren dockerd terminal nije dokaz starta poslije reboot-a. Ne instalirajte drugi daemon preko postojećeg Docker Desktop okruženja.

## Klon i pokretanje

Klonirajte javni repozitorijum i izaberite objavljeni tag koji provjeravate:

```sh
git clone https://github.com/bojkic/mi-preduzimamo.git mi-zajednica
cd mi-zajednica
git checkout <objavljeni-tag>
./script/mi_install install --profile demo --capture-phone
./script/mi_install verify
```

`<objavljeni-tag>` zamijenite stvarnim tagom koji uključuje installer; v0.1.3 je OTP hotfix i nema ovaj novi paket. Ne preuzimajte proizvoljnu buduću verziju iz ovog primjera. Izvor mora biti commitovan i čist. Nije potrebno zasebno klonirati engine: puni Git SHA dolazi iz lockfile-a.

Otvorite `http://127.0.0.1:3100` i Mailpit `http://127.0.0.1:8125`. Ako su portovi zauzeti, pri novoj instalaciji izaberite `--web-port 3200 --mail-port 8225`. Adresa `127.0.0.1` koristi se i kao host organizacije: Decidim forma ne prihvata goli `localhost` kao organizacioni domen.

`--capture-phone` je opciono. Bez njega lokalni demo ne glumi telefonskog providera. Sa njim isključivo broj `+15555550101` dobija simuliranu poruku kroz Mailpit; nema stvarnog SMS/Viber slanja i OTP se i dalje mora pravilno potvrditi. Drugi brojevi se odbijaju. Mailpit ne potvrđuje provider readiness.

## Administrator i izmišljena organizacija

Osnovni `verify` prvo treba da prođe sa nula organizacija. Demo naloge i sadržaj pripremate zasebno:

```sh
./script/mi_install demo-system
```

Privatno otvorite `.mi-install/private/credentials.json` u svom editoru. Nemojte kopirati lozinke u terminalski snimak, izvještaj ili javni issue. Prijavite se na `http://127.0.0.1:3100/system`, napravite organizaciju „MI preduzimamo — Zajednica Primjer“, host `127.0.0.1`, jezike `sr`, `sr-Cyrl`, `bs`, `hr` i pozovite administratora `admin@example.org`. Izbor hosta, naloga i prazne baze je namjerna zaštita demo alata.

```sh
./script/mi_install demo-content
```

Isti privatni fajl sada sadrži i lozinku organizacionog administratora. Prijavite se na `/sr/users/sign_in`, pregledajte sintetičke uslove i administraciju. Demo tekstovi nisu pravni dokumenti za stvarnu zajednicu. Ako organizacija već ima druge korisnike, pregledane pravne stranice ili sadržaj, alat odbija upis. Ponovljeni završen poziv čuva postojeće lozinke i stranice; prekid nastavite istom komandom.

Za potpunu probu telefonskog uključivanja i izbora komšiluka, prije registracije građana izričito uvezite izmišljene oblasti:

```sh
./script/mi_install demo-geography
```

Komanda zahtijeva završen `demo-content`, isti lokalni demo/DB identitet i praznu geografiju. Uvozi samo javni `db/examples/synthetic_community.geojson` (jedna izmišljena MZ i četiri komšiluka oko koordinata 0,0), u transakciji i bez promjene lozinki. Ponovljeni dovršeni poziv čuva podatke; postojeće oblasti bez tog demo markera odbijaju se. Ne pokrećite je nad ranijim RC6 primjerom kojem ste već ručno uvezli oblasti. Stvarna zajednica priprema sopstvene podatke zasebnim javnim geo taskom. `demo-content` i dalje ne učitava geografiju automatski.

U lokalnom demou i originalni „Potvrdi e-mail“ link i Devise potvrda nove adrese moraju stići u Mailpit sa `http://127.0.0.1:<web-port>` porijeklom. Ne prepravljajte primljeni link da bi proba prošla. Normalno potvrđena nova adresa mora otvoriti postojeću lokalizovanu sljedeću stranicu. Produkcioni profil zadržava javni HTTPS domen i nema lokalni override.

Privatne demo lozinke su izvan foto volumena. Nakon probe izvezite samo redigovane rezultate i uklonite privatni credential fajl kada više nije potreban; poslije uklanjanja demo provisioning više ne treba pokretati. Ako instalaciju zadržavate, prvo promijenite lozinke kroz uobičajeni postupak. Izmišljeni demo se ne pretvara u produkciju promjenom jedne zastavice.

## Rad i nastavak poslije greške

```sh
./script/mi_install check
./script/mi_install status
./script/mi_install stop
./script/mi_install start
./script/mi_install restart
./script/mi_install recreate
./script/mi_install verify
```

Zaustavljanje prvo šalje worker-u TSTP, čeka drain do 150 sekundi, zatim koristi TERM grace period od 90 sekundi. Ako drain ne završi, alat odbija prisilno gašenje. `resume` zna i za worker ostavljen u quiet režimu. Stvarni posao u toku mora se posebno provjeriti u nezavisnoj probi.

Poslije prekinutog build-a ili DB pripreme:

```sh
./script/mi_install resume
```

Ne ponavljajte `install`, ne brišite marker i ne generišite nove tajne. Privatni zapisi i redigovanja vrijedni logovi nalaze se u `.mi-install`; pregledajte ih lokalno. Ne šaljite cijeli direktorijum drugoj osobi. Ako je konfiguracija ručno promijenjena ili je Docker socket počeo da vodi na drugi daemon, alat odbija rad; ne zaobilazite provjeru brisanjem zapisa.

Svaka komanda koristi isti zapisani project, profil, Unix endpoint i eksplicitni env fajl. Konfliktne naslijeđene `COMPOSE_*`, `DOCKER_*` i osnovne DB/Rails tajne se odbijaju. Otvorite čist shell ili uklonite konkretan konflikt; vrijednosti se ne ispisuju. Ne koristite direktne Compose komande kao paralelni put upravljanja instalacijom.

Za kopiju i zasebnu probu vraćanja koristite [OPORAVAK.md](OPORAVAK.md). Trajni volumeni čuvaju PostgreSQL, Redis, fotografije i lokalni Mailpit. Restart/recreate nije backup. Ne koristite `down -v`, globalni prune, brisanje zajedničkog WSL cache-a ili gašenje drugih distribucija radi popravke. Interna demo mreža namjerno blokira izlazne integracije; AI, naplata, izvori i stvarne poruke zahtijevaju zasebnu produkcionu konfiguraciju i sopstvene naloge.

## Verzije i ograničenja build-a

Kandidat koristi Ruby 3.4.12, Rails 8.1.4, Decidim 0.32.2, Node 22.23.4 i npm 10.9.9. Node je usklađen sa zaključanim npm zavisnostima. Stari build sa 22.22.1 prošao je uz upozorenje; to nije dokaz da je prethodni build pao zbog Node-a.

Ruby, PostgreSQL, Redis, Mailpit i Nginx baze su pinovane digest-om; Node i ImageMagick preuzimanja se provjeravaju checksum-om. APT paketi nisu vezani za snapshot repozitorijum, pa budući build nije obećan kao bit-identičan. Runtime je višefazan, bez root korisnika; libvips i ImageMagick ostaju potrebni. Stvarne JPEG/PNG/WebP tokove i runtime biblioteke novog image-a tek treba potvrditi.

Historijski uzorak patchovane instalacije trajao je oko 8 min 38 s uz image oko 4.21 GB. To je rezultat drugog sklopa na jednom računaru, bez obećanja trajanja ili veličine ovog kandidata.

## Worker posao u toku

Demo image sadrži ograničen probni posao od 90 sekundi. Ne koristi provajdere niti podatke građana. Pokrenite ga i provjerite da je stvarno započeo:

```sh
./script/mi_install demo-probe
./script/mi_install demo-probe-status
```

Kada status pokaže `started: 1`, pokrenite `./script/mi_install recreate`. Poziv mora sačekati završetak posla kroz drain, pa zamijeniti kontejnere uz iste volumene. Poslije toga `demo-probe-status` treba da pokaže `attempts: 1`, `completions: 1`, `effect: 1`. Ponavljanje pokušaja se posebno vidi; idempotentna lokalna oznaka efekta nije dokaz stvarne spoljne dostave. Ako posao još nije počeo prije recreate-a, ta proba ne dokazuje posao u toku.

Za nadogradnju postojećih podataka koristite [NADOGRADNJA.md](NADOGRADNJA.md); ne ponavljajte novi `install`.

Istorijski B sklop i prve pripremne provjere koristili su Node 22.22.2/npm 10.9.7. Za novi kandidat izabrana je bezbjednosna zakrpa Node 22.23.4 od 20. 10. 2026. sa npm 10.9.9 u istoj Node 22 grani; [zvanični indeks izdanja](https://nodejs.org/dist/index.json). Novi sklop traži sopstveni build/probu.
