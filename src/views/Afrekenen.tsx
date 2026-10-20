import { useState } from 'react';
import { useData } from '../data';
import { centTekst, eur, naarCent, nieuweSleutel, rpc, type Bon, type KaartInfo, type Regel } from '../lib';
import { Bedrag, BonPapier, deelBon, melding, Rij, Scanner, useBezig, useSheet } from '../ui';

export type Bron = { soort: 'bestelling'; regels: Regel[] } | { soort: 'rekening'; id: number };
type Methode = 'contant' | 'pin' | 'kaart';

/** Betaalscherm voor een bestelling of een rekening. */
export function Afrekenen({ bron, totaal, methode, onKlaar }: { bron: Bron; totaal: number; methode: Methode; onKlaar: () => void }) {
  const { herlaad } = useData();
  const { open } = useSheet();
  const [stap, setStap] = useState<Methode>(methode);
  const [kaart, setKaart] = useState<{ code: string; info: KaartInfo } | null>(null);
  const [bezig, run] = useBezig();
  // Eén kenmerk per betaalscherm: een tweede poging na een verbindingsfout boekt niet dubbel.
  const [sleutel] = useState(nieuweSleutel);

  const vanKaart = kaart ? Math.min(kaart.info.saldo_cent, totaal) : 0;
  const rest = totaal - vanKaart;

  const betaal = (rest?: { methode: 'contant' | 'pin'; gegeven_cent?: number }) => run(async () => {
    const betalingen: Record<string, unknown>[] = [];
    if (kaart) betalingen.push({ methode: 'kaart', kaart: kaart.code });
    if (rest) betalingen.push(rest);
    const bon = await rpc<Bon>('afrekenen', {
      p_regels: bron.soort === 'bestelling' ? bron.regels : [],
      p_betalingen: betalingen,
      p_rekening_id: bron.soort === 'rekening' ? bron.id : null,
      // Het bedrag dat hier stond: is het intussen veranderd, dan weigert de kassa.
      p_verwacht_cent: totaal,
      p_sleutel: sleutel,
    });
    onKlaar();
    void herlaad();
    open(<BonScherm bon={bon} nieuw />);
  });

  if (stap === 'kaart' && !kaart) return <KaartKiezen totaal={totaal} onKaart={(code, info) => setKaart({ code, info })} />;

  return (
    <>
      {kaart && (
        <>
          <h2>Kaart {kaart.info.nummer}{kaart.info.naam ? ` · ${kaart.info.naam}` : ''}</h2>
          <Rij l="Saldo" r={eur(kaart.info.saldo_cent)} />
          <Rij l="Te betalen" r={eur(totaal)} />
          <Rij l="Van de kaart" r={eur(vanKaart)} sterk />
          {rest > 0 && <Rij l="Nog te betalen" r={eur(rest)} sterk />}
        </>
      )}
      {stap === 'kaart' && kaart && (rest === 0
        ? <button className="big m-card" disabled={bezig} onClick={() => betaal()}>Afschrijven</button>
        : <div className="btns">
            <button className="big m-cash" onClick={() => setStap('contant')}>Rest contant</button>
            <button className="big m-pin" disabled={bezig} onClick={() => setStap('pin')}>Rest pin</button>
          </div>)}
      {stap === 'contant' && <Contant bedrag={rest} bezig={bezig} onBetaal={(g) => betaal({ methode: 'contant', gegeven_cent: g })} />}
      {stap === 'pin' && (
        <>
          {!kaart && <h2>Pin</h2>}
          <div className="big-n">{eur(rest)}</div>
          <p className="mu c">Laat de klant pinnen en tik daarna op afronden.</p>
          <button className="big m-pin" disabled={bezig} onClick={() => betaal({ methode: 'pin' })}>Pin gelukt, afronden</button>
        </>
      )}
    </>
  );
}

