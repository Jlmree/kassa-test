// Een eenvoudig Excel-bestand (.xlsx) maken, zonder extra bibliotheek: tabbladen met een
// vaste kopregel, filters, kolombreedtes en opmaak voor euro's, aantallen, datums en tijden.
// Een .xlsx is een zip met XML-bestanden; hier ongecomprimeerd ("stored"), dat leest Excel prima.

/** Opmaak van een cel. */
export type Soort = 'tekst' | 'geld' | 'getal' | 'datum' | 'datumtijd' | 'tijd';
export interface Kolom { kop: string; soort?: Soort; breedte?: number }
/** Een cel: tekst, een getal (geld in centen), een tijd als "2026-10-24T21:15:00" (Nederlandse tijd), of leeg. */
export type Cel = string | number | null | undefined | { v: string | number | null; vet?: boolean; soort?: Soort };
export interface Blad { naam: string; kolommen: Kolom[]; rijen: Cel[][]; totaal?: Cel[]; filter?: boolean }

// Stijlen in styles.xml (volgorde = nummer): gewoon, kop, geld, getal, datum, datumtijd, tijd, en vet van elk.
const STIJL: Record<Soort, number> = { tekst: 0, geld: 2, getal: 3, datum: 4, datumtijd: 5, tijd: 6 };
const VET = 7; // + STIJL[soort]

const esc = (s: string) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;')
  // Excel weigert stuurtekens in XML.
  .replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f]/g, '');

function kolomLetter(i: number) {
  let s = '';
  for (i++; i > 0; i = Math.floor((i - 1) / 26)) s = String.fromCharCode(65 + ((i - 1) % 26)) + s;
  return s;
}

/** "2026-10-24T21:15:00" of "2026-10-24" → Excel-datumgetal (dagen sinds 30-12-1899), zonder tijdzone-gedoe. */
function excelDatum(t: string): number | null {
  const m = /^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2}))?)?/.exec(t);
  if (!m) return null;
  const ms = Date.UTC(+m[1], +m[2] - 1, +m[3], +(m[4] ?? 0), +(m[5] ?? 0), +(m[6] ?? 0));
  return (ms - Date.UTC(1899, 11, 30)) / 86400000;
}

function cel(c: Cel, soort: Soort, ref: string): string {
  const o = c !== null && typeof c === 'object' ? c : { v: c ?? null };
  const s = o.soort ?? soort;
  const stijl = STIJL[s] + (o.vet ? VET : 0);
  let v = o.v;
  if (v === null || v === undefined || v === '') return stijl ? `<c r="${ref}" s="${stijl}"/>` : '';
  if (s === 'geld' && typeof v === 'number') v = Math.round(v) / 100;
  if ((s === 'datum' || s === 'datumtijd' || s === 'tijd') && typeof v === 'string') {
    const d = excelDatum(v);
    if (d !== null) v = s === 'tijd' ? d - Math.floor(d) : s === 'datum' ? Math.floor(d) : d;
  }
  if (typeof v === 'number' && isFinite(v)) return `<c r="${ref}" s="${stijl}"><v>${v}</v></c>`;
  return `<c r="${ref}" s="${stijl}" t="inlineStr"><is><t xml:space="preserve">${esc(String(v))}</t></is></c>`;
}

function blad(b: Blad): string {
  const n = b.kolommen.length;
  const rij = (cellen: Cel[], r: number, kop = false) =>
    `<row r="${r}">${cellen.map((c, i) => kop ? `<c r="${kolomLetter(i)}${r}" s="1" t="inlineStr"><is><t xml:space="preserve">${esc(String(c ?? ''))}</t></is></c>`
      : cel(c, b.kolommen[i]?.soort ?? 'tekst', `${kolomLetter(i)}${r}`)).join('')}</row>`;
  const rijen = [rij(b.kolommen.map((k) => k.kop), 1, true), ...b.rijen.map((r, i) => rij(r, i + 2))];
  if (b.totaal) rijen.push(rij(b.totaal.map((c) => (c !== null && typeof c === 'object' ? { ...c, vet: true } : { v: c ?? null, vet: true })), b.rijen.length + 2));
  const laatste = `${kolomLetter(n - 1)}${b.rijen.length + 1}`;
  return `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
<sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>
<cols>${b.kolommen.map((k, i) => `<col min="${i + 1}" max="${i + 1}" width="${k.breedte ?? Math.max(10, Math.min(50, k.kop.length + 4))}" customWidth="1"/>`).join('')}</cols>
<sheetData>${rijen.join('')}</sheetData>
${b.filter !== false && b.rijen.length ? `<autoFilter ref="A1:${laatste}"/>` : ''}
</worksheet>`;
}

