import { useEffect, useRef, useState, type ReactNode } from 'react';
import { useData } from '../data';
import { eur, rpc } from '../lib';
import { useBezig } from '../ui';

// Beheer → Recap: de cijfers van een periode als dia's op het hele scherm, om
// bijvoorbeeld op de jaarvergadering of de seizoensafsluiting te laten zien.

interface RecapData {
  van: string; tot: string; bonnen: number; omzet_cent: number; artikelen: number;
  vorige: { bonnen: number; omzet_cent: number; artikelen: number };
  eerste_bon: string | null;
  top: { naam: string; aantal: number }[];
  bier: number;
  drukste_dag: { dag: string; bonnen: number } | null;
  drukste_kwartier: { van: string; bonnen: number } | null;
  klok: { dag: number; uur: number; bonnen: number }[];
  diensten: number; kas_klopt: number; langste_dienst_min: number | null;
  kaarten_gebruikt: number; opgewaardeerd_cent: number; populair_opwaardeerbedrag: number | null;
  vrijwilligers: { naam: string; diensten: number }[];
  medewerkers: number;
}

const iso = (d: Date) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
const getal = (n: number) => n.toLocaleString('nl-NL');
const dagNaam = ['maandag', 'dinsdag', 'woensdag', 'donderdag', 'vrijdag', 'zaterdag', 'zondag'];

/** Seizoen van 1 augustus tot en met 31 juli. */
function perioden(): { id: string; naam: string; van: string; tot: string }[] {
  const nu = new Date();
  const j = nu.getFullYear();
  const s = nu.getMonth() >= 7 ? j : j - 1;
  const jaarGeleden = new Date(nu); jaarGeleden.setFullYear(j - 1); jaarGeleden.setDate(jaarGeleden.getDate() + 1);
  return [
    { id: 'seizoen', naam: `Seizoen ${s}–${s + 1}`, van: `${s}-08-01`, tot: `${s + 1}-07-31` },
    { id: 'vorig-seizoen', naam: `Seizoen ${s - 1}–${s}`, van: `${s - 1}-08-01`, tot: `${s}-07-31` },
    { id: 'jaar', naam: `${j}`, van: `${j}-01-01`, tot: `${j}-12-31` },
    { id: '12m', naam: 'Afgelopen 12 maanden', van: iso(jaarGeleden), tot: iso(nu) },
  ];
}

function verschil(nu: number, toen: number) {
  if (!toen) return null;
  const p = Math.round(((nu - toen) / toen) * 100);
  if (p === 0) return 'evenveel als de periode ervoor';
  return `${p > 0 ? '+' : '−'}${Math.abs(p)}% ten opzichte van de periode ervoor`;
}

export function Recap() {
  const { winkel } = useData();
  const lijst = perioden();
  const [keus, setKeus] = useState(lijst[0].id);
  const [bedragen, setBedragen] = useState(true);
  const [namen, setNamen] = useState(false);
  const [data, setData] = useState<RecapData | null>(null);
  const [bezig, run] = useBezig();
  const p = lijst.find((x) => x.id === keus)!;

  const start = () => run(async () => {
    setData(await rpc<RecapData>('recap', { p_van: p.van, p_tot: p.tot }));
  });

  return (
    <>
      <p className="mu">Het seizoen van de bar in een paar schermen: wat er verkocht is, wanneer het druk was en hoe vaak de kas klopte. Mooi voor de jaarvergadering of de seizoensafsluiting.</p>
      <label>Periode</label>
      <div className="chips">
        {lijst.map((x) => <button key={x.id} className={x.id === keus ? 'on' : ''} onClick={() => setKeus(x.id)}>{x.naam}</button>)}
      </div>
      <label className="check"><input type="checkbox" checked={bedragen} onChange={(e) => setBedragen(e.target.checked)} /><span>Bedragen tonen<br /><span className="mu">Zet uit als je de recap aan leden laat zien.</span></span></label>
      <label className="check"><input type="checkbox" checked={namen} onChange={(e) => setNamen(e.target.checked)} /><span>Namen van vrijwilligers tonen<br /><span className="mu">De drie mensen die de meeste diensten openden.</span></span></label>
      <button className="big" disabled={bezig} onClick={start}>{bezig ? 'Even rekenen…' : 'Recap starten'}</button>
      {data && <Dias data={data} winkel={winkel} titel={p.naam} bedragen={bedragen} namen={namen} sluit={() => setData(null)} />}
    </>
  );
}

