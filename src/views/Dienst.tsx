import { useCallback, useEffect, useState, type ReactNode } from 'react';
import { useData } from '../data';
import { centTekst, datumTijd, eur, lees, methodeNaam, naarCent, rpc, sb, tijd, type Bon, type Dienst as D, type Product } from '../lib';
import { Bedrag, melding, Rij, useBezig, useSheet } from '../ui';
import { BonScherm } from './Afrekenen';

export function Dienst() {
  const { dienst } = useData();
  return dienst ? <OpenDienst d={dienst} /> : <DienstOpenen />;
}

// "2 u 5 min" sinds een tijdstip.
function duur(ts: string) {
  const min = Math.max(0, Math.round((Date.now() - Date.parse(ts)) / 60000));
  return min < 60 ? `${min} min` : `${Math.floor(min / 60)} u ${min % 60} min`;
}

// Staat de kassa al meer dan 12 uur open? Dan is hij waarschijnlijk vorige keer niet gesloten.
export const teLangOpen = (d: D | null) => !!d && Date.now() - Date.parse(d.geopend_ts) > 12 * 3600e3;

// Kasverschil in woorden: klopt, tekort of over.
export function Verschil({ c }: { c: number }) {
  if (c === 0) return <span className="pill ok">Klopt</span>;
  return <span className={'pill ' + (c < 0 ? 'min' : 'plus')}>{eur(Math.abs(c))} {c < 0 ? 'tekort' : 'over'}</span>;
}

interface VorigeDienst { gesloten_ts: string | null; geteld_cent: number | null; verwacht_cent: number | null }

function DienstOpenen() {
  const { herlaad } = useData();
  const [v, setV] = useState('');
  const [vorige, setVorige] = useState<VorigeDienst | null>(null);
  const [bezig, run] = useBezig();
  useEffect(() => {
    void lees(sb.from('diensten').select('gesloten_ts,geteld_cent,verwacht_cent').order('id', { ascending: false }).limit(1))
      .then((r) => setVorige((r as VorigeDienst[])[0] ?? null), () => {});
  }, []);
  const openen = () => run(async () => {
    const c = v ? naarCent(v) : 0;
    if (isNaN(c) || c < 0) throw new Error('Ongeldig bedrag');
    await rpc('dienst_openen', { p_beginsaldo_cent: c });
    await herlaad();
    melding('De kassa is open');
  });
  return (
    <>
      <div className="hero dicht">
        <span>De kassa is dicht</span>
        <b>Kassa openen</b>
      </div>
      <div className="card">
        <label htmlFor="bs" style={{ marginTop: 0 }}>Wisselgeld in de la bij het begin</label>
        {vorige?.geteld_cent != null && (
          <div className="quick">
            <button onClick={() => setV(centTekst(vorige.geteld_cent!))}>Zelfde als vorige telling ({eur(vorige.geteld_cent)})</button>
          </div>
        )}
        <Bedrag id="bs" waarde={v} onChange={setV} />
        <p className="mu">Tel het geld in de la voordat je begint. Aan het eind tel je opnieuw, zodat je ziet of het klopt.</p>
        <button className="big" disabled={bezig} onClick={openen}>Kassa openen</button>
      </div>
      {vorige?.gesloten_ts && vorige.geteld_cent != null && vorige.verwacht_cent != null && (
        <div className="card">
          <div className="hd"><span>Vorige dienst</span><Verschil c={vorige.geteld_cent - vorige.verwacht_cent} /></div>
          <span className="mu">Gesloten {datumTijd(vorige.gesloten_ts)}, geteld {eur(vorige.geteld_cent)}</span>
        </div>
      )}
      <LaatsteBonnen />
      <LeveringKnop />
    </>
  );
}

