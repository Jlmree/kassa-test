import { useCallback, useEffect, useState } from 'react';
import { datumTijd, eur, kaartCode, rpc } from '../lib';
import { Rij, useBezig } from '../ui';

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
