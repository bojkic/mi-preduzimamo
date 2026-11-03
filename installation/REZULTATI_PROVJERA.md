# Rezultati i granice instalacionih provjera

Pregled nezavisnih izvještaja od 3. novembra 2026. Ovaj sažetak zamjenjuje javno povezivanje na privatni `CLEAN_INSTALL_REPORT.md` i istorijski `INSTALACIJA_CLEAN.md`. Sirovi izvještaj, ZIP, lokalne putanje i pristupni podaci nisu dio javne dokumentacije. Za novu instalaciju koristite [LOKALNO.md](LOKALNO.md), a za server [PRODUKCIJA.md](PRODUKCIJA.md).

## Aktuelni pregled

| Obuhvat | Rezultat | Granica |
|---|---|---|
| Neizmijenjeni javni RC7: nova lokalna instalacija i direktni RC6 → RC7 upgrade | Prošlo u nezavisnoj WSL2 laboratoriji | Novi projekti/volumeni, zajednički OS/daemon/cache, bez VPS tvrdnje |
| Neizmijenjeni javni RC7: puni engine harness | Neuspješno: 1.188 / 6.443, 71 failure, četiri error, jedan skip | Izvorni rezultat je sačuvan |
| Pregledane RC7 engine dopunske ispravke | Prošlo: 1.194 testa / 6.787 tvrdnji, nula failures/errors/skips | Javni generated-host, svih139 izvornih fajlova; lokalno popravljena grana, ne stari javni tag |
| Četiri nove/dopunjene DB-free unit regresije na toj grani | Prošlo: 10 / 2.546, bez grešaka/preskakanja | Izolovani test bundle, bez mreže/DB/Redis-a |
| Objedinjeni RC8: novi image, browser i direktni RC7 → RC8 upgrade | Čeka završnu probu | Raniji prolazi se ne prepisuju novom image-u |
| Stvarni VPS/TLS/reboot, hladni off-site restore i sopstveni provajderi | Nije izvršeno | Zasebni resursi i stvarni rezultati |

RC7 novi install trajao je740s, a direktni upgrade/verify wrapper355s. Potvrđeni su normalni e-mail dokaz i povratak200, privatnost mail-job loga uz očuvan retry payload, eksplicitna demo geografija, fotografije i navedene lokalne persistence/drain/restore provjere. Stari javni tag ima preostale administratorske engleske tekstove i neuspjeli puni engine obuhvat.

Nezavisni engine follow-up prvo je potvrdio tačan reviewed tree `784d3a5aae508069024463a2f09957834ca3c51e`: 1.194 testa / 6.767 tvrdnji, tri failures. Stvarna dodatna popravka dešifruje snimljenu poštansku metadata adresu poslije commita; dvije testne dopune usklađuju poll locale i stvarne mounted admin putanje. Konačni pregledani tree `ade9a0194133c9b60829a4f1a2a2f3e21e2780fb` prošao je svih139 fajlova za oko290s ukupno (oko224s Minitest). Generated host koristi Rails8.1.3, a engine-only razvojni bundle Rails8.1.4, uz Ruby3.4.12 i Decidim0.32.2. Nije mijenjan launcher niti izbor testova. Prvi neuspjesi ostaju odvojeni.

Pregledani ZIP tog follow-up-a ima213 payload fajlova; CRC, svi manifest hash-evi, bundle i izvor/test identiteti su provjereni. Sirovi izvještaji, runtime konfiguracija i lokalne putanje nisu dio javnog repoa. Runtime instalacije nisu pokretane niti mijenjane tim engine-only krugom. Izvorne dopunske popravke uključene su u RC8; razvojni Gemfile dodatno navodi preduslove za locale i stvarni Sidekiq logger unit test.

## Istorijska proba

Originalni javni v0.1.2 nije prošao potpuni tok nove organizacije zbog neusklađenog poziva telefonske autorizacije sa Decidim 0.32. Testirani app je `8069eb28b499549a58e3f77515d801382022c34d`, engine `8fb44caaf22ebd8369bfb4d4cf5954f55298ad3d`.

Prema dostavljenom izvještaju, lokalno patchovana A/B varijanta prošla je dvije WSL/Docker probe. Ona uključuje lokalne izmjene i nije isto što i originalni javni tag. B uzorak navodi približno 8 min 38 s i image oko 4.21 GB. Paket od 17 izmijenjenih fajlova, trajanje i veličina opisuju taj eksperiment; nisu obećanje za novi installer. Image ID i lockfile hash te istorijske varijante nisu potvrđeni ovim sažetkom.

