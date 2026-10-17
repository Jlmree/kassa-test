# Bar-kassa

Kassasysteem voor een bar of vereniging. Werkt op telefoon, tablet en computer, met meerdere apparaten tegelijk op dezelfde gegevens.

## Wat kan het

- **Kassa**: producten aantikken en afrekenen met contant (met wisselgeld), pin, tegoedkaart of een combinatie (kaart + rest contant/pin).
- **Rekeningen**: open rekeningen op naam, bijbestellen vanaf elk apparaat, regels schrappen, later afrekenen.
- **Tegoedkaarten**: kaarten met QR-code maken en printen, opwaarderen, scannen met de camera, blokkeren bij verlies, tegoed overzetten naar een nieuwe kaart, geschiedenis per kaart.
- **Dienst (kasopmaak)**: kassa openen met wisselgeld, aan het eind tellen per munt/biljet; de kassa rekent uit wat er in de la hoort te zitten en laat het verschil zien.
- **Voorraad**: per product bijhouden, levering inboeken, na tellen corrigeren, waarschuwing als iets bijna op is. Verkopen, rekeningen en annuleringen werken de voorraad automatisch bij.
- **Rapporten**: per dag, week, maand of zelf gekozen periode; omzet per betaalmethode, product, medewerker, dag en uur; kaarttegoed in omloop; kasverschillen per dienst; export naar CSV (Excel).
- **Medewerkers en rechten**: iedereen logt in met een eigen account. Een beheerder keurt nieuwe medewerkers goed.
- **Logboek**: wie heeft wanneer een bon geannuleerd, een prijs gewijzigd, de kassa gesloten, enzovoort.
- Installeerbaar als app op het beginscherm.

## Beveiliging

- De app mag gegevens alleen **lezen**. Alles wat iets verandert (afrekenen, opwaarderen, annuleren, prijzen) gebeurt in de database zelf, die de rechten controleert en prijzen en saldo's zelf uitrekent. Een slimme gebruiker kan dus geen eigen prijs of saldo insturen.
- Elke betaling is één transactie: twee apparaten kunnen een kaart nooit tegelijk dubbel afschrijven.
- **Kaartcodes** zijn willekeurig (bijv. `K7MQ-3XRP`) en niet te raden. Betalen kan alleen met die code (QR scannen of typen), niet met alleen het kaartnummer. Medewerkers kunnen de codes niet opvragen; alleen een beheerder kan kaarten (opnieuw) printen.
- Rollen:
  - **Medewerker**: afrekenen, rekeningen, kaarten opwaarderen en blokkeren, kassa openen/sluiten, eigen bon annuleren binnen 15 minuten, bonnen van vandaag bekijken.
  - **Beheerder**: daarnaast producten, prijzen en voorraad, kaarten maken, alle bonnen annuleren, kaarten deblokkeren, rapporten, logboek en medewerkers beheren.
- Het allereerste account wordt beheerder. Alle volgende accounts hebben geen toegang totdat een beheerder ze goedkeurt.

## Installeren (eenmalig, ongeveer 10 minuten)

De gegevens staan in [Supabase](https://supabase.com), een gratis online database. De app zelf staat op GitHub Pages.

1. **Supabase-project maken**
   Maak een gratis account op supabase.com en klik op *New project*. Kies als regio *Frankfurt* (EU) en bewaar het databasewachtwoord.
2. **Database inrichten**
   Open in Supabase de *SQL Editor*, plak de volledige inhoud van [`supabase/migrations/20261017000000_kassa.sql`](supabase/migrations/20261017000000_kassa.sql) en klik op *Run*.
3. **Inloggen instellen**
   Ga naar *Authentication → URL Configuration* en zet de *Site URL* op het adres van de kassa (bijv. `https://jlmree.github.io/kassa-test/`).
   Wil je dat medewerkers zonder bevestigingsmail kunnen inloggen? Zet dan bij *Authentication → Sign In / Providers → Email* de optie *Confirm email* uit.
4. **App koppelen**
   Ga naar *Project Settings → API* (of *Data API*) en kopieer de *Project URL* en de *anon public* sleutel. Vul ze in in [`public/config.js`](public/config.js). Deze sleutel mag openbaar zijn: de beveiliging zit in de database.
5. **Publiceren**
   Zet in GitHub bij *Settings → Pages* de *Source* op **GitHub Actions**. Elke wijziging op `main` wordt daarna automatisch gepubliceerd.
6. **Eerste keer openen**
   Open de kassa en maak een account aan. Dat eerste account wordt beheerder. Laat daarna je medewerkers zelf een account aanmaken en keur ze goed bij *Beheer → Medewerkers*.

## Dagelijks gebruik

1. **Dienst → Kassa openen** met het wisselgeld in de la.
2. Verkopen via **Kassa**; rekeningen via **Rekeningen**; kaarten opwaarderen via **Kaarten**.
3. Aan het eind: **Dienst → Kassa sluiten en tellen**.

Producten uit de oude kassa overnemen: *Beheer → Producten → Producten overnemen uit de oude kassa*.

## Voor ontwikkelaars

- React + TypeScript + Vite, `@supabase/supabase-js`.
- `npm install`, daarna `npm run dev`. Zet je eigen Supabase-gegevens in `public/config.js`.
- `npm run build` maakt de site in `dist/`.
- Databasetests: start een lokale Supabase (`npx supabase start`, de migratie wordt automatisch toegepast) en draai
  `SUPABASE_ANON_KEY=<anon key> npm run test:db`. De tests verwachten een lege database (`npx supabase db reset`).
