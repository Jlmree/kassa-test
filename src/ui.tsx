import { createContext, useCallback, useContext, useEffect, useRef, useState, type ReactNode } from 'react';
import qrcode from 'qrcode-generator';
import { bonTekst, eur, methodeNaam, datumTijd, saldoLink, tril, type Bon } from './lib';
import logo from './logo.webp';

// ─── Melding onderin ───

let zetMelding: (t: string, goed?: boolean) => void = () => {};
/** Melding onderin die vanzelf verdwijnt. goed: groen met een vinkje, bijv. "Afrekenen gelukt". */
export const melding = (t: string, goed = false) => zetMelding(t, goed);

export function Melding() {
  const [m, setM] = useState<{ t: string; goed: boolean; n: number } | null>(null);
  useEffect(() => {
    let h: number, n = 0;
    zetMelding = (t, goed = false) => { setM({ t, goed, n: ++n }); clearTimeout(h); h = window.setTimeout(() => setM(null), 2600); };
  }, []);
  if (!m) return null;
  return (
    <div key={m.n} className={'toast' + (m.goed ? ' goed' : '')} role="status">
      {m.goed && <svg aria-hidden="true" viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" strokeWidth="3" strokeLinecap="round" strokeLinejoin="round"><path d="M5 12.5l4.5 4.5L19 7.5" /></svg>}
      {m.t}
    </div>
  );
}

/** Voert een actie uit, blokkeert dubbel tikken en toont fouten als melding. */
export function useBezig(): [boolean, <T>(f: () => Promise<T>) => Promise<T | undefined>] {
  const [bezig, setBezig] = useState(false);
  const lock = useRef(false);
  const run = useCallback(async <T,>(f: () => Promise<T>) => {
    if (lock.current) return undefined;
    lock.current = true;
    setBezig(true);
    try {
      return await f();
    } catch (e) {
      tril('fout');
      melding(e instanceof Error ? e.message : String(e));
      return undefined;
    } finally {
      lock.current = false;
      setBezig(false);
    }
  }, []);
  return [bezig, run];
}

// ─── Onderblad (sheet) ───

interface SheetCtx { open: (n: ReactNode) => void; sluit: () => void }
const SheetContext = createContext<SheetCtx>({ open: () => {}, sluit: () => {} });
export const useSheet = () => useContext(SheetContext);

export function SheetProvider({ children }: { children: ReactNode }) {
  const [inhoud, setInhoud] = useState<ReactNode>(null);
  const [sleutel, setSleutel] = useState(0);
  const open = useCallback((n: ReactNode) => { setInhoud(n); setSleutel((k) => k + 1); }, []);
  const sluit = useCallback(() => setInhoud(null), []);
  useEffect(() => {
    if (!inhoud) return;
    const k = (e: KeyboardEvent) => e.key === 'Escape' && sluit();
    addEventListener('keydown', k);
    return () => removeEventListener('keydown', k);
  }, [inhoud, sluit]);
  return (
    <SheetContext.Provider value={{ open, sluit }}>
      {children}
      {inhoud && (
        <div className="sheet" onClick={(e) => e.target === e.currentTarget && sluit()}>
          <Blad key={sleutel} sluit={sluit}>{inhoud}</Blad>
        </div>
      )}
    </SheetContext.Provider>
  );
}

/** Het blad zelf: omlaag vegen sluit het, zoals op een telefoon gewoon is. */
function Blad({ children, sluit }: { children: ReactNode; sluit: () => void }) {
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const el = ref.current!;
    const achter = el.parentElement!;
    let x0 = 0, y0 = 0, dy = 0, vy = 0, yVorig = 0, tVorig = 0;
    let mogelijk = false, slepen = false;
    const zet = (y: number, anim: boolean) => {
      el.style.transition = achter.style.transition = anim ? 'transform .18s ease-out, background-color .18s ease-out' : 'none';
      el.style.transform = y ? `translateY(${y}px)` : '';
      achter.style.backgroundColor = y ? `rgba(0, 0, 0, ${0.45 * Math.max(0, 1 - y / el.offsetHeight)})` : '';
    };
    const start = (e: TouchEvent) => {
      // Alleen als het blad bovenaan staat; anders scrol je gewoon door de inhoud.
      mogelijk = e.touches.length === 1 && (el.scrollTop <= 0 || !!(e.target as Element).closest?.('.grab'));
      slepen = false;
      x0 = e.touches[0].clientX; y0 = yVorig = e.touches[0].clientY; tVorig = e.timeStamp; dy = vy = 0;
    };
    const beweeg = (e: TouchEvent) => {
      if (!mogelijk) return;
      const { clientX: x, clientY: y } = e.touches[0];
      if (!slepen) {
        // Omhoog of opzij (bijv. door de snelknoppen): niet slepen.
        if (y - y0 < -4 || Math.abs(x - x0) > Math.abs(y - y0)) { mogelijk = false; return; }
        if (y - y0 < 10) return;
        slepen = true;
        y0 = y;
      }
      e.preventDefault();
      vy = (y - yVorig) / Math.max(1, e.timeStamp - tVorig);
      yVorig = y; tVorig = e.timeStamp;
      dy = Math.max(0, y - y0);
      zet(dy, false);
    };
    const eind = () => {
      if (!slepen) return;
      slepen = false;
      if (dy > Math.min(140, el.offsetHeight / 4) || vy > 0.6) {
        zet(el.offsetHeight, true);
        window.setTimeout(sluit, 180);
      } else zet(0, true);
    };
    el.addEventListener('touchstart', start, { passive: true });
    el.addEventListener('touchmove', beweeg, { passive: false });
    el.addEventListener('touchend', eind);
    el.addEventListener('touchcancel', eind);
    return () => {
      el.removeEventListener('touchstart', start);
      el.removeEventListener('touchmove', beweeg);
      el.removeEventListener('touchend', eind);
      el.removeEventListener('touchcancel', eind);
    };
  }, [sluit]);
  // Schermlezers noemen het blad naar zijn eerste kop.
  useEffect(() => {
    const kop = ref.current?.querySelector('h2, h3');
    if (kop) { kop.id ||= 'blad-kop'; ref.current!.setAttribute('aria-labelledby', kop.id); }
  });
  return (
    <div className="sh" role="dialog" aria-modal="true" ref={ref}>
      <div className="grab" />
      {children}
    </div>
  );
}

