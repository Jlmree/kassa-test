import { useCallback, useEffect, useState } from 'react';
import { useData } from '../data';
import { centTekst, csvRij, datumTijd, downloaden, eur, lidLink, methodeNaam, naarCent, rpc } from '../lib';
import { Bedrag, melding, Qr, Rij, useBezig, useSheet } from '../ui';

export interface Lid { id: number; naam: string; actief: boolean; open_cent: number; maand_cent: number; laatst: string | null }

function useLeden() {
  const [leden, setLeden] = useState<Lid[] | null>(null);
  const laad = useCallback(async () => {
    try { setLeden(await rpc<Lid[]>('streeplijst')); } catch (e) { melding((e as Error).message); }
  }, []);
  useEffect(() => { void laad(); }, [laad]);
  return [leden, laad] as const;
}

const zoekt = (l: Lid, z: string) => !z || l.naam.toLowerCase().includes(z);

/** Lid kiezen bij het afrekenen: zoeken of tikken, en een nieuw lid kan er meteen bij. */
export function KiesLid({ onKies }: { onKies: (l: Lid) => void }) {
  const [leden, laad] = useLeden();
  const [zoek, setZoek] = useState('');
  const [bezig, run] = useBezig();
  const z = zoek.trim().toLowerCase();
  const lijst = (leden ?? []).filter((l) => l.actief && zoekt(l, z));
  const nieuw = () => run(async () => {
    const id = await rpc<number>('lid_opslaan', { p_id: null, p_naam: zoek });
    await laad();
    onKies({ id, naam: zoek.trim(), actief: true, open_cent: 0, maand_cent: 0, laatst: null });
  });
  return (
    <>
      <h2>Op de streeplijst van…</h2>
      <input className="f zoek" type="search" autoFocus placeholder="Zoek een naam" value={zoek} onChange={(e) => setZoek(e.target.value)} aria-label="Zoek lid" />
      {!leden ? <p className="mu">Laden…</p> : (
        <div className="leden">
          {lijst.map((l) => (
            <button key={l.id} className="lid" onClick={() => onKies(l)}>
              <span>{l.naam}</span>{l.open_cent > 0 && <span className="mu">{eur(l.open_cent)}</span>}
            </button>
          ))}
        </div>
      )}
      {leden && !lijst.length && !z && <p className="mu">Nog geen leden. Typ hierboven een naam om de eerste toe te voegen.</p>}
      {z && !lijst.some((l) => l.naam.toLowerCase() === z) && (
        <button className="big alt" disabled={bezig} onClick={nieuw}>{zoek.trim()} toevoegen aan de streeplijst</button>
      )}
    </>
  );
}

/** Tabblad Streeplijst: wie moet nog wat, en afbetalen. */
export function Streeplijst() {
  const { open } = useSheet();
  const [leden, laad] = useLeden();
  const [zoek, setZoek] = useState('');
  const [ookOud, setOokOud] = useState(false);
  const [naam, setNaam] = useState('');
  const [bezig, run] = useBezig();
  const z = zoek.trim().toLowerCase();
  const lijst = (leden ?? []).filter((l) => (l.actief || ookOud || l.open_cent !== 0) && zoekt(l, z));
  const totaal = (leden ?? []).reduce((a, l) => a + l.open_cent, 0);
  const nieuw = () => run(async () => {
    await rpc('lid_opslaan', { p_id: null, p_naam: naam });
    setNaam('');
    await laad();
    melding('Toegevoegd');
  });
  return (
    <>
      <div className="kpi">
        <div><span className="mu">Leden</span><b>{(leden ?? []).filter((l) => l.actief).length}</b></div>
        <div><span className="mu">Staat nog open</span><b>{eur(totaal)}</b></div>
      </div>
      <input className="f zoek" type="search" placeholder="Zoek een naam" value={zoek} onChange={(e) => setZoek(e.target.value)} aria-label="Zoek lid" />
      <div className="card">
        {lijst.map((l) => (
          <Rij key={l.id} className={l.actief ? '' : 'vd'} onClick={() => open(<LidScherm id={l.id} onWijziging={laad} />)}
            l={<>{l.naam}{!l.actief && <span className="mu"> (van de lijst)</span>}<br /><span className="mu">{l.maand_cent ? `deze maand ${eur(l.maand_cent)}` : l.laatst ? `laatst ${datumTijd(l.laatst)}` : 'nog niets gestreept'}</span></>}
            r={<span className={l.open_cent ? '' : 'mu'}>{eur(l.open_cent)}</span>} />
        ))}
        {leden && !lijst.length && <p className="mu">{leden.length ? 'Niemand gevonden.' : 'Nog geen leden op de streeplijst.'}</p>}
        {!leden && <p className="mu">Laden…</p>}
      </div>
      {(leden ?? []).some((l) => !l.actief && !l.open_cent) && (
        <label className="check"><input type="checkbox" checked={ookOud} onChange={(e) => setOokOud(e.target.checked)} /> Ook leden tonen die van de lijst zijn gehaald</label>
      )}
      <label htmlFor="ln-nieuw">Nieuw lid</label>
      <form className="inl" onSubmit={(e) => { e.preventDefault(); void nieuw(); }}>
        <input className="f" id="ln-nieuw" placeholder="Naam" value={naam} maxLength={60} onChange={(e) => setNaam(e.target.value)} />
        <button disabled={bezig || !naam.trim()}>Toevoegen</button>
      </form>
    </>
  );
}

