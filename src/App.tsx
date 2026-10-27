import { useEffect, useState } from 'react';
import type { Session } from '@supabase/supabase-js';
import { DataProvider, useData } from './data';
import { bonGevraagd, ingesteld, inlogEmail, lees, PROEF, rpc, lidGevraagd, saldoGevraagd, sb, uitnodigingGevraagd, zuilGevraagd, toonInlognaam, type Profiel } from './lib';
import { proefLaden, proefOpnieuw } from '@proef';
import { melding, Melding, SheetProvider, useBezig, useSheet } from './ui';
import { Bestelling, Kassa, MandBalk, MandContext, useMand, type Mand } from './views/Kassa';
import { Rekeningen } from './views/Rekeningen';
import { Kaarten } from './views/Kaarten';
import { Dienst } from './views/Dienst';
import { LidOverzicht, Saldo, SaldoZuil } from './views/Saldo';
import { BonKlant } from './views/BonKlant';
import { Streeplijst } from './views/Streeplijst';
import { UitnodigingAannemen } from './views/Uitnodigen';
import { Beheer } from './views/Beheer';
import { NieuwNaUpdate } from './wijzigingen';

export function App() {
  if (!ingesteld) return <NietIngesteld />;
  // Klant met een tegoedkaart: alleen het saldo, zonder inloggen.
  if (zuilGevraagd()) return <>{PROEF && <ProefBalk />}<SaldoZuil /><Melding /></>;
  const uitn = uitnodigingGevraagd();
  if (uitn) return <>{PROEF && <ProefBalk />}<UitnodigingAannemen code={uitn} /><Melding /></>;
  const lid = lidGevraagd();
  if (lid != null) return <>{PROEF && <ProefBalk />}<LidOverzicht code={lid} /><Melding /></>;
  const bon = bonGevraagd();
  if (bon) return <>{PROEF && <ProefBalk />}<BonKlant code={bon} /><Melding /></>;
  const saldo = saldoGevraagd();
  if (saldo != null) return <>{PROEF && <ProefBalk />}<Saldo start={saldo} /><Melding /></>;
  return <>{PROEF && <ProefBalk />}<Inlog /><Melding /></>;
}

function ProefBalk() {
  return (
    <div className="proef">
      <span><b>Proefversie</b> · gegevens blijven op dit apparaat</span>
      <button onClick={() => { if (confirm('Alle proefgegevens wissen en opnieuw beginnen?')) void proefOpnieuw(); }}>Wissen</button>
    </div>
  );
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
    if (uid) void laadProfiel();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [uid]);
  // Wachtende medewerker: vanzelf verder zodra de beheerder goedkeurt.
  const wacht = !!profiel && (profiel.rol === 'wacht' || !profiel.actief);
  useEffect(() => {
    if (!wacht) return;
    const iv = setInterval(() => void laadProfiel(), 4000);
    return () => clearInterval(iv);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [wacht, uid]);

  if (sessie === undefined) return <div className="center mu">Laden…</div>;
  if (!sessie) return <Aanmelden />;
  if (!profiel) return <div className="center"><p className="mu">{fout || 'Laden…'}</p>{fout && <button className="big" onClick={laadProfiel}>Opnieuw</button>}</div>;
  if (wacht) return <Wachten profiel={profiel} opnieuw={laadProfiel} />;
  return <DataProvider profiel={profiel}><Kassasysteem /></DataProvider>;
}

type Tab = 'kassa' | 'rekeningen' | 'kaarten' | 'streeplijst' | 'dienst' | 'beheer';

function Kassasysteem() {
  const [tab, setTab] = useState<Tab>('kassa');
  const [mand, setMand] = useState<Mand>({});
  const [doel, setDoel] = useState<number | null>(null);
  return (
    <MandContext.Provider value={{ mand, setMand, doel, setDoel }}>
      <SheetProvider>
        <Scherm tab={tab} setTab={setTab} />
        <NieuwNaUpdate />
      </SheetProvider>
    </MandContext.Provider>
  );
}