// ─── Bon ───

export function BonPapier({ bon }: { bon: Bon }) {
  return (
    <div className="bon print">
      <img className="watermerk" src={logo} alt="" />
      <h3>{bon.winkel}</h3>
      <p className="c">{datumTijd(bon.ts)}</p>
      <p className="c">Bon {bon.bonnummer}</p>
      {bon.rekening_naam && <p className="c">Rekening van {bon.rekening_naam}</p>}
      {bon.geannuleerd && <p className="stamp">GEANNULEERD</p>}
      {bon.regels.map((r, i) => (
        <div className="bl" key={i}><span>{r.aantal}× {r.naam}</span><span>{eur(r.prijs_cent * r.aantal)}</span></div>
      ))}
      <div className="bl tt"><b>Totaal</b><b>{eur(bon.totaal_cent)}</b></div>
      {bon.betalingen.map((p, i) => (
        <div key={i}>
          <div className="bl"><span>{methodeNaam[p.methode]}{p.kaart_nummer ? ` (kaart ${p.kaart_nummer})` : ''}{p.lid_naam ? ` van ${p.lid_naam}` : ''}{p.reden ? ` (${p.reden})` : ''}</span><span>{eur(p.bedrag_cent)}</span></div>
          {p.gegeven_cent != null && (p.wisselgeld_cent || p.op_kaart_cent) ? (
            <><div className="bl"><span>Gegeven</span><span>{eur(p.gegeven_cent)}</span></div>
              {p.wisselgeld_cent ? <div className="bl"><span>Wisselgeld</span><span>{eur(p.wisselgeld_cent)}</span></div> : null}</>
          ) : null}
          {p.op_kaart_cent ? (
            <><div className="bl"><span>Op kaart {p.op_kaart_nummer}</span><span>{eur(p.op_kaart_cent)}</span></div>
              {p.op_kaart_saldo_na != null && <div className="bl"><span>Saldo kaart</span><span>{eur(p.op_kaart_saldo_na)}</span></div>}</>
          ) : null}
          {p.kaart_saldo_na != null && <div className="bl"><span>Saldo kaart</span><span>{eur(p.kaart_saldo_na)}</span></div>}
        </div>
      ))}
      {bon.door_naam && <p className="c">Bediend door {bon.door_naam}</p>}
      <p className="c">Bedankt!</p>
    </div>
  );
}