## Objavljene ispravke

v0.1.3 je zaseban OTP hotfix: direktna engine ispravka koristi dvoargumentni upstream API. Ciljani javni testovi prošli su 18 testova / 67 provjera. To nije dokaz nove čiste instalacije i ovaj tag nema novi installer.

Istorijski kandidat **v0.1.4-rc2** imao je sljedeći identitet:

| Identitet | Vrijednost |
|---|---|
| App | `148bd79181c797def4a15f5dd24a8570870e9131` |
| Engine | `c0c024553bdc99132191cfa484bd19a29d442301` |
| SHA-256 Gemfile.lock | `6aa8d2b149931dfcc853747b8f366121842e63f8ea573eb44d7211fa0035bf48` |
| Docker image ID | Nije izgrađen/potvrđen u čistoj Docker probi |
| Datum lokalnih provjera | 2. novembar 2026. |

Na tačnom javnom rc2 paru prošli su 18 request testova / 337 provjera, inventar 16 administratorskih ruta (1 test / 20 provjera), 9 browser testova / 99 provjera i produkcioni asset build. Browser je koristio stvarno izgrađene resurse. Upozorenja o veličini paketa i granici service-worker precache-a ostaju dokumentovana; novi image i čista instalacija nisu time potvrđeni.

## Nezavisna rc3 proba i naredna ispravka

Neizmijenjeni javni **v0.1.4-rc3** (`6fe54d18499f263377122fcb89d101bfd8d9cb59`, isti engine/lockfile kao gore) nije prošao čistu WSL2/Docker instalaciju. Prema nezavisnom izvještaju od 2. novembra 2026, Bundler je stao na `charlock_holmes 0.7.9`: build stage nije imao ICU razvojne biblioteke. Install je trajao528s do neuspjeha; resume je poslije142s ponovo stao na istom mjestu. Frontend, aplikacioni image i funkcionalni tokovi nisu dostignuti. I izvorni rc1 je pao na istom nedostatku, pa upgrade nije izvršen.