interface Historie {
  open_cent: number;
  regels: { ts: string; soort: 'streep' | 'afbetaald'; bedrag_cent: number; bonnummer: number | null; door_naam: string | null; wat: string | null }[];
}

function LidScherm({ id, onWijziging }: { id: number; onWijziging: () => Promise<void> }) {
  const { profiel, dienst, methoden } = useData();
  const { open } = useSheet();
  const [lid, setLid] = useState<Lid | null>(null);
  const [h, setH] = useState<Historie | null>(null);
  const [v, setV] = useState('');
  const [bezig, run] = useBezig();
  const beheer = profiel.rol === 'beheerder';
  const laad = useCallback(async () => {
    const [lijst, hist] = await Promise.all([rpc<Lid[]>('streeplijst'), rpc<Historie>('lid_historie', { p_lid: id })]);
    setLid(lijst.find((l) => l.id === id) ?? null);
    setH(hist);
  }, [id]);
  useEffect(() => { void run(laad); }, [laad, run]);
  if (!lid || !h) return <p className="mu">Laden…</p>;

  const bedrag = v ? naarCent(v) : h.open_cent;
  const afbetalen = (methode: 'contant' | 'pin' | 'overboeking') => run(async () => {
    if (!(bedrag > 0)) throw new Error('Vul een bedrag in');
    const rest = await rpc<number>('lat_afbetalen', { p_lid: id, p_bedrag_cent: bedrag, p_methode: methode });
    setV('');
    await laad();
    await onWijziging();
    melding(rest ? `Afbetaald, nog open ${eur(rest)}` : `${lid.naam} staat weer op nul`);
  });
  const wijzig = (naam: string, actief: boolean) => run(async () => {
    await rpc('lid_opslaan', { p_id: id, p_naam: naam, p_actief: actief });
    await laad();
    await onWijziging();
    melding('Opgeslagen');
  });

  return (
    <>
      <h2>{lid.naam}</h2>
      <p className="mu c">Staat nog open</p>
      <div className="big-n">{eur(h.open_cent)}</div>
      {h.open_cent > 0 && (
        <>
          <label htmlFor="ab">Afbetalen</label>
          <Bedrag id="ab" waarde={v} onChange={setV} placeholder={`Alles: ${centTekst(h.open_cent)}`} />
          {(methoden.contant || methoden.pin) && !dienst && <p className="mu">Contant of pin afbetalen kan als de kassa open is (tabblad Dienst).</p>}
          <div className="btns" style={{ marginTop: 8 }}>
            {methoden.contant && dienst && <button className="big m-cash" disabled={bezig} onClick={() => afbetalen('contant')}>Contant ontvangen</button>}
            {methoden.pin && dienst && <button className="big m-pin" disabled={bezig} onClick={() => afbetalen('pin')}>Pin ontvangen</button>}
            {beheer && <button className="big alt" disabled={bezig} onClick={() => afbetalen('overboeking')}>Overgemaakt</button>}
          </div>
          {!isNaN(bedrag) && bedrag > 0 && <p className="mu c">{eur(bedrag)} afbetalen{bedrag < h.open_cent ? `, daarna nog ${eur(h.open_cent - bedrag)} open` : ''}</p>}
        </>
      )}
      <h3 className="s">Geschiedenis</h3>
      <div className="card">
        {h.regels.map((r, i) => (
          <Rij key={i}
            l={<>{r.soort === 'streep' ? (r.wat ?? 'Gestreept') : `Afbetaald (${methodeNaam[r.wat?.split(' · ')[0] ?? ''] ?? r.wat})`}<br />
              <span className="mu">{datumTijd(r.ts)}{r.bonnummer ? ` · bon ${r.bonnummer}` : ''}{r.door_naam ? ` · ${r.door_naam}` : ''}{r.soort === 'afbetaald' && r.wat?.includes(' · ') ? ` · ${r.wat.split(' · ').slice(1).join(' · ')}` : ''}</span></>}
            r={r.soort === 'streep' ? eur(r.bedrag_cent) : '− ' + eur(r.bedrag_cent)} />
        ))}
        {!h.regels.length && <p className="mu">Nog niets gestreept.</p>}
      </div>
      <button className="ghost" onClick={() => open(<LidQr lid={lid} />)}>Eigen overzicht voor {lid.naam} (QR-code)</button>
      {beheer && <LidBeheer lid={lid} bezig={bezig} onOpslaan={wijzig} />}
    </>
  );
}

