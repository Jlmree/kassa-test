import { useEffect, useState } from 'react';
import { rpc, vertaal, type Bon } from '../lib';
import { BonPapier, deelBon, useBonBeeld } from '../ui';

/** De bon voor de klant: geopend via de QR-code na het afrekenen, zonder inloggen. Alleen bekijken. */
export function BonKlant({ code }: { code: string }) {
  const [bon, setBon] = useState<Bon | null>(null);
  const [fout, setFout] = useState('');
  useEffect(() => {
    rpc<Bon | { fout: string }>('bon_bekijken', { p_code: code })
      .then((r) => { if ('fout' in r) setFout(vertaal(r.fout)); else setBon(r); })
      .catch((e: Error) => setFout(vertaal(e.message)));
  }, [code]);
  return (
    <div className="login saldo">
      {bon ? <BonGetoond bon={bon} /> : fout ? <p className="card warnbox">{fout}</p> : <p className="mu c">Bon laden…</p>}
    </div>
  );
}

function BonGetoond({ bon }: { bon: Bon }) {
  const beeld = useBonBeeld(bon);
  return (
    <>
      <p className="mu c">Je bon van {bon.winkel}</p>
      <BonPapier bon={bon} />
      <button className="big" onClick={() => void deelBon(bon, beeld)}>Bewaren of delen</button>
      <p className="mu c">Bewaar hem als foto, of stuur hem door. Deze link werkt 90 dagen.</p>
    </>
  );
}