function Dias({ data: d, winkel, titel, bedragen, namen, sluit }: { data: RecapData; winkel: string; titel: string; bedragen: boolean; namen: boolean; sluit: () => void }) {
  const dias = maakDias(d, winkel, titel, bedragen, namen);
  const [i, setI] = useState(0);
  const ref = useRef<HTMLDivElement>(null);
  const vooruit = () => setI((x) => Math.min(x + 1, dias.length - 1));
  const terug = () => setI((x) => Math.max(x - 1, 0));

  useEffect(() => {
    const toets = (e: KeyboardEvent) => {
      if (e.key === 'ArrowRight' || e.key === ' ') { e.preventDefault(); vooruit(); }
      else if (e.key === 'ArrowLeft') terug();
      else if (e.key === 'Escape') sluit();
    };
    addEventListener('keydown', toets);
    return () => removeEventListener('keydown', toets);
  });

  const tik = (e: React.MouseEvent) => {
    const r = (e.currentTarget as HTMLElement).getBoundingClientRect();
    if (e.clientX - r.left < r.width / 3) terug(); else vooruit();
  };
  const grootScherm = () => {
    const el = ref.current;
    if (!el) return;
    if (document.fullscreenElement) void document.exitFullscreen().catch(() => {});
    else void el.requestFullscreen?.().catch(() => {});
  };
  const dia = dias[i];

  return (
    <div className={'recap ' + dia.kleur} ref={ref} role="dialog" aria-label={`Recap ${titel}`}>
      <div className="recap-balk">
        {dias.map((_, n) => <i key={n} className={n < i ? 'af' : n === i ? 'nu' : ''} />)}
      </div>
      <div className="recap-knoppen">
        <button onClick={grootScherm}>Groot scherm</button>
        <button onClick={sluit} aria-label="Recap sluiten">✕</button>
      </div>
      <div className="recap-dia" key={i} onClick={tik}>{dia.inhoud}</div>
      <div className="recap-voet">
        <button onClick={terug} disabled={i === 0} aria-label="Vorige">‹</button>
        <span>{i + 1} / {dias.length}</span>
        <button onClick={vooruit} disabled={i === dias.length - 1} aria-label="Volgende">›</button>
      </div>
    </div>
  );
}

interface Dia { kleur: 'groen' | 'zon' | 'inkt' | 'licht'; inhoud: ReactNode }

