import { useState } from 'react';
import { useData } from '../data';
import { eur, rpc, tijd, totaal } from '../lib';
import { melding, Rij, useBezig, useSheet } from '../ui';
import { Afrekenen } from './Afrekenen';

export function Rekeningen({ bestelVoor }: { bestelVoor: (id: number) => void }) {
  const { rekeningen, regels, herlaad } = useData();
  const { open } = useSheet();
  const [naam, setNaam] = useState('');
  const [bezig, run] = useBezig();
  const nieuw = () => run(async () => {
    if (!naam.trim()) throw new Error('Vul eerst een naam in');
    await rpc('rekening_maken', { p_naam: naam.trim() });
    setNaam('');
    await herlaad();
  });
  return (
    <>
      <form className="inl" onSubmit={(e) => { e.preventDefault(); void nieuw(); }}>
        <input className="f" placeholder="Naam voor nieuwe rekening" value={naam} onChange={(e) => setNaam(e.target.value)} aria-label="Naam" />
        <button disabled={bezig}>Maak aan</button>
      </form>
      <div style={{ height: 12 }} />
      {rekeningen.map((r) => {
        const l = regels.filter((x) => x.rekening_id === r.id);
        return (
          <button key={r.id} className="card wide" onClick={() => open(<RekeningScherm id={r.id} bestelVoor={bestelVoor} />)}>
            <div className="hd"><span>{r.naam}</span><span>{eur(totaal(l))}</span></div>
            <span className="mu">{l.reduce((a, x) => a + x.aantal, 0)} artikelen · sinds {tijd(r.aangemaakt)}</span>
          </button>
        );
      })}
      {!rekeningen.length && <p className="mu">Geen openstaande rekeningen. Maak er een aan met een naam, of zet een bestelling op rekening.</p>}
    </>
  );
}

function RekeningScherm({ id, bestelVoor }: { id: number; bestelVoor: (id: number) => void }) {
  const { rekeningen, regels, dienst, herlaad } = useData();
  const { open, sluit } = useSheet();
  const [bezig, run] = useBezig();
  const r = rekeningen.find((x) => x.id === id);
  if (!r) return <><h2>Rekening</h2><p className="mu">Deze rekening is afgerekend of verwijderd.</p><button className="ghost" onClick={sluit}>Sluiten</button></>;
  const l = regels.filter((x) => x.rekening_id === id);
  const som = totaal(l);
  const betaal = (methode: 'contant' | 'pin' | 'kaart') => open(<Afrekenen bron={{ soort: 'rekening', id }} totaal={som} methode={methode} onKlaar={() => {}} />);
  const schrap = (regel: number) => run(async () => { await rpc('rekening_regel_verwijderen', { p_regel_id: regel }); await herlaad(); melding('Regel verwijderd'); });
  const weg = () => run(async () => { await rpc('rekening_verwijderen', { p_rekening_id: id }); await herlaad(); sluit(); });
  return (
    <>
      <h2>Rekening van {r.naam}</h2>
      {l.map((x) => (
        <div className="row" key={x.id}>
          <span>{x.aantal}× {x.naam} <span className="mu">{tijd(x.ts)}</span></span>
          <span className="rt">{eur(x.prijs_cent * x.aantal)}</span>
          <button className="x" aria-label={`${x.naam} verwijderen`} disabled={bezig} onClick={() => schrap(x.id)}>×</button>
        </div>
      ))}
      <Rij l={<b>Totaal</b>} r={eur(som)} sterk />
      <button className="big alt" onClick={() => { bestelVoor(id); sluit(); }}>Bestelling toevoegen</button>
      {l.length > 0 && (dienst ? (
        <div className="btns" style={{ marginTop: 8 }}>
          <button className="big m-cash" onClick={() => betaal('contant')}>Contant</button>
          <button className="big m-pin" onClick={() => betaal('pin')}>Pin</button>
          <button className="big m-card" onClick={() => betaal('kaart')}>Kaart</button>
        </div>
      ) : <p className="card warnbox">Open eerst de kassa (tabblad Dienst) om af te rekenen.</p>)}
      {!l.length && <button className="ghost" disabled={bezig} onClick={weg}>Lege rekening verwijderen</button>}
    </>
  );
}
