# Bar-kassa

Kassasysteem voor een bar of vereniging. Draait op een eigen kleine server in het gebouw (bijvoorbeeld een HP t620 thin client); medewerkers rekenen af op hun telefoon of tablet via het wifi-netwerk. Alle apparaten zien dezelfde gegevens.

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

Log in op de t620 (met een toetsenbord en scherm, of via SSH), word root en voer het installatiescript uit:

```sh
su -
apt-get install -y curl
curl -fsSL https://raw.githubusercontent.com/Jlmree/kassa-test/main/server/installeer.sh | bash
```

(Op Ubuntu: `sudo -i` in plaats van `su -`.) De commando's hieronder voer je ook als root uit; met `sudo` ervoor kan ook.

Dit duurt een paar minuten. Aan het eind staat welk adres je op de telefoons moet openen.

### 4. Telefoons en tablets

Om de camera te mogen gebruiken (QR-kaarten scannen) moet de verbinding beveiligd zijn. De kassa maakt daarvoor een eigen certificaat dat elk apparaat **eenmalig** installeert:

1. Open op de telefoon `http://192.168.1.50` (het adres van je t620). Je krijgt een welkomstpagina.
2. Volg de stappen: certificaat downloaden en vertrouwen (iPhone: in Safari; Android: via Instellingen → Beveiliging).
3. Tik op **Naar de kassa** en zet hem op je beginscherm.

**Liever geen certificaat op elke telefoon?** Maak een gratis naam aan op [duckdns.org](https://www.duckdns.org) (bijvoorbeeld `mijnbar.duckdns.org`) en installeer met:

```sh
curl -fsSL https://raw.githubusercontent.com/Jlmree/kassa-test/main/server/installeer.sh | KASSA_DOMEIN=mijnbar.duckdns.org KASSA_DUCKDNS_TOKEN=<jouw token> bash
```

De kassa krijgt dan een echt certificaat en is bereikbaar op `https://mijnbar.duckdns.org`. Alleen vanaf je eigen wifi: de naam wijst naar het interne adres van de t620. (Sommige routers blokkeren dat; zoek dan in de router naar "DNS-rebind-bescherming" en voeg een uitzondering toe voor de naam.)

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
| Back-up terugzetten | `sudo /opt/kassa/bin/terugzetten.sh /var/backups/kassa/<bestand>.dump` |
| Nieuwe versie installeren | `sudo /opt/kassa/bin/bijwerken.sh` (maakt eerst een back-up; je gegevens blijven staan) |
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
- `server/`: installatie- en onderhoudsscripts; `server/pakket.sh` maakt `kassa.tar.gz`. Bij elke push naar `main` publiceert GitHub Actions een release met dat pakket.
- `supabase/migrations/`: het databaseschema met alle functies en rechten. Nieuwe wijzigingen komen in een nieuw bestand; `bijwerken.sh` voert ze één keer uit.
- Databasetests (verwachten een lege database):
  `SUPABASE_URL=https://<server> SUPABASE_ANON_KEY=<sleutel uit /opt/kassa/app/config.js> NODE_EXTRA_CA_CERTS=<certificaat> npm run test:db`
