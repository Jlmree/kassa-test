# Bar-kassa

Kassasysteem voor een bar of vereniging. Draait op een eigen kleine server in het gebouw (bijvoorbeeld een HP t620 thin client); medewerkers rekenen af op hun telefoon of tablet via het wifi-netwerk. Alle apparaten zien dezelfde gegevens.

**Eerst proberen?** De [proefversie](https://jlmree.github.io/kassa-test/) werkt meteen in je browser, met voorbeeldgegevens (twee weken verkopen, kaarten, rekeningen). Log in als *Demo*, *Anna* of *Kees* met wachtwoord `proef1234`. Wat je daar doet blijft alleen op je eigen apparaat.

## Wat kan het

- **Kassa**: producten aantikken en afrekenen met contant (met wisselgeld), pin, tegoedkaart of een combinatie (kaart + rest contant/pin).
- **Rekeningen**: open rekeningen op naam, bijbestellen vanaf elk apparaat, regels schrappen, later afrekenen.
- **Tegoedkaarten**: kaarten met QR-code maken en printen, opwaarderen, scannen met de camera van de telefoon, blokkeren bij verlies, tegoed overzetten naar een nieuwe kaart, geschiedenis per kaart.
- **Dienst (kasopmaak)**: kassa openen met wisselgeld, aan het eind tellen per munt/biljet; de kassa rekent uit wat er in de la hoort en laat het verschil zien.
- **Voorraad**: per product bijhouden, levering inboeken, na tellen corrigeren, waarschuwing als iets bijna op is.
- **Rapporten**: per dag, week, maand of zelf gekozen periode; omzet per betaalmethode, product, medewerker, dag en uur; kaarttegoed in omloop; kasverschillen; export naar CSV (Excel).
- **Medewerkers en rechten**: iedereen logt in met een eigen naam en wachtwoord; een beheerder keurt nieuwe medewerkers goed en kan wachtwoorden opnieuw instellen.
- **Logboek**: wie heeft wanneer een bon geannuleerd, een prijs gewijzigd, de kassa gesloten, enzovoort.
- **Automatische back-ups** elk uur, ook naar een USB-stick.

## Beveiliging

- De app mag gegevens alleen **lezen**. Alles wat iets verandert (afrekenen, opwaarderen, annuleren, prijzen) gebeurt in de database zelf, die de rechten controleert en prijzen en saldo's zelf uitrekent.
- Elke betaling is één transactie: twee apparaten kunnen een kaart nooit tegelijk dubbel afschrijven.
- **Kaartcodes** zijn willekeurig (bijv. `K7MQ-3XRP`) en niet te raden. Betalen kan alleen met die code (QR scannen of typen), niet met alleen het kaartnummer. Alleen een beheerder kan kaarten (opnieuw) printen.
- Rollen:
  - **Medewerker**: afrekenen, rekeningen, kaarten opwaarderen en blokkeren, kassa openen/sluiten, eigen bon annuleren binnen 15 minuten, bonnen van vandaag bekijken.
  - **Beheerder**: daarnaast producten, prijzen en voorraad, kaarten maken, alle bonnen annuleren, kaarten deblokkeren, rapporten, logboek en medewerkers.
- Het allereerste account wordt beheerder. Alle volgende accounts hebben geen toegang totdat een beheerder ze goedkeurt.
- De database is alleen vanaf de server zelf bereikbaar; telefoons praten uitsluitend via https met de webserver.

## Installeren op de HP t620

Een t620 (of een andere oude 64-bit pc) is ruim voldoende: de kassa gebruikt ongeveer 200 MB geheugen en 1 GB schijfruimte.

### 1. Linux installeren

1. Download **Debian 12** ("netinst", amd64) van debian.org en zet het met [balenaEtcher](https://etcher.balena.io) op een USB-stick.
2. Start de t620 en druk op **F9** om van de USB-stick op te starten (F10 opent de BIOS).
3. Installeer Debian. Kies bij *Softwareselectie* alleen **SSH-server** en **Standaard systeemhulpmiddelen** (geen bureaubladomgeving).
4. Zet in de BIOS (F10, meestal onder *Advanced → Power-On Options*) **After Power Loss** op **Power On**, zodat de kassa na een stroomstoring vanzelf weer aangaat.

Ubuntu Server 24.04 werkt ook.

### 2. Vast adres

Geef de t620 in je router een **vast IP-adres** (zoek naar "DHCP-reservering" of "vast IP"), bijvoorbeeld `192.168.1.50`. Zo vinden de telefoons hem altijd terug.

### 3. Kassa installeren

Alles zit in één installatiebestand: **`kassa-installatie.run`** (ongeveer 25 MB), te vinden bij de [nieuwste release](https://github.com/Jlmree/kassa-test/releases/latest). Log in op de t620 (met toetsenbord en scherm, of via SSH), word root en voer uit:

```sh
su -
wget https://github.com/Jlmree/kassa-test/releases/latest/download/kassa-installatie.run
bash kassa-installatie.run
```

(Op Ubuntu: `sudo -i` in plaats van `su -`.) Het bestand kan ook via een USB-stick op de t620 komen; zie de handleiding. De commando's hieronder voer je ook als root uit.

Dit duurt een paar minuten (er is internet nodig voor PostgreSQL en de webserver). Aan het eind staat welk adres je op de telefoons moet openen. Hetzelfde bestand later nog eens starten is veilig: het werkt de kassa bij en je gegevens blijven staan.

### 4. Telefoons en tablets

Om de camera te mogen gebruiken (QR-kaarten scannen) moet de verbinding beveiligd zijn. De kassa maakt daarvoor een eigen certificaat dat elk apparaat **eenmalig** installeert:

1. Open op de telefoon `http://192.168.1.50` (het adres van je t620). Je krijgt een welkomstpagina.
2. Volg de stappen: certificaat downloaden en vertrouwen (iPhone: in Safari; Android: via Instellingen → Beveiliging).
3. Tik op **Naar de kassa** en zet hem op je beginscherm.

**Liever geen certificaat op elke telefoon?** Maak een gratis naam aan op [duckdns.org](https://www.duckdns.org) (bijvoorbeeld `mijnbar.duckdns.org`) en installeer met:

```sh
bash kassa-installatie.run --duckdns mijnbar.duckdns.org <jouw token>
```

De kassa krijgt dan een echt certificaat en is bereikbaar op `https://mijnbar.duckdns.org`. Alleen vanaf je eigen wifi: de naam wijst naar het interne adres van de t620. (Sommige routers blokkeren dat; zoek dan in de router naar "DNS-rebind-bescherming" en voeg een uitzondering toe voor de naam.)

### Kassa ook op het scherm van de t620

Wil je aan de bar ook direct op de t620 afrekenen, met een (aanraak)scherm erop aangesloten? Installeer dan met:

```sh
bash kassa-installatie.run --scherm
```

De t620 start daarna vanzelf op in de kassa, schermvullend en zonder bureaublad; telefoons en tablets blijven gewoon werken. Log één keer in met een USB-toetsenbord, daarna blijft het scherm ingelogd. Onderhoud aan de t620 zelf: **Ctrl+Alt+F2** geeft een gewone inlog. Uitzetten: `bash kassa-installatie.run --zonder-scherm`. Dit werkt op Debian (op Ubuntu is Chromium alleen als snap te krijgen).

### 5. Eerste keer

Open de kassa en maak een account aan. Dat eerste account wordt beheerder. Laat daarna je medewerkers zelf een account aanmaken en keur ze goed bij *Beheer → Medewerkers*.

## Dagelijks gebruik

1. **Dienst → Kassa openen** met het wisselgeld in de la.
2. Verkopen via **Kassa**; rekeningen via **Rekeningen**; kaarten opwaarderen via **Kaarten**.
3. Aan het eind: **Dienst → Kassa sluiten en tellen**.

Producten uit de oude kassa overnemen: *Beheer → Producten → Producten overnemen uit de oude kassa* (plak daar een back-up van de oude kassa).

## Onderhoud

| Wat | Hoe |
| --- | --- |
| Back-ups | Elk uur automatisch in `/var/backups/kassa` (14 dagen bewaard). Steek een USB-stick met de naam **KASSA-BACKUP** in de t620, dan gaat er elk uur ook een kopie naartoe (90 dagen bewaard). |
| Back-up terugzetten | `/opt/kassa/bin/terugzetten.sh /var/backups/kassa/<bestand>.dump` |
| Nieuwe versie installeren | In de app: *Beheer → Instellingen → Bijwerken* (de t620 heeft daarvoor internet nodig). Of op de t620: `/opt/kassa/bin/bijwerken.sh`, of zonder internet `/opt/kassa/bin/bijwerken.sh <pad naar kassa-installatie.run>` vanaf een USB-stick. Er wordt altijd eerst een back-up gemaakt; je gegevens blijven staan. |
| Status bekijken | `systemctl status kassa-auth kassa-rest caddy postgresql` |
| Logboek van de server | `journalctl -u kassa-auth -u kassa-rest -u caddy --since today` |

Wachtwoord vergeten? Een beheerder stelt een nieuw wachtwoord in bij *Beheer → Medewerkers*.

## Hoe het in elkaar zit

```
telefoon / tablet ──https──▶ Caddy (webserver, certificaat)
                              ├── /           de app (React)
                              ├── /auth/v1/   inloggen (Supabase Auth)
                              └── /rest/v1/   database-API (PostgREST)
                                                  │
                                              PostgreSQL  ← alle regels en berekeningen
```

Alles draait op de t620 zelf, zonder Docker. De app werkt ook met een Supabase-project in de cloud: vul dan het adres en de *anon public* sleutel in `public/config.js` in en voer `supabase/migrations/*.sql` uit in de SQL Editor.

## Voor ontwikkelaars

- React + TypeScript + Vite, `@supabase/supabase-js`. `npm install`, `npm run dev`, `npm run build`.
- `server/`: installatie- en onderhoudsscripts; `server/pakket.sh` maakt het installatiebestand `kassa-installatie.run` (uitpakker + app + databasebestanden + PostgREST + Supabase Auth). Bij elke push naar `main` publiceert GitHub Actions het als release.
- `src/wijzigingen.json`: wat er per versie anders is, in gewone taal (nieuwste bovenaan). Zet bij elke wijziging een punt bovenaan; de app toont het na een update en bij *Bijwerken*, en het gaat mee in de GitHub-release.
- `supabase/migrations/`: het databaseschema met alle functies en rechten. Nieuwe wijzigingen komen in een nieuw bestand; `bijwerken.sh` voert ze één keer uit.
- `npm run test:proef` controleert dat de proefversie op elke weekdag goed wordt klaargezet (draait ook vóór elke publicatie).
- `npm run build:proef` maakt de proefversie (`dist-proef/`): dezelfde app, maar met PostgreSQL in de browser ([PGlite](https://pglite.dev)) in plaats van een server. Het schema, de rechten en alle functies uit `supabase/migrations/` draaien daar ongewijzigd; `src/demo/` bootst het inloggen en de database-API na en vult de voorbeeldgegevens. GitHub Actions publiceert hem bij elke push naar `main` op GitHub Pages (Settings → Pages → Source: *GitHub Actions*).
- Databasetests (verwachten een lege database):
  `SUPABASE_URL=https://<server> SUPABASE_ANON_KEY=<sleutel uit /opt/kassa/app/config.js> NODE_EXTRA_CA_CERTS=<certificaat> npm run test:db`