function OpenDienst({ d }: { d: D }) {
  const { open } = useSheet();
  const oud = teLangOpen(d);
  return (
    <>
      {oud && (
        <div className="card warnbox">
          <b>De kassa staat al open sinds {datumTijd(d.geopend_ts)}</b>
          <p className="mu">Is hij vorige keer niet gesloten? Sluit en tel hem dan eerst, en open hem daarna opnieuw. Anders komen de verkopen van vandaag bij die oude dienst.</p>
          <button className="big alt" onClick={() => open(<DienstSluiten />)}>Eerst sluiten en tellen</button>
        </div>
      )}
      <div className="hero">
        <span>Open sinds {oud ? datumTijd(d.geopend_ts) : tijd(d.geopend_ts)} ({duur(d.geopend_ts)}){d.geopend_door ? ` · ${d.geopend_door}` : ''}</span>
        <small>Hoort nu in de la</small>
        <b>{eur(d.verwacht_cent)}</b>
      </div>
      <DienstKaarten d={d} />
      {!oud && <button className="big alt" onClick={() => open(<DienstSluiten />)}>Kassa sluiten en tellen</button>}
      <LaatsteBonnen />
      <LeveringKnop />
    </>
  );
}

function LeveringKnop() {
  const { open } = useSheet();
  return <button className="ghost" onClick={() => open(<Levering />)}>Levering inboeken</button>;
}

/** Een levering inboeken: per product het aantal dat erbij komt. Mag iedere medewerker. */
function Levering() {
  const { producten, herlaad } = useData();
  const { sluit } = useSheet();
  const [aantal, setAantal] = useState<Record<number, string>>({});
  const [bezig, run] = useBezig();
  const lijst = producten.filter((p) => !p.verwijderd).sort((a, b) => a.categorie.localeCompare(b.categorie) || a.volgorde - b.volgorde);
  const gekozen = lijst.filter((p) => (parseInt(aantal[p.id] || '0') || 0) > 0);
  const inboeken = () => run(async () => {
    if (!gekozen.length) throw new Error('Vul bij minstens één product een aantal in');
    for (const p of gekozen) {
      await rpc('voorraad_boeken', { p_product_id: p.id, p_aantal: parseInt(aantal[p.id]), p_soort: 'levering' });
    }
    await herlaad();
    sluit();
    melding('Ingeboekt: ' + gekozen.map((p) => `${aantal[p.id]}× ${p.naam}`).join(', '));
  });
  const rij = (p: Product) => (
    <label key={p.id}>
      <span>{p.naam} <small className="mu">nu {p.voorraad}</small></span>
      <input className="f" inputMode="numeric" placeholder="0" value={aantal[p.id] ?? ''} aria-label={`Geleverd: ${p.naam}`}
        onChange={(e) => setAantal({ ...aantal, [p.id]: e.target.value.replace(/\D/g, '').slice(0, 5) })} />
    </label>
  );
  return (
    <>
      <h2>Levering inboeken</h2>
      <p className="mu">Vul in hoeveel er van elk product is binnengekomen; dat komt bij de voorraad. Klopt de voorraad helemaal niet, dan telt een beheerder hem bij Beheer → Producten.</p>
      <div className="tel lev">{lijst.map(rij)}</div>
      <button className="big" disabled={bezig || !gekozen.length} onClick={inboeken}>
        {gekozen.length ? `${gekozen.length} ${gekozen.length === 1 ? 'product' : 'producten'} inboeken` : 'Inboeken'}
      </button>
    </>
  );
}

const kleur: Record<string, string> = { contant: 'var(--m-cash)', pin: 'var(--m-pin)', kaart: 'var(--sun)' };

// Verdeling over contant / pin / kaart als één balk met legenda.
export function Verdeling({ delen }: { delen: { methode: string; bedrag_cent: number }[] }) {
  const tot = delen.reduce((a, x) => a + x.bedrag_cent, 0);
  if (!tot) return <p className="mu">Nog niets verkocht.</p>;
  return (
    <>
      <div className="stack">{delen.filter((x) => x.bedrag_cent > 0).map((x) => <i key={x.methode} style={{ flex: x.bedrag_cent, background: kleur[x.methode] }} />)}</div>
      {delen.map((x) => (
        <Rij key={x.methode} l={<><i className="dot" style={{ background: kleur[x.methode] }} />{methodeNaam[x.methode]}</>}
          r={<>{eur(x.bedrag_cent)} <span className="mu pct">{Math.round((x.bedrag_cent / tot) * 100)}%</span></>} />
      ))}
    </>
  );
}

