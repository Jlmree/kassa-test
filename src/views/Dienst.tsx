import { useCallback, useEffect, useState } from 'react';
import { useData } from '../data';
import { eur, lees, naarCent, rpc, sb, tijd, type Bon, type Dienst as D } from '../lib';
import { Bedrag, melding, Rij, useBezig, useSheet } from '../ui';
import { BonScherm } from './Afrekenen';

export function Dienst() {
  const { dienst } = useData();
  return dienst ? <OpenDienst d={dienst} /> : <DienstOpenen />;
}

function DienstOpenen() {
  const { herlaad } = useData();
  const [v, setV] = useState('');
  const [bezig, run] = useBezig();
  const openen = () => run(async () => {
    const c = v ? naarCent(v) : 0;
    if (isNaN(c) || c < 0) throw new Error('Ongeldig bedrag');
    await rpc('dienst_openen', { p_beginsaldo_cent: c });
    await herlaad();
    melding('De kassa is open');
  });
  return (
    <>
      <h2>Kassa openen</h2>
      <p className="mu">Tel het wisselgeld in de la voordat je begint. Aan het eind tel je opnieuw, zodat je ziet of het klopt.</p>
      <label htmlFor="bs">Wisselgeld in de la bij het begin</label>
      <Bedrag id="bs" waarde={v} onChange={setV} />
      <button className="big" disabled={bezig} onClick={openen}>Kassa openen</button>
      <LaatsteBonnen />
    </>
  );
}

function OpenDienst({ d }: { d: D }) {
  const { open } = useSheet();
  return (
    <>
      <p className="mu">Open sinds {tijd(d.geopend_ts)}{d.geopend_door ? ` door ${d.geopend_door}` : ''}</p>
      <div className="kpi">
        <div><span className="mu">Omzet</span><b>{eur(d.omzet_cent)}</b></div>
        <div><span className="mu">Bonnen</span><b>{d.bonnen}</b></div>
      </div>
      <DienstCijfers d={d} />
      <button className="big alt" onClick={() => open(<DienstSluiten />)}>Kassa sluiten en tellen</button>
      <LaatsteBonnen />
    </>
  );
}

export function DienstCijfers({ d }: { d: D }) {
  return (
    <>
      <Rij l="Contant" r={eur(d.contant_cent)} />
      <Rij l="Pin" r={eur(d.pin_cent)} />
      <Rij l="Van kaarten" r={eur(d.kaart_cent)} />
      <Rij l="Kaarten opgewaardeerd, contant" r={eur(d.opwaardering_contant_cent)} />
      <Rij l="Kaarten opgewaardeerd, pin" r={eur(d.opwaardering_pin_cent)} />
      <Rij l="Wisselgeld bij begin" r={eur(d.beginsaldo_cent)} />
      <Rij l={<b>Hoort in de la</b>} r={eur(d.verwacht_cent)} sterk />
      {d.geteld_cent != null && (
        <>
          <Rij l="Geteld" r={eur(d.geteld_cent)} />
          <Rij l={<b>Verschil</b>} r={<span className={d.geteld_cent - d.verwacht_cent < 0 ? 'neg' : ''}>{eur(d.geteld_cent - d.verwacht_cent)}</span>} sterk />
        </>
      )}
    </>
  );
}

const munten = [5000, 2000, 1000, 500, 200, 100, 50, 20, 10, 5];

function DienstSluiten() {
  const { dienst, herlaad } = useData();
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
    open(<><h2>Kassa gesloten</h2><DienstCijfers d={r} /></>);
  });
  return (
    <>
      <h2>Kassa sluiten</h2>
      <p className="mu">Tel het geld in de la. Vul per munt of biljet het aantal in, of vul direct het totaal in.</p>
      <div className="tel">
        {munten.map((m) => (
          <label key={m}><span>{eur(m)}</span>
            <input className="f" inputMode="numeric" value={stuks[m] ?? ''} placeholder="0" onChange={(e) => setStuks({ ...stuks, [m]: e.target.value.replace(/\D/g, '') })} />
          </label>
        ))}
      </div>
      <label htmlFor="los">Of het totaal in één keer</label>
      <Bedrag id="los" waarde={los} onChange={setLos} />
      <Rij l="Hoort in de la" r={eur(dienst.verwacht_cent)} />
      <Rij l="Geteld" r={isNaN(geteld) ? '?' : eur(geteld)} />
      <Rij l={<b>Verschil</b>} r={isNaN(verschil) ? '?' : <span className={verschil < 0 ? 'neg' : ''}>{eur(verschil)}</span>} sterk />
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
  return (
    <>
      <h3 className="s">Bonnen van vandaag</h3>
      {bonnen.map((b) => (
        <Rij key={b.id} className={b.geannuleerd ? 'vd' : ''} onClick={() => toon(b.id)}
          l={<>{tijd(b.ts)} · Bon {b.bonnummer}{b.rekening_naam ? `, ${b.rekening_naam}` : ''}<br /><span className="mu">{b.betalingen.map((x) => x.methode).join(' + ')}{b.door_naam ? ` · ${b.door_naam}` : ''}</span></>}
          r={eur(b.totaal_cent)} />
      ))}
      {!bonnen.length && <p className="mu">Nog geen verkopen.</p>}
    </>
  );
}