Paket **v0.1.4-rc4** dodaje `libicu-dev` u build i eksplicitni `libicu72` u Debian Bookworm runtime, uz provjeru učitavanja native gem-ova pod runtime korisnikom tokom izgradnje. Ovo je ispravka potvrđenog nedostatka, ne tvrdnja da je nova čista instalacija prošla ili da drugih prepreka nema. [ICU development paket](https://packages.debian.org/bookworm/libicu-dev), [ICU runtime paket](https://packages.debian.org/bookworm/libicu72).

## RC4 dijagnostička proba i priprema RC5

Neizmijenjeni RC4 nije prošao novi Docker build: nakon odvojeno riješenog lokalnog DNS problema `groupadd` nije pronađen u ograničenom PATH-u. Dijagnostička grana zatim je ispravila apsolutne putanje account alata, prerano učitavanje demo posla i prepoznavanje tačnih upstream podrazumijevanih help/DQ stranica. Izmijenjene ili prilagođene stranice ostaju zaštićene.

Prema nezavisnom paketu od 3. novembra 2026, zakrpljena varijanta prošla je registraciju/OTP/prijavu, proces, JPEG/PNG/WebP tokove, posao u toku kroz drain/recreate, persistence i izolovani backup/restore. Nadogradnja patchovanog rc1 na dijagnostički merge cilj provjerena je i sa pending i sa granted telefonom. Jedna nadogradnja ipak je vratila HTTP502 zbog stare Nginx adrese; ručni javni restart je oporavio HTTP. Jedna početna rc1 slika imala je pogrešan engine/lock i ispravno je odbijena; uzrok tog nepodudaranja nije konačno utvrđen. Nijedan od ovih rezultata nije čisti javni-tag PASS.

Naredni kandidat **v0.1.4-rc5** preuzima pregledane instalacione popravke, osvježava demo gateway pri promjeni app revizije i koristi DNS razrješavanje promjenljive adrese. Novi installer prije prijave uspjeha provjerava i lokalnu HTTP putanju. Dodate su ranije provjere očekivanog engine/lock porijekla i potpuniji manifest, bez podrazumijevanog gašenja cache-a. Podrška starijem upgrade klijentu i runtime provjera porijekla ostaju. Dodate su i kalendarske oznake/latinični mjeseci i ciljani prevodi; novi UI još čeka browser provjeru.

Na razvojnom kandidatu prolaze69 instalacionih/provenance/HTTP provjera, uključujući stvarni izolovani Nginx/DNS test promjene adrese,6 Ruby testova/157 provjera oznaka i3 JS testa locale-a. To nisu Docker ili browser rezultati novog taga. Novi čisti RC5 build, kompletna funkcionalna matrica i zasebne VPS provjere ostaju neizvršeni.

## Neizmijenjeni javni RC5 — nezavisni izvještaj od 3. novembra 2026

Primljeni izvještaj i dnevnik navode novu praznu Ubuntu 24.04.5 WSL2 distribuciju i zaseban Docker daemon bez ranijih slika/kontejnera/volumena. Windows/kernel/RAM ostaju zajednički, a zasebna lokalna mrežna priprema i DNS opisani su u izvještaju; to nije novi VPS. Navedena četiri hash-a dostavljenih izvještajnih fajlova provjerena su prema priloženom manifestu. Sirovi redigovani logovi, screenshot-i i Git bundle navedeni u izvještaju nisu dostavljeni uz tih pet fajlova; ove rezultate navodimo kao nezavisni izvještaj, bez tvrdnje o njihovom novom serverskom izvršenju ili pregledu nedostavljenih fajlova.

| Identitet | RC5 |
|---|---|
| App | `d3cbb44421a62cff973067efe790e6a730c917b8` |
| Engine | `d18843e6e682850abf91722631d9df66de6cebbf` |
| Lockfile SHA-256 | `eba53849217f3013c034c4179c60f91f7aa6dc600f93b8de8ea67141cad0fbc0` |
| Glavni image | `sha256:c7c737b49355e6423f6db5d68ef17bcaf7f015a54580ac6180ddd0104c1587ba` |
| Profil / okruženje | demo, Linux x86_64, novi WSL2 daemon |

Hladni install prošao je za 658 s bez aplikacionih zakrpa. Prijavljeni su prolazi praznog verify-a, registracije/OTP/prijave, tri foto formata, procesa, worker-a i lokalnog Mailpit-a, stop/start/recreate-a sa stvarnim poslom u toku i nezavisnim tajnama drugog projekta. Javna Python suite ima 69 prolaznih testova nakon pripreme nedostajućih testnih Nginx temp direktorijuma; ciljana Rails suite ima 46 testova/308 provjera. Prvi neuspjesi i priprema okruženja ostaju u dnevniku.

Docker backup/restore izvršeni su u zasebnim praznim volumenima/projektu istog novog daemon-a, sa očuvanim ključevima, karantinom, 232 tabele, 230 sekvenci, šest storage fajlova i novim upisom bez superuser prava. Image je već postojao na tom daemon-u, pa hladni import na drugom praznom daemon-u i off-site restore nisu potvrđeni. Tri nadogradnje patchovanog rc1/merge/marker varijante prošle su sa očuvanim podacima i bez ručnog gateway restarta; stvarna app IP promjena nije izazvana. Detalji i granice su u [NADOGRADNJA.md](NADOGRADNJA.md) i [OPORAVAK.md](OPORAVAK.md).

UI ostaje djelimično neispravan: bosanski kalendar ima M01–M12/Sun–Sat, unutrašnje kalendarske oznake ostaju engleske, kartica potvrde e-maila protivrječi posebnom panelu, a isto vrijeme prijave različito je prikazano u sažetku i toku. Nema više undefined ARIA oznaka; sr koristi latinične mjesece i datum se pravilno serijalizuje u sva četiri jezika. Ovi nedostaci ne poništavaju izvedene podatkovne probe, ali sprečavaju potpuni UI PASS.

## Objedinjene naredne popravke

Kandidat v0.1.4-rc6 sadrži lokalizovane unutrašnje kalendarske oznake za sva četiri jezika i determinističke bosanske nazive mjeseci/dana, bez promjene datuma ili globalnog Intl-a. Status e-maila koristi isti postojeći dokaz trenutne adrese kao panel za potvrdu, bez promjene autentifikacije. Sažetak/tok/poruke/datumi prijava prikazuju aplikacionu vremensku zonu. Redis, demo gateway i Mailpit dobijaju isto ograničenje logova kao app/worker/DB. Dockerfile i zaključane zavisnosti nisu mijenjani radi smanjivanja image-a; postojeća višefazna slika već odvaja kompajler/development biblioteke. Dodatno uklanjanje runtime alata odloženo je kao opcioni rad, da se ne proširuje potvrđeni build bez potrebe.

Ovaj kandidat još nema novi Docker/kompajlirani browser PASS. Sljedeća objedinjena proba mora provjeriti kalendar/navigaciju/datum na svim jezicima, isti status potvrde e-maila prije i poslije stvarnog lokalnog dokazivanja/promjene adrese, zimsko/ljetno vrijeme i prelaz dana za prijave, Compose logging i nadogradnju iz neizmijenjenog javnog rc5 na novi javni tag. Stare zakrpljene rc1 podatkovne probe ostaju istorijski dokaz. Ponoviti opravdanu funkcionalnu matricu, ne prepisivati prethodne PASS oznake novom commitu.

## Puni RC6 paket i objedinjeni završni kandidat

Paket od 3. novembra 2026 sadrži 1.336 payload fajlova i manifest (ZIP 1.337 unosa); svaki payload hash i CRC ponovo su provjereni. Pregledani su originalni neuspjesi, redigovani logovi, ključni JSON dokazi, screenshot-i i prerequisite Git bundle-i. Secret scanner označio je tri pojave iste već javne FactoryBot testne lozinke u testnom izvorniku/patchu; to nisu runtime tajne. Sirovi privatni worker log sa credential argumentom nije dio paketa. Paket se ne objavljuje kao korisnički sadržaj niti kopira u repo.

Neizmijenjeni RC6 prošao je install (547 s), direktni javni RC5 → RC6 upgrade (404 s installer-a), funkcionalne/persistence/foto/drain probe, kontrolisane build i DB greške sa bezbjednim resume-om, kao i stvarnu promjenu app IP adrese bez gateway restarta. Osnovni verify radi prazne instalacije. Kalendar je prošao navigaciju i ISO na sva četiri jezika; izvještaj i 4 browser testa/63 provjere ne daju opšti PASS za sve admin tekstove. Backup/karantinski restore na istom daemon-u čuva podatke, fotografije, sliku i ključeve; hladni off-site import i VPS nisu testirani.

RC6 ipak nema puni e-mail tok: stvarni worker nije pronašao Devise confirmation template, lokalni proof link nema pravi origin/port, a potvrđena nova adresa vraća korisnika na nelokalizovanu SMS rutu koja ne postoji u Decidim 0.32. Tri dijagnostičke app zakrpe i dvije engine testne zakrpe sačuvane su odvojeno od neizmijenjenog taga; dijagnostički prolaz se ne prenosi RC6. Pogrešne testne rute su potvrđene izvornim route definicijama.

Završni kandidat v0.1.4-rc7 objedinjuje eksplicitni upstream mailer fallback, čuvanje lokalnog demo origin-a, lokalizovane SMS/prijavne rute i testove, Rails/Sidekiq mail-job log privatnost, 100 ciljanih UI prevoda i očuvanje editor interpolacija. Javni generated-host postupak sada priprema podržane zavisnosti i čuva izolaciju/tuđe direktorijume. Opcioni demo-geography zatvara nedostajući sintetički onboarding preduslov, bez automatskog uvoza u demo-content i bez prepisivanja postojećih oblasti.

Sve te izmjene pripadaju jednom završnom testnom krugu. Novi worker/e-mail/UI/geo/generated-host rezultati RC7 još nisu izvršeni na ovom serveru. Nove i stare prolaske voditi sa tačnim source/image identitetom. Ransack/Minitest izmjene su samo generisani razvojni host; runtime Dockerfile i zaključane runtime zavisnosti ostaju isti.

## Matrica prihvatanja

| Obuhvat | Status | Šta rezultat dokazuje |
|---|---|---|
| Originalni v0.1.2 | Neuspješno | Izvorni OTP tok treba ispravku |
| Istorijska patchovana A/B varijanta | Prošlo prema dostavljenom izvještaju | Samo tadašnji lokalno izmijenjeni sklop |
| rc2 ciljani testovi i asset build na Linux domaćinu | Prošlo u navedenom obuhvatu | Kod/render/browser resursi tog para; bez nove Docker instalacije |
| rc2 čista WSL2/Docker instalacija | Neizvršeno | Potrebna nezavisna proba samo iz javnih izvora |
| rc2 Docker backup/restore i nadogradnja sa postojećim podacima | Neizvršeno | Native drill i command doubles nisu zamjena |
| rc3 čista WSL2/Docker instalacija | Neuspješno | Nedostaje ICU dev; nema gotovog image-a ni runtime PASS-a |
| rc4 čista WSL2/Docker instalacija | Neuspješno | PATH/boot/default-page prepreke; zakrpljena varijanta se vodi zasebno |
| rc4 dijagnostička varijanta | Djelimično prošlo | Runtime/podaci provjereni; automatski HTTP upgrade i kalendar imali nedostatke |
| rc5 neizmijenjeni javni tag | Lokalni funkcionalni PASS prema izvještaju; UI djelimično FAIL | Nova WSL2 instalacija/restore i dijagnostički upgrade; bez VPS/cold off-site importa |
| rc6 neizmijenjeni javni tag | Instalacija/upgrade/kalendar/podaci prošli; e-mail FAIL | Puni nezavisni paket; lokalni origin/template/return ruta blokiraju puni funkcionalni PASS |
| rc7 neizmijenjeni javni tag | Lokalni install/upgrade/worker prošli; puni engine i dio admin jezika neuspješni | Kasniji popravljen engine prolaz naveden odvojeno u aktuelnom pregledu |
| rc8 objedinjene ispravke | Nova instalaciona/browser proba čeka rezultat | Direktni javni RC7 → RC8 sa očuvanim podacima i ključevima |
| Novi Linux VPS, javni DNS/TLS/obnova i reboot | Neizvršeno | WSL2 rezultat se ne prenosi u ovaj red |
| Stvarni SMTP/SMS/Viber/AI/naplata | Nije potvrđeno ovom probom | Opcioni sopstveni nalozi i zasebno odobrene provjere |

Ažuriranje postojećeg native servera nije nova instalacija na praznom VPS-u. WSL2 je dovoljan za lokalno Docker prihvatanje kada se koraci stvarno izvrše; za sljedeći krug lokalne probe nije potreban zaseban VPS. Javno serversko prihvatanje ostaje odvojeno.

## Sljedeća nezavisna proba

Slijedite [PROVJERA_WSL2.md](PROVJERA_WSL2.md), [OPORAVAK.md](OPORAVAK.md) i [NADOGRADNJA.md](NADOGRADNJA.md). Sljedeća završna proba poslije objave bira javni **v0.1.4-rc8** i njegov puni SHA (`git rev-parse HEAD`); rc2/rc3 identiteti iznad ostaju istorijski rezultati.

Agent smije nastaviti dijagnostiku i popravljati prepreke u zasebnoj grani. Prvo sačuvati neuspjeh neizmijenjenog taga, pa svaki diff/commit, razlog i rezultate. Cjelovit prolaz sa zakrpama označiti kao prolaz te zakrpljene varijante. Poslije prenosa i objave ispravki treba zasebna čista instalacija novog javnog taga bez zakrpa.

Početni rc1 takođe nema ICU dev. Za dijagnostički upgrade može se pripremiti **patchovani rc1**, sa sačuvanim diff-om, procesom i fotografijom. Installer zahtijeva da cilj bude potomak trenutnog commita: lokalni rc1 patch commit nije predak javnog rc4. Zato u zasebnom checkout-u pripremite pregledan dijagnostički merge koji sadrži patchovani početak i novi javni tag, preuzmite taj commit u instalacioni checkout bez prebacivanja aktivnog koda, pa koristite njegov puni SHA kroz upgrade. Sačuvajte sve identitete i provjerite odnos predak–potomak; ne zaobilazite zaštitu niti prepisujte instalacioni zapis. Taj rezultat pripada dijagnostičkoj merge varijanti, ne direktnom javni-tag → javni-tag prelazu. Takav početak nije izvorni rc1 clean-install PASS. Ako izvorni rc1 ne može da se instalira, dokumentovati blokadu; dvije prazne instalacije ne dokazuju nadogradnju.

U izvještaju navedite stvarne verzije, app/engine SHA, hash lockfile-a, image ID, profil, datum, trajanje i rezultate prije bilo kakve popravke. Ne prenosite PASS između commitova ili okruženja. Ne objavljujte env fajlove, OTP, lozinke, tokene ili lične Windows putanje.
