import { useCallback, useEffect, useRef, useState } from 'react';
import { datumTijd, eur, kaartCode, lidCode, methodeNaam, rpc, vertaal } from '../lib';
import { Rij, Scanner, useBezig } from '../ui';

interface KaartSaldo {
  nummer: number; naam: string | null; saldo_cent: number; geblokkeerd: boolean; winkel: string;
  historie: { ts: string; bedrag_cent: number; soort: string }[];
}
// De server geeft een fout terug als {"fout": "..."} (zodat mislukte pogingen geteld blijven).
async function zonderFout<T>(p: Promise<T | { fout: string }>): Promise<T> {
  const r = await p;
  if (r && typeof r === 'object' && 'fout' in r) throw new Error(vertaal(r.fout));
  return r as T;
}
const saldoVan = (code: string) => zonderFout(rpc<KaartSaldo | { fout: string }>('kaart_saldo', { p_code: code }));

interface LidStand {
  naam: string; open_cent: number; maand_cent: number; winkel: string;
  regels: { ts: string; soort: 'streep' | 'afbetaald'; bedrag_cent: number; bonnummer: number | null; door_naam: string | null; wat: string | null }[];
}
const lidVan = (code: string) => zonderFout(rpc<LidStand | { fout: string }>('lid_overzicht', { p_code: code }));

const soortNaam: Record<string, string> = { opwaardering: 'Opgewaardeerd', betaling: 'Betaald', annulering: 'Teruggezet', overzetting: 'Overgezet', vervallen: 'Vervallen', prijs: 'Gewonnen (loterij)' };

/** Saldo-pagina voor klanten: geopend via de QR-code op de kaart, zonder inloggen. Alleen bekijken. */
export function Saldo({ start }: { start: string }) {
  const [code, setCode] = useState(start);
  const [invoer, setInvoer] = useState('');
  const [k, setK] = useState<KaartSaldo | null>(null);
  const [fout, setFout] = useState('');
  const [bezig, run] = useBezig();
  const laad = useCallback((c: string) => run(async () => {
    try {
      setK(await saldoVan(c));
      setFout('');
    } catch (e) { setK(null); setFout((e as Error).message); }
  }), [run]);
  useEffect(() => { if (code) void laad(code); }, [code, laad]);
  const zoek = () => {
    const c = kaartCode(invoer);
    if (!c) return;
    // In de adresbalk zetten, zodat de pagina als bladwijzer bewaard kan worden.
    history.replaceState(null, '', location.pathname.replace(/saldo\/?$/, '') + '?saldo=' + encodeURIComponent(c));
    setCode(c);
  };

  return (
    <div className="login saldo">
      {k ? (
        <>
          <p className="mu">{k.winkel} · Tegoedkaart</p>
          <h1>Kaart {k.nummer}{k.naam ? <span className="mu"> · {k.naam}</span> : null}</h1>
          <div className="big-n">{eur(k.saldo_cent)}</div>
          {k.geblokkeerd && <p className="stamp">GEBLOKKEERD</p>}
          <p className="mu c">{k.geblokkeerd ? 'Deze kaart is geblokkeerd. Vraag aan de bar wat er kan.' : 'Opwaarderen doe je aan de bar.'}</p>
          <button className="big alt" disabled={bezig} onClick={() => void laad(code)}>Vernieuwen</button>
          {k.historie.length > 0 && <h3 className="s">Laatste keren</h3>}
          <div className="card">
            {k.historie.map((h, i) => (
              <Rij key={i} l={<>{soortNaam[h.soort] ?? h.soort}<br /><span className="mu">{datumTijd(h.ts)}</span></>}
                r={(h.bedrag_cent > 0 ? '+' : '') + eur(h.bedrag_cent)} />
            ))}
            {!k.historie.length && <p className="mu">Nog niets gebeurd met deze kaart.</p>}
          </div>
          <p className="mu">Tip: bewaar deze pagina als bladwijzer of zet hem op je beginscherm, dan zie je je saldo met één tik.</p>
        </>
      ) : (
        <>
          <h1>Saldo bekijken</h1>
          <p className="mu">Scan de QR-code op je tegoedkaart met de camera van je telefoon, of typ de code die onder de QR-code staat.</p>
          {fout && <p className="card warnbox">{fout}</p>}
          <label htmlFor="sc">Code van je kaart</label>
          <form className="inl" onSubmit={(e) => { e.preventDefault(); zoek(); }}>
            <input className="f" id="sc" value={invoer} autoCapitalize="characters" autoComplete="off" placeholder="ABCD-EFGH" onChange={(e) => setInvoer(e.target.value)} />
            <button disabled={bezig}>Bekijk</button>
          </form>
          {bezig && <p className="mu">Laden…</p>}
        </>
      )}
      <p className="mu c"><a href={location.pathname.replace(/saldo\/?$/, '')}>Medewerker? Naar de kassa</a></p>
    </div>
  );
}