export async function deelBon(bon: Bon) {
  const t = bonTekst(bon);
  try {
    if (navigator.share) { await navigator.share({ title: `Bon ${bon.bonnummer}`, text: t }); return; }
  } catch (e) {
    if ((e as Error).name === 'AbortError') return;
  }
  try { await navigator.clipboard.writeText(t); melding('Bon gekopieerd'); } catch { melding('Delen lukt hier niet, gebruik Printen'); }
}

// ─── QR ───

/** Tegoedkaart op creditcardformaat (85,6 × 54 mm), om te printen en uit te knippen. */
/**
 * Een gemaakt bestand (bijv. Excel) opslaan. Het maken duurt even; daarna moet je zelf nog
 * een keer tikken, anders weigert een telefoon het downloaden of delen.
 */
export function BestandKlaar({ naam, blob, uitleg }: { naam: string; blob: Blob; uitleg?: string }) {
  const [url] = useState(() => URL.createObjectURL(blob));
  useEffect(() => () => URL.revokeObjectURL(url), [url]);
  const bestand = new File([blob], naam, { type: blob.type });
  const delen = typeof navigator.canShare === 'function' && navigator.canShare({ files: [bestand] }) && matchMedia('(pointer: coarse)').matches;
  const deel = () => navigator.share({ files: [bestand], title: naam }).catch((e: Error) => {
    if (e.name !== 'AbortError') melding('Delen lukte niet. Probeer Downloaden.');
  });
  return (
    <>
      <h2>Bestand is klaar</h2>
      <p className="mu">{naam} · {Math.max(1, Math.round(blob.size / 1024))} kB</p>
      {uitleg && <p>{uitleg}</p>}
      {delen && <button className="big" onClick={() => void deel()}>Opslaan of delen</button>}
      <a className={'big knop-link' + (delen ? ' alt' : '')} href={url} download={naam}>Downloaden</a>
      {delen && <p className="mu">Op een telefoon kun je het bestand met Opslaan of delen direct in Bestanden zetten, mailen of naar de penningmeester sturen.</p>}
    </>
  );
}

export function QrKaart({ nummer, code, winkel }: { nummer: number; code: string; winkel: string }) {
  return (
    <div className="kk">
      <img className="watermerk" src={logo} alt="" />
      <Qr tekst={saldoLink(code)} />
      <div className="kk-t">
        <span className="kk-w">{winkel}</span>
        <span>Tegoedkaart</span>
        <b>Kaart {nummer}</b>
        <small>{code}</small>
        <span className="kk-s">Scan voor je saldo</span>
      </div>
    </div>
  );
}

/** Achterkant van een tegoedkaart: het logo groot in het midden, met de naam van de bar. */
export function KaartAchter({ winkel, naam }: { winkel: string; naam: boolean }) {
  return (
    <div className="kk kk-achter">
      <img src={logo} alt="" />
      {naam && <b>{winkel}</b>}
    </div>
  );
}

/**
 * Tegoedkaarten om te printen: per A4 tien (2 naast elkaar, 5 onder elkaar). Met achterkant
 * komt na elk vel een vel achterkanten, per rij links en rechts verwisseld: dubbelzijdig
 * printen en omslaan langs de lange kant, dan valt elke achterkant achter zijn eigen kaart.
 */
