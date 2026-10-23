import { useCallback, useEffect, useState } from 'react';
import { datumTijd, inlogEmail, lees, PROEF, rpc, sb, uitnodigingLink } from '../lib';
import { melding, Qr, useBezig, useSheet } from '../ui';

interface Uitnodiging { id: number; code: string; naam: string; rol: 'medewerker' | 'beheerder'; verloopt: string }

// QR-code om met de wifi te verbinden (zoals telefooncamera's die lezen).
const wifiCode = (naam: string, ww: string) => {
  const e = (s: string) => s.replace(/[\\;,:"]/g, (c) => '\\' + c);
  return `WIFI:T:WPA;S:${e(naam)};P:${e(ww)};;`;
};

/** Beheer → Medewerkers: iemand uitnodigen met een QR-code, en de uitnodigingen die nog open staan. */
export function Uitnodigen() {
  const { open } = useSheet();
  const [naam, setNaam] = useState('');
  const [rol, setRol] = useState<'medewerker' | 'beheerder'>('medewerker');
  const [lijst, setLijst] = useState<Uitnodiging[]>([]);
  const [zelf, setZelf] = useState<boolean | null>(null);
  const [bezig, run] = useBezig();
  const laad = useCallback(async () => {
    const r = await lees(sb.from('uitnodigingen').select('id,code,naam,rol,verloopt').is('gebruikt_ts', null).eq('ingetrokken', false)
      .gt('verloopt', new Date().toISOString()).order('aangemaakt', { ascending: false })) as Uitnodiging[];
    setLijst(r);
    setZelf(await rpc<boolean>('aanmelden_open'));
  }, []);
  useEffect(() => { void run(laad); }, [laad, run]);
  const maak = () => run(async () => {
    const u = await rpc<Uitnodiging>('uitnodiging_maken', { p_naam: naam, p_rol: rol });
    setNaam('');
    await laad();
    open(<UitnodigingScherm u={u} />);
  });
  const trekIn = (u: Uitnodiging) => run(async () => {
    await rpc('uitnodiging_intrekken', { p_id: u.id });
    await laad();
    melding(`Uitnodiging voor ${u.naam} ingetrokken`);
  });
  const zetZelf = (aan: boolean) => run(async () => {
    await rpc('aanmelden_instellen', { p_aan: aan });
    setZelf(aan);
    melding('Opgeslagen');
  });
  return (
    <>
      <h3 className="s">Iemand uitnodigen</h3>
      <p className="mu">Vul de naam in waarmee die persoon gaat inloggen. Er verschijnt een QR-code: laat die scannen met de telefoon van de nieuwe medewerker, die kiest een wachtwoord en is meteen binnen. De code werkt één keer en 24 uur lang.</p>
      <form className="inl" onSubmit={(e) => { e.preventDefault(); void maak(); }}>
        <input className="f" placeholder="Naam, bijv. Jan" value={naam} maxLength={40} onChange={(e) => setNaam(e.target.value)} aria-label="Naam" />
        <select className="f" value={rol} onChange={(e) => setRol(e.target.value as 'medewerker' | 'beheerder')} aria-label="Rol">
          <option value="medewerker">Medewerker</option><option value="beheerder">Beheerder</option>
        </select>
      </form>
      <button className="big" disabled={bezig || !naam.trim()} onClick={maak}>Uitnodiging maken</button>
      {lijst.length > 0 && (
        <div className="card">
          <div className="hd"><span>Nog niet gebruikt</span></div>
          {lijst.map((u) => (
            <div className="row" key={u.id}>
              <span>{u.naam} <span className="mu">· {u.rol} · tot {datumTijd(u.verloopt)}</span></span>
              <span className="inl">
                <button onClick={() => open(<UitnodigingScherm u={u} />)}>Toon</button>
                <button disabled={bezig} onClick={() => trekIn(u)}>Intrekken</button>
              </span>
            </div>
          ))}
        </div>
      )}
      {zelf != null && (
        <label className="check">
          <input type="checkbox" checked={zelf} disabled={bezig} onChange={(e) => zetZelf(e.target.checked)} />
          <span>Ook zelf een account aanvragen op het inlogscherm<br /><span className="mu">Een beheerder keurt die aanvragen goed. Uit is veiliger: dan kan alleen wie is uitgenodigd een account krijgen.</span></span>
        </label>
      )}
    </>
  );
}

/** De QR-codes voor een nieuwe medewerker: eerst de wifi (als de kassa die heeft), dan de uitnodiging. */
function UitnodigingScherm({ u }: { u: Uitnodiging }) {
  const [wifi, setWifi] = useState<{ wifi_naam: string | null; wifi_wachtwoord: string | null } | null>(null);
  useEffect(() => {
    void lees(sb.from('systeem').select('wifi_naam,wifi_wachtwoord').maybeSingle()).then((r) => setWifi(r as typeof wifi), () => setWifi(null));
  }, []);
  const link = uitnodigingLink(u.code);
  const metWifi = !!(wifi?.wifi_naam && wifi.wifi_wachtwoord);
  return (
    <>
      <h2>Uitnodiging voor {u.naam}</h2>
      <p className="mu">Laat {u.naam} de code{metWifi ? 's' : ''} scannen met de camera van de eigen telefoon. Geldig tot {datumTijd(u.verloopt)}, één keer. Deel hem niet in een groepsapp: wie hem als eerste gebruikt, krijgt het account.</p>
      {metWifi && (
        <div className="card uitn">
          <b>1. Verbind met de wifi</b>
          <div className="qr-m"><Qr tekst={wifiCode(wifi!.wifi_naam!, wifi!.wifi_wachtwoord!)} /></div>
          <span className="mu c">Netwerk {wifi!.wifi_naam}</span>
        </div>
      )}
      <div className="card uitn">
        <b>{metWifi ? '2. ' : ''}Open de kassa</b>
        <div className="qr-m"><Qr tekst={link} /></div>
        <span className="mu c">{u.naam} kiest een wachtwoord en is meteen {u.rol}.</span>
      </div>
      <button onClick={() => { void navigator.clipboard?.writeText(link).then(() => melding('Link gekopieerd'), () => melding(link)); }}>Link kopiëren</button>
      {/^https:\/\/\d+\.\d+\.\d+\.\d+/.test(location.origin) && <p className="mu">Zonder DuckDNS komt de telefoon eerst op de welkomstpagina om het certificaat te installeren; daarna gaat {u.naam} met <i>Naar de kassa</i> verder met de uitnodiging.</p>}
    </>
  );
}

/** Wat de nieuwe medewerker ziet na het scannen: wachtwoord kiezen en meteen naar binnen. */
export function UitnodigingAannemen({ code }: { code: string }) {
  const [info, setInfo] = useState<{ naam: string; rol: string; winkel: string } | null>(null);
  const [fout, setFout] = useState('');
  const [ingelogd, setIngelogd] = useState<string | null | undefined>(undefined);
  const [ww, setWw] = useState('');
  const [ww2, setWw2] = useState('');
  const [bezig, run] = useBezig();
  const verder = () => location.replace(location.pathname);
  useEffect(() => {
    void sb.auth.getSession().then(({ data }) => setIngelogd(data.session?.user.email ?? null));
    void rpc<{ naam: string; rol: string; winkel: string } | { fout: string }>('uitnodiging_info', { p_code: code })
      .then((r) => ('fout' in r ? setFout(r.fout) : setInfo(r)), (e: Error) => setFout(e.message));
  }, [code]);
  const aannemen = () => run(async () => {
    if (!info) return;
    if (ww.length < 8) throw new Error('Kies een wachtwoord van minstens 8 tekens');
    if (ww !== ww2) throw new Error('De wachtwoorden zijn niet gelijk');
    const { error } = await sb.auth.signUp({ email: inlogEmail(info.naam), password: ww, options: { data: { naam: info.naam, uitnodiging: code } } });
    if (error) {
      if (/already registered/i.test(error.message)) throw new Error(`Er is al een account met de naam ${info.naam}. Vraag de beheerder om een uitnodiging met een andere naam (bijvoorbeeld met je achternaam erbij).`);
      throw new Error('Deze uitnodiging is verlopen of al gebruikt. Vraag de beheerder om een nieuwe QR-code.');
    }
    verder();
  });
  if (ingelogd === undefined) return <div className="center mu">Laden…</div>;
  return (
    <div className="login">
      {ingelogd ? (
        <>
          <h1>Uitnodiging</h1>
          <p>Op deze telefoon is al iemand ingelogd. Log eerst uit om de uitnodiging te gebruiken.</p>
          <button className="big" onClick={() => void sb.auth.signOut().then(() => setIngelogd(null))}>Uitloggen</button>
          <button className="ghost" onClick={verder}>Naar de kassa</button>
        </>
      ) : fout ? (
        <>
          <h1>Uitnodiging</h1>
          <p className="card warnbox">{fout}</p>
          <button className="big alt" onClick={verder}>Naar het inlogscherm</button>
        </>
      ) : !info ? <p className="mu">Laden…</p> : (
        <>
          <p className="mu">{info.winkel}</p>
          <h1>Welkom {info.naam}</h1>
          <p>Je bent uitgenodigd als {info.rol}. Kies een wachtwoord; daarmee log je voortaan in met de naam <b>{info.naam}</b>.</p>
          <form onSubmit={(e) => { e.preventDefault(); void aannemen(); }}>
            <input type="text" autoComplete="username" value={inlogEmail(info.naam)} readOnly hidden />
            <label htmlFor="uw1">Wachtwoord (minstens 8 tekens)</label>
            <input className="f" id="uw1" type="password" autoComplete="new-password" value={ww} onChange={(e) => setWw(e.target.value)} />
            <label htmlFor="uw2">Nog een keer</label>
            <input className="f" id="uw2" type="password" autoComplete="new-password" value={ww2} onChange={(e) => setWw2(e.target.value)} />
            <button className="big" disabled={bezig}>Account maken en beginnen</button>
          </form>
          {PROEF && <p className="mu">Proefversie: dit account bestaat alleen op dit apparaat.</p>}
        </>
      )}
    </div>
  );
}