function maakDias(d: RecapData, winkel: string, titel: string, bedragen: boolean, namen: boolean): Dia[] {
  const dias: Dia[] = [];
  dias.push({ kleur: 'groen', inhoud: <><p className="rc-klein">{winkel}</p><h1 className="rc-groot">{titel}</h1><p className="rc-tekst">De bar in cijfers.</p><p className="rc-hint">Tik om verder te gaan</p></> });

  if (!d.bonnen) {
    dias.push({ kleur: 'inkt', inhoud: <><h1 className="rc-groot">Nog niets</h1><p className="rc-tekst">In deze periode zijn er nog geen bonnen. Kies een andere periode.</p></> });
    return dias;
  }

  const v = verschil(d.bonnen, d.vorige.bonnen);
  dias.push({ kleur: 'zon', inhoud: <><p className="rc-klein">Aangeslagen</p><h1 className="rc-getal">{getal(d.bonnen)}</h1><p className="rc-tekst">bonnen, met samen {getal(d.artikelen)} dingen erop.</p>{v && <p className="rc-klein">{v}</p>}</> });

  if (d.top.length) {
    const max = d.top[0].aantal;
    dias.push({ kleur: 'licht', inhoud: <>
      <p className="rc-klein">Het populairst</p>
      <h1 className="rc-groot">{d.top[0].naam}</h1>
      <ol className="rc-top">
        {d.top.map((t) => <li key={t.naam}><span>{t.naam}</span><i style={{ width: `${Math.max(6, (t.aantal / max) * 100)}%` }} /><b>{getal(t.aantal)}</b></li>)}
      </ol>
    </> });
  }

  if (d.bier > 0) {
    const liter = Math.round(d.bier * 0.25);
    const vergelijk = liter >= 300 ? `Genoeg om ${getal(Math.round(liter / 150))} badkuipen mee te vullen.` : liter >= 10 ? `Dat zijn ${getal(Math.round(liter / 10))} volle emmers.` : 'Een goed begin.';
    dias.push({ kleur: 'zon', inhoud: <><p className="rc-klein">Getapt</p><h1 className="rc-getal">{getal(d.bier)}</h1><p className="rc-tekst">glazen bier, ongeveer {getal(liter)} liter.</p><p className="rc-klein">{vergelijk}</p></> });
  }

  if (d.drukste_dag) {
    const dag = new Date(d.drukste_dag.dag + 'T12:00:00');
    const kw = d.drukste_kwartier ? new Date(d.drukste_kwartier.van) : null;
    const t = (x: Date) => x.toLocaleTimeString('nl-NL', { hour: '2-digit', minute: '2-digit' });
    dias.push({ kleur: 'inkt', inhoud: <>
      <p className="rc-klein">De drukste avond</p>
      <h1 className="rc-groot">{dag.toLocaleDateString('nl-NL', { weekday: 'long', day: 'numeric', month: 'long' })}</h1>
      <p className="rc-tekst">{getal(d.drukste_dag.bonnen)} bonnen op één dag.</p>
      {kw && d.drukste_kwartier && <p className="rc-klein">Het drukste kwartier: {dagNaam[(kw.getDay() + 6) % 7]} {t(kw)}–{t(new Date(kw.getTime() + 15 * 60000))}, {getal(d.drukste_kwartier.bonnen)} bonnen.</p>}
    </> });
  }

  if (d.klok.length) dias.push({ kleur: 'licht', inhoud: <Klok klok={d.klok} /> });

  if (d.diensten) {
    const uren = d.langste_dienst_min ? `${Math.floor(d.langste_dienst_min / 60)} uur en ${d.langste_dienst_min % 60} minuten` : null;
    dias.push({ kleur: 'groen', inhoud: <>
      <p className="rc-klein">Achter de bar</p>
      <h1 className="rc-getal">{getal(d.diensten)}</h1>
      <p className="rc-tekst">keer ging de kassa open.</p>
      {d.kas_klopt > 0 && <p className="rc-tekst">{getal(d.kas_klopt)} keer klopte de kas bij het tellen tot op de cent.</p>}
      {uren && <p className="rc-klein">De langste dienst: {uren}.</p>}
    </> });
  }

  if (d.kaarten_gebruikt || d.opgewaardeerd_cent) {
    dias.push({ kleur: 'zon', inhoud: <>
      <p className="rc-klein">Barkaarten</p>
      <h1 className="rc-getal">{getal(d.kaarten_gebruikt)}</h1>
      <p className="rc-tekst">kaarten waarmee betaald is.</p>
      {bedragen && d.opgewaardeerd_cent > 0 && <p className="rc-tekst">Samen {eur(d.opgewaardeerd_cent)} opgewaardeerd.</p>}
      {d.populair_opwaardeerbedrag && <p className="rc-klein">Het vaakst gekozen: {eur(d.populair_opwaardeerbedrag)}.</p>}
    </> });
  }

  if (bedragen && d.omzet_cent) {
    const vo = verschil(d.omzet_cent, d.vorige.omzet_cent);
    dias.push({ kleur: 'inkt', inhoud: <><p className="rc-klein">Omzet</p><h1 className="rc-getal rc-bedrag">€ {getal(Math.round(d.omzet_cent / 100))}</h1><p className="rc-tekst">voor de club, zonder wat er gratis is weggegeven.</p>{vo && <p className="rc-klein">{vo}</p>}</> });
  }

  if (namen && d.vrijwilligers.length) {
    dias.push({ kleur: 'groen', inhoud: <>
      <p className="rc-klein">De vaste krachten</p>
      <ol className="rc-namen">{d.vrijwilligers.map((x) => <li key={x.naam}><b>{x.naam}</b><span>{x.diensten} {x.diensten === 1 ? 'dienst' : 'diensten'}</span></li>)}</ol>
    </> });
  }

  dias.push({ kleur: 'zon', inhoud: <>
    <h1 className="rc-groot">Bedankt, vrijwilligers!</h1>
    <p className="rc-tekst">{d.medewerkers > 1 ? `${getal(d.medewerkers)} mensen stonden achter de bar.` : 'Zonder jullie geen kantine.'} Op naar het volgende seizoen.</p>
  </> });
  return dias;
}

/** Weekklok: per dag en uur hoe druk het was. */
function Klok({ klok }: { klok: RecapData['klok'] }) {
  const uren = klok.map((k) => k.uur);
  const van = Math.min(...uren), tot = Math.max(...uren);
  const max = Math.max(...klok.map((k) => k.bonnen));
  const n = (dag: number, uur: number) => klok.find((k) => k.dag === dag && k.uur === uur)?.bonnen ?? 0;
  const top = klok.reduce((a, k) => (k.bonnen > a.bonnen ? k : a), klok[0]);
  const reeks = Array.from({ length: tot - van + 1 }, (_, i) => van + i);
  return (
    <>
      <p className="rc-klein">Het ritme van de kantine</p>
      <h1 className="rc-groot">{dagNaam[top.dag - 1]} rond {top.uur}:00</h1>
      <div className="rc-klok" style={{ gridTemplateColumns: `3em repeat(${reeks.length}, minmax(0, 1fr))` }} role="img" aria-label={`Het drukst op ${dagNaam[top.dag - 1]} rond ${top.uur} uur`}>
        {[1, 2, 3, 4, 5, 6, 7].map((dag) => (
          <div key={dag} className="rc-rij">
            <span>{dagNaam[dag - 1].slice(0, 2)}</span>
            {reeks.map((u) => { const x = n(dag, u); return <i key={u} style={{ opacity: x ? 0.15 + 0.85 * (x / max) : 0.06 }} />; })}
          </div>
        ))}
        <div className="rc-rij rc-uren"><span />{reeks.map((u) => <span key={u}>{u % 2 === 0 ? u : ''}</span>)}</div>
      </div>
    </>
  );
}
