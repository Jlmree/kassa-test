import { useEffect, useState } from 'react';
import { datum, eur, lees, naarCent, rpc, sb } from '../lib';
import { melding, Rij, useBezig } from '../ui';

// Beheer → Loterij: een winnende barkaart trekken. Komen telt, niet wat iemand drinkt.

type Manier = 'dagen' | 'gelijk' | 'opwaarderen';
const manieren: { id: Manier; naam: string; uitleg: string }[] = [
  { id: 'dagen', naam: 'Trouwe bezoeker', uitleg: '1 lot per avond dat met de kaart is betaald' },
  { id: 'gelijk', naam: 'Iedereen gelijk', uitleg: '1 lot per kaart waarmee in de periode is betaald' },
  { id: 'opwaarderen', naam: 'Opwaarderen', uitleg: '1 lot per € 10 dat op de kaart is gezet' },
];
const manierNaam = (m: string) => manieren.find((x) => x.id === m)?.naam ?? m;

interface Voorbeeld { deelnemers: number; loten: number; lijst: { nummer: number; naam: string | null; loten: number }[] }
interface Uitslag { nummer: number; naam: string | null; loten: number; totaal: number; deelnemers: number; prijs_cent: number; omschrijving: string | null; nummers: number[] }
interface Trekking { id: number; ts: string; door_naam: string | null; van: string; tot: string; manier: string; deelnemers: number; loten: number; winnaar_nummer: number; winnaar_loten: number; prijs_cent: number; omschrijving: string | null }

const iso = (d: Date) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
function snel(): { naam: string; van: string; tot: string }[] {
  const nu = new Date();
  const s = nu.getMonth() >= 7 ? nu.getFullYear() : nu.getFullYear() - 1;
  return [
    { naam: 'Deze maand', van: iso(new Date(nu.getFullYear(), nu.getMonth(), 1)), tot: iso(nu) },
    { naam: 'Vorige maand', van: iso(new Date(nu.getFullYear(), nu.getMonth() - 1, 1)), tot: iso(new Date(nu.getFullYear(), nu.getMonth(), 0)) },
    { naam: 'Dit seizoen', van: `${s}-08-01`, tot: iso(nu) },
  ];
}

export function Loterij() {
  const perioden = snel();
  const [van, setVan] = useState(perioden[0].van);
  const [tot, setTot] = useState(perioden[0].tot);
  const [manier, setManier] = useState<Manier>('dagen');
  const [max, setMax] = useState('10');
  const [uit, setUit] = useState('');
  const [prijs, setPrijs] = useState('');
  const [omschrijving, setOmschrijving] = useState('');
  const [vb, setVb] = useState<Voorbeeld | null>(null);
  const [zeker, setZeker] = useState(false);
  const [uitslag, setUitslag] = useState<Uitslag | null>(null);
  const [lijst, setLijst] = useState<Trekking[]>([]);
  const [bezig, run] = useBezig();

  const laadLijst = () => lees(sb.from('loterij_trekkingen').select('*').order('ts', { ascending: false }).limit(20)).then((r) => setLijst(r as Trekking[]), () => {});
  useEffect(() => { void laadLijst(); }, []);
  // Andere instellingen: eerst opnieuw kijken wie meedoet.
  useEffect(() => { setVb(null); setZeker(false); }, [van, tot, manier, max, uit]);

  const args = () => {
    const nummers = uit.split(/[^0-9]+/).filter(Boolean).map(Number);
    const m = manier === 'gelijk' ? 1 : parseInt(max, 10);
    if (!(m >= 1 && m <= 100)) throw new Error('Kies een maximum van 1 tot 100 loten per kaart');
    // Geen kaarten uitgesloten: weglaten (de database neemt dan een lege lijst).
    return { p_van: van, p_tot: tot, p_manier: manier, p_max: m, ...(nummers.length ? { p_uitgesloten: nummers } : {}) };
  };
  const prijsCent = prijs.trim() ? naarCent(prijs) : 0;

  const bekijk = () => run(async () => setVb(await rpc<Voorbeeld>('loterij_voorbeeld', args())));
  const trek = () => run(async () => {
    if (isNaN(prijsCent)) throw new Error('Vul een geldig bedrag in, bijvoorbeeld 10 of 7,50');
    const u = await rpc<Uitslag>('loterij_trekken', { ...args(), p_prijs_cent: prijsCent, p_omschrijving: omschrijving.trim() || null });
    setZeker(false);
    setUitslag(u);
    void laadLijst();
  });

  return (
    <>
      <p className="mu">Trek een winnende barkaart. Bij Trouwe bezoeker en Iedereen gelijk telt komen, niet wat iemand drinkt. Elke trekking wordt bewaard en komt in het logboek.</p>

      <label>Periode</label>
      <div className="chips small">
        {perioden.map((p) => <button key={p.naam} className={p.van === van && p.tot === tot ? 'on' : ''} onClick={() => { setVan(p.van); setTot(p.tot); }}>{p.naam}</button>)}
      </div>
      <div className="inl">
        <input className="f" type="date" aria-label="Van" value={van} onChange={(e) => setVan(e.target.value)} />
        <input className="f" type="date" aria-label="Tot en met" value={tot} onChange={(e) => setTot(e.target.value)} />
      </div>

      <label>Wie krijgt meer kans?</label>
      {manieren.map((m) => (
        <label key={m.id} className="check">
          <input type="radio" name="manier" checked={manier === m.id} onChange={() => setManier(m.id)} />
          <span>{m.naam}<br /><span className="mu">{m.uitleg}</span></span>
        </label>
      ))}
      {manier !== 'gelijk' && (
        <label>Hoogstens zoveel loten per kaart<input className="f" inputMode="numeric" value={max} onChange={(e) => setMax(e.target.value)} /></label>
      )}
      <label>Kaarten die niet meedoen <span className="mu">(nummers, bijv. van jeugdleden of de bar zelf)</span>
        <input className="f" value={uit} onChange={(e) => setUit(e.target.value)} placeholder="Bijv. 12, 40, 41" />
      </label>

      <label>Prijs als tegoed op de kaart <span className="mu">(mag leeg)</span>
        <input className="f" inputMode="decimal" value={prijs} onChange={(e) => setPrijs(e.target.value)} placeholder="Bijv. 10" />
      </label>
      <label>Wat is de prijs? <span className="mu">(mag leeg)</span>
        <input className="f" maxLength={80} value={omschrijving} onChange={(e) => setOmschrijving(e.target.value)} placeholder="Bijv. Gratis rondje, Clubsjaal" />
      </label>

      <button className="big alt" disabled={bezig} onClick={bekijk}>Wie doen er mee?</button>

      {vb && (
        <div className="card" style={{ marginTop: 12 }}>
          <div className="hd"><span>{vb.deelnemers} {vb.deelnemers === 1 ? 'kaart doet' : 'kaarten doen'} mee</span><span>{vb.loten} loten</span></div>
          {vb.lijst.slice(0, 10).map((k) => (
            <Rij key={k.nummer} l={`Kaart ${k.nummer}${k.naam ? ` · ${k.naam}` : ''}`} r={`${k.loten} ${k.loten === 1 ? 'lot' : 'loten'} · ${(Math.round((k.loten / vb.loten) * 1000) / 10).toLocaleString('nl-NL')}%`} />
          ))}
          {vb.lijst.length > 10 && <p className="mu">En nog {vb.lijst.length - 10} {vb.lijst.length - 10 === 1 ? 'andere kaart' : 'andere kaarten'}.</p>}
          {vb.deelnemers > 0 && !zeker && <button className="big" disabled={bezig} onClick={() => setZeker(true)}>Trekking starten</button>}
          {zeker && (
            <div className="card warnbox" style={{ marginTop: 10 }}>
              <p style={{ margin: '0 0 6px' }}>De trekking is definitief en komt in het logboek.{prijsCent > 0 && !isNaN(prijsCent) ? ` Er komt ${eur(prijsCent)} tegoed op de winnende kaart.` : ''}</p>
              <div className="btns">
                <button onClick={() => setZeker(false)}>Nog niet</button>
                <button className="big" disabled={bezig} onClick={trek}>Ja, trekken</button>
              </div>
            </div>
          )}
        </div>
      )}

      {lijst.length > 0 && (
        <>
          <h3 className="s">Eerdere trekkingen</h3>
          {lijst.map((t) => (
            <Rij key={t.id} l={`${datum(t.ts)} · Kaart ${t.winnaar_nummer} (${t.winnaar_loten} van ${t.loten} loten, ${manierNaam(t.manier)})`}
              r={t.prijs_cent ? eur(t.prijs_cent) : (t.omschrijving ?? '')} />
          ))}
          <p className="mu">Samen {eur(lijst.reduce((a, t) => a + t.prijs_cent, 0))} aan tegoed uitgedeeld. Dat staat ook in het rapport.</p>
        </>
      )}

      {uitslag && <Trekscherm u={uitslag} sluit={() => { setUitslag(null); melding('Trekking bewaard'); }} />}
    </>
  );
}

