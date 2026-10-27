import { rpc } from './lib';
import { maakXlsx, type Blad, type Cel } from './xlsx';

// Boekhouding als Excel-bestand (Beheer → Rapport → Boekhouding): alles van een periode,
// per kalenderdag. Bedragen komen in centen van de server en gaan als euro's het bestand in.

interface Bon {
  bon: number; ts: string; dienst: string | null; medewerker: string | null; rekening: string | null; totaal: number;
  contant: number; pin: number; kaart: number; lat: number; gratis: number;
  kaarten: string | null; lid: string | null; reden: string | null;
  geannuleerd: boolean; geannuleerd_ts: string | null; geannuleerd_door: string | null;
}
interface Regel { bon: number; ts: string; product: string; categorie: string; aantal: number; prijs: number; geannuleerd: boolean }
interface DienstCijfers {
  id: number; geopend_ts: string; gesloten_ts: string | null; geopend_door: string | null; gesloten_door: string | null;
  beginsaldo_cent: number; omzet_cent: number; bonnen: number; contant_cent: number; pin_cent: number; kaart_cent: number;
  lat_cent: number; gratis_cent: number; uitgaven_cent: number; afbetaald_contant_cent: number; afbetaald_pin_cent: number;
  opwaardering_contant_cent: number; opwaardering_pin_cent: number; verwacht_cent: number; geteld_cent: number | null; opmerking: string | null;
}
interface KaartMutatie { ts: string; kaart: number; naam: string | null; soort: string; methode: string | null; bedrag: number; bon: number | null }
interface Lid { lid: string; begin: number; gestreept: number; contant: number; pin: number; overboeking: number }
interface Afbetaling { ts: string; lid: string; methode: string; bedrag: number; opmerking: string | null }
interface Uitgave { ts: string; omschrijving: string; bedrag: number; voorgeschoten_door: string | null; door_naam: string | null; terugbetaald_ts: string | null; terugbetaald_hoe: string | null; terug_door_naam: string | null }
interface Terug { ts: string; omschrijving: string; bedrag: number; voorgeschoten_door: string | null; terugbetaald_hoe: string }
interface Data {
  kassa: string; van: string; tot: string; gemaakt: string;
  bonnen: Bon[]; regels: Regel[]; diensten: DienstCijfers[]; kaart: KaartMutatie[]; kaart_begin: number; kaart_eind: number;
  streeplijst: Lid[]; afbetalingen: Afbetaling[]; uitgaven: Uitgave[]; terugbetaald: Terug[]; voorgeschoten_open: number;
}

const som = <T>(l: T[], f: (x: T) => number) => l.reduce((a, x) => a + f(x), 0);
const dag = (ts: string) => ts.slice(0, 10);
const weekdag = (d: string) => ['zondag', 'maandag', 'dinsdag', 'woensdag', 'donderdag', 'vrijdag', 'zaterdag'][new Date(d + 'T12:00:00').getDay()];
const soortNaam: Record<string, string> = { opwaardering: 'Opgewaardeerd', betaling: 'Betaald', annulering: 'Teruggezet (annulering)', overzetting: 'Overgezet', vervallen: 'Vervallen', prijs: 'Gewonnen (loterij)' };
const methode: Record<string, string> = { contant: 'Contant', pin: 'Pin', overboeking: 'Overboeking' };
const kop = (t: string): Cel[] => [{ v: t, vet: true }];
const g = (centen: number): Cel => ({ v: centen, soort: 'geld' });
const n = (x: number): Cel => ({ v: x, soort: 'getal' });

