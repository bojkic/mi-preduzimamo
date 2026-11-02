# Rezultati i granice instalacionih provjera

Pregled: 2. novembar 2026. Ovaj sažetak zamjenjuje javno povezivanje na privatni `CLEAN_INSTALL_REPORT.md` i istorijski `INSTALACIJA_CLEAN.md`. Sirovi izvještaj, ZIP, lokalne putanje i pristupni podaci nisu dio javne dokumentacije. Za novu instalaciju koristite [LOKALNO.md](LOKALNO.md), a za server [PRODUKCIJA.md](PRODUKCIJA.md).

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

Naredni paket **v0.1.4-rc4** dodaje `libicu-dev` u build i eksplicitni `libicu72` u Debian Bookworm runtime, uz provjeru učitavanja native gem-ova pod runtime korisnikom tokom izgradnje. Ovo je ispravka potvrđenog nedostatka, ne tvrdnja da je nova čista instalacija prošla ili da drugih prepreka nema. [ICU development paket](https://packages.debian.org/bookworm/libicu-dev), [ICU runtime paket](https://packages.debian.org/bookworm/libicu72).

## Matrica prihvatanja

| Obuhvat | Status | Šta rezultat dokazuje |
|---|---|---|
| Originalni v0.1.2 | Neuspješno | Izvorni OTP tok treba ispravku |
| Istorijska patchovana A/B varijanta | Prošlo prema dostavljenom izvještaju | Samo tadašnji lokalno izmijenjeni sklop |
| rc2 ciljani testovi i asset build na Linux domaćinu | Prošlo u navedenom obuhvatu | Kod/render/browser resursi tog para; bez nove Docker instalacije |
| rc2 čista WSL2/Docker instalacija | Neizvršeno | Potrebna nezavisna proba samo iz javnih izvora |
| rc2 Docker backup/restore i nadogradnja sa postojećim podacima | Neizvršeno | Native drill i command doubles nisu zamjena |
| rc3 čista WSL2/Docker instalacija | Neuspješno | Nedostaje ICU dev; nema gotovog image-a ni runtime PASS-a |
| rc4 čista WSL2/Docker instalacija | Neizvršeno | Nova proba nakon ispravke; ne prenositi stare PASS rezultate |
| Novi Linux VPS, javni DNS/TLS/obnova i reboot | Neizvršeno | WSL2 rezultat se ne prenosi u ovaj red |
| Stvarni SMTP/SMS/Viber/AI/naplata | Nije potvrđeno ovom probom | Opcioni sopstveni nalozi i zasebno odobrene provjere |

Ažuriranje postojećeg native servera nije nova instalacija na praznom VPS-u. WSL2 je dovoljan za lokalno Docker prihvatanje kada se koraci stvarno izvrše; za sljedeći krug lokalne probe nije potreban zaseban VPS. Javno serversko prihvatanje ostaje odvojeno.

## Sljedeća nezavisna proba

Slijedite [PROVJERA_WSL2.md](PROVJERA_WSL2.md), [OPORAVAK.md](OPORAVAK.md) i [NADOGRADNJA.md](NADOGRADNJA.md). Sljedeća proba bira javni **v0.1.4-rc4** i njegov puni SHA (`git rev-parse HEAD`); rc2/rc3 identiteti iznad ostaju istorijski rezultati.

Agent smije nastaviti dijagnostiku i popravljati prepreke u zasebnoj grani. Prvo sačuvati neuspjeh neizmijenjenog taga, pa svaki diff/commit, razlog i rezultate. Cjelovit prolaz sa zakrpama označiti kao prolaz te zakrpljene varijante. Poslije prenosa i objave ispravki treba zasebna čista instalacija novog javnog taga bez zakrpa.

Početni rc1 takođe nema ICU dev. Za dijagnostički upgrade može se pripremiti **patchovani rc1**, sa sačuvanim diff-om, procesom i fotografijom. Installer zahtijeva da cilj bude potomak trenutnog commita: lokalni rc1 patch commit nije predak javnog rc4. Zato u zasebnom checkout-u pripremite pregledan dijagnostički merge koji sadrži patchovani početak i novi javni tag, preuzmite taj commit u instalacioni checkout bez prebacivanja aktivnog koda, pa koristite njegov puni SHA kroz upgrade. Sačuvajte sve identitete i provjerite odnos predak–potomak; ne zaobilazite zaštitu niti prepisujte instalacioni zapis. Taj rezultat pripada dijagnostičkoj merge varijanti, ne direktnom javni-tag → javni-tag prelazu. Takav početak nije izvorni rc1 clean-install PASS. Ako izvorni rc1 ne može da se instalira, dokumentovati blokadu; dvije prazne instalacije ne dokazuju nadogradnju.

U izvještaju navedite stvarne verzije, app/engine SHA, hash lockfile-a, image ID, profil, datum, trajanje i rezultate prije bilo kakve popravke. Ne prenosite PASS između commitova ili okruženja. Ne objavljujte env fajlove, OTP, lozinke, tokene ili lične Windows putanje.