/** Printblad voor barkaarten: kop, printknop, uitleg en de vellen. Eén kaart of honderd. */
export function KaartenPrinten({ lijst, winkel }: { lijst: { nummer: number; code: string }[]; winkel: string }) {
  return (
    <>
      <h2>{lijst.length === 1 ? `Kaart ${lijst[0].nummer} printen` : `${lijst.length} kaarten`}</h2>
      <div className="btns"><button className="big" onClick={() => window.print()}>Printen of PDF</button></div>
      <p className="mu">Op creditcardformaat, tien per A4. Print op 100% (niet "passend maken") en knip langs de stippellijnen.</p>
      <KaartenVellen lijst={lijst} winkel={winkel} />
    </>
  );
}

export function KaartenVellen({ lijst, winkel }: { lijst: { nummer: number; code: string }[]; winkel: string }) {
  const lees = (k: string, d: string) => { try { return localStorage.getItem(k) ?? d; } catch { return d; } };
  const [achter, setAchter] = useState(() => lees('kaart-achterkant', '1') === '1');
  const [naam, setNaam] = useState(() => lees('kaart-achter-naam', '1') === '1');
  const [dx, setDx] = useState(() => lees('kaart-achter-dx', '0'));
  const [dy, setDy] = useState(() => lees('kaart-achter-dy', '0'));
  const bewaar = (k: string, v: string) => { try { localStorage.setItem(k, v); } catch { /* geen opslag */ } };
  const mm = (v: string) => Math.max(-10, Math.min(10, parseFloat(v.replace(',', '.')) || 0));
  const vellen: { nummer: number; code: string }[][] = [];
  for (let i = 0; i < lijst.length; i += 10) vellen.push(lijst.slice(i, i + 10));
  return (
    <>
      <label className="check"><input type="checkbox" checked={achter} onChange={(e) => { setAchter(e.target.checked); bewaar('kaart-achterkant', e.target.checked ? '1' : '0'); }} />
        <span>Achterkant meeprinten (logo{naam ? ' en naam' : ''})<br /><span className="mu">Print dubbelzijdig en kies "omslaan langs de lange kant", op 100%.</span></span></label>
      {achter && <>
        <label className="check"><input type="checkbox" checked={naam} onChange={(e) => { setNaam(e.target.checked); bewaar('kaart-achter-naam', e.target.checked ? '1' : '0'); }} /><span>Naam van de bar op de achterkant</span></label>
        <details>
          <summary>Valt de achterkant net niet goed? Schuif hem op</summary>
          <p className="mu">Print eerst één vel en houd het tegen het licht. Positief is naar rechts of naar beneden, in millimeters.</p>
          <div className="inl">
            <label style={{ flex: 1, margin: 0 }}>Opzij (mm)<input className="f" inputMode="decimal" value={dx} onChange={(e) => { setDx(e.target.value); bewaar('kaart-achter-dx', e.target.value); }} /></label>
            <label style={{ flex: 1, margin: 0 }}>Omhoog/omlaag (mm)<input className="f" inputMode="decimal" value={dy} onChange={(e) => { setDy(e.target.value); bewaar('kaart-achter-dy', e.target.value); }} /></label>
          </div>
        </details>
      </>}
      <div className="print">
        {vellen.map((vel, v) => (
          <div key={v}>
            <div className="kaarten vel">{vel.map((k) => <QrKaart key={k.nummer} nummer={k.nummer} code={k.code} winkel={winkel} />)}</div>
            {achter && (
              <div className="kaarten vel achter" style={{ transform: `translate(${mm(dx)}mm, ${mm(dy)}mm)` }}>
                {Array.from({ length: Math.ceil(vel.length / 2) * 2 }, (_, i) => {
                  // Per rij omgedraaid: de achterkant van de linkerkaart staat rechts.
                  const k = vel[i % 2 === 0 ? i + 1 : i - 1];
                  return k ? <KaartAchter key={i} winkel={winkel} naam={naam} /> : <div key={i} className="kk-leeg" />;
                })}
              </div>
            )}
          </div>
        ))}
      </div>
    </>
  );
}