const TOON_SECONDEN = 10;

/**
 * Saldo-zuil: een oude telefoon of tablet aan de muur (of een scherm met een
 * USB-scanner). Klanten houden hun kaart voor de camera en zien even hun saldo;
 * daarna staat de zuil vanzelf weer klaar. Geen inloggen, alleen bekijken.
 */
export function SaldoZuil() {
  const [k, setK] = useState<KaartSaldo | null>(null);
  const [lid, setLid] = useState<LidStand | null>(null);
  const [fout, setFout] = useState('');
  const [over, setOver] = useState(0);
  const [voorkant, setVoorkant] = useState(() => { try { return localStorage.getItem('zuil-camera') !== 'achter'; } catch { return true; } });
  const bezig = useRef(false);

  const toon = useCallback(async (invoer: string) => {
    const lc = lidCode(invoer);
    const c = lc ?? kaartCode(invoer);
    if (!c || bezig.current) return;
    bezig.current = true;
    try {
      if (lc) { setLid(await lidVan(lc)); setK(null); } else { setK(await saldoVan(c)); setLid(null); }
      setFout('');
    } catch (e) {
      setK(null); setLid(null);
      setFout((e as Error).message);
    } finally {
      bezig.current = false;
      setOver(TOON_SECONDEN);
    }
  }, []);

  // Aftellen, daarna terug naar "houd je kaart voor de camera".
  useEffect(() => {
    if (!over) return;
    const t = setTimeout(() => { if (over === 1) { setK(null); setLid(null); setFout(''); } setOver(over - 1); }, 1000);
    return () => clearTimeout(t);
  }, [over]);

  // Een USB-scanner typt de code en drukt op Enter.
  useEffect(() => {
    let buf = '', tijd = 0;
    const toets = (e: KeyboardEvent) => {
      if (Date.now() - tijd > 300) buf = '';
      tijd = Date.now();
      if (e.key === 'Enter') { if (buf.length >= 8) void toon(buf); buf = ''; }
      else if (e.key.length === 1) buf += e.key;
    };
    window.addEventListener('keydown', toets);
    return () => window.removeEventListener('keydown', toets);
  }, [toon]);

  // Scherm niet op slot laten gaan (waar de browser dat toestaat).
  useEffect(() => {
    type Slot = { release: () => Promise<void> };
    const wl = (navigator as unknown as { wakeLock?: { request: (t: 'screen') => Promise<Slot> } }).wakeLock;
    let slot: Slot | null = null;
    const vraag = () => { if (wl && document.visibilityState === 'visible') wl.request('screen').then((s) => (slot = s), () => {}); };
    vraag();
    document.addEventListener('visibilitychange', vraag);
    return () => { document.removeEventListener('visibilitychange', vraag); void slot?.release(); };
  }, []);

  const wissel = () => {
    const v = !voorkant;
    setVoorkant(v);
    try { localStorage.setItem('zuil-camera', v ? 'voor' : 'achter'); } catch { /* geen opslag */ }
  };

  return (
    <div className="zuil">
      {k || lid || fout ? (
        <div className="zuil-uitkomst" onClick={() => setOver(1)}>
          {lid ? (
            <>
              <p className="mu">Streeplijst van {lid.naam}</p>
              <div className="zuil-saldo">{eur(lid.open_cent)}</div>
              <p className="mu">{lid.open_cent > 0 ? 'staat nog open' : 'Alles is betaald.'}{lid.maand_cent ? ` · deze maand ${eur(lid.maand_cent)} gestreept` : ''}</p>
              {lid.regels.slice(0, 3).map((r, i) => (
                <Rij key={i} l={<>{r.soort === 'streep' ? r.wat : 'Afbetaald'} <span className="mu">{datumTijd(r.ts)}</span></>} r={(r.soort === 'streep' ? '' : '− ') + eur(r.bedrag_cent)} />
              ))}
            </>
          ) : k ? (
            <>
              <p className="mu">Kaart {k.nummer}</p>
              <div className="zuil-saldo">{eur(k.saldo_cent)}</div>
              {k.geblokkeerd ? <p className="stamp">GEBLOKKEERD</p> : <p className="mu">Opwaarderen doe je aan de bar.</p>}
              {k.historie.slice(0, 3).map((h, i) => (
                <Rij key={i} l={<>{soortNaam[h.soort] ?? h.soort} <span className="mu">{datumTijd(h.ts)}</span></>} r={(h.bedrag_cent > 0 ? '+' : '') + eur(h.bedrag_cent)} />
              ))}
            </>
          ) : <p className="card warnbox">{fout}</p>}
          <p className="mu c">Over {over} seconden weer klaar</p>
        </div>
      ) : (
        <>
          <h1>Saldo bekijken</h1>
          <p className="zuil-uitleg">Houd de QR-code van je kaart of je streeplijst voor de camera</p>
          <Scanner key={String(voorkant)} voorkant={voorkant} zonderCamera="Camera niet beschikbaar. Geef de browser toestemming voor de camera, of sluit een USB-scanner aan." onCode={(c) => void toon(c)} />
          <button className="ghost" onClick={wissel}>Andere camera</button>
        </>
      )}
    </div>
  );
}

