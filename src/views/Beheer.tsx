import { useCallback, useEffect, useState } from 'react';
import { useData, type Methoden } from '../data';
import { centTekst, csvRij, datum, datumTijd, downloaden, eur, lees, methodeNaam, naarCent, PROEF, rpc, sb, tijd, type Dienst, type Product, type Profiel, type Rol, zuilLink } from '../lib';
import { melding, Qr, QrKaart, Rij, useBezig, useSheet } from '../ui';
import { DienstKaarten, Verdeling, Verschil } from './Dienst';
import { StreeplijstMaand } from './Streeplijst';
import { Controle } from './Controle';
import { Uitnodigen } from './Uitnodigen';
import { KaartScherm } from './Kaarten';
import { nieuwer as nogNietBekend, WijzigingLijst, wijzigingen, type Wijziging } from '../wijzigingen';

const delen = ['Rapport', 'Producten', 'Kaarten', 'Streeplijst', 'Medewerkers', 'Controle', 'Logboek', 'Instellingen'] as const;
type Deel = (typeof delen)[number];
const uitleg: Record<Deel, string> = {
  Rapport: 'Omzet, betaalmethoden, producten en kasverschillen per periode',
  Producten: 'Prijzen, categorieën en voorraad',
  Kaarten: 'Nieuwe tegoedkaarten maken en QR-codes printen',
  Streeplijst: 'Per maand wat ieder lid heeft gestreept, en exporteren voor de incasso',
  Medewerkers: 'Toegang geven, rollen en wachtwoorden',
  Controle: 'Annuleringen, kasverschillen en contant geld per medewerker',
  Logboek: 'Wie heeft wat gedaan',
  Instellingen: 'Naam op de bon, betaalmethoden, bijwerken en wat er nieuw is',
};

export function Beheer() {
  const [deel, setDeel] = useState<Deel | null>(null);
  const { producten, methoden } = useData();
  const [wacht, setWacht] = useState(0);
  const laag = producten.filter((p) => p.actief && p.voorraad <= p.voorraad_min);
  const op = laag.filter((p) => p.voorraad <= 0).length;
  useEffect(() => {
    if (deel) return;
    void lees(sb.from('profielen').select('rol,actief')).then((r) => setWacht((r as Profiel[]).filter((x) => x.rol === 'wacht' && x.actief).length), () => {});
  }, [deel]);
  const melding_: Partial<Record<Deel, string>> = {
    Producten: laag.length ? (op ? `${op} op${laag.length > op ? `, ${laag.length - op} bijna op` : ''}` : `${laag.length} bijna op`) : undefined,
    Medewerkers: wacht ? `${wacht} ${wacht === 1 ? 'wacht' : 'wachten'} op toegang` : undefined,
  };
  if (!deel) {
    return (
      <div className="menu">
        {delen.filter((d) => (d !== 'Kaarten' || methoden.kaart) && (d !== 'Streeplijst' || methoden.lat)).map((d) => (
          <button key={d} className="card wide" onClick={() => setDeel(d)}>
            <div className="hd"><span>{d}</span>{melding_[d] && <span className="pill min">{melding_[d]}</span>}</div>
            <span className="mu">{uitleg[d]}</span>
          </button>
        ))}
      </div>
    );
  }
  return (
    <>
      <div className="kop">
        <button className="terug" onClick={() => setDeel(null)}>‹ Beheer</button>
        <h2>{deel}</h2>
      </div>
      {deel === 'Rapport' && <Rapport />}
      {deel === 'Producten' && <Producten />}
      {deel === 'Kaarten' && <><KaartenMaken /><KaartenOpruimen /></>}
      {deel === 'Streeplijst' && <StreeplijstMaand />}
      {deel === 'Medewerkers' && <Medewerkers />}
      {deel === 'Controle' && <Controle />}
      {deel === 'Logboek' && <Logboek />}
      {deel === 'Instellingen' && <Instellingen />}
    </>
  );
}

// ───────────── Rapport ─────────────

interface RapportData {
  omzet_cent: number; bonnen: number; geannuleerd: number; geannuleerd_cent: number;
  per_methode: { methode: string; bedrag_cent: number }[];
  per_product: { naam: string; aantal: number; bedrag_cent: number }[];
  per_medewerker: { naam: string; bonnen: number; bedrag_cent: number }[];
  per_dag: { dag: string; bonnen: number; bedrag_cent: number }[];
  per_uur: { uur: number; bonnen: number; bedrag_cent: number }[];
  opwaarderingen: { methode: string; aantal: number; bedrag_cent: number }[];
  kaarttegoed_cent: number; kaarten_actief: number; open_rekeningen_cent: number; diensten: Dienst[];
  vervallen_cent?: number;
}

// Een baravond loopt door tot 06:00: verkopen na middernacht horen bij de avond ervoor.
const BARDAG_UUR = 6;
const bardag = (d: Date) => new Date(d.getFullYear(), d.getMonth(), d.getDate(), BARDAG_UUR);
const dagStart = (d: Date) => { const s = bardag(d); return d < s ? plusDagen(s, -1) : s; };
const plusDagen = (d: Date, n: number) => new Date(d.getFullYear(), d.getMonth(), d.getDate() + n, d.getHours());
const isoDag = (d: Date) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;

function periode(k: string): [Date, Date] {
  const v = dagStart(new Date());
  switch (k) {
    case 'Gisteren': return [plusDagen(v, -1), v];
    case 'Deze week': { const s = plusDagen(v, -((v.getDay() + 6) % 7)); return [s, plusDagen(s, 7)]; }
    case 'Deze maand': return [new Date(v.getFullYear(), v.getMonth(), 1, BARDAG_UUR), new Date(v.getFullYear(), v.getMonth() + 1, 1, BARDAG_UUR)];
    case 'Vorige maand': return [new Date(v.getFullYear(), v.getMonth() - 1, 1, BARDAG_UUR), new Date(v.getFullYear(), v.getMonth(), 1, BARDAG_UUR)];
    case 'Dit jaar': return [new Date(v.getFullYear(), 0, 1, BARDAG_UUR), new Date(v.getFullYear() + 1, 0, 1, BARDAG_UUR)];
    default: return [v, plusDagen(v, 1)];
  }
}