/** QR-code waarmee een lid de eigen streeplijst bekijkt (scannen, printen of de link sturen). */
function LidQr({ lid }: { lid: Lid }) {
  const { profiel, winkel } = useData();
  const [code, setCode] = useState<string | null>(null);
  const [zeker, setZeker] = useState(false);
  const [bezig, run] = useBezig();
  useEffect(() => { void run(async () => setCode(await rpc<string>('lid_code', { p_lid: lid.id }))); }, [lid.id, run]);
  const vervang = () => run(async () => {
    setCode(await rpc<string>('lid_nieuwe_code', { p_lid: lid.id }));
    setZeker(false);
    melding('Nieuwe code gemaakt; de oude werkt niet meer');
  });
  if (!code) return <p className="mu">Laden…</p>;
  const link = lidLink(code);
  return (
    <>
      <h2>Eigen overzicht voor {lid.naam}</h2>
      <p className="mu">Laat {lid.naam} deze code scannen met de eigen telefoon, of print hem. Daarmee ziet {lid.naam} wat er op de streeplijst staat en wie er heeft ingeschonken, zonder in te loggen. Ook de saldo-zuil leest deze code.</p>
      <div className="print kaarten een">
        <div className="kk">
          <Qr tekst={link} />
          <div className="kk-t">
            <span className="kk-w">{winkel}</span>
            <span>Streeplijst</span>
            <b>{lid.naam}</b>
            <small>{code}</small>
            <span className="kk-s">Scan voor je streeplijst</span>
          </div>
        </div>
      </div>
      <div className="btns">
        <button onClick={() => window.print()}>Printen of PDF</button>
        <button onClick={() => { void navigator.clipboard?.writeText(link).then(() => melding('Link gekopieerd'), () => melding(link)); }}>Link kopiëren</button>
      </div>
      {profiel.rol === 'beheerder' && (!zeker
        ? <button className="ghost" onClick={() => setZeker(true)}>Nieuwe code maken (oude werkt dan niet meer)</button>
        : <button className="big warn" disabled={bezig} onClick={vervang}>Ja, nieuwe code voor {lid.naam}</button>)}
    </>
  );
}