export function Qr({ tekst }: { tekst: string }) {
  const q = qrcode(0, 'M');
  q.addData(tekst);
  q.make();
  return <span className="qr" dangerouslySetInnerHTML={{ __html: q.createSvgTag({ cellSize: 4, margin: 2, scalable: true }) }} />;
}

// ─── Camera-scanner ───

interface Detector { detect(v: HTMLVideoElement): Promise<{ rawValue: string }[]> }

/** Camera die QR-codes leest. voorkant: de camera aan de schermkant (een telefoon aan de muur). */
export function Scanner({ onCode, voorkant = false, zonderCamera = 'Camera niet beschikbaar. Typ de code hieronder.' }: { onCode: (c: string) => void; voorkant?: boolean; zonderCamera?: string }) {
  const video = useRef<HTMLVideoElement>(null);
  const cb = useRef(onCode);
  cb.current = onCode;
  const [fout, setFout] = useState('');

  useEffect(() => {
    let stream: MediaStream | null = null, t = 0, stop = false, laatst = '';
    (async () => {
      try {
        stream = await navigator.mediaDevices.getUserMedia({ video: { facingMode: voorkant ? 'user' : 'environment' } });
      } catch {
        setFout(zonderCamera);
        return;
      }
      if (stop) { stream.getTracks().forEach((t) => t.stop()); return; }
      const v = video.current!;
      v.srcObject = stream;
      await v.play().catch(() => {});
      const BD = (window as unknown as { BarcodeDetector?: new (o: object) => Detector }).BarcodeDetector;
      const bd = BD ? new BD({ formats: ['qr_code'] }) : null;
      const jsQR = bd ? null : (await import('jsqr')).default;
      const cv = document.createElement('canvas'), cx = cv.getContext('2d', { willReadFrequently: true })!;
      const tik = async () => {
        if (stop) return;
        if (v.videoWidth) {
          let val = '';
          try {
            if (bd) val = (await bd.detect(v))[0]?.rawValue ?? '';
            else if (jsQR) {
              // Verkleind tot hooguit 640 breed: scheelt veel rekenwerk (en batterij) op een oude telefoon.
              const f = Math.min(1, 640 / v.videoWidth);
              cv.width = Math.round(v.videoWidth * f); cv.height = Math.round(v.videoHeight * f); cx.drawImage(v, 0, 0, cv.width, cv.height);
              val = jsQR(cx.getImageData(0, 0, cv.width, cv.height).data, cv.width, cv.height)?.data ?? '';
            }
          } catch { /* volgende frame */ }
          if (val && val !== laatst) { laatst = val; setTimeout(() => (laatst = ''), 2500); tril('scan'); cb.current(val); }
        }
        // Vijf keer per seconde kijken is genoeg en houdt de telefoon koel.
        t = window.setTimeout(tik, 200);
      };
      tik();
    })();
    return () => { stop = true; clearTimeout(t); stream?.getTracks().forEach((s) => s.stop()); };
  }, [voorkant, zonderCamera]);

  return fout ? <p className="mu">{fout}</p> : <video ref={video} className={'scan' + (voorkant ? ' spiegel' : '')} playsInline muted />;
}

// ─── Kleine bouwstenen ───

export function Bedrag({ waarde, onChange, id, placeholder, autoFocus }: { waarde: string; onChange: (v: string) => void; id?: string; placeholder?: string; autoFocus?: boolean }) {
  return <input className="f" id={id} inputMode="decimal" placeholder={placeholder ?? '0,00'} value={waarde} autoFocus={autoFocus} onChange={(e) => onChange(e.target.value)} />;
}

export function Rij({ l, r, sterk, onClick, className }: { l: ReactNode; r: ReactNode; sterk?: boolean; onClick?: () => void; className?: string }) {
  const inner = <><span>{l}</span><span className="rt">{sterk ? <b>{r}</b> : r}</span></>;
  return onClick
    ? <button className={'row ' + (className ?? '')} onClick={onClick}>{inner}</button>
    : <div className={'row ' + (sterk ? 'tot ' : '') + (className ?? '')}>{inner}</div>;
}
