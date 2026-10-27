import { bonBtw, datumTijd, eur, methodeNaam, type Bon } from './lib';
import logo from './logo.webp';

// De bon als afbeelding (PNG), om te delen via WhatsApp, mail enzovoort. Zelfde inhoud
// als de bon op het scherm, getekend op een canvas: wit papier, letters als van een bonprinter.

const B = 600; // breedte in beeldpunten (keer 2 voor scherpte)
const RAND = 36;
const LETTER = '"Courier New", Courier, monospace';

type Stap =
  | { soort: 'midden'; tekst: string; grootte: number; vet?: boolean; kleur?: string }
  | { soort: 'rij'; links: string; rechts: string; vet?: boolean; grootte?: number }
  | { soort: 'lijn' }
  | { soort: 'stempel'; tekst: string }
  | { soort: 'ruimte'; h: number }
  | { soort: 'logo' };

function stappen(b: Bon): Stap[] {
  const s: Stap[] = [{ soort: 'logo' }, { soort: 'midden', tekst: b.winkel, grootte: 26, vet: true }, { soort: 'midden', tekst: datumTijd(b.ts), grootte: 17 }, { soort: 'midden', tekst: `Bon ${b.bonnummer}`, grootte: 17 }];
  if (b.rekening_naam) s.push({ soort: 'midden', tekst: `Rekening van ${b.rekening_naam}`, grootte: 17 });
  if (b.geannuleerd) s.push({ soort: 'stempel', tekst: 'GEANNULEERD' });
  s.push({ soort: 'ruimte', h: 10 });
  for (const r of b.regels) s.push({ soort: 'rij', links: `${r.aantal}× ${r.naam}`, rechts: eur(r.prijs_cent * r.aantal) });
  s.push({ soort: 'lijn' }, { soort: 'rij', links: 'Totaal', rechts: eur(b.totaal_cent), vet: true, grootte: 20 });
  for (const p of b.betalingen) {
    s.push({ soort: 'rij', links: `${methodeNaam[p.methode]}${p.kaart_nummer ? ` (kaart ${p.kaart_nummer})` : ''}${p.lid_naam ? ` van ${p.lid_naam}` : ''}${p.reden ? ` (${p.reden})` : ''}`, rechts: eur(p.bedrag_cent) });
    if (p.gegeven_cent != null && (p.wisselgeld_cent || p.op_kaart_cent)) {
      s.push({ soort: 'rij', links: 'Gegeven', rechts: eur(p.gegeven_cent) });
      if (p.wisselgeld_cent) s.push({ soort: 'rij', links: 'Wisselgeld', rechts: eur(p.wisselgeld_cent) });
    }
    if (p.op_kaart_cent) {
      s.push({ soort: 'rij', links: `Op kaart ${p.op_kaart_nummer}`, rechts: eur(p.op_kaart_cent) });
      if (p.op_kaart_saldo_na != null) s.push({ soort: 'rij', links: 'Saldo kaart', rechts: eur(p.op_kaart_saldo_na) });
    }
    if (p.kaart_saldo_na != null) s.push({ soort: 'rij', links: 'Saldo kaart', rechts: eur(p.kaart_saldo_na) });
  }
  const btw = bonBtw(b);
  if (btw.length) {
    s.push({ soort: 'ruimte', h: 8 });
    for (const x of btw) s.push({ soort: 'rij', links: `Btw ${x.pct}% over ${eur(x.bruto)}`, rechts: eur(x.btw), grootte: 15 });
    if (b.btw_nummer) s.push({ soort: 'midden', tekst: `Btw-nummer ${b.btw_nummer}`, grootte: 15 });
  }
  s.push({ soort: 'ruimte', h: 12 });
  if (b.door_naam) s.push({ soort: 'midden', tekst: `Bediend door ${b.door_naam}`, grootte: 17 });
  s.push({ soort: 'midden', tekst: 'Bedankt!', grootte: 17 });
  return s;
}

const hoogte = (x: Stap) => x.soort === 'logo' ? 96 : x.soort === 'midden' ? x.grootte * 1.5 : x.soort === 'rij' ? (x.grootte ?? 17) * 1.55
  : x.soort === 'lijn' ? 16 : x.soort === 'stempel' ? 46 : x.h;

function laadLogo(): Promise<HTMLImageElement | null> {
  return new Promise((klaar) => {
    const img = new Image();
    img.onload = () => klaar(img);
    img.onerror = () => klaar(null);
    img.src = logo;
  });
}

/** Tekst inkorten met … tot hij past. */
function pas(c: CanvasRenderingContext2D, t: string, max: number) {
  if (c.measureText(t).width <= max) return t;
  while (t.length > 1 && c.measureText(t + '…').width > max) t = t.slice(0, -1);
  return t + '…';
}

export async function bonAfbeelding(b: Bon): Promise<Blob> {
  const lijst = stappen(b);
  const img = await laadLogo();
  if (!img) lijst.shift();
  const H = Math.ceil(RAND * 2 + lijst.reduce((a, x) => a + hoogte(x), 0));
  const schaal = 2;
  const cv = document.createElement('canvas');
  cv.width = B * schaal; cv.height = H * schaal;
  const c = cv.getContext('2d')!;
  c.scale(schaal, schaal);
  c.fillStyle = '#fff'; c.fillRect(0, 0, B, H);
  c.textBaseline = 'middle';
  let y = RAND;
  for (const x of lijst) {
    const h = hoogte(x), m = y + h / 2;
    if (x.soort === 'logo' && img) {
      const r = Math.min((B - 2 * RAND) / img.width, 80 / img.height);
      c.drawImage(img, (B - img.width * r) / 2, y, img.width * r, img.height * r);
    } else if (x.soort === 'midden') {
      c.font = `${x.vet ? 'bold ' : ''}${x.grootte}px ${LETTER}`; c.fillStyle = x.kleur ?? '#111'; c.textAlign = 'center';
      c.fillText(pas(c, x.tekst, B - 2 * RAND), B / 2, m);
    } else if (x.soort === 'rij') {
      c.font = `${x.vet ? 'bold ' : ''}${x.grootte ?? 17}px ${LETTER}`; c.fillStyle = '#111';
      c.textAlign = 'right'; c.fillText(x.rechts, B - RAND, m);
      const ruimte = B - 2 * RAND - c.measureText(x.rechts).width - 16;
      c.textAlign = 'left'; c.fillText(pas(c, x.links, ruimte), RAND, m);
    } else if (x.soort === 'lijn') {
      c.strokeStyle = '#555'; c.lineWidth = 1.5; c.setLineDash([6, 5]);
      c.beginPath(); c.moveTo(RAND, m); c.lineTo(B - RAND, m); c.stroke(); c.setLineDash([]);
    } else if (x.soort === 'stempel') {
      c.strokeStyle = c.fillStyle = '#b23a26'; c.lineWidth = 3;
      c.strokeRect(RAND, y + 6, B - 2 * RAND, h - 12);
      c.font = `bold 22px ${LETTER}`; c.textAlign = 'center'; c.fillText(x.tekst, B / 2, m);
    }
    y += h;
  }
  // Gekartelde onderrand, zoals afgescheurd bonpapier.
  c.fillStyle = '#e9ece8';
  c.beginPath(); c.moveTo(0, H);
  for (let i = 0; i <= B; i += 12) c.lineTo(i, H - (i / 12) % 2 * 6);
  c.lineTo(B, H); c.closePath(); c.fill();
  return new Promise((klaar, fout) => cv.toBlob((bl) => (bl ? klaar(bl) : fout(new Error('Afbeelding maken lukte niet'))), 'image/png'));
}