function Staaf({ l, w, max, r }: { l: string; w: number; max: number; r: string }) {
  return (
    <div className="bar"><span>{l}</span><i style={{ width: `${max ? Math.max(2, (w / max) * 100) : 0}%` }} /><span className="rt">{r}</span></div>
  );
}

function Rapport() {
  const [keuze, setKeuze] = useState('Vandaag');
  const [eigen, setEigen] = useState<[string, string]>([isoDag(dagStart(new Date())), isoDag(dagStart(new Date()))]);
  const [r, setR] = useState<RapportData | null>(null);
  const [bezig, run] = useBezig();
  const [van, tot] = keuze === 'Zelf kiezen'
    ? [new Date(eigen[0] + 'T06:00'), plusDagen(new Date(eigen[1] + 'T06:00'), 1)]
    : periode(keuze);
  const sleutel = `${+van}-${+tot}`;
  useEffect(() => {
    if (isNaN(+van) || isNaN(+tot)) return;
    void run(async () => setR(await rpc<RapportData>('rapport', { p_van: van.toISOString(), p_tot: tot.toISOString() })));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [sleutel, run]);

  const exporteer = () => run(async () => {
    const rows = await lees(sb.from('verkopen').select('bonnummer,ts,door_naam,rekening_naam,totaal_cent,geannuleerd,verkoop_regels(naam,aantal,prijs_cent),betalingen(methode,bedrag_cent)')
      .gte('ts', van.toISOString()).lt('ts', tot.toISOString()).order('ts')) as {
        bonnummer: number; ts: string; door_naam: string | null; rekening_naam: string | null; totaal_cent: number; geannuleerd: boolean;
        verkoop_regels: { naam: string; aantal: number; prijs_cent: number }[]; betalingen: { methode: string; bedrag_cent: number }[];
      }[];
    const m = (b: typeof rows[number], x: string) => centTekst(b.betalingen.filter((p) => p.methode === x).reduce((a, p) => a + p.bedrag_cent, 0));
    const csv = [csvRij(['bon', 'datum', 'tijd', 'bediend door', 'rekening', 'totaal', 'contant', 'pin', 'kaart', 'streeplijst', 'geannuleerd', 'regels'])]
      .concat(rows.map((b) => csvRij([b.bonnummer, isoDag(new Date(b.ts)), tijd(b.ts), b.door_naam, b.rekening_naam, centTekst(b.totaal_cent),
        m(b, 'contant'), m(b, 'pin'), m(b, 'kaart'), m(b, 'lat'), b.geannuleerd ? 'ja' : '', b.verkoop_regels.map((l) => `${l.aantal}x ${l.naam}`).join(', ')])));
    downloaden(`verkopen-${isoDag(van)}-tot-${isoDag(plusDagen(tot, -1))}.csv`, csv.join('\n'));
  });
  const exporteerProducten = () => {
    if (!r) return;
    downloaden(`producten-${isoDag(van)}-tot-${isoDag(plusDagen(tot, -1))}.csv`,
      [csvRij(['product', 'aantal', 'omzet'])].concat(r.per_product.map((p) => csvRij([p.naam, p.aantal, centTekst(p.bedrag_cent)]))).join('\n'));
  };

  const maxDag = Math.max(0, ...(r?.per_dag ?? []).map((x) => x.bedrag_cent));
  const maxUur = Math.max(0, ...(r?.per_uur ?? []).map((x) => x.bedrag_cent));
  return (
    <>
      <div className="chips small">
        {['Vandaag', 'Gisteren', 'Deze week', 'Deze maand', 'Vorige maand', 'Dit jaar', 'Zelf kiezen'].map((k) => (
          <button key={k} className={k === keuze ? 'on' : ''} onClick={() => setKeuze(k)}>{k}</button>
        ))}
      </div>
      {keuze === 'Zelf kiezen' && (
        <div className="inl">
          <input type="date" className="f" aria-label="Van" value={eigen[0]} onChange={(e) => setEigen([e.target.value, eigen[1]])} />
          <input type="date" className="f" aria-label="Tot en met" value={eigen[1]} onChange={(e) => setEigen([eigen[0], e.target.value])} />
        </div>
      )}
      <p className="mu">{datum(van)}{+plusDagen(van, 1) !== +tot ? ` t/m ${datum(plusDagen(tot, -1))}` : ''} · een dag loopt tot 6 uur 's ochtends{bezig ? ' · laden…' : ''}</p>
      {r && (
        <>
          <div className="kpi">
            <div><span className="mu">Omzet</span><b>{eur(r.omzet_cent)}</b></div>
            <div><span className="mu">Bonnen</span><b>{r.bonnen}</b></div>
            <div><span className="mu">Gemiddeld per bon</span><b>{eur(r.bonnen ? Math.round(r.omzet_cent / r.bonnen) : 0)}</b></div>
            <div><span className="mu">Geannuleerd</span><b>{r.geannuleerd}</b><span className="mu">{eur(r.geannuleerd_cent)}</span></div>
          </div>
          <Blok titel="Betaalmethoden">
            <Verdeling delen={['contant', 'pin', 'kaart'].map((m) => ({ methode: m, bedrag_cent: r.per_methode.find((x) => x.methode === m)?.bedrag_cent ?? 0 }))} />
          </Blok>
          {r.per_dag.length > 1 && <Blok titel="Per dag">{r.per_dag.map((x) => <Staaf key={x.dag} l={datum(x.dag)} w={x.bedrag_cent} max={maxDag} r={eur(x.bedrag_cent)} />)}</Blok>}
          {r.per_uur.length > 0 && <Blok titel="Per uur">{r.per_uur.map((x) => <Staaf key={x.uur} l={`${x.uur}:00`} w={x.bedrag_cent} max={maxUur} r={eur(x.bedrag_cent)} />)}</Blok>}
          <Blok titel="Producten" rechts={<span className="mu">{r.per_product.reduce((a, x) => a + x.aantal, 0)} stuks</span>}>
            <Ingeklapt lijst={r.per_product} rij={(x) => <Rij key={x.naam} l={`${x.naam} (${x.aantal}×)`} r={eur(x.bedrag_cent)} />} />
            {!r.per_product.length && <p className="mu">Niets verkocht.</p>}
          </Blok>
          <Blok titel="Medewerkers">
            {r.per_medewerker.map((x) => <Rij key={x.naam} l={`${x.naam} (${x.bonnen} bonnen)`} r={eur(x.bedrag_cent)} />)}
            {!r.per_medewerker.length && <p className="mu">Niets verkocht.</p>}
          </Blok>
          <Blok titel="Tegoedkaarten en rekeningen">
            {r.opwaarderingen.map((x) => <Rij key={x.methode} l={`Opgewaardeerd, ${x.methode === 'pin' ? 'pin' : 'contant'} (${x.aantal}×)`} r={eur(x.bedrag_cent)} />)}
            {!!r.vervallen_cent && <Rij l="Tegoed vervallen (kaarten verwijderd)" r={eur(r.vervallen_cent)} />}
            <Rij l={`Tegoed nu op ${r.kaarten_actief} kaarten`} r={eur(r.kaarttegoed_cent)} />
            <Rij l="Nu open op rekeningen" r={eur(r.open_rekeningen_cent)} />
          </Blok>
          <Blok titel="Diensten en kasverschillen">
            <Ingeklapt lijst={r.diensten} n={5} rij={(d) => <DienstRij key={d.id} d={d} />} />
            {!r.diensten.length && <p className="mu">Geen diensten in deze periode.</p>}
          </Blok>
          <div className="btns" style={{ marginTop: 16 }}>
            <button disabled={bezig} onClick={exporteer}>Bonnen als CSV</button>
            <button onClick={exporteerProducten}>Producten als CSV</button>
          </div>
        </>
      )}
    </>
  );
}

function DienstRij({ d }: { d: Dienst }) {
  const { open } = useSheet();
  const verschil = d.geteld_cent != null ? d.geteld_cent - d.verwacht_cent : null;
  return (
    <Rij onClick={() => open(<><h2>Dienst {datumTijd(d.geopend_ts)}</h2>
      <p className="mu">Geopend door {d.geopend_door ?? '?'}{d.gesloten_ts ? `, gesloten ${datumTijd(d.gesloten_ts)} door ${d.gesloten_door ?? '?'}` : ', nog open'}</p>
      <DienstKaarten d={d} /></>)}
      l={<>{datumTijd(d.geopend_ts)}{d.gesloten_ts ? '' : ' (open)'}<br /><span className="mu">omzet {eur(d.omzet_cent)}{d.geopend_door ? ` · ${d.geopend_door}` : ''}</span></>}
      r={verschil == null ? '' : <Verschil c={verschil} />} />
  );
}

function Blok({ titel, rechts, children }: { titel: string; rechts?: React.ReactNode; children: React.ReactNode }) {
  return <div className="card"><div className="hd"><span>{titel}</span>{rechts}</div>{children}</div>;
}

// Lange lijst: eerst de bovenste paar, de rest op verzoek.
function Ingeklapt<T>({ lijst, n = 6, rij }: { lijst: T[]; n?: number; rij: (x: T) => React.ReactNode }) {
  const [alles, setAlles] = useState(false);
  return (
    <>
      {(alles ? lijst : lijst.slice(0, n)).map(rij)}
      {lijst.length > n && <button className="ghost" onClick={() => setAlles(!alles)}>{alles ? 'Minder tonen' : `Alle ${lijst.length} tonen`}</button>}
    </>
  );
}

// ───────────── Producten & voorraad ─────────────

function Producten() {
  const { producten } = useData();
  const { open } = useSheet();
  const laag = producten.filter((p) => p.actief && p.voorraad <= p.voorraad_min);
  const cats = [...new Set(producten.map((p) => p.categorie))];
  return (
    <>
      {laag.length > 0 && (
        <div className="card warnbox">
          <b>Op of bijna op</b>
          {laag.map((p) => <Rij key={p.id} l={p.naam} r={p.voorraad <= 0 ? 'op' : `${p.voorraad} over`} onClick={() => open(<ProductScherm id={p.id} />)} />)}
          <p className="mu">Tik op een product en boek een levering of telling.</p>
        </div>
      )}
      {cats.map((c) => (
        <div key={c}>
          <h3 className="s">{c}</h3>
          {producten.filter((p) => p.categorie === c).map((p) => (
            <Rij key={p.id} className={p.actief ? '' : 'vd'} onClick={() => open(<ProductScherm id={p.id} />)}
              l={<>{p.naam}<span className={'mu' + (p.voorraad <= p.voorraad_min ? ' neg' : '')}> · voorraad {p.voorraad}</span></>}
              r={eur(p.prijs_cent)} />
          ))}
        </div>
      ))}
      <button className="big" onClick={() => open(<ProductScherm id={null} />)}>Nieuw product</button>
      <OudeKassa />
    </>
  );
}

function ProductScherm({ id }: { id: number | null }) {
  const { producten, herlaad } = useData();
  const { sluit } = useSheet();
  const p: Partial<Product> = (id != null && producten.find((x) => x.id === id)) || { categorie: producten[0]?.categorie ?? 'Drinken', actief: true };
  const [f, setF] = useState({
    naam: p.naam ?? '', prijs: p.prijs_cent != null ? centTekst(p.prijs_cent) : '', categorie: p.categorie ?? '',
    volgorde: String(p.volgorde ?? 0), actief: p.actief ?? true, voorraad: '', voorraad_min: String(p.voorraad_min ?? 0),
  });
  const [aantal, setAantal] = useState('');
  const [bezig, run] = useBezig();
  const opslaan = () => run(async () => {
    const prijs = naarCent(f.prijs);
    if (!f.naam.trim()) throw new Error('Vul een naam in');
    if (isNaN(prijs) || prijs < 0) throw new Error('Vul een geldige prijs in');
    // Elk product heeft een voorraad; bij een nieuw product meteen de beginvoorraad.
    const voorraad = /^\d+$/.test(f.voorraad.trim()) ? parseInt(f.voorraad) : NaN;
    if (id == null && isNaN(voorraad)) throw new Error('Vul de voorraad in (hoeveel er nu is, ook als dat 0 is)');
    await rpc('product_opslaan', { p: { id, naam: f.naam, prijs_cent: prijs, categorie: f.categorie, actief: f.actief, volgorde: parseInt(f.volgorde) || 0, voorraad: id == null ? voorraad : undefined, voorraad_min: parseInt(f.voorraad_min) || 0 } });
    await herlaad();
    sluit();
    melding('Opgeslagen');
  });
  const voorraad = (soort: 'levering' | 'telling') => run(async () => {
    const n = parseInt(aantal);
    if (isNaN(n)) throw new Error('Vul een aantal in');
    const nieuw = await rpc<number>('voorraad_boeken', { p_product_id: id, p_aantal: n, p_soort: soort });
    setAantal('');
    await herlaad();
    melding(`Voorraad is nu ${nieuw}`);
  });
  const weg = () => run(async () => { await rpc('product_verwijderen', { p_id: id }); await herlaad(); sluit(); });
  const zet = (k: keyof typeof f) => (e: React.ChangeEvent<HTMLInputElement>) => setF({ ...f, [k]: e.target.type === 'checkbox' ? e.target.checked : e.target.value });
  return (
    <>
      <h2>{id == null ? 'Nieuw product' : p.naam}</h2>
      <label htmlFor="pn">Naam</label><input className="f" id="pn" value={f.naam} onChange={zet('naam')} />
      <label htmlFor="pp">Prijs in euro</label><input className="f" id="pp" inputMode="decimal" value={f.prijs} onChange={zet('prijs')} />
      <label htmlFor="pc">Categorie</label>
      <input className="f" id="pc" list="cats" value={f.categorie} onChange={zet('categorie')} />
      <datalist id="cats">{[...new Set(producten.map((x) => x.categorie))].map((c) => <option key={c} value={c} />)}</datalist>
      <label htmlFor="pv">Volgorde (lager = eerder)</label><input className="f" id="pv" inputMode="numeric" value={f.volgorde} onChange={zet('volgorde')} />
      <label className="check"><input type="checkbox" checked={f.actief} onChange={zet('actief')} /> Tonen in de kassa</label>
      {id == null && (<><label htmlFor="pvr">Voorraad nu</label><input className="f" id="pvr" inputMode="numeric" placeholder="Hoeveel is er nu?" value={f.voorraad} onChange={zet('voorraad')} /></>)}
      <label htmlFor="pm">Waarschuwen bij voorraad van</label><input className="f" id="pm" inputMode="numeric" value={f.voorraad_min} onChange={zet('voorraad_min')} />
      <button className="big" disabled={bezig} onClick={opslaan}>Opslaan</button>
      {id != null && (
        <>
          <h3 className="s">Voorraad: {p.voorraad}</h3>
          <div className="inl">
            <input className="f" inputMode="numeric" placeholder="Aantal" value={aantal} onChange={(e) => setAantal(e.target.value)} aria-label="Aantal" />
            <button disabled={bezig} onClick={() => voorraad('levering')}>+ Levering</button>
            <button disabled={bezig} onClick={() => voorraad('telling')}>= Geteld</button>
          </div>
          <p className="mu">Levering telt het aantal erbij op. Geteld zet de voorraad op precies dit aantal.</p>
          <button className="ghost" disabled={bezig} onClick={weg}>Product verwijderen</button>
        </>
      )}
    </>
  );
}

/** Producten overnemen uit de oude kassa (zelfde website) of uit een geplakte back-up. */
function OudeKassa() {
  const { producten, herlaad } = useData();
  const [tekst, setTekst] = useState('');
  const [bezig, run] = useBezig();
  let oud = '';
  try { oud = localStorage.getItem('bar-kassa-v1') ?? ''; } catch { /* geen opslag */ }
  const overnemen = (bron: string) => run(async () => {
    let lijst: { name: string; price: number; cat: string; on: number }[];
    try { lijst = JSON.parse(bron).products; if (!Array.isArray(lijst)) throw 0; } catch { throw new Error('Dit is geen geldige back-up van de oude kassa'); }
    const bestaand = new Set(producten.map((p) => p.naam.toLowerCase()));
    let n = 0;
    for (const p of lijst) {
      if (bestaand.has(String(p.name).toLowerCase())) continue;
      await rpc('product_opslaan', { p: { naam: p.name, prijs_cent: p.price, categorie: p.cat, actief: !!p.on } });
      n++;
    }
    await herlaad();
    melding(n ? `${n} producten overgenomen` : 'Alle producten bestonden al');
  });
  return (
    <details className="card" style={{ marginTop: 16 }}>
      <summary>Producten overnemen uit de oude kassa</summary>
      {oud && <button className="big alt" disabled={bezig} onClick={() => overnemen(oud)}>Overnemen van dit apparaat</button>}
      <p className="mu">Of plak een back-up van de oude kassa (Kaarten → Back-up). Kaarten worden niet overgenomen: die krijgen nieuwe, veilige codes. Overgenomen producten beginnen met voorraad 0: tel ze daarna (tik op het product, = Geteld).</p>
      <textarea className="f" value={tekst} onChange={(e) => setTekst(e.target.value)} aria-label="Back-up" />
      <button disabled={bezig || !tekst} onClick={() => overnemen(tekst)}>Overnemen uit back-up</button>
    </details>
  );
}

// ───────────── Kaarten maken / printen ─────────────

function KaartenMaken() {
  const { open } = useSheet();
  const { winkel } = useData();
  const [n, setN] = useState('12');
  const [van, setVan] = useState('');
  const [tot, setTot] = useState('');
  const [bezig, run] = useBezig();
  const toon = (lijst: { nummer: number; code: string }[]) => open(
    <>
      <h2>{lijst.length} kaarten</h2>
      <div className="btns"><button className="big" onClick={() => window.print()}>Printen of PDF</button></div>
      <p className="mu">Op creditcardformaat, tien per A4. Print op 100% (niet "passend maken") en knip langs de stippellijnen.</p>
      <div className="print kaarten">
        {lijst.map((k) => <QrKaart key={k.nummer} nummer={k.nummer} code={k.code} winkel={winkel} />)}
      </div>
    </>,
  );
  const maken = () => run(async () => toon(await rpc('kaarten_maken', { p_aantal: parseInt(n) || 0 })));
  const herprint = () => run(async () => {
    const a = parseInt(van), b = parseInt(tot || van);
    if (!(a > 0) || !(b >= a) || b - a > 300) throw new Error('Kies een geldige reeks nummers');
    const lijst = await rpc<{ nummer: number; code: string }[]>('kaart_codes', { p_nummers: Array.from({ length: b - a + 1 }, (_, i) => a + i) });
    if (!lijst.length) throw new Error('Geen kaarten met deze nummers');
    toon(lijst);
  });
  return (
    <>
      <p className="mu">Elke kaart krijgt een QR-code met een geheime code die niet te raden is. Alleen met die code (scannen of typen) kan er van de kaart betaald worden.</p>
      <label htmlFor="nk">Nieuwe kaarten maken</label>
      <div className="inl"><input className="f" id="nk" inputMode="numeric" value={n} onChange={(e) => setN(e.target.value)} /><button disabled={bezig} onClick={maken}>Maak en toon</button></div>
      <label htmlFor="hv">Bestaande kaarten opnieuw printen (nummer van – tot)</label>
      <div className="inl">
        <input className="f" id="hv" inputMode="numeric" placeholder="van" value={van} onChange={(e) => setVan(e.target.value)} />
        <input className="f" inputMode="numeric" placeholder="tot" aria-label="tot" value={tot} onChange={(e) => setTot(e.target.value)} />
        <button disabled={bezig} onClick={herprint}>Toon</button>
      </div>
    </>
  );
}

// ───────────── Kaarten opruimen ─────────────

interface Opruimen { leeg: number; met_tegoed: { id: number; nummer: number; naam: string | null; saldo_cent: number; laatst_gebruikt: string }[] }

/** Kaarten die een jaar niet zijn gebruikt: zonder tegoed in één keer weg, met tegoed per kaart. */
function KaartenOpruimen() {
  const { open } = useSheet();
  const [o, setO] = useState<Opruimen | null>(null);
  const [zeker, setZeker] = useState(false);
  const [bezig, run] = useBezig();
  const laad = useCallback(async () => setO(await rpc<Opruimen>('kaarten_opruimen_overzicht')), []);
  useEffect(() => { void run(laad); }, [laad, run]);
  const opruimen = () => run(async () => {
    const n = await rpc<number>('kaarten_opruimen');
    setZeker(false);
    await laad();
    melding(`${n} ${n === 1 ? 'kaart' : 'kaarten'} opgeruimd`);
  });
  if (!o) return null;
  const tegoed = o.met_tegoed.reduce((a, k) => a + k.saldo_cent, 0);
  return (
    <>
      <h3 className="s">Oude kaarten opruimen</h3>
      <p className="mu">Kaarten die 12 maanden niet zijn gebruikt. Ze verdwijnen uit de lijst en werken niet meer; de geschiedenis blijft bewaard en het nummer komt niet opnieuw voor.</p>
      {!o.leeg && !o.met_tegoed.length && <p className="mu">Er zijn geen oude kaarten.</p>}
      {o.leeg > 0 && (!zeker
        ? <button className="big" onClick={() => setZeker(true)}>{o.leeg} {o.leeg === 1 ? 'kaart' : 'kaarten'} zonder tegoed opruimen</button>
        : (
          <div className="card warnbox">
            <p>{o.leeg} {o.leeg === 1 ? 'kaart' : 'kaarten'} zonder tegoed verwijderen?</p>
            <div className="btns">
              <button onClick={() => setZeker(false)}>Nee</button>
              <button className="big warn" disabled={bezig} onClick={opruimen}>Ja, opruimen</button>
            </div>
          </div>
        ))}
      {o.met_tegoed.length > 0 && (
        <div className="card">
          <div className="hd"><span>Oud, maar met tegoed ({eur(tegoed)})</span></div>
          <p className="mu">Deze gaan niet vanzelf weg. Tik op een kaart om hem te bekijken en eventueel te verwijderen; het tegoed vervalt dan.</p>
          {o.met_tegoed.map((k) => (
            <Rij key={k.id} onClick={() => open(<KaartScherm id={k.id} onWijziging={() => void laad()} />)}
              l={<>Kaart {k.nummer}{k.naam ? ` · ${k.naam}` : ''}<br /><span className="mu">laatst gebruikt {datum(k.laatst_gebruikt)}</span></>}
              r={eur(k.saldo_cent)} />
          ))}
        </div>
      )}
    </>
  );
}

// ───────────── Medewerkers ─────────────

const rolNaam: Record<Rol, string> = { wacht: 'Wacht op goedkeuring', medewerker: 'Medewerker', beheerder: 'Beheerder' };

function WachtwoordInstellen({ p }: { p: Profiel }) {
  const { sluit } = useSheet();
  const [ww, setWw] = useState('');
  const [bezig, run] = useBezig();
  return (
    <>
      <h2>Wachtwoord voor {p.naam}</h2>
      <p className="mu">Geef het nieuwe wachtwoord door aan {p.naam}. Die kan het daarna zelf wijzigen (tik rechtsboven op je naam).</p>
      <label htmlFor="mw">Nieuw wachtwoord (minstens 8 tekens)</label>
      <input className="f" id="mw" value={ww} autoComplete="off" onChange={(e) => setWw(e.target.value)} />
      <button className="big" disabled={bezig} onClick={() => run(async () => {
        await rpc('wachtwoord_instellen', { p_id: p.id, p_wachtwoord: ww });
        sluit();
        melding('Wachtwoord ingesteld');
      })}>Instellen</button>
    </>
  );
}

function Medewerkers() {
  const { profiel } = useData();
  const { open } = useSheet();
  const [lijst, setLijst] = useState<Profiel[]>([]);
  const [bezig, run] = useBezig();
  const laad = useCallback(() => run(async () => setLijst(await lees(sb.from('profielen').select('*').order('aangemaakt')) as Profiel[])), [run]);
  useEffect(() => { void laad(); }, [laad]);
  const zet = (p: Profiel, rol: Rol, actief: boolean) => run(async () => {
    await rpc('gebruiker_bijwerken', { p_id: p.id, p_rol: rol, p_actief: actief });
    setLijst(await lees(sb.from('profielen').select('*').order('aangemaakt')) as Profiel[]);
    melding('Opgeslagen');
  });
  const wachtend = lijst.filter((p) => p.rol === 'wacht' && p.actief);
  return (
    <>
      <Uitnodigen />
      <h3 className="s">Medewerkers</h3>
      {wachtend.map((p) => (
        <div className="card warnbox" key={p.id}>
          <div className="hd"><span>{p.naam}</span><span className="mu">wacht</span></div>
          <div className="btns">
            <button className="big" disabled={bezig} onClick={() => zet(p, 'medewerker', true)}>Goedkeuren</button>
            <button disabled={bezig} onClick={() => zet(p, 'wacht', false)}>Weigeren</button>
          </div>
        </div>
      ))}
      {lijst.filter((p) => !wachtend.includes(p)).map((p) => (
        <div className={'card' + (p.actief ? '' : ' vd')} key={p.id}>
          <div className="hd"><span>{p.naam}{p.id === profiel.id ? ' (jij)' : ''}</span><span className="mu">{p.actief ? rolNaam[p.rol] : 'Uitgeschakeld'}</span></div>
          <div className="inl">
            <select className="f" value={p.rol} disabled={bezig} aria-label={`Rol van ${p.naam}`} onChange={(e) => zet(p, e.target.value as Rol, p.actief)}>
              <option value="medewerker">Medewerker</option><option value="beheerder">Beheerder</option><option value="wacht">Geen toegang</option>
            </select>
            <button disabled={bezig} onClick={() => zet(p, p.rol, !p.actief)}>{p.actief ? 'Uitschakelen' : 'Inschakelen'}</button>
          </div>
          <button className="ghost" onClick={() => open(<WachtwoordInstellen p={p} />)}>Nieuw wachtwoord instellen</button>
        </div>
      ))}
      <p className="mu">Medewerkers kunnen afrekenen, rekeningen bijhouden, kaarten opwaarderen en de kassa openen en sluiten. Beheerders kunnen daarnaast prijzen en voorraad aanpassen, kaarten maken, alle bonnen annuleren en rapporten zien.</p>
    </>
  );
}

// ───────────── Logboek ─────────────

const actieNaam: Record<string, string> = {
  rekening_maken: 'Rekening aangemaakt', rekening_regel_verwijderen: 'Regel van rekening geschrapt', rekening_verwijderen: 'Rekening verwijderd',
  verkoop_annuleren: 'Bon geannuleerd', kaarten_maken: 'Kaarten gemaakt', kaart_blokkeren: 'Kaart geblokkeerd', kaart_deblokkeren: 'Kaart gedeblokkeerd',
  kaart_overzetten: 'Kaarttegoed overgezet', product_nieuw: 'Product toegevoegd', prijs_wijzigen: 'Prijs gewijzigd', product_verwijderen: 'Product verwijderd',
  dienst_openen: 'Kassa geopend', dienst_sluiten: 'Kassa gesloten', gebruiker_bijwerken: 'Medewerker gewijzigd',
  wachtwoord_instellen: 'Wachtwoord ingesteld', kaart_naam: 'Kaart op naam gezet', levering: 'Levering ingeboekt',
  betaalmethoden: 'Betaalmethoden aangepast', lid_nieuw: 'Lid op de streeplijst gezet', lid_wijzigen: 'Lid gewijzigd',
  lat_afbetalen: 'Streeplijst afbetaald', uitnodiging_maken: 'Uitnodiging gemaakt', uitnodiging_intrekken: 'Uitnodiging ingetrokken',
  uitnodiging_gebruikt: 'Uitnodiging gebruikt (nieuw account)', aanmelden_instellen: 'Zelf aanmelden aan/uit gezet', lid_nieuwe_code: 'Nieuwe streeplijst-code gemaakt',
  kaart_verwijderen: 'Kaart verwijderd', kaarten_opruimen: 'Oude kaarten opgeruimd',
};

function details(a: string, d: Record<string, unknown> | null): string {
  if (!d) return '';
  const e = (k: string) => (typeof d[k] === 'number' ? eur(d[k] as number) : '');
  switch (a) {
    case 'verkoop_annuleren': return `Bon ${d.bon}, ${e('totaal_cent')}`;
    case 'prijs_wijzigen': return `${d.product}: ${e('van')} → ${e('naar')}`;
    case 'dienst_sluiten': return `verschil ${e('verschil_cent')}`;
    case 'dienst_openen': return `wisselgeld ${e('beginsaldo_cent')}`;
    case 'kaart_overzetten': return `kaart ${d.van} → ${d.naar}, ${e('bedrag_cent')}`;
    case 'kaart_verwijderen': return `kaart ${d.kaart}${d.naam ? ` (${d.naam})` : ''}${d.vervallen_cent ? `, ${e('vervallen_cent')} tegoed vervallen` : ''}`;
    case 'kaarten_opruimen': return `${d.aantal} kaarten zonder tegoed`;
    case 'rekening_regel_verwijderen': return `${d.aantal}× ${d.naam}`;
    case 'betaalmethoden': return (['contant', 'pin', 'kaart', 'rekening', 'lat'] as const).filter((k) => d[k] != null).map((k) => `${methodeLabel[k]} ${d[k] ? 'aan' : 'uit'}`).join(', ');
    case 'lat_afbetalen': return `${d.naam}: ${e('bedrag_cent')} (${methodeNaam[d.methode as string] ?? d.methode})`;
    case 'gebruiker_bijwerken': return `${d.gebruiker}: ${d.actief ? rolNaam[d.rol as Rol] : 'uitgeschakeld'}`;
    default: return ['naam', 'product', 'kaart', 'aantal', 'gebruiker'].filter((k) => d[k] != null).map((k) => String(d[k])).join(', ');
  }
}

function Logboek() {
  const [lijst, setLijst] = useState<{ id: number; ts: string; door_naam: string | null; actie: string; details: Record<string, unknown> | null }[]>([]);
  const [, run] = useBezig();
  useEffect(() => { void run(async () => setLijst(await lees(sb.from('logboek').select('*').order('ts', { ascending: false }).limit(300)) as typeof lijst)); }, [run]);
  return (
    <>
      <p className="mu">Wie heeft wat gedaan. Dit logboek kan door niemand worden aangepast.</p>
      {lijst.map((l) => (
        <Rij key={l.id} l={<>{actieNaam[l.actie] ?? l.actie}<br /><span className="mu">{details(l.actie, l.details)}</span></>}
          r={<span className="mu">{datumTijd(l.ts)}<br />{l.door_naam}</span>} />
      ))}
    </>
  );
}

// ───────────── Instellingen ─────────────

function Instellingen() {
  const { winkel, methoden, herlaad } = useData();
  const [naam, setNaam] = useState(winkel);
  const [bezig, run] = useBezig();
  return (
    <>
      <label htmlFor="wn">Naam op de bon</label>
      <div className="inl">
        <input className="f" id="wn" value={naam} onChange={(e) => setNaam(e.target.value)} />
        <button disabled={bezig} onClick={() => run(async () => { await rpc('instellingen_opslaan', { p_naam: naam }); await herlaad(); melding('Opgeslagen'); })}>Opslaan</button>
      </div>
      <Betaalmethoden />
      {methoden.kaart && <ZuilUitleg />}
      <Bijwerken />
      <h3 className="s">Wat is er nieuw</h3>
      <WijzigingLijst lijst={wijzigingen} />
    </>
  );
}

const methodeLabel: Record<keyof Methoden, string> = { contant: 'Contant', pin: 'Pin', kaart: 'Kaart', rekening: 'Op rekening', lat: 'Streeplijst' };
const methodeUitleg: Record<keyof Methoden, string> = {
  contant: 'Betalen met contant geld',
  pin: 'Betalen met de pinautomaat',
  kaart: 'Tegoedkaarten: opwaarderen en ermee betalen',
  rekening: 'Bestellingen op een rekening zetten en later afrekenen',
  lat: 'Leden zetten een streep en betalen later, bijvoorbeeld per maand',
};

// Een oude telefoon of tablet aan de muur waar klanten hun kaart voor houden.
function ZuilUitleg() {
  const [toon, setToon] = useState(false);
  const link = zuilLink();
  return (
    <>
      <h3 className="s">Saldo-zuil</h3>
      <p className="mu">Hang een oude telefoon of tablet aan de muur bij de bar. Klanten houden hun kaart voor de camera en zien hun saldo; na tien seconden staat hij weer klaar. Een USB-scanner werkt ook. Er hoeft niemand op in te loggen.</p>
      {!toon ? <button className="ghost" onClick={() => setToon(true)}>Zo stel je hem in</button> : (
        <div className="card">
          <ol className="stappen">
            <li>Verbind de oude telefoon met de wifi van de kassa en installeer het certificaat (zoals bij de andere telefoons).</li>
            <li>Scan deze code met die telefoon, of open <b>{link}</b>.</li>
            <li>Sta de camera toe. Zet de telefoon in de stand die hem op deze pagina houdt (iPhone: Begeleide toegang; Android: App vastzetten) en laat hem aan de oplader.</li>
          </ol>
          <div className="qrs-zuil"><Qr tekst={link} /></div>
        </div>
      )}
    </>
  );
}

// Welke betaalknoppen de kassa toont, bijvoorbeeld pin uit als er geen pinautomaat is.
function Betaalmethoden() {
  const { methoden, rekeningen, herlaad } = useData();
  const [m, setM] = useState(methoden);
  const [bezig, run] = useBezig();
  const veranderd = (Object.keys(m) as (keyof Methoden)[]).some((k) => m[k] !== methoden[k]);
  const opslaan = () => run(async () => {
    if (!m.contant && !m.pin && !m.kaart && !m.lat) throw new Error('Zet minstens één van contant, pin, kaart of streeplijst aan');
    await rpc('betaalmethoden_opslaan', { p_contant: m.contant, p_pin: m.pin, p_kaart: m.kaart, p_rekening: m.rekening, p_lat: m.lat });
    await herlaad();
    melding('Opgeslagen');
  });
  return (
    <>
      <h3 className="s">Betaalmethoden</h3>
      <p className="mu">Wat uit staat, verdwijnt van de kassa op alle telefoons.</p>
      {(Object.keys(methodeLabel) as (keyof Methoden)[]).map((k) => (
        <label key={k} className="check">
          <input type="checkbox" checked={m[k]} onChange={(e) => setM({ ...m, [k]: e.target.checked })} />
          <span>{methodeLabel[k]}<br /><span className="mu">{methodeUitleg[k]}</span></span>
        </label>
      ))}
      {!m.kaart && methoden.kaart && <p className="card warnbox">Staat er nog tegoed op kaarten, dan kan daar niet meer mee betaald worden zolang kaart uit staat.</p>}
      {!m.rekening && methoden.rekening && rekeningen.length > 0 && <p className="card warnbox">Er {rekeningen.length === 1 ? 'staat nog 1 rekening' : `staan nog ${rekeningen.length} rekeningen`} open. Die blijven te zien tot ze zijn afgerekend.</p>}
      <button className="big" disabled={bezig || !veranderd} onClick={opslaan}>Betaalmethoden opslaan</button>
    </>
  );
}

interface Systeem {
  versie: string | null; nieuwste: string | null; gecontroleerd: string | null; verzoek: string | null;
  status: 'klaar' | 'bezig' | 'mislukt'; melding: string | null; bijgewerkt_ts: string | null; wijzigingen: Wijziging[] | null;
}
const versieNr = (v: string | null) => parseInt((v ?? '').replace(/\D/g, ''), 10) || 0;

// Nieuwe versie installeren. De app zet alleen een verzoek klaar; de kassa-server
// voert het binnen een minuut uit (server/bijwerker.sh) en meldt hier de voortgang.
function Bijwerken() {
  const [s, setS] = useState<Systeem | null>(null);
  const [weg, setWeg] = useState(false);
  const [zeker, setZeker] = useState(false);
  const [bezig, run] = useBezig();
  const laad = useCallback(async () => {
    try {
      setS(await lees(sb.from('systeem').select('*').maybeSingle()) as Systeem | null);
      setWeg(false);
    } catch { setWeg(true); }
  }, []);
  const wacht = !!s && (s.status === 'bezig' || !!s.verzoek);
  useEffect(() => { void laad(); }, [laad]);
  // Tijdens een update vaker kijken; de server is dan ook even niet bereikbaar.
  useEffect(() => {
    if (!wacht && !weg) return;
    const t = setInterval(() => void laad(), 3000);
    return () => clearInterval(t);
  }, [wacht, weg, laad]);

  if (PROEF) return <><h3 className="s">Bijwerken</h3><p className="mu">De proefversie is altijd de nieuwste versie. Op de kassa-server werk je hier de kassa bij.</p></>;
  if (!s) return null;
  if (!s.versie) return <><h3 className="s">Bijwerken</h3><p className="mu">Bijwerken vanuit de app kan alleen op de eigen kassa-server.</p></>;
  const nieuwer = versieNr(s.nieuwste) > versieNr(s.versie);
  const verzoek = (soort: string) => run(async () => { await rpc('systeem_verzoek', { p_soort: soort }); setZeker(false); await laad(); });
  return (
    <>
      <h3 className="s">Bijwerken</h3>
      <Rij l="Deze kassa" r={s.versie} />
      <Rij l="Nieuwste versie" r={s.nieuwste ?? 'nog niet bekend'} />
      {s.gecontroleerd && <p className="mu">Gecontroleerd: {datumTijd(s.gecontroleerd)}</p>}
      {weg && wacht && <p><b>De kassa-server herstart… even geduld.</b></p>}
      {s.melding && <p className={s.status === 'mislukt' ? 'neg' : ''}>{s.melding}</p>}
      {s.status === 'klaar' && !nieuwer && s.bijgewerkt_ts && Date.now() - Date.parse(s.bijgewerkt_ts) < 3600e3 && (
        <button className="big" onClick={() => location.reload()}>Nieuwe versie laden</button>
      )}
      {!wacht && (nieuwer ? (
        zeker ? (
          <div className="card warnbox">
            <p>De kassa is een paar minuten niet bereikbaar. Er wordt eerst een back-up gemaakt. Niet doen terwijl er afgerekend wordt.</p>
            <div className="btns">
              <button onClick={() => setZeker(false)}>Nee</button>
              <button className="big" disabled={bezig} onClick={() => verzoek('bijwerken')}>Ja, bijwerken</button>
            </div>
          </div>
        ) : (
          <>
            {Array.isArray(s.wijzigingen) && nogNietBekend(s.wijzigingen, wijzigingen).length > 0 && (
              <div className="card"><p><b>Nieuw in {s.nieuwste}</b></p><WijzigingLijst lijst={nogNietBekend(s.wijzigingen, wijzigingen)} /></div>
            )}
            <button className="big" onClick={() => setZeker(true)}>Bijwerken naar {s.nieuwste}</button>
          </>
        )
      ) : (
        <>
          {s.nieuwste && <p className="mu">De kassa is up-to-date.</p>}
          <button className="big alt" disabled={bezig} onClick={() => verzoek('controleren')}>Zoeken naar een nieuwe versie</button>
        </>
      ))}
      {wacht && <p className="mu">Even geduld…</p>}
    </>
  );
}