function Scherm({ tab, setTab }: { tab: Tab; setTab: (t: Tab) => void }) {
  const { profiel, winkel, verbonden, geladen, dienst, methoden, rekeningen } = useData();
  const { open } = useSheet();
  const { setDoel } = useMand();
  // Uitgezette betaalmethoden verdwijnen uit het menu; open rekeningen blijven te zien tot ze zijn afgerekend.
  const tabs: [Tab, string][] = [['kassa', 'Kassa']];
  if (methoden.rekening || rekeningen.length) tabs.push(['rekeningen', 'Rekeningen']);
  if (methoden.kaart) tabs.push(['kaarten', 'Kaarten']);
  if (methoden.lat) tabs.push(['streeplijst', 'Streeplijst']);
  tabs.push(['dienst', 'Dienst']);
  if (profiel.rol === 'beheerder') tabs.push(['beheer', 'Beheer']);
  useEffect(() => { if (!tabs.some(([t]) => t === tab)) setTab('kassa'); });
  return (
    <div className="app">
      <header>
        <h1>{winkel}</h1>
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
            {tab === 'streeplijst' && <Streeplijst />}
            {tab === 'dienst' && <Dienst />}
            {tab === 'beheer' && <Beheer />}
          </>
        )}
      </main>
      {tab === 'kassa' && <MandBalk onOpen={() => open(<Bestelling />)} />}
      <nav className={tabs.length > 5 ? 'veel' : ''}>
        {tabs.map(([t, l]) => <button key={t} className={t === tab ? 'on' : ''} onClick={() => setTab(t)}>{l}</button>)}
      </nav>
    </div>
  );
}

function Account() {
  const { profiel } = useData();
  const [naam, setNaam] = useState(profiel.naam);
  const [ww, setWw] = useState('');
  const [login, setLogin] = useState('');
  const [bezig, run] = useBezig();
  useEffect(() => { void sb.auth.getSession().then(({ data }) => setLogin(toonInlognaam(data.session?.user.email ?? ''))); }, []);
  return (
    <>
      <h2>{profiel.naam}</h2>
      <p className="mu">{profiel.rol === 'beheerder' ? 'Beheerder' : 'Medewerker'}{login ? ` · je logt in met "${login}"` : ''}</p>
      <label htmlFor="mn">Je naam (staat op de bon)</label>
      <div className="inl">
        <input className="f" id="mn" value={naam} onChange={(e) => setNaam(e.target.value)} />
        <button disabled={bezig} onClick={() => run(async () => { await rpc('mijn_naam_wijzigen', { p_naam: naam }); melding('Opgeslagen, log opnieuw in om het overal te zien'); })}>Opslaan</button>
      </div>
      <label htmlFor="nw">Nieuw wachtwoord</label>
      <div className="inl">
        <input className="f" id="nw" type="password" autoComplete="new-password" value={ww} onChange={(e) => setWw(e.target.value)} />
        <button disabled={bezig} onClick={() => run(async () => {
          if (ww.length < 8) throw new Error('Kies een wachtwoord van minstens 8 tekens');
          const { error } = await sb.auth.updateUser({ password: ww });
          if (error) throw new Error(error.message);
          setWw('');
          melding('Wachtwoord gewijzigd');
        })}>Wijzig</button>
      </div>
      <p className="mu" style={{ marginTop: 16 }}>Tip: zet de kassa op je beginscherm (in je browser: Delen of menu → Zet op beginscherm). Dan opent hij als een app.</p>
      <button className="big alt" onClick={() => void sb.auth.signOut()}>{PROEF ? 'Uitloggen (wisselen van account)' : 'Uitloggen'}</button>
    </>
  );
}