function Kaartje({ titel, rechts, children }: { titel: string; rechts?: ReactNode; children: ReactNode }) {
  return <div className="card"><div className="hd"><span>{titel}</span>{rechts}</div>{children}</div>;
}

/** De cijfers van een dienst, in blokjes: verkopen, geld in de la, kaarten en (na sluiten) de telling. */
export function DienstKaarten({ d }: { d: D }) {
  const opw = d.opwaardering_contant_cent + d.opwaardering_pin_cent;
  return (
    <>
      <Kaartje titel="Verkopen" rechts={<span>{eur(d.omzet_cent)}</span>}>
        <p className="mu" style={{ margin: '0 0 8px' }}>{d.bonnen} {d.bonnen === 1 ? 'bon' : 'bonnen'}{d.bonnen ? `, gemiddeld ${eur(Math.round(d.omzet_cent / d.bonnen))}` : ''}</p>
        <Verdeling delen={[{ methode: 'contant', bedrag_cent: d.contant_cent }, { methode: 'pin', bedrag_cent: d.pin_cent }, { methode: 'kaart', bedrag_cent: d.kaart_cent }]} />
      </Kaartje>
      <Kaartje titel="Geld in de la">
        <Rij l="Wisselgeld bij begin" r={eur(d.beginsaldo_cent)} />
        <Rij l="+ Contant verkocht" r={eur(d.contant_cent)} />
        {d.opwaardering_contant_cent > 0 && <Rij l="+ Kaarten opgewaardeerd, contant" r={eur(d.opwaardering_contant_cent)} />}
        <Rij l={<b>= Hoort in de la</b>} r={eur(d.verwacht_cent)} sterk />
        {d.geteld_cent != null && (
          <>
            <Rij l="Geteld" r={eur(d.geteld_cent)} />
            <div className="row tot"><span><b>Uitkomst</b></span><Verschil c={d.geteld_cent - d.verwacht_cent} /></div>
          </>
        )}
        {d.opmerking && <p className="mu">Opmerking: {d.opmerking}</p>}
      </Kaartje>
      {(opw > 0 || d.kaart_cent > 0) && (
        <Kaartje titel="Tegoedkaarten">
          <Rij l="Opgewaardeerd, contant" r={eur(d.opwaardering_contant_cent)} />
          <Rij l="Opgewaardeerd, pin" r={eur(d.opwaardering_pin_cent)} />
          <Rij l="Betaald met kaart" r={eur(d.kaart_cent)} />
        </Kaartje>
      )}
    </>
  );
}

const munten = [5000, 2000, 1000, 500, 200, 100, 50, 20, 10, 5];

