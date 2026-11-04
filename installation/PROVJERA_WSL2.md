# Nezavisna provjera na Windows-u / WSL2

Status: završni postupak za objedinjeni RC9 kandidat. RC7 install/upgrade imaju nezavisni lokalni prolaz, a ranije pregledane engine ispravke svoj generated-host prolaz. Dodatni native RC8 pokušaj otkrio je dva runtime kvara, sada popravljena i ciljano provjerena u RC9 kandidatu. Novi RC9 image, browser i direktni upgrade imaju zasebnu provjeru.

Codex aplikacija na Windows-u može voditi provjeru ako izvršava Linux komande unutar izabrane WSL2 distribucije. Codex CLI u toj distribuciji je alternativni način rada. Repozitorijum držati na Linux filesystem-u distribucije, npr. `~/mi-proba`, a ne u Windows direktorijumu sa prethodnim instalacionim fajlovima.

## Okruženje i porijeklo

Zabilježiti datum, Windows/WSL i Linux verzije, arhitekturu, Docker Engine/Compose verzije, dostupnu memoriju i slobodan prostor. Koristiti novu distribuciju ili dokumentovano prazne resurse za ovu instalaciju. Novi direktorijum sam po sebi nije dokaz čistog okruženja. Sačuvati druge distribucije, aplikacije i Docker resurse.

Prva proba provjerava kandidata. Druga proba poslije objave anonimno preuzima samo javni tag i uputstva. Za obje navesti puni app SHA, engine SHA iz lockfile-a, hash lockfile-a, image identitet i build manifest. Ne kopirati prethodni bundle, bazu, env, adaptere ili lokalne zakrpe. Svaki potreban popravak evidentirati; rezultat prije popravke ostaje neuspješan za prvobitni kandidat.

## Funkcionalni obuhvat

1. Pokrenuti dokumentovani demo installer. Prvo izvršiti osnovni `verify` bez organizacije i demo sadržaja.
2. Izričito pripremiti izmišljenu organizaciju i administratora. Potvrditi prijavu i da sintetički pravni tekstovi imaju jasnu oznaku.
3. Pregledati javni i administratorski interfejs na srpskom latinicom, srpskom ćirilicom, bosanskom i hrvatskom: meni, izbor jezika, dashboard i izbor datuma.
4. Napraviti sintetički proces i provjeriti JPEG, PNG i WebP priloge. Zabilježiti stvarno prikazivanje i preuzimanje, uz ograničenja formata.
5. Provjeriti worker i lokalnu poruku u Mailpit-u. Opcioni telefonski capture je simulacija samo za dozvoljeni testni broj. Provjeriti ispravan, pogrešan, istekao i već potrošen dokaz; stvarni SMS/Viber readiness voditi odvojeno.
6. Provjeriti imenovane i poštanske autorizacije prema ciljanim P0 testovima. Sintetički postojeći pending/granted podaci moraju sačuvati zaštite.
7. Provjeriti stop/start i zamjenu kontejnera, uz poređenje podataka i fotografija. Posebno pokrenuti kontrolisan posao koji je još u toku pri quiet/drain/stop postupku; potvrditi završetak ili bezbjedan povratak bez duplog učinka.
8. Provjeriti zauzete portove, konfliktne shell promjenljive, paralelni poziv, postojeće resurse i prekid instalacije. Nastavak mora očuvati prvobitne tajne i podatke. Druga nezavisna instalacija mora dobiti druge tajne; izvještaj navodi samo rezultat poređenja.

## Granice dokaza i izvještaj

Za svaki korak označiti izvršeno/prošlo, neuspješno, neizvršeno ili neprimjenjivo sa razlogom. Sačuvati redigovane logove, snimke, trajanje i vršno zauzeće. Ne slati `.mi-install`, popunjeni env, demo lozinke, OTP ili privatne logove bez redakcije. Izvještaj ne smije sadržati lične Windows putanje.

WSL2 može potvrditi lokalnu instalaciju, restart/recreate i izolovan backup/restore ako se ti koraci stvarno izvedu. Javni domen/TLS, obnova sertifikata i automatski start nakon restarta zasebnog Linux VPS-a ostaju zasebne provjere. Restart kontejnera nije reboot servera. Za VPS prihvatanje treba stvarni odvojeni VPS i testni domen; Windows/WSL rezultat se ne prepisuje u taj red matrice.

Prilikom probe ne slati stvarne poruke, ne aktivirati plaćene integracije i ne mijenjati Windows/WSL globalna podešavanja, bez korisnikovog posebnog naloga. Ne koristiti `down -v` ili globalni prune kao popravku neuspjele instalacije.

## Nastavak provjere uz popravke