export async function boekhoudingMaken(van: string, tot: string): Promise<{ naam: string; blob: Blob }> {
  const d = await rpc<Data>('boekhouding', { p_van: van, p_tot: tot });
  const ok = d.bonnen.filter((b) => !b.geannuleerd);
  const weg = d.bonnen.filter((b) => b.geannuleerd);
  const okRegels = d.regels.filter((r) => !r.geannuleerd);
  const km = (s: string, m?: string) => som(d.kaart.filter((x) => x.soort === s && (!m || x.methode === m)), (x) => x.bedrag);
  const af = (m: string) => som(d.afbetalingen.filter((x) => x.methode === m), (x) => x.bedrag);
  const kasUit = som(d.uitgaven.filter((u) => !u.voorgeschoten_door), (u) => u.bedrag) + som(d.terugbetaald.filter((t) => t.terugbetaald_hoe === 'kas'), (t) => t.bedrag);
  const gesloten = d.diensten.filter((x) => x.gesloten_ts && x.geteld_cent !== null);
  const verkocht = som(ok, (b) => b.totaal), gratis = som(ok, (b) => b.gratis);
  const streepBegin = som(d.streeplijst, (x) => x.begin), gestreept = som(d.streeplijst, (x) => x.gestreept);

  // ── Samenvatting ──
  const s: Cel[][] = [
    kop('Periode'),
    ['Kassa', d.kassa],
    ['Van', { v: d.van, soort: 'datum' }],
    ['Tot en met', { v: d.tot, soort: 'datum' }],
    ['Gemaakt op', { v: d.gemaakt, soort: 'datumtijd' }],
    ['Indeling', 'Per kalenderdag, 00:00–24:00'],
    ['Dienst die na middernacht doorloopt', 'Eén regel in Kasopmaak'],
    [],
    kop('Verkoop'),
    ['Bonnen', n(ok.length)],
    ['Verkocht (waarde van alles over de bar)', g(verkocht)],
    ['waarvan gratis weggegeven', g(gratis)],
    ['Omzet (betaald of op de streeplijst)', g(verkocht - gratis)],
    ['Geannuleerde bonnen (aantal)', n(weg.length)],
    ['Geannuleerde bonnen (bedrag, niet in de omzet)', g(som(weg, (b) => b.totaal))],
    [],
    kop('Omzet per betaalmethode'),
    ['Contant', g(som(ok, (b) => b.contant))],
    ['Pin', g(som(ok, (b) => b.pin))],
    ['Barkaart (vooraf betaald tegoed)', g(som(ok, (b) => b.kaart))],
    ['Streeplijst (later te betalen)', g(som(ok, (b) => b.lat))],
    [],
    kop('Geld ontvangen'),
    ['Contant: verkopen', g(som(ok, (b) => b.contant))],
    ['Contant: barkaarten opgewaardeerd', g(km('opwaardering', 'contant'))],
    ['Contant: streeplijst afbetaald', g(af('contant'))],
    ['Pin: verkopen', g(som(ok, (b) => b.pin))],
    ['Pin: barkaarten opgewaardeerd', g(km('opwaardering', 'pin'))],
    ['Pin: streeplijst afbetaald', g(af('pin'))],
    ['Pin totaal (vergelijk met het pinapparaat)', { v: som(ok, (b) => b.pin) + km('opwaardering', 'pin') + af('pin'), soort: 'geld', vet: true }],
    ['Overboeking: streeplijst afbetaald', g(af('overboeking'))],
    [],
    kop('Kas'),
    ['Uitgaven betaald uit de kas', g(kasUit)],
    ['Diensten geteld', n(gesloten.length)],
    ['Kasverschil (geteld min verwacht)', g(som(gesloten, (x) => (x.geteld_cent ?? 0) - x.verwacht_cent))],
    [],
    kop('Barkaarten (tegoed van kaarthouders)'),
    ['Tegoed aan het begin', g(d.kaart_begin)],
    ['+ opgewaardeerd', g(km('opwaardering'))],
    ['− betaald met de kaart', g(km('betaling'))],
    ['+ teruggezet (geannuleerde bonnen)', g(km('annulering'))],
    ['− vervallen (kaarten verwijderd)', g(km('vervallen'))],
    ['+ gewonnen met de loterij', g(km('prijs'))],
    ['± overgezet naar andere kaarten', g(km('overzetting'))],
    ['Tegoed aan het eind', { v: d.kaart_eind, soort: 'geld', vet: true }],
    [],
    kop('Streeplijst (nog te betalen door leden)'),
    ['Open aan het begin', g(streepBegin)],
    ['+ gestreept', g(gestreept)],
    ['− afbetaald', g(-(af('contant') + af('pin') + af('overboeking')))],
    ['Open aan het eind', { v: streepBegin + gestreept - af('contant') - af('pin') - af('overboeking'), soort: 'geld', vet: true }],
    [],
    kop('Uitgaven'),
    ['Geregistreerd in de periode', g(som(d.uitgaven, (u) => u.bedrag))],
    ['waarvan uit de kas', g(som(d.uitgaven.filter((u) => !u.voorgeschoten_door), (u) => u.bedrag))],
    ['waarvan voorgeschoten', g(som(d.uitgaven.filter((u) => u.voorgeschoten_door), (u) => u.bedrag))],
    ['Voorgeschoten, aan het eind nog terug te betalen', g(d.voorgeschoten_open)],
  ];
  const bladen: Blad[] = [{ naam: 'Samenvatting', kolommen: [{ kop: 'Onderdeel', breedte: 52 }, { kop: 'Bedrag', breedte: 22 }], rijen: s, filter: false }];

  // ── Per dag ──
  const dagen = [...new Set([...d.bonnen.map((b) => dag(b.ts)), ...d.kaart.map((k) => dag(k.ts)), ...d.afbetalingen.map((a) => dag(a.ts)), ...d.uitgaven.map((u) => dag(u.ts))])].sort();
  const perDag = dagen.map((x) => {
    const b = ok.filter((y) => dag(y.ts) === x);
    const k = (m: string) => som(d.kaart.filter((y) => y.soort === 'opwaardering' && y.methode === m && dag(y.ts) === x), (y) => y.bedrag);
    return [{ v: x, soort: 'datum' } as Cel, weekdag(x), n(b.length), g(som(b, (y) => y.totaal) - som(b, (y) => y.gratis)),
      g(som(b, (y) => y.contant)), g(som(b, (y) => y.pin)), g(som(b, (y) => y.kaart)), g(som(b, (y) => y.lat)), g(som(b, (y) => y.gratis)),
      g(som(weg.filter((y) => dag(y.ts) === x), (y) => y.totaal)), g(k('contant')), g(k('pin')),
      g(som(d.afbetalingen.filter((y) => dag(y.ts) === x), (y) => y.bedrag)), g(som(d.uitgaven.filter((y) => dag(y.ts) === x), (y) => y.bedrag))];
  });
  const kolomSom = (rijen: Cel[][], i: number) => som(rijen, (r) => { const c = r[i]; return typeof c === 'object' && c && typeof c.v === 'number' ? c.v : typeof c === 'number' ? c : 0; });
  const totaalRij = (rijen: Cel[][], soorten: ('geld' | 'getal' | null)[], label = 'Totaal'): Cel[] =>
    soorten.map((s, i) => (i === 0 ? label : s === 'geld' ? g(kolomSom(rijen, i)) : s === 'getal' ? n(kolomSom(rijen, i)) : null));
  bladen.push({
    naam: 'Per dag', rijen: perDag,
    kolommen: [{ kop: 'Datum', soort: 'datum', breedte: 12 }, { kop: 'Dag', breedte: 11 }, { kop: 'Bonnen', soort: 'getal' }, { kop: 'Omzet', soort: 'geld', breedte: 13 },
      { kop: 'Contant', soort: 'geld', breedte: 13 }, { kop: 'Pin', soort: 'geld', breedte: 13 }, { kop: 'Barkaart', soort: 'geld', breedte: 13 }, { kop: 'Streeplijst', soort: 'geld', breedte: 13 },
      { kop: 'Gratis', soort: 'geld', breedte: 12 }, { kop: 'Geannuleerd', soort: 'geld', breedte: 13 }, { kop: 'Opgewaardeerd contant', soort: 'geld', breedte: 14 },
      { kop: 'Opgewaardeerd pin', soort: 'geld', breedte: 14 }, { kop: 'Streeplijst afbetaald', soort: 'geld', breedte: 14 }, { kop: 'Uitgaven', soort: 'geld', breedte: 12 }],
    totaal: totaalRij(perDag, [null, null, 'getal', 'geld', 'geld', 'geld', 'geld', 'geld', 'geld', 'geld', 'geld', 'geld', 'geld', 'geld']),
  });

  // ── Bonnen ──
  const bonRijen: Cel[][] = d.bonnen.map((b) => [n(b.bon), { v: b.ts, soort: 'datum' }, { v: b.ts, soort: 'tijd' }, { v: b.dienst, soort: 'datumtijd' },
    b.medewerker, b.rekening, g(b.totaal), g(b.contant), g(b.pin), g(b.kaart), b.kaarten, g(b.lat), b.lid, g(b.gratis), b.reden,
    b.geannuleerd ? 'ja' : '', { v: b.geannuleerd_ts, soort: 'datumtijd' }, b.geannuleerd_door]);
  const okRijen = bonRijen.filter((_, i) => !d.bonnen[i].geannuleerd);
  bladen.push({
    naam: 'Bonnen', rijen: bonRijen,
    kolommen: [{ kop: 'Bon', soort: 'getal', breedte: 8 }, { kop: 'Datum', soort: 'datum', breedte: 12 }, { kop: 'Tijd', soort: 'tijd', breedte: 7 },
      { kop: 'Dienst (geopend op)', soort: 'datumtijd', breedte: 17 }, { kop: 'Medewerker', breedte: 16 }, { kop: 'Rekening', breedte: 14 },
      { kop: 'Totaal', soort: 'geld', breedte: 12 }, { kop: 'Contant', soort: 'geld', breedte: 12 }, { kop: 'Pin', soort: 'geld', breedte: 12 },
      { kop: 'Barkaart', soort: 'geld', breedte: 12 }, { kop: 'Kaartnummer', breedte: 12 }, { kop: 'Streeplijst', soort: 'geld', breedte: 12 },
      { kop: 'Lid', breedte: 16 }, { kop: 'Gratis', soort: 'geld', breedte: 11 }, { kop: 'Reden gratis', breedte: 14 }, { kop: 'Geannuleerd', breedte: 11 },
      { kop: 'Geannuleerd op', soort: 'datumtijd', breedte: 17 }, { kop: 'Geannuleerd door', breedte: 16 }],
    totaal: [`Totaal (${okRijen.length} bonnen, zonder geannuleerd)`, null, null, null, null, null, g(kolomSom(okRijen, 6)), g(kolomSom(okRijen, 7)), g(kolomSom(okRijen, 8)),
      g(kolomSom(okRijen, 9)), null, g(kolomSom(okRijen, 11)), null, g(kolomSom(okRijen, 13))],
  });

  // ── Bonregels ──
  bladen.push({
    naam: 'Bonregels',
    rijen: d.regels.map((r) => [n(r.bon), { v: r.ts, soort: 'datum' }, { v: r.ts, soort: 'tijd' }, r.product, r.categorie, n(r.aantal), g(r.prijs), g(r.prijs * r.aantal), r.geannuleerd ? 'ja' : '']),
    kolommen: [{ kop: 'Bon', soort: 'getal', breedte: 8 }, { kop: 'Datum', soort: 'datum', breedte: 12 }, { kop: 'Tijd', soort: 'tijd', breedte: 7 }, { kop: 'Product', breedte: 24 },
      { kop: 'Categorie', breedte: 14 }, { kop: 'Aantal', soort: 'getal', breedte: 8 }, { kop: 'Prijs', soort: 'geld', breedte: 11 }, { kop: 'Bedrag', soort: 'geld', breedte: 12 }, { kop: 'Geannuleerd', breedte: 11 }],
    totaal: ['Totaal (zonder geannuleerd)', null, null, null, null, n(som(okRegels, (r) => r.aantal)), null, g(som(okRegels, (r) => r.prijs * r.aantal))],
  });

  // ── Producten ──
  const perProduct = new Map<string, { categorie: string; product: string; aantal: number; bedrag: number }>();
  for (const r of okRegels) {
    const k = `${r.categorie}\u0000${r.product}`;
    const x = perProduct.get(k) ?? { categorie: r.categorie, product: r.product, aantal: 0, bedrag: 0 };
    x.aantal += r.aantal; x.bedrag += r.prijs * r.aantal; perProduct.set(k, x);
  }
  const prod = [...perProduct.values()].sort((a, b) => a.categorie.localeCompare(b.categorie) || b.bedrag - a.bedrag);
  bladen.push({
    naam: 'Producten',
    rijen: prod.map((p) => [p.categorie, p.product, n(p.aantal), g(p.bedrag), g(p.aantal ? Math.round(p.bedrag / p.aantal) : 0)]),
    kolommen: [{ kop: 'Categorie', breedte: 16 }, { kop: 'Product', breedte: 26 }, { kop: 'Aantal', soort: 'getal', breedte: 9 }, { kop: 'Waarde', soort: 'geld', breedte: 13 }, { kop: 'Gemiddelde prijs', soort: 'geld', breedte: 15 }],
    totaal: ['Totaal', null, n(som(prod, (p) => p.aantal)), g(som(prod, (p) => p.bedrag))],
  });

  // ── Kasopmaak per dienst ──
  const dienstRijen: Cel[][] = d.diensten.map((x) => [n(x.id), { v: x.geopend_ts, soort: 'datumtijd' }, x.geopend_door, { v: x.gesloten_ts, soort: 'datumtijd' }, x.gesloten_door,
    g(x.beginsaldo_cent), n(x.bonnen), g(x.omzet_cent), g(x.contant_cent), g(x.pin_cent), g(x.kaart_cent), g(x.lat_cent), g(x.gratis_cent),
    g(x.opwaardering_contant_cent), g(x.opwaardering_pin_cent), g(x.afbetaald_contant_cent), g(x.afbetaald_pin_cent), g(x.uitgaven_cent),
    g(x.verwacht_cent), x.geteld_cent === null ? null : g(x.geteld_cent), x.geteld_cent === null ? null : g(x.geteld_cent - x.verwacht_cent), x.opmerking]);
  bladen.push({
    naam: 'Kasopmaak', rijen: dienstRijen,
    kolommen: [{ kop: 'Dienst', soort: 'getal', breedte: 8 }, { kop: 'Geopend', soort: 'datumtijd', breedte: 17 }, { kop: 'Geopend door', breedte: 15 }, { kop: 'Gesloten', soort: 'datumtijd', breedte: 17 },
      { kop: 'Gesloten door', breedte: 15 }, { kop: 'Beginsaldo', soort: 'geld', breedte: 12 }, { kop: 'Bonnen', soort: 'getal', breedte: 8 }, { kop: 'Verkocht', soort: 'geld', breedte: 12 },
      { kop: 'Contant', soort: 'geld', breedte: 12 }, { kop: 'Pin', soort: 'geld', breedte: 12 }, { kop: 'Barkaart', soort: 'geld', breedte: 12 }, { kop: 'Streeplijst', soort: 'geld', breedte: 12 },
      { kop: 'Gratis', soort: 'geld', breedte: 11 }, { kop: 'Opgewaardeerd contant', soort: 'geld', breedte: 14 }, { kop: 'Opgewaardeerd pin', soort: 'geld', breedte: 14 },
      { kop: 'Afbetaald contant', soort: 'geld', breedte: 14 }, { kop: 'Afbetaald pin', soort: 'geld', breedte: 13 }, { kop: 'Uitgaven uit kas', soort: 'geld', breedte: 13 },
      { kop: 'Verwacht in de la', soort: 'geld', breedte: 14 }, { kop: 'Geteld', soort: 'geld', breedte: 12 }, { kop: 'Verschil', soort: 'geld', breedte: 11 }, { kop: 'Opmerking', breedte: 30 }],
    totaal: totaalRij(dienstRijen, [null, null, null, null, null, null, 'getal', 'geld', 'geld', 'geld', 'geld', 'geld', 'geld', 'geld', 'geld', 'geld', 'geld', 'geld', null, null, 'geld', null]),
  });

  // ── Barkaarten ──
  bladen.push({
    naam: 'Barkaarten',
    rijen: d.kaart.map((k) => [{ v: k.ts, soort: 'datum' }, { v: k.ts, soort: 'tijd' }, n(k.kaart), k.naam, soortNaam[k.soort] ?? k.soort, k.methode ? methode[k.methode] ?? k.methode : null, g(k.bedrag), k.bon === null ? null : n(k.bon)]),
    kolommen: [{ kop: 'Datum', soort: 'datum', breedte: 12 }, { kop: 'Tijd', soort: 'tijd', breedte: 7 }, { kop: 'Kaart', soort: 'getal', breedte: 8 }, { kop: 'Naam op de kaart', breedte: 18 },
      { kop: 'Soort', breedte: 22 }, { kop: 'Betaald met', breedte: 12 }, { kop: 'Bedrag', soort: 'geld', breedte: 12 }, { kop: 'Bon', soort: 'getal', breedte: 8 }],
    totaal: ['Verandering van het tegoed', null, null, null, null, null, g(som(d.kaart, (k) => k.bedrag))],
  });

  // ── Streeplijst ──
  bladen.push({
    naam: 'Streeplijst',
    rijen: d.streeplijst.map((l) => [l.lid, g(l.begin), g(l.gestreept), g(l.contant), g(l.pin), g(l.overboeking), g(l.begin + l.gestreept - l.contant - l.pin - l.overboeking)]),
    kolommen: [{ kop: 'Lid', breedte: 22 }, { kop: 'Open aan het begin', soort: 'geld', breedte: 15 }, { kop: 'Gestreept', soort: 'geld', breedte: 12 }, { kop: 'Afbetaald contant', soort: 'geld', breedte: 14 },
      { kop: 'Afbetaald pin', soort: 'geld', breedte: 13 }, { kop: 'Afbetaald overboeking', soort: 'geld', breedte: 16 }, { kop: 'Open aan het eind', soort: 'geld', breedte: 15 }],
    totaal: ['Totaal', g(som(d.streeplijst, (l) => l.begin)), g(gestreept), g(af('contant')), g(af('pin')), g(af('overboeking')),
      g(som(d.streeplijst, (l) => l.begin + l.gestreept - l.contant - l.pin - l.overboeking))],
  });
  bladen.push({
    naam: 'Streeplijst afbetaald',
    rijen: d.afbetalingen.map((a) => [{ v: a.ts, soort: 'datum' }, { v: a.ts, soort: 'tijd' }, a.lid, methode[a.methode] ?? a.methode, g(a.bedrag), a.opmerking]),
    kolommen: [{ kop: 'Datum', soort: 'datum', breedte: 12 }, { kop: 'Tijd', soort: 'tijd', breedte: 7 }, { kop: 'Lid', breedte: 22 }, { kop: 'Hoe', breedte: 13 }, { kop: 'Bedrag', soort: 'geld', breedte: 12 }, { kop: 'Opmerking', breedte: 30 }],
    totaal: ['Totaal', null, null, null, g(som(d.afbetalingen, (a) => a.bedrag))],
  });

  // ── Uitgaven ──
  bladen.push({
    naam: 'Uitgaven',
    rijen: d.uitgaven.map((u) => [{ v: u.ts, soort: 'datum' }, { v: u.ts, soort: 'tijd' }, u.omschrijving, g(u.bedrag), u.voorgeschoten_door ? `Voorgeschoten door ${u.voorgeschoten_door}` : 'De kas',
      u.door_naam, { v: u.terugbetaald_ts, soort: 'datum' }, u.terugbetaald_hoe === 'kas' ? 'Uit de kas' : u.terugbetaald_hoe === 'overboeking' ? 'Overgemaakt' : null, u.terug_door_naam]),
    kolommen: [{ kop: 'Datum', soort: 'datum', breedte: 12 }, { kop: 'Tijd', soort: 'tijd', breedte: 7 }, { kop: 'Omschrijving', breedte: 24 }, { kop: 'Bedrag', soort: 'geld', breedte: 12 },
      { kop: 'Betaald uit', breedte: 26 }, { kop: 'Geregistreerd door', breedte: 17 }, { kop: 'Terugbetaald op', soort: 'datum', breedte: 14 }, { kop: 'Terugbetaald', breedte: 13 }, { kop: 'Terugbetaald door', breedte: 17 }],
    totaal: ['Totaal', null, null, g(som(d.uitgaven, (u) => u.bedrag))],
  });

  const veilig = (t: string) => t.normalize('NFD').replace(/[\u0300-\u036f]/g, '').replace(/[^A-Za-z0-9]+/g, '-').replace(/^-|-$/g, '').toLowerCase() || 'kassa';
  return { naam: `boekhouding-${veilig(d.kassa)}-${d.van}-tot-${d.tot}.xlsx`, blob: maakXlsx(bladen) };
}
