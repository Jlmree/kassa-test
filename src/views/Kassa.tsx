import { createContext, useContext, useMemo, useState } from 'react';
import { useData } from '../data';
import { datumTijd, eur, rpc, totaal, type Product } from '../lib';
import { melding, Rij, useBezig, useSheet } from '../ui';
import { Afrekenen } from './Afrekenen';
import { teLangOpen } from './Dienst';

export type Mand = Record<number, number>;

// De bestelling in aanbouw, plus (optioneel) de rekening waarvoor besteld wordt.
interface MandCtx { mand: Mand; setMand: (m: Mand) => void; doel: number | null; setDoel: (id: number | null) => void }
export const MandContext = createContext<MandCtx>(null!);
export const useMand = () => useContext(MandContext);

export function Kassa({ naarDienst }: { naarDienst: () => void }) {
  const { mand, setMand, doel, setDoel } = useMand();
  const { producten, rekeningen, dienst } = useData();
  const zichtbaar = producten.filter((p) => p.actief);
  const cats = [...new Set(zichtbaar.map((p) => p.categorie))];
  // '' = Alles: alle producten, gegroepeerd per categorie.
  const [cat, setCat] = useState('');
  const huidig = cats.includes(cat) ? cat : '';
  const rek = doel != null ? rekeningen.find((r) => r.id === doel) : undefined;
  const tegels = (lijst: Product[]) => (
    <div className="grid">
      {lijst.map((p) => (
        <button key={p.id} className={'tile' + (p.voorraad_bijhouden && p.voorraad <= 0 ? ' op' : '')}
          onClick={() => { if (kanErbij(p, mand[p.id] ?? 0)) setMand({ ...mand, [p.id]: (mand[p.id] ?? 0) + 1 }); }}>
          <span className="nm">{p.naam}</span>
          <span className="pr">{eur(p.prijs_cent)}{p.voorraad_bijhouden && <Voorraad p={p} />}</span>
          {mand[p.id] ? <i className="bd">{mand[p.id]}</i> : null}
        </button>
      ))}
    </div>
  );

  return (
    <>
      {!dienst && !rek && (
        <button className="banner" onClick={naarDienst}><span>De kassa is nog dicht</span><b>Openen</b></button>
      )}
      {teLangOpen(dienst) && !rek && (
        <button className="banner" onClick={naarDienst}><span>De kassa staat al open sinds {datumTijd(dienst!.geopend_ts)}</span><b>Eerst sluiten</b></button>
      )}
      {rek && (
        <div className="banner"><span>Bestelling voor {rek.naam}</span><button onClick={() => { setDoel(null); setMand({}); }}>Stoppen</button></div>
      )}
      {cats.length > 1 && (
        <div className="chips">
          <button className={huidig === '' ? 'on' : ''} onClick={() => setCat('')}>Alles</button>
          {cats.map((c) => <button key={c} className={c === huidig ? 'on' : ''} onClick={() => setCat(c)}>{c}</button>)}
        </div>
      )}
      {huidig !== '' ? tegels(zichtbaar.filter((p) => p.categorie === huidig))
        : cats.length > 1 ? cats.map((c) => (
          <section key={c}>
            <h3 className="cat">{c}</h3>
            {tegels(zichtbaar.filter((p) => p.categorie === c))}
          </section>
        ))
        : tegels(zichtbaar)}
      {!zichtbaar.length && <p className="mu">Nog geen producten. Een beheerder kan ze toevoegen bij Beheer → Producten.</p>}
    </>
  );
}

// Niet meer aantikken dan er op voorraad is (de database controleert het ook).
function kanErbij(p: Product, inMand: number) {
  if (!p.voorraad_bijhouden || inMand < p.voorraad) return true;
  melding((p.voorraad <= 0 ? `${p.naam} is op.` : `Er ${p.voorraad === 1 ? 'is' : 'zijn'} nog maar ${p.voorraad} ${p.naam} op voorraad.`)
    + ' Net geleverd? Boek het in bij Dienst → Levering inboeken.');
  return false;
}

function Voorraad({ p }: { p: Product }) {
  const laag = p.voorraad <= p.voorraad_min;
  return <span className={'stock' + (laag ? ' laag' : '')}> · {p.voorraad <= 0 ? 'op' : `${p.voorraad} over`}</span>;
}

export function mandRegels(mand: Mand, producten: Product[]) {
  return Object.entries(mand).flatMap(([id, aantal]) => {
    const p = producten.find((x) => x.id === +id);
    return p ? [{ ...p, aantal }] : [];
  });
}

