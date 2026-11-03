# Nadogradnja postojeće instalacije

Status: provjereni su Git/filesystem tok i prekidi uz Docker command doubles; stvarna Docker nadogradnja još traži probu. Prije javnog rada potvrdite postupak na sintetičkoj zajednici i pregledajte napomene izdanja.

## Izbor verzije

U postojećem čistom checkout-u preuzmite tagove, bez ručnog `checkout` ili `git pull` prebacivanja aktivnog koda:

```sh
git fetch --tags origin
git rev-parse <izabrani-tag>^{commit}
./script/mi_install upgrade --revision <puni-app-SHA>
```

Zamijenite oba mjesta stvarnim tagom i punim SHA iz prve komande. Cilj mora biti potomak trenutnog commita i podržavati protokol nadogradnje. Za sopstvene izmjene prvo napravite pregledan merge u svojoj grani; ne gubite ih force checkout-om. Host lockfile određuje tačan engine SHA.

Alat prvo gradi novi image, dok postojeći web i worker rade. Koristi samo commitovani Git sadržaj, bez runtime tajni. Potom pravi zaseban backup starog para i čuva image, bazu, fotografije, Redis i potrebne ključeve. Pri backup-u web/worker se zaustavljaju poslije quiet/drain postupka; ostaju zaustavljeni do migracija i pokretanja novog para.

Novi kod, image i Compose zapis prelaze zajedno. Aplikacioni DB/Rails/JWT ključevi, domen i podešavanja se čuvaju. Izvršavaju se `db:migrate` i `data:migrate`, pa se pokreću servisi i provjerava stvarno učitan image/izvor. Generisani build context se osvježava novim commitom; operativni start ne gradi tiho sliku iz starog konteksta. Sačuvani stari backup se ne briše.

Promjena PostgreSQL glavne verzije/distribucije ili trajnog storage mapiranja zahtijeva zaseban pregledan postupak. Ovaj app/engine upgrade ih odbija prije prekida rada. Ne povezujte novi glavni PostgreSQL image sa starim volumenom na svoju ruku.

## Prekid i greška

```sh
./script/mi_install check
./script/mi_install resume
```

Isti privatni zapis pamti završen build, backup, prelazak Git/config stanja i migracije. Nastavak ne generiše nove tajne. Ako je prekid nastao poslije Git checkout-a, a prije završnog upisa konfiguracije, alat usaglašava samo zabilježeni stari/novi par. Drugi, neočekivani kod ili ručno izmijenjeni env se odbijaju.

Prije cutover-a možete izričito odustati:

```sh
./script/mi_install upgrade-abort
```

Time se pokreće stari par i čuvaju se i djelimične kopije. Poslije započetog cutover-a/migracija nema automatskog rollback-a: promjena koda ne poništava promjenu baze. Pregledajte privatni log i primijenite ispravan forward repair, ili vratite pre-upgrade backup sa starim kodom/image-om u novi izolovani cilj prema [OPORAVAK.md](OPORAVAK.md). Ne pokrećite stari kod nad djelimično migriranom bazom bez posebne provjere.

## Provjera ishoda

Poslije nadogradnje provjerite prijavu, postojeći sadržaj i fotografije, administratorske tokove i kontrolisan worker posao. `/up` i provjera image-a nisu dokaz ispravnosti svake funkcije ili spoljne dostave. Sačuvajte stvarne app/engine SHA, image ID, hash lockfile-a, rezultate i napomene o migracijama. Stare kopije zadržite prema svojoj politici i do provjerenog oporavka.

## Lokalni HTTP poslije zamjene kontejnera

U RC4 dijagnostičkoj probi backend je bio healthy, ali demo gateway je zadržao staru app adresu i vratio502. U novom kandidatu gateway nosi app revision label radi ponovnog stvaranja pri promjeni verzije, a Nginx razrješava promjenljive servisne adrese. Novi installer provjerava i lokalni `/up` kroz operator-facing port, bez praćenja redirect-a ili naslijeđenog HTTP proxy-ja. Produkcioni loopback probe nije provjera javnog TLS-a.

Ako upgrade započinje starijim installer kodom, poslije završetka izvršite `./script/mi_install verify` iz novog checkout-a i pregledajte browser. Raniji javni `./script/mi_install restart` oporavio je opaženi demo502; čuva podatke, ali donosi dodatni prekid. Ne koristite brisanje guard zapisa, ručni checkout aktivnog koda ili `down -v`. Nezavisna rc5 Docker/browser proba opisana je ispod; naredni izmijenjeni kandidat zahtijeva novu provjeru. Lokalni Nginx/DNS test sam nije zamjena.

## Nezavisna rc5 provjera

Prema izvještaju od 3. novembra 2026, nadogradnja patchovanog rc1 na merge sa tree-om tačno jednakim javnom rc5 prošla je za 574 s, a dva dijagnostička marker potomka za 399 s i 371 s. Sadržaj, postojeće pending/granted autorizacije, ključevi, administratorska lozinka i fotografija ostali su očuvani. Gateway je automatski zamijenjen sa ispravnim revision label-om; završni HTTP i browser prošli su bez dodatnog restarta. Privremeni 502 tokom planskog zaustavljanja weba nije trajni post-upgrade kvar.

Docker je svaki put ponovo dodijelio iste IP adrese. Ovo potvrđuje gateway recreation i završni HTTP, ali nije prisilna promjena žive app IP adrese. Takva proba ostaje zasebna, uz već prolazan izolovani native Nginx/DNS test. Patchovani rc1 i marker potomci nisu javna izdanja; ovaj rezultat nije direktni neizmijenjeni javni-tag → javni-tag prelaz. Nova nadogradnja na naredni izmijenjeni kandidat mora se zasebno izvršiti.
