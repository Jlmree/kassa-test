import { useCallback, useEffect, useRef, useState } from 'react';
import { datumTijd, eur, kaartCode, rpc } from '../lib';
import { Rij, Scanner, useBezig } from '../ui';

interface KaartSaldo {
  nummer: number; naam: string | null; saldo_cent: number; geblokkeerd: boolean; winkel: string;
  historie: { ts: string; bedrag_cent: number; soort: string }[];
}
const soortNaam: Record<string, string> = { opwaardering: 'Opgewaardeerd', betaling: 'Betaald', annulering: 'Teruggezet', overzetting: 'Overgezet' };

/** Saldo-pagina voor klanten: geopend via de QR-code op de kaart, zonder inloggen. Alleen bekijken. */
export function Saldo({ start }: { start: string }) {
  const [code, setCode] = useState(start);
  const [invoer, setInvoer] = useState('');
  const [k, setK] = useState<KaartSaldo | null>(null);
  const [fout, setFout] = useState('');
  const [bezig, run] = useBezig();
  const laad = useCallback((c: string) => run(async () => {
    try {
      setK(await rpc<KaartSaldo>('kaart_saldo', { p_code: c }));
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
  const [fout, setFout] = useState('');
  const [over, setOver] = useState(0);
  const [voorkant, setVoorkant] = useState(() => { try { return localStorage.getItem('zuil-camera') !== 'achter'; } catch { return true; } });
  const bezig = useRef(false);

  const toon = useCallback(async (invoer: string) => {
    const c = kaartCode(invoer);
    if (!c || bezig.current) return;
    bezig.current = true;
    try {
      setK(await rpc<KaartSaldo>('kaart_saldo', { p_code: c }));
      setFout('');
    } catch (e) {
      setK(null);
      setFout((e as Error).message);
    } finally {
      bezig.current = false;
      setOver(TOON_SECONDEN);
    }
  }, []);

  // Aftellen, daarna terug naar "houd je kaart voor de camera".
  useEffect(() => {
    if (!over) return;
    const t = setTimeout(() => { if (over === 1) { setK(null); setFout(''); } setOver(over - 1); }, 1000);
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
      {k || fout ? (
        <div className="zuil-uitkomst" onClick={() => setOver(1)}>
          {k ? (
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
          <p className="zuil-uitleg">Houd de QR-code van je kaart voor de camera</p>
          <Scanner key={String(voorkant)} voorkant={voorkant} zonderCamera="Camera niet beschikbaar. Geef de browser toestemming voor de camera, of sluit een USB-scanner aan." onCode={(c) => void toon(c)} />
          <button className="ghost" onClick={wissel}>Andere camera</button>
        </>
      )}
    </div>
  );
}