/** Eigen streeplijst van een lid: geopend via de persoonlijke QR-code, zonder inloggen. Alleen bekijken. */
export function LidOverzicht({ code }: { code: string }) {
  const [l, setL] = useState<LidStand | null>(null);
  const [fout, setFout] = useState('');
  const [bezig, run] = useBezig();
  const laad = useCallback(() => run(async () => {
    try { setL(await lidVan(code)); setFout(''); } catch (e) { setFout((e as Error).message); }
  }), [code, run]);
  useEffect(() => { void laad(); }, [laad]);
  return (
    <div className="login saldo">
      {fout && <><h1>Streeplijst</h1><p className="card warnbox">{fout}</p></>}
      {!l && !fout && <p className="mu">Laden…</p>}
      {l && (
        <>
          <p className="mu">{l.winkel} · Streeplijst</p>
          <h1>{l.naam}</h1>
          <p className="mu c">Staat nog open</p>
          <div className="big-n">{eur(l.open_cent)}</div>
          <p className="mu c">{l.maand_cent ? `Deze maand ${eur(l.maand_cent)} gestreept. ` : ''}Afrekenen doe je aan de bar.</p>
          <button className="big alt" disabled={bezig} onClick={() => void laad()}>Vernieuwen</button>
          <h3 className="s">Wat er op je lijst staat</h3>
          <div className="card">
            {l.regels.map((r, i) => (
              <Rij key={i}
                l={<>{r.soort === 'streep' ? r.wat : `Afbetaald (${methodeNaam[r.wat ?? ''] ?? r.wat})`}<br />
                  <span className="mu">{datumTijd(r.ts)}{r.bonnummer ? ` · bon ${r.bonnummer}` : ''}{r.door_naam ? ` · ingeschonken door ${r.door_naam}` : ''}</span></>}
                r={(r.soort === 'streep' ? '' : '− ') + eur(r.bedrag_cent)} />
            ))}
            {!l.regels.length && <p className="mu">Nog niets gestreept.</p>}
          </div>
          <p className="mu">Klopt er iets niet? Meld het aan de bar of bij het bestuur. Bewaar deze pagina als bladwijzer; deel de link niet, want wie hem heeft kan je lijst zien.</p>
        </>
      )}
    </div>
  );
}
