import { createContext, useCallback, useContext, useEffect, useRef, useState, type ReactNode } from 'react';
import qrcode from 'qrcode-generator';
import { bonTekst, eur, methodeNaam, datumTijd, saldoLink, type Bon } from './lib';
import logo from './logo.webp';

// ─── Melding onderin ───

let zetMelding: (t: string) => void = () => {};
export const melding = (t: string) => zetMelding(t);

export function Melding() {
  const [t, setT] = useState('');
  useEffect(() => {
    let h: number;
    zetMelding = (x) => { setT(x); clearTimeout(h); h = window.setTimeout(() => setT(''), 2600); };
  }, []);
  return t ? <div className="toast" role="status">{t}</div> : null;
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
          <div className="sh" role="dialog" aria-modal="true" key={sleutel}>
            <div className="grab" />
            {inhoud}
          </div>
        </div>
      )}
    </SheetContext.Provider>
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
          <div className="bl"><span>{methodeNaam[p.methode]}{p.kaart_nummer ? ` (kaart ${p.kaart_nummer})` : ''}{p.lid_naam ? ` van ${p.lid_naam}` : ''}</span><span>{eur(p.bedrag_cent)}</span></div>
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
          if (val && val !== laatst) { laatst = val; setTimeout(() => (laatst = ''), 2500); cb.current(val); }
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