export function MandBalk({ onOpen }: { onOpen: () => void }) {
  const { producten } = useData();
  const { mand } = useMand();
  const r = mandRegels(mand, producten);
  if (!r.length) return null;
  const n = r.reduce((a, x) => a + x.aantal, 0);
  return (
    <div className="cartbar">
      <button className="cart" onClick={onOpen}>
        <span>{n} {n > 1 ? 'artikelen' : 'artikel'}</span><b>{eur(totaal(r))}</b><span>Bestelling ›</span>
      </button>
    </div>
  );
}

/** Onderblad met de bestelling en de betaalknoppen. */
export function Bestelling() {
  const { mand, setMand, doel, setDoel } = useMand();
  const { producten, rekeningen, dienst, methoden, herlaad } = useData();
  const { open, sluit } = useSheet();
  const [bezig, run] = useBezig();
  const regels = useMemo(() => mandRegels(mand, producten), [mand, producten]);
  const rek = doel != null ? rekeningen.find((r) => r.id === doel) : undefined;
  if (!regels.length) return <><h2>Bestelling</h2><p className="mu">De bestelling is leeg.</p></>;
  const som = totaal(regels);
  const zet = (id: number, d: number) => {
    const p = producten.find((x) => x.id === id);
    if (d > 0 && p && !kanErbij(p, mand[id] ?? 0)) return;
    const m = { ...mand, [id]: (mand[id] ?? 0) + d };
    if (m[id] <= 0) delete m[id];
    setMand(m);
  };
  const leeg = () => { setMand({}); setDoel(null); };
  const opRekening = (id: number, naam: string) => run(async () => {
    await rpc('rekening_toevoegen', { p_rekening_id: id, p_regels: regels.map((r) => ({ product_id: r.id, aantal: r.aantal })) });
    leeg();
    sluit();
    void herlaad();
    melding(`Op rekening van ${naam}`);
  });
  const betaal = (methode: 'contant' | 'pin' | 'kaart') => open(
    <Afrekenen bron={{ soort: 'bestelling', regels: regels.map((r) => ({ product_id: r.id, aantal: r.aantal })) }} totaal={som} methode={methode} onKlaar={leeg} />,
  );

  return (
    <>
      <h2>Bestelling</h2>
      {rek && <p className="mu">Voor de rekening van {rek.naam}</p>}
      {regels.map((r) => (
        <div className="row" key={r.id}>
          <span>{r.naam}</span>
          <span className="qty">
            <button aria-label="Minder" onClick={() => zet(r.id, -1)}>−</button><b>{r.aantal}</b>
            <button aria-label="Meer" onClick={() => zet(r.id, 1)}>+</button>
          </span>
          <span className="rt">{eur(r.prijs_cent * r.aantal)}</span>
        </div>
      ))}
      <Rij l={<b>Totaal</b>} r={eur(som)} sterk />
      {rek ? (
        <button className="big" disabled={bezig} onClick={() => opRekening(rek.id, rek.naam)}>Zet op rekening van {rek.naam}</button>
      ) : !dienst ? (
        <p className="warnbox card">Open eerst de kassa (tabblad Dienst) om af te rekenen.</p>
      ) : (
        <div className="btns">
          {methoden.contant && <button className="big m-cash" onClick={() => betaal('contant')}>Contant</button>}
          {methoden.pin && <button className="big m-pin" onClick={() => betaal('pin')}>Pin</button>}
          {methoden.kaart && <button className="big m-card" onClick={() => betaal('kaart')}>Kaart</button>}
          {methoden.rekening && <button className="big m-tab" onClick={() => open(<KiesRekening onKies={opRekening} />)}>Op rekening</button>}
        </div>
      )}
      <button className="ghost" onClick={() => { leeg(); sluit(); }}>Bestelling wissen</button>
    </>
  );
}

function KiesRekening({ onKies }: { onKies: (id: number, naam: string) => void }) {
  const { rekeningen, regels } = useData();
  const [naam, setNaam] = useState('');
  const [bezig, run] = useBezig();
  const nieuw = () => run(async () => {
    const n = naam.trim();
    if (!n) throw new Error('Vul eerst een naam in');
    const id = await rpc<number>('rekening_maken', { p_naam: n });
    onKies(id, n);
  });
  return (
    <>
      <h2>Op rekening</h2>
      {rekeningen.map((r) => (
        <Rij key={r.id} l={r.naam} r={eur(totaal(regels.filter((x) => x.rekening_id === r.id)))} onClick={() => onKies(r.id, r.naam)} />
      ))}
      <label htmlFor="nr">{rekeningen.length ? 'Of een nieuwe rekening' : 'Naam voor een nieuwe rekening'}</label>
      <form className="inl" onSubmit={(e) => { e.preventDefault(); void nieuw(); }}>
        <input className="f" id="nr" placeholder="Naam" value={naam} onChange={(e) => setNaam(e.target.value)} />
        <button disabled={bezig}>Maak aan</button>
      </form>
    </>
  );
}
