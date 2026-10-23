import { useCallback, useEffect, useState } from 'react';
import { useData } from '../data';
import { datumTijd, eur, lees, naarCent, rpc, sb } from '../lib';
import { Bedrag, melding, Rij, useBezig, useSheet } from '../ui';

interface Uitgave {
  id: number; ts: string; omschrijving: string; bedrag_cent: number; voorgeschoten_door: string | null; door_naam: string | null;
  terugbetaald_ts: string | null; terugbetaald_hoe: 'kas' | 'overboeking' | null;
}

/** Bij Dienst: boodschappen en andere uitgaven, uit de kas of voorgeschoten. Werkt ook als de kassa dicht is. */
export function Uitgaven() {
  const { profiel, herlaad } = useData();
  const { open } = useSheet();
  const [lijst, setLijst] = useState<Uitgave[]>([]);
  const [bezig, run] = useBezig();
  const beheer = profiel.rol === 'beheerder';
  const laad = useCallback(async () => {
    setLijst(await lees(sb.from('uitgaven').select('id,ts,omschrijving,bedrag_cent,voorgeschoten_door,door_naam,terugbetaald_ts,terugbetaald_hoe')
      .is('verwijderd_ts', null).order('ts', { ascending: false }).limit(50)) as Uitgave[]);
  }, []);
  useEffect(() => { void laad().catch(() => {}); }, [laad]);
  const klaar = async () => { await laad(); await herlaad(); };
  const open_ = lijst.filter((u) => u.voorgeschoten_door && !u.terugbetaald_ts);
  const recent = lijst.filter((u) => Date.now() - Date.parse(u.ts) < 30 * 24 * 3600e3).slice(0, 8);
  const terug = (u: Uitgave, hoe: 'kas' | 'overboeking') => run(async () => {
    await rpc('uitgave_terugbetalen', { p_id: u.id, p_hoe: hoe });
    await klaar();
    melding(hoe === 'kas' ? `${eur(u.bedrag_cent)} uit de kas terugbetaald aan ${u.voorgeschoten_door}` : 'Afgestreept als overgemaakt');
  });
  return (
    <div className="card">
      <div className="hd"><span>Uitgaven</span></div>
      <button className="big alt" onClick={() => open(<UitgaveScherm onKlaar={klaar} />)}>Uitgave registreren</button>
      {open_.length > 0 && (
        <>
          <h3 className="s">Nog terug te betalen</h3>
          {open_.map((u) => (
            <div key={u.id} className="uitg">
              <Rij l={<>{u.voorgeschoten_door} · {u.omschrijving}<br /><span className="mu">{datumTijd(u.ts)}</span></>} r={eur(u.bedrag_cent)} />
              <div className="btns">
                <button disabled={bezig} onClick={() => terug(u, 'kas')}>Terugbetaald uit de kas</button>
                {beheer && <button disabled={bezig} onClick={() => terug(u, 'overboeking')}>Overgemaakt</button>}
              </div>
            </div>
          ))}
        </>
      )}
      {recent.length > 0 && (
        <>
          <h3 className="s">Laatste uitgaven</h3>
          {recent.map((u) => (
            <Rij key={u.id} onClick={beheer ? () => open(<UitgaveWeg u={u} onKlaar={klaar} />) : undefined}
              l={<>{u.omschrijving}<br /><span className="mu">{datumTijd(u.ts)}{u.door_naam ? ` · ${u.door_naam}` : ''} · {
                u.voorgeschoten_door ? `voorgeschoten door ${u.voorgeschoten_door}${u.terugbetaald_ts ? (u.terugbetaald_hoe === 'kas' ? ', terugbetaald uit de kas' : ', overgemaakt') : ''}` : 'uit de kas'}</span></>}
              r={eur(u.bedrag_cent)} />
          ))}
        </>
      )}
      <p className="mu">Bonnetje? Stop het in de envelop bij de kassa.</p>
    </div>
  );
}

function UitgaveScherm({ onKlaar }: { onKlaar: () => Promise<void> }) {
  const { dienst } = useData();
  const { sluit } = useSheet();
  const [wat, setWat] = useState('Boodschappen');
  const [bedrag, setBedrag] = useState('');
  const [voorgeschoten, setVoorgeschoten] = useState(false);
  const [wie, setWie] = useState('');
  const [bezig, run] = useBezig();
  const opslaan = () => run(async () => {
    const c = naarCent(bedrag);
    if (!wat.trim()) throw new Error('Vul in waarvoor het was');
    if (!(c > 0)) throw new Error('Vul een bedrag in');
    if (voorgeschoten && !wie.trim()) throw new Error('Vul in wie het heeft voorgeschoten');
    await rpc('uitgave_registreren', { p_omschrijving: wat.trim(), p_bedrag_cent: c, p_voorgeschoten_door: voorgeschoten ? wie.trim() : null });
    await onKlaar();
    sluit();
    melding(voorgeschoten ? `Geregistreerd: ${wie.trim()} krijgt ${eur(c)} terug` : `Geregistreerd: ${eur(c)} uit de kas`);
  });
  return (
    <>
      <h2>Uitgave registreren</h2>
      <label htmlFor="uw">Waarvoor</label>
      <input className="f" id="uw" maxLength={60} value={wat} onChange={(e) => setWat(e.target.value)} />
      <label htmlFor="ub">Bedrag</label>
      <Bedrag id="ub" waarde={bedrag} onChange={setBedrag} autoFocus />
      <label style={{ marginTop: 12 }}>Betaald uit</label>
      <div className="chips">
        <button className={!voorgeschoten ? 'on' : ''} onClick={() => setVoorgeschoten(false)}>De kas</button>
        <button className={voorgeschoten ? 'on' : ''} onClick={() => setVoorgeschoten(true)}>Voorgeschoten</button>
      </div>
      {voorgeschoten
        ? <input className="f" maxLength={40} placeholder="Door wie? Bijv. Jan" value={wie} onChange={(e) => setWie(e.target.value)} aria-label="Voorgeschoten door" />
        : <p className="mu">{dienst ? 'De kassa is open: het bedrag gaat af van wat er in de la hoort.' : 'Bij de volgende keer openen houdt het voorstel voor het wisselgeld hier rekening mee.'}</p>}
      {voorgeschoten && <p className="mu">Het komt bij <i>Nog terug te betalen</i> tot het is terugbetaald.</p>}
      <button className="big" disabled={bezig} onClick={opslaan}>Opslaan</button>
    </>
  );
}

function UitgaveWeg({ u, onKlaar }: { u: Uitgave; onKlaar: () => Promise<void> }) {
  const { sluit } = useSheet();
  const [bezig, run] = useBezig();
  const weg = () => run(async () => {
    await rpc('uitgave_verwijderen', { p_id: u.id });
    await onKlaar();
    sluit();
    melding('Uitgave verwijderd');
  });
  return (
    <>
      <h2>{u.omschrijving}: {eur(u.bedrag_cent)}</h2>
      <p className="mu">{datumTijd(u.ts)}{u.door_naam ? `, geregistreerd door ${u.door_naam}` : ''}.</p>
      <p>Verkeerd geregistreerd? Verwijder het en registreer het opnieuw. Het blijft in het logboek staan.</p>
      <button className="big warn" disabled={bezig} onClick={weg}>Uitgave verwijderen</button>
      <button className="ghost" onClick={sluit}>Terug</button>
    </>
  );
}
