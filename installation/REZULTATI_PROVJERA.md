# Rezultati i granice instalacionih provjera

Pregled: 2. novembar 2026. Ovaj sažetak zamjenjuje javno povezivanje na privatni `CLEAN_INSTALL_REPORT.md` i istorijski `INSTALACIJA_CLEAN.md`. Sirovi izvještaj, ZIP, lokalne putanje i pristupni podaci nisu dio javne dokumentacije. Za novu instalaciju koristite [LOKALNO.md](LOKALNO.md), a za server [PRODUKCIJA.md](PRODUKCIJA.md).

## Istorijska proba

Originalni javni v0.1.2 nije prošao potpuni tok nove organizacije zbog neusklađenog poziva telefonske autorizacije sa Decidim 0.32. Testirani app je `8069eb28b499549a58e3f77515d801382022c34d`, engine `8fb44caaf22ebd8369bfb4d4cf5954f55298ad3d`.

Prema dostavljenom izvještaju, lokalno patchovana A/B varijanta prošla je dvije WSL/Docker probe. Ona uključuje lokalne izmjene i nije isto što i originalni javni tag. B uzorak navodi približno 8 min 38 s i image oko 4.21 GB. Paket od 17 izmijenjenih fajlova, trajanje i veličina opisuju taj eksperiment; nisu obećanje za novi installer. Image ID i lockfile hash te istorijske varijante nisu potvrđeni ovim sažetkom.

## Objavljene ispravke

v0.1.3 je zaseban OTP hotfix: direktna engine ispravka koristi dvoargumentni upstream API. Ciljani javni testovi prošli su 18 testova / 67 provjera. To nije dokaz nove čiste instalacije i ovaj tag nema novi installer.

Instalacioni kandidat je **v0.1.4-rc2**:

| Identitet | Vrijednost |
|---|---|
| App | `148bd79181c797def4a15f5dd24a8570870e9131` |
| Engine | `c0c024553bdc99132191cfa484bd19a29d442301` |
| SHA-256 Gemfile.lock | `6aa8d2b149931dfcc853747b8f366121842e63f8ea573eb44d7211fa0035bf48` |
| Docker image ID | Nije izgrađen/potvrđen u čistoj Docker probi |
| Datum lokalnih provjera | 2. novembar 2026. |

Na tačnom javnom rc2 paru prošli su 18 request testova / 337 provjera, inventar 16 administratorskih ruta (1 test / 20 provjera), 9 browser testova / 99 provjera i produkcioni asset build. Browser je koristio stvarno izgrađene resurse. Upozorenja o veličini paketa i granici service-worker precache-a ostaju dokumentovana; novi image i čista instalacija nisu time potvrđeni.

## Matrica prihvatanja

| Obuhvat | Status | Šta rezultat dokazuje |
|---|---|---|
| Originalni v0.1.2 | Neuspješno | Izvorni OTP tok treba ispravku |
| Istorijska patchovana A/B varijanta | Prošlo prema dostavljenom izvještaju | Samo tadašnji lokalno izmijenjeni sklop |
| rc2 ciljani testovi i asset build na Linux domaćinu | Prošlo u navedenom obuhvatu | Kod/render/browser resursi tog para; bez nove Docker instalacije |
| rc2 čista WSL2/Docker instalacija | Neizvršeno | Potrebna nezavisna proba samo iz javnih izvora |
| rc2 Docker backup/restore i nadogradnja sa postojećim podacima | Neizvršeno | Native drill i command doubles nisu zamjena |
| Novi Linux VPS, javni DNS/TLS/obnova i reboot | Neizvršeno | WSL2 rezultat se ne prenosi u ovaj red |
| Stvarni SMTP/SMS/Viber/AI/naplata | Nije potvrđeno ovom probom | Opcioni sopstveni nalozi i zasebno odobrene provjere |

Ažuriranje postojećeg native servera nije nova instalacija na praznom VPS-u. WSL2 je dovoljan za lokalno Docker prihvatanje kada se koraci stvarno izvrše; za sljedeći krug lokalne probe nije potreban zaseban VPS. Javno serversko prihvatanje ostaje odvojeno.

## Sljedeća nezavisna proba

Slijedite [PROVJERA_WSL2.md](PROVJERA_WSL2.md), [OPORAVAK.md](OPORAVAK.md) i [NADOGRADNJA.md](NADOGRADNJA.md). Testirajte anonimno preuzet javni rc2 tag; dokumentacione dopune na main grani ne mijenjaju njegov kod. Za nadogradnju koristite zasebnu sintetičku rc1 instalaciju sa sadržajem i fotografijom, pa dokumentovani upgrade na puni rc2 app SHA.

U izvještaju navedite stvarne verzije, app/engine SHA, hash lockfile-a, image ID, profil, datum, trajanje i rezultate prije bilo kakve popravke. Ne prenosite PASS između commitova ili okruženja. Ne objavljujte env fajlove, OTP, lozinke, tokene ili lične Windows putanje.