function DienstSluiten() {
  const { dienst, herlaad, rekeningen, regels } = useData();
  const { open } = useSheet();
  const [stuks, setStuks] = useState<Record<number, string>>({});
  const [los, setLos] = useState('');
  const [opm, setOpm] = useState('');
  const [bezig, run] = useBezig();
  if (!dienst) return <p className="mu">De kassa is al gesloten.</p>;
  const geteld = los ? naarCent(los) : munten.reduce((a, m) => a + m * (parseInt(stuks[m] || '0') || 0), 0);
  const verschil = geteld - dienst.verwacht_cent;
  const sluiten = () => run(async () => {
    if (isNaN(geteld)) throw new Error('Ongeldig bedrag');
    const r = await rpc<D>('dienst_sluiten', { p_geteld_cent: geteld, p_opmerking: opm });
    await herlaad();
    open(<><h2>Kassa gesloten</h2><DienstKaarten d={r} /></>);
  });
  return (
    <>
      <h2>Kassa sluiten</h2>
      {rekeningen.length > 0 && (
        <div className="card warnbox">
          <b>Nog {rekeningen.length === 1 ? '1 rekening' : `${rekeningen.length} rekeningen`} open</b>
          {rekeningen.map((r) => (
            <Rij key={r.id} l={r.naam} r={eur(regels.filter((x) => x.rekening_id === r.id).reduce((a, x) => a + x.prijs_cent * x.aantal, 0))} />
          ))}
          <p className="mu">Reken ze eerst af bij Rekeningen, of laat ze bewust openstaan. Wat nog open staat, telt niet mee in deze telling.</p>
        </div>
      )}
      <div className="hero klein"><small>Hoort in de la</small><b>{eur(dienst.verwacht_cent)}</b></div>
      <p className="mu">Tel het geld in de la: vul per munt of biljet het aantal in.</p>
      <div className="tel">
        {munten.map((m) => {
          const n = parseInt(stuks[m] || '0') || 0;
          return (
            <label key={m}><span>{eur(m)}</span>
              <input className="f" inputMode="numeric" value={stuks[m] ?? ''} placeholder="0" disabled={!!los}
                onChange={(e) => setStuks({ ...stuks, [m]: e.target.value.replace(/\D/g, '') })} aria-label={`Aantal van ${eur(m)}`} />
              <small className="mu">{n ? eur(n * m) : ''}</small>
            </label>
          );
        })}
      </div>
      <label htmlFor="los">Of meteen het totaal</label>
      <Bedrag id="los" waarde={los} onChange={setLos} />
      <div className="card uitkomst">
        <Rij l="Geteld" r={isNaN(geteld) ? '?' : eur(geteld)} sterk />
        <div className="row"><span>Uitkomst</span>{isNaN(verschil) ? '?' : <Verschil c={verschil} />}</div>
      </div>
      <label htmlFor="opm">Opmerking (optioneel)</label>
      <input className="f" id="opm" value={opm} onChange={(e) => setOpm(e.target.value)} placeholder="Bijv. 20 euro afgestort" />
      <button className="big" disabled={bezig} onClick={sluiten}>Kassa sluiten</button>
    </>
  );
}

interface BonRij { id: number; bonnummer: number; ts: string; totaal_cent: number; geannuleerd: boolean; rekening_naam: string | null; door_naam: string | null; betalingen: { methode: string }[] }

function LaatsteBonnen() {
  const { open } = useSheet();
  const { dienst } = useData();
  const [bonnen, setBonnen] = useState<BonRij[]>([]);
  const [alles, setAlles] = useState(false);
  const laad = useCallback(async () => {
    try {
      setBonnen(await lees(sb.from('verkopen').select('id,bonnummer,ts,totaal_cent,geannuleerd,rekening_naam,door_naam,betalingen(methode)')
        .gt('ts', new Date(Date.now() - 20 * 3600e3).toISOString()).order('ts', { ascending: false }).limit(100)) as BonRij[]);
    } catch (e) { melding((e as Error).message); }
  }, []);
  // Opnieuw laden zodra er een verkoop bijkomt (dan verandert het dienstoverzicht).
  useEffect(() => { void laad(); }, [laad, dienst?.bonnen, dienst?.omzet_cent]);
  const toon = async (id: number) => {
    try { open(<BonScherm bon={await rpc<Bon>('bon', { p_verkoop_id: id })} />); } catch (e) { melding((e as Error).message); }
  };
  const zichtbaar = alles ? bonnen : bonnen.slice(0, 5);
  return (
    <div className="card">
      <div className="hd"><span>Bonnen van vandaag</span><span className="mu">{bonnen.length}</span></div>
      {zichtbaar.map((b) => (
        <Rij key={b.id} className={b.geannuleerd ? 'vd' : ''} onClick={() => toon(b.id)}
          l={<>
            <span className="tijd">{tijd(b.ts)}</span> Bon {b.bonnummer}{b.rekening_naam ? ` · ${b.rekening_naam}` : ''}
            <br /><span className="mu">{b.betalingen.map((x) => (
              <span key={x.methode}><i className="dot" style={{ background: kleur[x.methode] }} />{methodeNaam[x.methode]} </span>
            ))}{b.door_naam ? `· ${b.door_naam}` : ''}</span>
          </>}
          r={eur(b.totaal_cent)} />
      ))}
      {!bonnen.length && <p className="mu">Nog geen verkopen.</p>}
      {bonnen.length > 5 && <button className="ghost" onClick={() => setAlles(!alles)}>{alles ? 'Minder tonen' : `Alle ${bonnen.length} bonnen tonen`}</button>}
    </div>
  );
}