Poslije čuvanja prvobitnog rezultata agent smije praviti ispravke u zasebnoj grani i nastaviti punu funkcionalnu matricu. Za svaku ispravku sačuvati diff/commit, razlog i neuspjeli/ponovljeni rezultat. Ne mijenjati stare tagove, zaobilaziti OTP ili izlagati DB/Redis radi prolaza. Ne mijenjati tuđe resurse ili produkciju. Izvještaj mora razlikovati originalni tag, zakrpljenu varijantu i kasniju čistu probu objavljenog novog taga. Izvorni rc1 takođe je stao na nedostajućem ICU-u; eventualni pripremljeni upgrade početak jasno označiti kao patchovani rc1.

## Završni objedinjeni krug RC9

Posebno otvoriti stvarne native liste prijedloga na desktopu i telefonu, zatim native administrativnu prijavu i povratak na isti filtrirani spisak (jezik, područje, starost, prikaz i pretraga). Pokriti native editor, čuvanje izmjena, faze i uspješno objavljivanje procesa u sva četiri jezika, uključujući URL objašnjenje. To su tokovi dodatnih RC8 nalaza; engine-only prolaz ih nije sve pokrivao.

Završni krug pokreće se nad objavljenim parom svih pregledanih popravki (v0.1.4-rc9). Posebno pokriti novu čistu instalaciju i direktni javni RC7 → RC9 upgrade sa postojećim pending/granted korisnicima, procesom, fotografijama i istim ključevima. Podaci i geografske oblasti ranijih projekata čuvaju se; demo-geography pripada samo novom praznom demo primjeru. Potrebni su dovoljno prostora i pregledani sopstveni resursi; bez globalnog prune-a, gašenja drugih distribucija ili mijenjanja njihovih bezbjednosnih podešavanja.

Stvarni worker mora isporučiti Devise potvrdu nove adrese i originalni lokalni proof link u Mailpit. Link se otvara bez ručnog mijenjanja scheme/host/porta; poslije potvrde normalno se otvara postojeća lokalizovana sljedeća stranica. Provjeriti i svjež worker/eager boot sa uključenim missing-translation režimom. Poslije kontrolisane greške pregledati samo redigovan log: token, adresa i serialized mail args ne smiju se pojaviti; izvršni/retry payload ne smije biti promijenjen radi logovanja.

Provjeriti Publish/Update/Phases i editor na sva četiri jezika, native ARIA oznake i interpolirane nivoe naslova/pozicije resizera. Datumi/kalendar i timezone/DST, OTP negativni/pozitivni, privacy/tenancy, fotografije, posao u toku, persistence/restore i živi guard-ovi ostaju u dokumentovanom obuhvatu. Generated-host launcher koristi javno podržani izbor testova i uputstvo engine docs/VERIFIKACIJA.md, bez privatnih ručnih Gemfile/script izmjena.

Posebno potvrditi da validna BIH verifikacija radi unutar postojećih 24 sata, da istekli/potrošeni dokaz i zaključana autorizacija ostaju odbijeni, te da prijava bez lozinke zadržava 10 minuta. Dodjela bodova nakon potvrde telefona mora biti tačno jednom, bez efekata prije commita ili poslije rollback-a. Poštanski geokoder smije dobiti dešifrovanu sintetičku adresu samo poslije commita, uz obrisane metadata na dodijeljenoj autorizaciji. Za administraciju provjeriti i standardne menije, publish flash, pretragu i logo alt tekst u sva četiri jezika.

Dokumentovani raniji engine generated-host rezultat ima 1.194 testa / 6.787 tvrdnji na tada pregledanom popravljenom izvoru. RC9 dodatno mijenja queue servis i locale tekstove, pa to nije novi puni RC9 rezultat. Sačuvati tačan identitet i uporediti runtime/test/harness sadržaj prije pozivanja na taj dokaz. Ne ponavljati već prolazne kolekcije bez promjene pogođenog koda ili okruženja; novi Docker/browser tokovi i host regresije ostaju zasebne provjere. Razvojni Ruby unit bundle engine-a uključuje opcioni Sidekiq logger preduslov; normalni generated-host bundle nije zamjena za taj unit kontekst.

Priložiti puni redigovani ZIP sa izvještajem, dnevnikom, stvarnim logovima/snimcima/manifestima i svakim eventualnim novim patchom, uz SHA256SUMS. Za svaku stavku zabilježiti izvršeno/prošlo, neuspješno, neizvršeno ili neprimjenjivo sa razlogom. Ovaj lokalni krug ne potvrđuje javni Linux VPS/TLS/reboot/obnovu sertifikata, hladni off-site import/restore/aktivaciju ili stvarne provajdere. Ako se zahtijeva i njihovo konačno prihvatanje, moraju biti dostupni zaseban testni server/domen, backup cilj i sopstveni odobreni nalozi; WSL rezultat se ne prepisuje u te redove.