function LidBeheer({ lid, bezig, onOpslaan }: { lid: Lid; bezig: boolean; onOpslaan: (naam: string, actief: boolean) => void }) {
  const [naam, setNaam] = useState(lid.naam);
  return (
    <>
      <label htmlFor="ln">Naam</label>
      <div className="inl">
        <input className="f" id="ln" value={naam} maxLength={60} onChange={(e) => setNaam(e.target.value)} />
        <button disabled={bezig || !naam.trim() || naam.trim() === lid.naam} onClick={() => onOpslaan(naam, lid.actief)}>Opslaan</button>
      </div>
      {lid.actief
        ? <button className="ghost" disabled={bezig} onClick={() => onOpslaan(lid.naam, false)}>Van de streeplijst halen{lid.open_cent > 0 ? ' (openstaand blijft staan)' : ''}</button>
        : <button className="ghost" disabled={bezig} onClick={() => onOpslaan(lid.naam, true)}>Weer op de streeplijst zetten</button>}
    </>
  );
}

interface MaandRij { id: number; naam: string; actief: boolean; gestreept_cent: number; keer: number; afbetaald_cent: number; open_cent: number }

const maandNaam = (m: string) => new Date(m + '-01T12:00:00').toLocaleDateString('nl-NL', { month: 'long', year: 'numeric' });

/** Beheer → Streeplijst: per maand wie wat heeft gestreept, met export voor de incasso. */
export function StreeplijstMaand() {
  const nu = new Date();
  const [maand, setMaand] = useState(`${nu.getFullYear()}-${String(nu.getMonth() + 1).padStart(2, '0')}`);
  const [rijen, setRijen] = useState<MaandRij[] | null>(null);
  useEffect(() => {
    setRijen(null);
    rpc<MaandRij[]>('streeplijst_maand', { p_maand: maand + '-01' }).then(setRijen, (e) => melding(e.message));
  }, [maand]);
  const schuif = (d: number) => {
    const [j, m] = maand.split('-').map(Number);
    const x = new Date(j, m - 1 + d, 1);
    setMaand(`${x.getFullYear()}-${String(x.getMonth() + 1).padStart(2, '0')}`);
  };
  const som = (k: 'gestreept_cent' | 'afbetaald_cent' | 'open_cent') => (rijen ?? []).reduce((a, r) => a + r[k], 0);
  const exporteer = () => downloaden(`streeplijst-${maand}.csv`, [csvRij(['naam', 'keer gestreept', `gestreept in ${maandNaam(maand)}`, 'afbetaald in die maand', 'staat nu open'])]
    .concat((rijen ?? []).map((r) => csvRij([r.naam, r.keer, centTekst(r.gestreept_cent), centTekst(r.afbetaald_cent), centTekst(r.open_cent)]))).join('\n'));
  return (
    <>
      <div className="inl maand">
        <button onClick={() => schuif(-1)} aria-label="Vorige maand">‹</button>
        <b>{maandNaam(maand)}</b>
        <button onClick={() => schuif(1)} aria-label="Volgende maand">›</button>
      </div>
      <div className="kpi">
        <div><span className="mu">Gestreept</span><b>{eur(som('gestreept_cent'))}</b></div>
        <div><span className="mu">Afbetaald</span><b>{eur(som('afbetaald_cent'))}</b></div>
        <div><span className="mu">Nu open</span><b>{eur(som('open_cent'))}</b></div>
      </div>
      <div className="card">
        {!rijen ? <p className="mu">Laden…</p> : rijen.map((r) => (
          <Rij key={r.id} l={<>{r.naam}<br /><span className="mu">{r.keer}× gestreept, {eur(r.gestreept_cent)}{r.afbetaald_cent ? ` · afbetaald ${eur(r.afbetaald_cent)}` : ''}</span></>}
            r={<span className={r.open_cent ? '' : 'mu'}>{eur(r.open_cent)}</span>} />
        ))}
        {rijen && !rijen.length && <p className="mu">Niets gestreept in deze maand.</p>}
      </div>
      <button className="big" disabled={!rijen?.length} onClick={exporteer}>Exporteren naar Excel (CSV)</button>
      <p className="mu">Rechts staat wat ieder lid nu nog moet. Is er overgemaakt of geïncasseerd? Boek het af bij het lid in het tabblad Streeplijst → Overgemaakt.</p>
    </>
  );
}
