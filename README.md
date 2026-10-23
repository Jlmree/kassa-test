# Bar-kassa

Kassasysteem voor een bar of vereniging. Draait op een eigen kleine server in het gebouw (bijvoorbeeld een HP t620 thin client); medewerkers rekenen af op hun telefoon of tablet via een eigen wifi-netwerk van de kassa (of de wifi van het gebouw). Er is geen internet nodig om te verkopen. Alle apparaten zien dezelfde gegevens.

**Eerst proberen?** De [proefversie](https://jlmree.github.io/kassa-test/) werkt meteen in je browser, met voorbeeldgegevens (twee weken verkopen, kaarten, rekeningen). Log in als *Demo*, *Anna* of *Kees* met wachtwoord `proef1234`. Wat je daar doet blijft alleen op je eigen apparaat.

## Wat kan het

- **Kassa**: producten aantikken en afrekenen met contant (met wisselgeld), pin, tegoedkaart of een combinatie (kaart + rest contant/pin).
- **Te weinig wisselgeld**: is het wisselgeld meer dan er volgens de kassa in de la zit, dan waarschuwt de kassa. Het wisselgeld kan dan als tegoed op een barkaart (een nieuwe uit de stapel of de kaart van de klant); het hele bedrag gaat in de la en de kas klopt bij het sluiten. De kassa kent alleen het totaal in de la, niet de briefjes en munten: zorg bij het openen voor genoeg klein geld.
- **Betaalmethoden kiezen**: de beheerder zet contant, pin, kaart en op rekening aan of uit (bijv. geen pin in een kantine zonder pinautomaat). Wat uit staat, verdwijnt van de kassa.
- **Rekeningen**: open rekeningen op naam, bijbestellen vanaf elk apparaat, regels schrappen, later afrekenen.
- **Streeplijst per lid**: leden zetten een streep (één tik op hun naam) en betalen later, bijvoorbeeld per maand: contant, pin of overboeking. Per lid wat er openstaat en de geschiedenis; per maand een overzicht met export voor de incasso.
- **Tegoedkaarten**: kaarten met QR-code maken en printen (creditcardformaat, tien per A4), opwaarderen, scannen met de camera van de telefoon, blokkeren bij verlies, tegoed overzetten naar een nieuwe kaart, geschiedenis per kaart.
- **Saldo voor klanten**: een klant scant de QR-code van de eigen kaart met de camera van de eigen telefoon en ziet saldo en de laatste betalingen, zonder account. Alleen bekijken; betalen kan alleen aan de bar. Zonder QR-code: open het adres van de kassa met `/saldo` erachter (bijv. `https://10.42.0.1/saldo`) en typ de code. De telefoon van de klant moet de kassa kunnen bereiken: geef klanten het wachtwoord van de kassa-wifi (zonder account kunnen ze alleen het saldo zien), of gebruik de wifi van het gebouw. Met DuckDNS krijgen klanten geen certificaatmelding.
- **Saldo-zuil**: een oude telefoon of tablet aan de muur (adres van de kassa met `/zuil` erachter, of `?zuil`) waar klanten hun kaart voor houden; ook met een USB-scanner. Na tien seconden staat hij weer klaar. Uitleg met QR-code in *Beheer → Instellingen → Saldo-zuil*.
- **Dienst (kasopmaak)**: kassa openen met wisselgeld, aan het eind tellen per munt/biljet; de kassa rekent uit wat er in de la hoort en laat het verschil zien.
- **Voorraad**: per product bijhouden, levering inboeken, na tellen corrigeren, waarschuwing als iets bijna op is.
- **Rapporten**: per dag, week, maand of zelf gekozen periode; omzet per betaalmethode, product, medewerker, dag en uur; kaarttegoed in omloop; kasverschillen; export naar CSV (Excel).
- **Medewerkers en rechten**: iedereen logt in met een eigen naam en wachtwoord. Een beheerder nodigt nieuwe medewerkers uit met een QR-code (scannen, wachtwoord kiezen, klaar; met de wifi-code erbij) of keurt aanvragen goed, en kan wachtwoorden opnieuw instellen.
- **Logboek**: wie heeft wanneer een bon geannuleerd, een prijs gewijzigd, de kassa gesloten, enzovoort.
- **Automatische back-ups** elk uur, ook naar een USB-stick.

## Beveiliging

- De app mag gegevens alleen **lezen**. Alles wat iets verandert (afrekenen, opwaarderen, annuleren, prijzen) gebeurt in de database zelf, die de rechten controleert en prijzen en saldo's zelf uitrekent.
- Elke betaling is één transactie: twee apparaten kunnen een kaart nooit tegelijk dubbel afschrijven.
- **Kaartcodes** zijn willekeurig (bijv. `K7MQ-3XRP`) en niet te raden. Betalen kan alleen met die code (QR scannen of typen), niet met alleen het kaartnummer. Alleen een beheerder kan kaarten (opnieuw) printen.
- Rollen:
  - **Medewerker**: afrekenen, rekeningen, kaarten opwaarderen en blokkeren, kassa openen/sluiten, eigen bon annuleren binnen 15 minuten, bonnen van vandaag bekijken.
  - **Beheerder**: daarnaast producten, prijzen en voorraad, kaarten maken, alle bonnen annuleren, kaarten deblokkeren, rapporten, logboek en medewerkers.
- De beheerder wordt bij het installeren op de server zelf aangemaakt. Accounts die in de app worden aangemaakt, hebben geen toegang totdat een beheerder ze goedkeurt; zo kan niemand via internet als eerste beheerder worden.
- De database is alleen vanaf de server zelf bereikbaar; telefoons praten uitsluitend via https met de webserver.
- Het eigen wifi-netwerk van de kassa is beveiligd met een wachtwoord (WPA2); alleen wie dat heeft, komt bij de kassa.
- Na 10 verkeerde wachtwoorden in 10 minuten gaat een account 10 minuten op slot (een nieuw wachtwoord van de beheerder haalt het eraf). Op de saldo-pagina zijn na 10 verkeerde codes de codes 10 minuten geblokkeerd.
- Back-ups op de USB-stick zijn versleuteld met een eigen wachtwoord (bij de installatie getoond; later: `/opt/kassa/bin/backup.sh wachtwoord`). Schrijf het op en bewaar het buiten de kantine: zonder dit wachtwoord is een back-up op een andere computer niet terug te zetten.
- *Beheer → Controle* laat per medewerker annuleringen, kasverschillen en contant ontvangen geld zien. Leden kunnen hun eigen streeplijst bekijken (met wie er inschonk), zodat een verkeerd streepje opvalt.
- Zelf doen: geef de beheerder en het Linux-account van de computer sterke wachtwoorden, zet tweestapsverificatie aan op het GitHub-account waar de updates vandaan komen, en gebruik liefst DuckDNS in plaats van een eigen certificaat op elke telefoon.

## Installeren op de HP t620

Een t620 (of een andere oude 64-bit pc) is ruim voldoende: de kassa gebruikt ongeveer 200 MB geheugen en 1 GB schijfruimte.

### 1. Linux installeren

1. Download **Debian 12** ("netinst", amd64) van debian.org en zet het met [balenaEtcher](https://etcher.balena.io) op een USB-stick.
2. Start de t620 en druk op **F9** om van de USB-stick op te starten (F10 opent de BIOS).
3. Installeer Debian. Kies bij *Softwareselectie* alleen **SSH-server** en **Standaard systeemhulpmiddelen** (geen bureaubladomgeving).
4. Zet in de BIOS (F10, meestal onder *Advanced → Power-On Options*) **After Power Loss** op **Power On**, zodat de kassa na een stroomstoring vanzelf weer aangaat.

Ubuntu Server 24.04 werkt ook.

### 2. Wifi voor de telefoons

Kies een van de twee:

**A. Eigen wifi-netwerk van de kassa (aanbevolen).** De t620 is dan zelf het wifi-punt: de telefoons verbinden met het netwerk *Kassa* en de kassa staat altijd op `https://10.42.0.1`. Je hebt de wifi van het gebouw niet nodig, en een router die het adres verandert kan niets stuk maken. Nodig: wifi in de t620 (er zit een M.2-sleuf voor een wifi-kaart in; veel exemplaren hebben er al een) of een USB-wifi-stick die als wifi-punt kan werken ("AP-modus"; bijvoorbeeld een stick met een MediaTek MT7612U- of Ralink RT5370-chip). Zit de t620 met een netwerkkabel aan internet, dan geeft hij dat door aan de telefoons; zonder internet werkt de kassa gewoon. Eén wifi-punt dekt een kantine of barruimte; voor een groot gebouw is B beter.

**B. Wifi van het gebouw of een los wifi-punt.** Sluit de t620 met een kabel aan op de router (of op een los wifi-punt) en geef hem in de router een **vast IP-adres** (zoek naar "DHCP-reservering" of "vast IP"), bijvoorbeeld `192.168.1.50`. Zo vinden de telefoons hem altijd terug.

### 3. Kassa installeren

Alles zit in één installatiebestand: **`kassa-installatie.run`** (ongeveer 25 MB), te vinden bij de [nieuwste release](https://github.com/Jlmree/kassa-test/releases/latest). Log in op de t620 (met toetsenbord en scherm, of via SSH), word root en voer uit:

```sh
su -
wget https://github.com/Jlmree/kassa-test/releases/latest/download/kassa-installatie.run
bash kassa-installatie.run --wifi
```

Met `--wifi` maakt de t620 het netwerk *Kassa* met een bedacht wachtwoord; aan het eind staan de naam, het wachtwoord en een QR-code om te verbinden. Zelf kiezen kan ook: `--wifi-naam "Kantine Kassa" --wifi-wachtwoord geheim123` (minstens 8 tekens). Later nog eens zien: `/opt/kassa/bin/wifi.sh status`. Uitzetten: `--zonder-wifi`. Kies je voor B (wifi van het gebouw), laat `--wifi` dan weg.

(Op Ubuntu: `sudo -i` in plaats van `su -`.) Het bestand kan ook via een USB-stick op de t620 komen; zie de handleiding. De commando's hieronder voer je ook als root uit.

Dit duurt een paar minuten (er is internet nodig voor PostgreSQL en de webserver). Aan het eind staat welk adres je op de telefoons moet openen. Hetzelfde bestand later nog eens starten is veilig: het werkt de kassa bij en je gegevens blijven staan.

### 4. Telefoons en tablets

Om de camera te mogen gebruiken (QR-kaarten scannen) moet de verbinding beveiligd zijn. De kassa maakt daarvoor een eigen certificaat dat elk apparaat **eenmalig** installeert:

1. Verbind de telefoon met de wifi van de kassa (scan de QR-code van de installatie met de camera) en open `http://10.42.0.1`. Bij B open je het vaste adres van de t620, bijvoorbeeld `http://192.168.1.50`. Je krijgt een welkomstpagina.
2. Volg de stappen: certificaat downloaden en vertrouwen (iPhone: in Safari; Android: via Instellingen → Beveiliging).
3. Tik op **Naar de kassa** en zet hem op je beginscherm.

**Liever geen certificaat op elke telefoon?** Maak een gratis naam aan op [duckdns.org](https://www.duckdns.org) (bijvoorbeeld `mijnbar.duckdns.org`) en installeer met:

```sh
bash kassa-installatie.run --duckdns mijnbar.duckdns.org <jouw token>
```

De kassa krijgt dan een echt certificaat en is bereikbaar op `https://mijnbar.duckdns.org`, alleen op de wifi van de kassa (of van het gebouw): de naam wijst naar het interne adres van de t620. Met het eigen wifi-netwerk werkt de naam ook als er even geen internet is. Voor het certificaat heeft de t620 bij het installeren en daarna eens per twee maanden internet nodig (via de kabel). (Bij B blokkeren sommige routers zo'n naam; zoek dan in de router naar "DNS-rebind-bescherming" en voeg een uitzondering toe voor de naam.)

### Kassa ook op het scherm van de t620

Wil je aan de bar ook direct op de t620 afrekenen, met een (aanraak)scherm erop aangesloten? Installeer dan met:

```sh
bash kassa-installatie.run --scherm
```

De t620 start daarna vanzelf op in de kassa, schermvullend en zonder bureaublad; telefoons en tablets blijven gewoon werken. Log één keer in met een USB-toetsenbord, daarna blijft het scherm ingelogd. Onderhoud aan de t620 zelf: **Ctrl+Alt+F2** geeft een gewone inlog. Uitzetten: `bash kassa-installatie.run --zonder-scherm`. Dit werkt op Debian (op Ubuntu is Chromium alleen als snap te krijgen).

### 5. Eerste keer

Aan het eind van de installatie vraagt het script een naam en wachtwoord voor de beheerder; daarmee log je in de app in. (Overgeslagen? Dan later met `/opt/kassa/bin/beheerder.sh`.) Nodig daarna je medewerkers uit bij *Beheer → Medewerkers → Iemand uitnodigen*: ze scannen de QR-code, kiezen een wachtwoord en zijn meteen binnen. (Zelf een account aanvragen en laten goedkeuren kan ook; dat zet je daar uit als je alleen met uitnodigingen wilt werken.) Kies bij *Beheer → Instellingen → Betaalmethoden* welke betaalmethoden jullie gebruiken; zet bijvoorbeeld pin uit als er geen pinautomaat is.

## Dagelijks gebruik

1. **Dienst → Kassa openen** met het wisselgeld in de la.
2. Verkopen via **Kassa**; rekeningen via **Rekeningen**; kaarten opwaarderen via **Kaarten**.
3. Aan het eind: **Dienst → Kassa sluiten en tellen**.

Producten uit de oude kassa overnemen: *Beheer → Producten → Producten overnemen uit de oude kassa* (plak daar een back-up van de oude kassa).

## Onderhoud

| Wat | Hoe |
| --- | --- |
| Back-ups | Elk uur automatisch in `/var/backups/kassa` (14 dagen bewaard). Steek een USB-stick met de naam **KASSA-BACKUP** in de t620, dan gaat er elk uur ook een kopie naartoe (90 dagen bewaard). |
| Beheerder aanmaken, of weer binnenkomen als je het wachtwoord van de enige beheerder kwijt bent | `/opt/kassa/bin/beheerder.sh` |
| Back-up terugzetten | `/opt/kassa/bin/terugzetten.sh /var/backups/kassa/<bestand>.dump`, of van de USB-stick: `terugzetten.sh <stick>/kassa/<bestand>.dump.enc` (vraagt het back-upwachtwoord als de back-up van een andere computer komt) |
| Nieuwe versie installeren | In de app: *Beheer → Instellingen → Bijwerken* (de t620 heeft daarvoor internet nodig). Of op de t620: `/opt/kassa/bin/bijwerken.sh`, of zonder internet `/opt/kassa/bin/bijwerken.sh <pad naar kassa-installatie.run>` vanaf een USB-stick. Er wordt altijd eerst een back-up gemaakt; je gegevens blijven staan. |
| Wifi-naam en wachtwoord (met QR-code) | `/opt/kassa/bin/wifi.sh status`. Ander wachtwoord: `bash kassa-installatie.run --wifi-wachtwoord nieuw-wachtwoord` (daarna opnieuw verbinden op elke telefoon). |
| Status bekijken | `systemctl status kassa-auth kassa-rest caddy postgresql` (met eigen wifi ook `kassa-wifi kassa-wifi-dns`) |
| Logboek van de server | `journalctl -u kassa-auth -u kassa-rest -u caddy --since today` |

Wachtwoord vergeten? Een beheerder stelt een nieuw wachtwoord in bij *Beheer → Medewerkers*.

## Hoe het in elkaar zit

```
telefoon / tablet ──wifi "Kassa" (hostapd, dnsmasq)──https──▶ Caddy (webserver, certificaat)
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
