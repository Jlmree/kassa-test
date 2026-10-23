import { useEffect, useState } from 'react';
import { datumTijd, eur, methodeNaam, rpc } from '../lib';
import { melding, Rij } from '../ui';
import { Verschil } from './Dienst';

interface Medewerker {
  id: string; naam: string; bonnen: number; omzet_cent: number; geannuleerd: number; geannuleerd_cent: number; geannuleerd_contant_cent: number;
  diensten: number; kasverschil_cent: number; tekorten: number; opgewaardeerd_contant_cent: number; opgewaardeerd_pin_cent: number;
  gestreept_cent: number; afbetaald_contant_cent: number;
}
interface ControleData {
  medewerkers: Medewerker[];
  annuleringen: { bonnummer: number; ts: string; totaal_cent: number; door_naam: string | null; geannuleerd_ts: string; geannuleerd_door: string | null; methoden: string | null }[];
  tekorten: { id: number; gesloten_ts: string; verschil_cent: number; opmerking: string | null; geopend_door: string | null; gesloten_door: string | null }[];
}

const perioden = { '7 dagen': 7, '30 dagen': 30, '90 dagen': 90 } as const;
type Periode = keyof typeof perioden;

// Wat opvalt; geen bewijs, wel een reden om even te kijken of te vragen.
function opvallend(m: Medewerker): string[] {
  const r: string[] = [];
  if (m.geannuleerd >= 3 && m.geannuleerd / Math.max(1, m.bonnen) >= 0.05) r.push(`${m.geannuleerd} van ${m.bonnen} bonnen geannuleerd`);
  if (m.geannuleerd_contant_cent > 0) r.push(`${eur(m.geannuleerd_contant_cent)} aan contante bonnen geannuleerd`);
  if (m.tekorten >= 2) r.push(`${m.tekorten} keer een tekort bij het tellen`);
  if (m.kasverschil_cent <= -500) r.push(`samen ${eur(-m.kasverschil_cent)} tekort in de la`);
  return r;
}

/** Beheer → Controle: per medewerker annuleringen, kasverschillen en contant geld dat binnenkwam. */
export function Controle() {
  const [periode, setPeriode] = useState<Periode>('30 dagen');
  const [c, setC] = useState<ControleData | null>(null);
  useEffect(() => {
    setC(null);
    const tot = new Date(Date.now() + 3600e3), van = new Date(Date.now() - perioden[periode] * 86400e3);
    rpc<ControleData>('controle', { p_van: van.toISOString(), p_tot: tot.toISOString() }).then(setC, (e) => melding(e.message));
  }, [periode]);
  const opval = (c?.medewerkers ?? []).flatMap((m) => opvallend(m).map((t) => `${m.naam}: ${t}`));
  return (
    <>
      <p className="mu">Wie heeft wat gedaan met geld. Een tekort of een annulering is meestal een vergissing; valt iets steeds bij dezelfde persoon op, vraag er dan naar.</p>
      <div className="chips small">
        {(Object.keys(perioden) as Periode[]).map((p) => <button key={p} className={p === periode ? 'on' : ''} onClick={() => setPeriode(p)}>{p}</button>)}
      </div>
      {!c ? <p className="mu">Laden…</p> : (
        <>
          {opval.length > 0
            ? <div className="card warnbox"><b>Valt op</b><ul className="stappen">{opval.map((t) => <li key={t}>{t}</li>)}</ul></div>
            : <p className="card">Niets bijzonders in deze periode.</p>}
          {c.medewerkers.map((m) => (
            <div className="card" key={m.id}>
              <div className="hd"><span>{m.naam}</span><span>{eur(m.omzet_cent)}</span></div>
              <Rij l="Bonnen" r={String(m.bonnen)} />
              <Rij l="Geannuleerd" r={m.geannuleerd ? `${m.geannuleerd} · ${eur(m.geannuleerd_cent)}${m.geannuleerd_contant_cent ? ` (contant ${eur(m.geannuleerd_contant_cent)})` : ''}` : '–'} />
              {m.diensten > 0 && <Rij l={`Kassa gesloten (${m.diensten}×)`} r={<Verschil c={m.kasverschil_cent} />} />}
              {(m.opgewaardeerd_contant_cent > 0 || m.opgewaardeerd_pin_cent > 0) && (
                <Rij l="Kaarten opgewaardeerd" r={`${eur(m.opgewaardeerd_contant_cent)} contant · ${eur(m.opgewaardeerd_pin_cent)} pin`} />
              )}
              {m.gestreept_cent > 0 && <Rij l="Op de streeplijst gezet" r={eur(m.gestreept_cent)} />}
              {m.afbetaald_contant_cent > 0 && <Rij l="Streeplijst contant ontvangen" r={eur(m.afbetaald_contant_cent)} />}
            </div>
          ))}
          <h3 className="s">Kasverschillen</h3>
          <div className="card">
            {c.tekorten.map((t) => (
              <Rij key={t.id} l={<>{datumTijd(t.gesloten_ts)}<br /><span className="mu">geopend door {t.geopend_door ?? '?'}, geteld door {t.gesloten_door ?? '?'}{t.opmerking ? ` · "${t.opmerking}"` : ''}</span></>}
                r={<Verschil c={t.verschil_cent} />} />
            ))}
            {!c.tekorten.length && <p className="mu">Elke telling klopte.</p>}
          </div>
          <h3 className="s">Geannuleerde bonnen</h3>
          <div className="card">
            {c.annuleringen.map((a) => (
              <Rij key={a.bonnummer} l={<>Bon {a.bonnummer} · {(a.methoden ?? '').split(', ').map((x) => methodeNaam[x] ?? x).join(', ')}<br />
                <span className="mu">{datumTijd(a.ts)} door {a.door_naam ?? '?'}; geannuleerd door {a.geannuleerd_door ?? '?'}</span></>} r={eur(a.totaal_cent)} />
            ))}
            {!c.annuleringen.length && <p className="mu">Geen geannuleerde bonnen.</p>}
          </div>
        </>
      )}
    </>
  );
}
