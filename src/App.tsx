import { useEffect, useState } from 'react';
import type { Session } from '@supabase/supabase-js';
import { DataProvider, useData } from './data';
import { ingesteld, lees, rpc, sb, type Profiel } from './lib';
import { melding, Melding, SheetProvider, useBezig, useSheet } from './ui';
import { Bestelling, Kassa, MandBalk, MandContext, useMand, type Mand } from './views/Kassa';
import { Rekeningen } from './views/Rekeningen';
import { Kaarten } from './views/Kaarten';
import { Dienst } from './views/Dienst';
import { Beheer } from './views/Beheer';

export function App() {
  if (!ingesteld) return <NietIngesteld />;
  return <><Inlog /><Melding /></>;
}

function Inlog() {
  const [sessie, setSessie] = useState<Session | null | undefined>(undefined);
  const [profiel, setProfiel] = useState<Profiel | null>(null);
  const [fout, setFout] = useState('');

  useEffect(() => {
    void sb.auth.getSession().then(({ data }) => setSessie(data.session));
    const { data } = sb.auth.onAuthStateChange((_e, s) => setSessie(s));
    return () => data.subscription.unsubscribe();
  }, []);

  const uid = sessie?.user.id;
  const laadProfiel = async () => {
    if (!uid) return;
    try {
      setProfiel(await lees(sb.from('profielen').select('*').eq('id', uid).single()) as Profiel);
      setFout('');
    } catch (e) { setFout((e as Error).message); }
  };
  useEffect(() => {
    setProfiel(null);
    if (!uid) return;
    void laadProfiel();
    // Wachtende medewerker: live zien wanneer de beheerder goedkeurt.
    const k = sb.channel('profiel').on('postgres_changes', { event: 'UPDATE', schema: 'public', table: 'profielen', filter: `id=eq.${uid}` }, () => void laadProfiel()).subscribe();
    return () => void sb.removeChannel(k);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [uid]);

  if (sessie === undefined) return <div className="center mu">Laden…</div>;
  if (!sessie) return <Aanmelden />;
  if (!profiel) return <div className="center"><p className="mu">{fout || 'Laden…'}</p>{fout && <button className="big" onClick={laadProfiel}>Opnieuw</button>}</div>;
  if (profiel.rol === 'wacht' || !profiel.actief) return <Wachten profiel={profiel} opnieuw={laadProfiel} />;
  return <DataProvider profiel={profiel}><Kassasysteem /></DataProvider>;
}

type Tab = 'kassa' | 'rekeningen' | 'kaarten' | 'dienst' | 'beheer';

function Kassasysteem() {
  const [tab, setTab] = useState<Tab>('kassa');
  const [mand, setMand] = useState<Mand>({});
  const [doel, setDoel] = useState<number | null>(null);
  return (
    <MandContext.Provider value={{ mand, setMand, doel, setDoel }}>
      <SheetProvider>
        <Scherm tab={tab} setTab={setTab} />
      </SheetProvider>
    </MandContext.Provider>
  );
}

function Scherm({ tab, setTab }: { tab: Tab; setTab: (t: Tab) => void }) {
  const { profiel, winkel, verbonden, geladen, dienst } = useData();
  const { open } = useSheet();
  const { setDoel } = useMand();
  const tabs: [Tab, string][] = [['kassa', 'Kassa'], ['rekeningen', 'Rekeningen'], ['kaarten', 'Kaarten'], ['dienst', 'Dienst']];
  if (profiel.rol === 'beheerder') tabs.push(['beheer', 'Beheer']);
  return (
    <div className="app">
      <header>
        <b>{winkel}</b>
        <span className={'dot ' + (dienst ? 'on' : '')} title={dienst ? 'Kassa open' : 'Kassa dicht'} />
        <button className="who" onClick={() => open(<Account />)}>{profiel.naam}</button>
      </header>
      {!verbonden && <div className="offline">Geen verbinding met de server. Afrekenen lukt pas weer als de verbinding terug is.</div>}
      <main>
        {!geladen ? <p className="mu">Laden…</p> : (
          <>
            {tab === 'kassa' && <Kassa naarDienst={() => setTab('dienst')} />}
            {tab === 'rekeningen' && <Rekeningen bestelVoor={(id) => { setDoel(id); setTab('kassa'); }} />}
            {tab === 'kaarten' && <Kaarten />}
            {tab === 'dienst' && <Dienst />}
            {tab === 'beheer' && <Beheer />}
          </>
        )}
      </main>
      {tab === 'kassa' && <MandBalk onOpen={() => open(<Bestelling />)} />}
      <nav>
        {tabs.map(([t, l]) => <button key={t} className={t === tab ? 'on' : ''} onClick={() => setTab(t)}>{l}</button>)}
      </nav>
    </div>
  );
}

function Account() {
  const { profiel } = useData();
  const [naam, setNaam] = useState(profiel.naam);
  const [bezig, run] = useBezig();
  return (
    <>
      <h2>{profiel.naam}</h2>
      <p className="mu">{profiel.rol === 'beheerder' ? 'Beheerder' : 'Medewerker'}</p>
      <label htmlFor="mn">Je naam (staat op de bon)</label>
      <div className="inl">
        <input className="f" id="mn" value={naam} onChange={(e) => setNaam(e.target.value)} />
        <button disabled={bezig} onClick={() => run(async () => { await rpc('mijn_naam_wijzigen', { p_naam: naam }); melding('Opgeslagen, log opnieuw in om het overal te zien'); })}>Opslaan</button>
      </div>
      <p className="mu" style={{ marginTop: 16 }}>Tip: zet de kassa op je beginscherm (in je browser: Delen of menu → Zet op beginscherm). Dan opent hij als een app.</p>
      <button className="big alt" onClick={() => void sb.auth.signOut()}>Uitloggen</button>
    </>
  );
}

function Aanmelden() {
  const [nieuw, setNieuw] = useState(false);
  const [naam, setNaam] = useState('');
  const [email, setEmail] = useState('');
  const [ww, setWw] = useState('');
  const [bezig, run] = useBezig();
  const verstuur = () => run(async () => {
    if (nieuw) {
      if (!naam.trim()) throw new Error('Vul je naam in');
      if (ww.length < 8) throw new Error('Kies een wachtwoord van minstens 8 tekens');
      const { data, error } = await sb.auth.signUp({ email, password: ww, options: { data: { naam: naam.trim() } } });
      if (error) throw new Error(error.message);
      if (!data.session) melding('Bevestig je e-mailadres via de link in je mail en log daarna in');
    } else {
      const { error } = await sb.auth.signInWithPassword({ email, password: ww });
      if (error) throw new Error(error.message === 'Invalid login credentials' ? 'E-mailadres of wachtwoord klopt niet' : error.message);
    }
  });
  return (
    <div className="login">
      <h1>Bar-kassa</h1>
      <div className="chips">
        <button className={!nieuw ? 'on' : ''} onClick={() => setNieuw(false)}>Inloggen</button>
        <button className={nieuw ? 'on' : ''} onClick={() => setNieuw(true)}>Account aanmaken</button>
      </div>
      <form onSubmit={(e) => { e.preventDefault(); void verstuur(); }}>
        {nieuw && (<><label htmlFor="ln">Naam</label><input className="f" id="ln" autoComplete="name" value={naam} onChange={(e) => setNaam(e.target.value)} /></>)}
        <label htmlFor="le">E-mailadres</label>
        <input className="f" id="le" type="email" autoComplete="email" value={email} onChange={(e) => setEmail(e.target.value)} />
        <label htmlFor="lw">Wachtwoord</label>
        <input className="f" id="lw" type="password" autoComplete={nieuw ? 'new-password' : 'current-password'} value={ww} onChange={(e) => setWw(e.target.value)} />
        <button className="big" disabled={bezig}>{nieuw ? 'Account aanmaken' : 'Inloggen'}</button>
      </form>
      {nieuw && <p className="mu">Het allereerste account wordt beheerder. Alle volgende accounts moeten door een beheerder worden goedgekeurd.</p>}
    </div>
  );
}

function Wachten({ profiel, opnieuw }: { profiel: Profiel; opnieuw: () => void }) {
  return (
    <div className="login">
      <h1>Hallo {profiel.naam}</h1>
      <p>{profiel.actief ? 'Je account is aangemaakt. Een beheerder moet je nog toegang geven. Zodra dat gebeurd is, gaat dit scherm vanzelf verder.' : 'Je account is uitgeschakeld. Neem contact op met een beheerder.'}</p>
      <button className="big" onClick={opnieuw}>Opnieuw kijken</button>
      <button className="ghost" onClick={() => void sb.auth.signOut()}>Uitloggen</button>
    </div>
  );
}

function NietIngesteld() {
  return (
    <div className="login">
      <h1>Bar-kassa</h1>
      <p>De kassa is nog niet gekoppeld aan een database.</p>
      <p className="mu">Vul in <code>config.js</code> het adres en de <i>anon public</i> sleutel van je Supabase-project in. Zie de README voor de stappen.</p>
    </div>
  );
}