function Aanmelden() {
  const [nieuw, setNieuw] = useState(false);
  const [naam, setNaam] = useState(PROEF ? 'Demo' : '');
  const [ww, setWw] = useState(PROEF ? 'proef1234' : '');
  const [bezig, run] = useBezig();
  const [klaar, setKlaar] = useState(!PROEF);
  // Mag je hier zelf een account aanvragen? (De beheerder kan dat uitzetten; dan alleen met een uitnodiging.)
  const [open, setOpen] = useState(true);
  useEffect(() => { void rpc<boolean>('aanmelden_open').then((o) => { setOpen(o !== false); if (o === false) setNieuw(false); }, () => {}); }, [klaar]);
  useEffect(() => { if (PROEF) void proefLaden().then((opgeslagen) => {
    setKlaar(true);
    if (!opgeslagen) melding('Opslaan in deze browser lukt nu niet. De proefkassa werkt, maar wat je doet is weg als je de pagina sluit. Sluit andere tabbladen met de proefversie en laad de pagina opnieuw.');
  }, (e: Error) => { setKlaar(true); melding('De proefkassa kon niet starten: ' + e.message + '. Probeer opnieuw of tik bovenaan op Wissen.'); }); }, []);
  const verstuur = () => run(async () => {
    if (!naam.trim()) throw new Error('Vul je naam in');
    const email = inlogEmail(naam);
    if (nieuw) {
      if (ww.length < 8) throw new Error('Kies een wachtwoord van minstens 8 tekens');
      const { data, error } = await sb.auth.signUp({ email, password: ww, options: { data: { naam: naam.trim() } } });
      if (error) throw new Error(/already registered/i.test(error.message) ? 'Deze naam is al in gebruik, kies een andere' : error.message);
      if (!data.session) melding('Bevestig je e-mailadres via de link in je mail en log daarna in');
    } else {
      const { error } = await sb.auth.signInWithPassword({ email, password: ww });
      if (error) throw new Error(/Invalid login/i.test(error.message)
        ? (PROEF ? 'Naam of wachtwoord klopt niet. Probeer Demo met proef1234, of tik bovenaan op Wissen.' : 'Naam of wachtwoord klopt niet')
        : error.message);
    }
  });
  return (
    <div className="login">
      <h1>Bar-kassa</h1>
      <div className="chips">
        <button className={!nieuw ? 'on' : ''} onClick={() => setNieuw(false)}>Inloggen</button>
        {open && <button className={nieuw ? 'on' : ''} onClick={() => setNieuw(true)}>Account aanmaken</button>}
      </div>
      <form onSubmit={(e) => { e.preventDefault(); void verstuur(); }}>
        <label htmlFor="ln">Naam</label>
        <input className="f" id="ln" autoComplete="username" autoCapitalize="words" value={naam} onChange={(e) => setNaam(e.target.value)} />
        <label htmlFor="lw">Wachtwoord</label>
        <input className="f" id="lw" type="password" autoComplete={nieuw ? 'new-password' : 'current-password'} value={ww} onChange={(e) => setWw(e.target.value)} />
        <button className="big" disabled={bezig || !klaar}>{!klaar ? 'Proefkassa klaarzetten…' : nieuw ? 'Account aanmaken' : 'Inloggen'}</button>
      </form>
      {!klaar && <p className="mu">De eerste keer duurt dit even: de proefkassa (ongeveer 15 MB) wordt op dit apparaat klaargezet. Laat deze pagina open. Staat de proefversie nog in een ander tabblad open, sluit dat dan.</p>}
      {PROEF && !nieuw && (
        <div className="kaartje">
          <p><b>Proefaccounts</b> (wachtwoord <code>proef1234</code>):</p>
          <p><b>Demo</b>: beheerder, ziet alles. <b>Anna</b>: medewerker. <b>Kees</b>: wacht nog op goedkeuring.</p>
        </div>
      )}
      {nieuw && !PROEF && <p className="mu">Een nieuw account moet eerst door een beheerder worden goedgekeurd. Sneller: vraag de beheerder om een uitnodiging (een QR-code), dan ben je meteen binnen.</p>}
      {!open && <p className="mu">Nieuw? Vraag de beheerder om een uitnodiging: je scant een QR-code en kiest een wachtwoord.</p>}
      {!nieuw && <p className="mu">Wachtwoord vergeten? Vraag een beheerder om een nieuw wachtwoord in te stellen.</p>}
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