const STYLES = `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
<numFmts count="4"><numFmt numFmtId="164" formatCode="&quot;€&quot;\\ #,##0.00;[Red]&quot;€&quot;\\ \\-#,##0.00"/><numFmt numFmtId="165" formatCode="dd\\-mm\\-yyyy"/><numFmt numFmtId="166" formatCode="dd\\-mm\\-yyyy\\ hh:mm"/><numFmt numFmtId="167" formatCode="hh:mm"/></numFmts>
<fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font></fonts>
<fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill><fill><patternFill patternType="solid"><fgColor rgb="FFDCE8E2"/><bgColor indexed="64"/></patternFill></fill></fills>
<borders count="2"><border/><border><bottom style="thin"><color rgb="FF1D6B58"/></bottom></border></borders>
<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
<cellXfs count="14">
<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>
<xf numFmtId="0" fontId="1" fillId="2" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1"/>
<xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>
<xf numFmtId="3" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>
<xf numFmtId="165" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>
<xf numFmtId="166" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>
<xf numFmtId="167" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>
<xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/>
<xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/>
<xf numFmtId="164" fontId="1" fillId="0" borderId="0" xfId="0" applyNumberFormat="1" applyFont="1"/>
<xf numFmtId="3" fontId="1" fillId="0" borderId="0" xfId="0" applyNumberFormat="1" applyFont="1"/>
<xf numFmtId="165" fontId="1" fillId="0" borderId="0" xfId="0" applyNumberFormat="1" applyFont="1"/>
<xf numFmtId="166" fontId="1" fillId="0" borderId="0" xfId="0" applyNumberFormat="1" applyFont="1"/>
<xf numFmtId="167" fontId="1" fillId="0" borderId="0" xfId="0" applyNumberFormat="1" applyFont="1"/>
</cellXfs>
<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>
</styleSheet>`;

// ─── Zip (ongecomprimeerd) ───
const CRC = (() => { const t = new Uint32Array(256); for (let n = 0; n < 256; n++) { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; t[n] = c >>> 0; } return t; })();
function crc32(b: Uint8Array) { let c = 0xffffffff; for (let i = 0; i < b.length; i++) c = CRC[(c ^ b[i]) & 0xff] ^ (c >>> 8); return (c ^ 0xffffffff) >>> 0; }

function zip(bestanden: { naam: string; inhoud: string }[]): Blob {
  const enc = new TextEncoder();
  const delen: Uint8Array[] = [];
  const centraal: Uint8Array[] = [];
  let pos = 0;
  for (const f of bestanden) {
    const naam = enc.encode(f.naam), data = enc.encode(f.inhoud), crc = crc32(data);
    const kop = new DataView(new ArrayBuffer(30));
    kop.setUint32(0, 0x04034b50, true); kop.setUint16(4, 20, true); kop.setUint16(6, 0x0800, true); kop.setUint16(8, 0, true);
    kop.setUint16(10, 0, true); kop.setUint16(12, 0x21, true); kop.setUint32(14, crc, true);
    kop.setUint32(18, data.length, true); kop.setUint32(22, data.length, true); kop.setUint16(26, naam.length, true); kop.setUint16(28, 0, true);
    delen.push(new Uint8Array(kop.buffer), naam, data);
    const c = new DataView(new ArrayBuffer(46));
    c.setUint32(0, 0x02014b50, true); c.setUint16(4, 20, true); c.setUint16(6, 20, true); c.setUint16(8, 0x0800, true); c.setUint16(10, 0, true);
    c.setUint16(12, 0, true); c.setUint16(14, 0x21, true); c.setUint32(16, crc, true); c.setUint32(20, data.length, true); c.setUint32(24, data.length, true);
    c.setUint16(28, naam.length, true); c.setUint32(42, pos, true);
    centraal.push(new Uint8Array(c.buffer), naam);
    pos += 30 + naam.length + data.length;
  }
  const grootte = centraal.reduce((a, b) => a + b.length, 0);
  const eind = new DataView(new ArrayBuffer(22));
  eind.setUint32(0, 0x06054b50, true); eind.setUint16(8, bestanden.length, true); eind.setUint16(10, bestanden.length, true);
  eind.setUint32(12, grootte, true); eind.setUint32(16, pos, true);
  return new Blob([...delen, ...centraal, new Uint8Array(eind.buffer)] as BlobPart[], { type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' });
}

/** Maakt het .xlsx-bestand. Bladnamen: hoogstens 31 tekens, zonder : \ / ? * [ ]. */
export function maakXlsx(bladen: Blad[]): Blob {
  const namen = bladen.map((b) => b.naam.replace(/[:\\/?*[\]]/g, ' ').slice(0, 31));
  return zip([
    { naam: '[Content_Types].xml', inhoud: `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>${bladen.map((_, i) => `<Override PartName="/xl/worksheets/sheet${i + 1}.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>`).join('')}</Types>` },
    { naam: '_rels/.rels', inhoud: `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>` },
    { naam: 'xl/workbook.xml', inhoud: `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>${namen.map((n, i) => `<sheet name="${esc(n)}" sheetId="${i + 1}" r:id="rId${i + 1}"/>`).join('')}</sheets></workbook>` },
    { naam: 'xl/_rels/workbook.xml.rels', inhoud: `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">${bladen.map((_, i) => `<Relationship Id="rId${i + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet${i + 1}.xml"/>`).join('')}<Relationship Id="rId${bladen.length + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>` },
    { naam: 'xl/styles.xml', inhoud: STYLES },
    ...bladen.map((b, i) => ({ naam: `xl/worksheets/sheet${i + 1}.xml`, inhoud: blad(b) })),
  ]);
}
