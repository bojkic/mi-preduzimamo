# Nezavisna provjera na Windows-u / WSL2

Status: postupak za narednu probu; novi installer još nije potvrđen čistom instalacijom. Konačni javni tag i commitovi unose se kada kandidat bude objavljen. Ne koristiti ovaj dokument kao potvrdu uspjeha.

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