function Contant({ bedrag, bezig, onBetaal }: { bedrag: number; bezig: boolean; onBetaal: (gegeven: number) => void }) {
  const [v, setV] = useState('');
  const g = v ? naarCent(v) : bedrag;
  const snel = [...new Set([bedrag, ...[500, 1000, 2000, 5000].filter((x) => x > bedrag)])].slice(0, 5);
  return (
    <>
      <h2>Contant</h2>
      <div className="big-n">{eur(bedrag)}</div>
      <div className="quick">
        {snel.map((x) => <button key={x} onClick={() => setV(centTekst(x))}>{x === bedrag ? 'Gepast' : eur(x)}</button>)}
      </div>
      <label htmlFor="gegeven">Gegeven bedrag</label>
      <Bedrag id="gegeven" waarde={v} onChange={setV} />
      <div className="chg">{!v ? '' : isNaN(g) ? 'Ongeldig bedrag' : g >= bedrag ? `Wisselgeld: ${eur(g - bedrag)}` : `Nog ${eur(bedrag - g)} tekort`}</div>
      <button className="big m-cash" disabled={bezig || isNaN(g) || g < bedrag} onClick={() => onBetaal(g)}>Afronden</button>
    </>
  );
}

/** Kaart scannen of code typen; alleen een echte kaartcode is genoeg om te betalen. */
export function KaartKiezen({ totaal, onKaart, betalen = true }: { totaal?: number; onKaart: (code: string, info: KaartInfo) => void; betalen?: boolean }) {
  const [code, setCode] = useState('');
  const [bezig, run] = useBezig();
  const zoek = (c: string) => run(async () => {
    const info = await rpc<KaartInfo>('kaart_info', { p_zoek: c });
    if (betalen && !info.betaalcode) throw new Error('Scan de QR-code of typ de kaartcode (het kaartnummer is niet genoeg om te betalen)');
    if (info.geblokkeerd && betalen) throw new Error(`Kaart ${info.nummer} is geblokkeerd`);
    if (betalen && info.saldo_cent <= 0) throw new Error(`Er staat geen tegoed op kaart ${info.nummer}`);
    onKaart(c, info);
  });
  return (
    <>
      <h2>{betalen ? 'Betalen met kaart' : 'Kaart zoeken'}</h2>
      {totaal != null && <p className="mu">Te betalen: {eur(totaal)}</p>}
      <Scanner onCode={(c) => { setCode(c); void zoek(c); }} />
      <label htmlFor="kc">{betalen ? 'Of typ de kaartcode' : 'Of typ de kaartcode of het kaartnummer'}</label>
      <form className="inl" onSubmit={(e) => { e.preventDefault(); if (code.trim()) void zoek(code); }}>
        <input className="f" id="kc" value={code} autoCapitalize="characters" autoComplete="off" placeholder={betalen ? 'ABCD-EFGH' : 'ABCD-EFGH of 12'} onChange={(e) => setCode(e.target.value)} />
        <button disabled={bezig}>OK</button>
      </form>
    </>
  );
}

export function BonScherm({ bon: start, nieuw }: { bon: Bon; nieuw?: boolean }) {
  const { sluit } = useSheet();
  const { herlaad, profiel } = useData();
  const [bon, setBon] = useState(start);
  const [bezig, run] = useBezig();
  const [zeker, setZeker] = useState(false);
  const annuleren = () => run(async () => {
    const b = await rpc<Bon>('verkoop_annuleren', { p_verkoop_id: bon.id });
    setBon(b);
    void herlaad();
    melding('Bon geannuleerd');
  });
  const magAnnuleren = !bon.geannuleerd && (profiel.rol === 'beheerder' || (bon.door_naam === profiel.naam && Date.now() - +new Date(bon.ts) < 15 * 60e3));
  return (
    <>
      <BonPapier bon={bon} />
      <div className="btns">
        <button onClick={() => deelBon(bon)}>Delen</button>
        <button onClick={() => window.print()}>Printen of PDF</button>
      </div>
      {nieuw && <button className="big" onClick={sluit}>Nieuwe bestelling</button>}
      {magAnnuleren && !zeker && <button className="ghost" onClick={() => setZeker(true)}>Bon annuleren</button>}
      {magAnnuleren && zeker && (
        <div className="card warnbox">
          <p>Weet je het zeker? Voorraad en kaarttegoed worden teruggezet. Contant geld geef je zelf terug.</p>
          <div className="btns">
            <button onClick={() => setZeker(false)}>Nee</button>
            <button className="big warn" disabled={bezig} onClick={annuleren}>Ja, annuleren</button>
          </div>
        </div>
      )}
      {!nieuw && <button className="ghost" onClick={sluit}>Sluiten</button>}
    </>
  );
}
