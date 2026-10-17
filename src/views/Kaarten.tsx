import { useCallback, useEffect, useState } from 'react';
import { useData } from '../data';
import { centTekst, datumTijd, eur, lees, naarCent, rpc, sb, type KaartInfo } from '../lib';
import { Bedrag, melding, Qr, Rij, useBezig, useSheet } from '../ui';
import { KaartKiezen } from './Afrekenen';

type Kaart = Omit<KaartInfo, 'betaalcode'>;

export function Kaarten() {
  const { open } = useSheet();
  const [kaarten, setKaarten] = useState<Kaart[]>([]);
  const laad = useCallback(async () => {
    try {
      setKaarten(await lees(sb.from('kaarten').select('id,nummer,saldo_cent,geblokkeerd').order('nummer')) as Kaart[]);
    } catch (e) { melding((e as Error).message); }
  }, []);
  useEffect(() => { void laad(); }, [laad]);
  const metTegoed = kaarten.filter((k) => k.saldo_cent > 0 || k.geblokkeerd);
  const toon = (id: number) => open(<KaartScherm id={id} onWijziging={laad} />);
  return (
    <>
      <div className="kpi">
        <div><span className="mu">Kaarten</span><b>{kaarten.length}</b></div>
        <div><span className="mu">Tegoed in omloop</span><b>{eur(kaarten.reduce((a, k) => a + (k.geblokkeerd ? 0 : k.saldo_cent), 0))}</b></div>
      </div>
      <button className="big" onClick={() => open(<KaartKiezen betalen={false} onKaart={(_, i) => toon(i.id)} />)}>Kaart scannen of opzoeken</button>
      <h3 className="s">Kaarten met tegoed</h3>
      {metTegoed.map((k) => <Rij key={k.id} className={k.geblokkeerd ? 'vd' : ''} l={`Kaart ${k.nummer}${k.geblokkeerd ? ' (geblokkeerd)' : ''}`} r={eur(k.saldo_cent)} onClick={() => toon(k.id)} />)}
      {!metTegoed.length && <p className="mu">Nog geen kaarten met tegoed. Nieuwe kaarten maakt een beheerder bij Beheer → Kaarten.</p>}
    </>
  );
}

function KaartScherm({ id, onWijziging }: { id: number; onWijziging: () => void }) {
  const { profiel, dienst } = useData();
  const { open } = useSheet();
  const [k, setK] = useState<Kaart | null>(null);
  const [v, setV] = useState('');
  const [bezig, run] = useBezig();
  const beheer = profiel.rol === 'beheerder';
  const laad = useCallback(async () => {
    setK(await lees(sb.from('kaarten').select('id,nummer,saldo_cent,geblokkeerd').eq('id', id).single()) as Kaart);
  }, [id]);
  useEffect(() => { void run(laad); }, [laad, run]);
  if (!k) return <p className="mu">Laden…</p>;

  const bedrag = naarCent(v);
  const opwaarderen = (methode: 'contant' | 'pin') => run(async () => {
    if (!(bedrag > 0)) throw new Error('Kies of vul een bedrag in');
    const saldo = await rpc<number>('kaart_opwaarderen', { p_kaart_id: k.id, p_bedrag_cent: bedrag, p_methode: methode });
    setV('');
    await laad();
    onWijziging();
    melding(`Opgewaardeerd, saldo ${eur(saldo)}`);
  });
  const blok = (b: boolean) => run(async () => { await rpc('kaart_blokkeren', { p_kaart_id: k.id, p_blok: b }); await laad(); onWijziging(); });

  return (
    <>
      <h2>Kaart {k.nummer}</h2>
      <div className="big-n">{eur(k.saldo_cent)}</div>
      {k.geblokkeerd && <p className="stamp">GEBLOKKEERD</p>}
      {!k.geblokkeerd && (dienst ? (
        <>
          <label htmlFor="ta">Opwaarderen</label>
          <div className="quick">{[500, 1000, 2000].map((x) => <button key={x} onClick={() => setV(centTekst(x))}>{eur(x)}</button>)}</div>
          <Bedrag id="ta" waarde={v} onChange={setV} placeholder="Ander bedrag, bijvoorbeeld 7,50" />
          <div className="btns" style={{ marginTop: 8 }}>
            <button className="big m-cash" disabled={bezig} onClick={() => opwaarderen('contant')}>Contant ontvangen</button>
            <button className="big m-pin" disabled={bezig} onClick={() => opwaarderen('pin')}>Pin ontvangen</button>
          </div>
        </>
      ) : <p className="card warnbox">Open eerst de kassa (tabblad Dienst) om op te waarderen.</p>)}
      {beheer && <KaartBeheer k={k} onKlaar={async () => { await laad(); onWijziging(); }} />}
      {!k.geblokkeerd && <button className="ghost" disabled={bezig} onClick={() => blok(true)}>Kaart blokkeren (kwijt)</button>}
      {k.geblokkeerd && beheer && <button className="ghost" disabled={bezig} onClick={() => blok(false)}>Blokkade opheffen</button>}
      {beheer && <button className="ghost" onClick={() => open(<KaartHistorie k={k} />)}>Geschiedenis bekijken</button>}
    </>
  );
}