/** De trekking op het hele scherm: nummers rollen langs en stoppen op de winnaar. */
function Trekscherm({ u, sluit }: { u: Uitslag; sluit: () => void }) {
  const rustig = typeof matchMedia === 'function' && matchMedia('(prefers-reduced-motion: reduce)').matches;
  const [nr, setNr] = useState<number | null>(rustig ? u.nummer : null);
  // Pas klaar na het laatste tikje: het winnende nummer kan onderweg ook langskomen.
  const [klaar, setKlaar] = useState(rustig);
  useEffect(() => {
    if (rustig) return;
    const reeks = u.nummers.length ? u.nummers : [u.nummer];
    let stap = 0, t = 0;
    const tik = () => {
      stap++;
      if (stap >= 28) { setNr(u.nummer); setKlaar(true); return; }
      setNr(reeks[stap % reeks.length]);
      t = window.setTimeout(tik, 60 + stap * stap * 0.6); // steeds langzamer
    };
    t = window.setTimeout(tik, 60);
    return () => clearTimeout(t);
  }, [u, rustig]);
  return (
    <div className={'recap ' + (klaar ? 'zon' : 'inkt')} role="dialog" aria-label="Trekking">
      <div className="recap-knoppen">
        <button onClick={() => void document.documentElement.requestFullscreen?.().catch(() => {})}>Groot scherm</button>
        <button onClick={sluit} aria-label="Sluiten">✕</button>
      </div>
      <div className="recap-dia" style={{ cursor: 'default' }}>
        <p className="rc-klein">{klaar ? 'En de winnaar is' : 'De trekking…'}</p>
        <h1 className="rc-getal" aria-live="polite">Kaart {nr ?? '…'}</h1>
        {klaar && <>
          {u.naam && <p className="rc-groot">{u.naam}</p>}
          <p className="rc-tekst">{u.omschrijving ?? 'Gefeliciteerd!'}</p>
          {u.prijs_cent > 0 && <p className="rc-tekst">{eur(u.prijs_cent)} staat al op de kaart.</p>}
          <p className="rc-klein">{u.loten} van de {u.totaal} loten · {u.deelnemers} kaarten deden mee</p>
        </>}
      </div>
    </div>
  );
}