function KaartBeheer({ k, onKlaar }: { k: Kaart; onKlaar: () => Promise<void> }) {
  const [code, setCode] = useState<string | null>(null);
  const [naar, setNaar] = useState('');
  const [bezig, run] = useBezig();
  useEffect(() => {
    void rpc<{ code: string }[]>('kaart_codes', { p_nummers: [k.nummer] }).then((r) => setCode(r?.[0]?.code ?? null)).catch(() => {});
  }, [k.nummer]);
  const overzetten = () => run(async () => {
    if (!naar.trim()) throw new Error('Typ de code of het nummer van de nieuwe kaart');
    const s = await rpc<number>('kaart_overzetten', { p_van: k.id, p_naar: naar });
    setNaar('');
    await onKlaar();
    melding(`Overgezet, nieuwe kaart heeft ${eur(s)}`);
  });
  return (
    <>
      {code && (
        <div className="bon print qrs one">
          <div className="qc"><Qr tekst={code} /><b>Kaart {k.nummer}</b><small>{code}</small></div>
        </div>
      )}
      {code && <button className="ghost" onClick={() => window.print()}>QR-code printen</button>}
      {k.saldo_cent > 0 && (
        <>
          <label htmlFor="naar">Tegoed overzetten naar andere kaart (deze wordt geblokkeerd)</label>
          <div className="inl">
            <input className="f" id="naar" value={naar} onChange={(e) => setNaar(e.target.value)} placeholder="Code of nummer nieuwe kaart" />
            <button disabled={bezig} onClick={overzetten}>Zet over</button>
          </div>
        </>
      )}
    </>
  );
}

const soortNaam: Record<string, string> = { opwaardering: 'Opgewaardeerd', betaling: 'Betaald', annulering: 'Teruggezet (annulering)', overzetting: 'Overgezet' };

function KaartHistorie({ k }: { k: Kaart }) {
  const [h, setH] = useState<{ ts: string; bedrag_cent: number; soort: string; methode: string | null; bonnummer: number | null; door_naam: string | null }[] | null>(null);
  useEffect(() => { void rpc<typeof h>('kaart_historie', { p_kaart_id: k.id }).then(setH).catch((e) => melding(e.message)); }, [k.id]);
  return (
    <>
      <h2>Kaart {k.nummer}: geschiedenis</h2>
      {!h ? <p className="mu">Laden…</p> : !h.length ? <p className="mu">Nog niets gebeurd met deze kaart.</p> : h.map((x, i) => (
        <Rij key={i} l={<>{soortNaam[x.soort]}{x.methode ? ` (${x.methode})` : ''}{x.bonnummer ? `, bon ${x.bonnummer}` : ''}<br /><span className="mu">{datumTijd(x.ts)}{x.door_naam ? ` · ${x.door_naam}` : ''}</span></>} r={(x.bedrag_cent > 0 ? '+' : '') + eur(x.bedrag_cent)} />
      ))}
    </>
  );
}
