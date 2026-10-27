import { createClient } from '@supabase/supabase-js';
import { proefClient } from '@proef';

// ─── Verbinding ───

declare global {
  interface Window { KASSA_CONFIG?: { supabaseUrl?: string; supabaseAnonKey?: string } }
}
const cfg = window.KASSA_CONFIG ?? {};
// Proefversie (npm run build:proef): database in de browser in plaats van een server.
export const PROEF = import.meta.env.VITE_PROEF === '1';
export const ingesteld = PROEF || Boolean(cfg.supabaseUrl && cfg.supabaseAnonKey);
export const sb = PROEF ? proefClient : createClient(cfg.supabaseUrl || 'http://localhost', cfg.supabaseAnonKey || 'x', {
  auth: { persistSession: true, autoRefreshToken: true },
});

export async function rpc<T = unknown>(fn: string, args?: Record<string, unknown>): Promise<T> {
  const { data, error } = await sb.rpc(fn, args);
  if (error) throw new Error(vertaal(error.message));
  return data as T;
}

export async function lees<T>(q: PromiseLike<{ data: T | null; error: { message: string } | null }>): Promise<T> {
  const { data, error } = await q;
  if (error) throw new Error(vertaal(error.message));
  return data as T;
}

/** Foutmelding van de server in gewone taal. */
export function vertaal(m: string) {
  if (/Failed to fetch|NetworkError|Load failed/i.test(m)) return 'Geen verbinding met de server. Controleer het internet en probeer opnieuw.';
  if (/Invalid login credentials/i.test(m)) return 'E-mailadres of wachtwoord klopt niet';
  if (/User already registered/i.test(m)) return 'Er bestaat al een account met dit e-mailadres';
  if (/Password should be at least/i.test(m)) return 'Kies een wachtwoord van minstens 8 tekens';
  if (/rate limit/i.test(m)) return 'Te veel pogingen, wacht even en probeer opnieuw';
  if (/JWT expired/i.test(m)) return 'Je sessie is verlopen, log opnieuw in';
  if (/deadlock detected|could not serialize/i.test(m)) return 'Het was even heel druk op de kassa. Probeer het nog een keer.';
  if (PROEF && /kaart.*niet gevonden/i.test(m)) return m.replace(/([^.?!])$/, '$1.') + ' In de proefversie heeft elke telefoon of browser zijn eigen kaarten. Alleen de voorbeeldkaarten 1 tot en met 20 werken overal; print die opnieuw bij Beheer → Kaarten.';
  // Bedragen uit de database staan met een punt (€ 31.00); in de app met een komma.
  return m.replace(/€ (\d+)\.(\d{2})\b/g, '€ $1,$2');
}

/**
 * Voelbaar signaal: 'goed' (betaling gelukt), 'scan' (kaart gescand, heel kort) of 'fout' (drie keer).
 * In een drukke kantine hoor je de telefoon niet. Android trilt via de browser. Een iPhone kan
 * dat vanuit een website niet; daar geeft een onzichtbare schakelaar een tikje (iOS 18 en nieuwer).
 */
export function tril(soort: 'goed' | 'scan' | 'fout' | boolean) {
  const s = soort === true ? 'goed' : soort === false ? 'fout' : soort;
  try {
    if (typeof navigator.vibrate === 'function') { navigator.vibrate(s === 'goed' ? 40 : s === 'scan' ? 20 : [70, 60, 70, 60, 70]); return; }
    iosTik();
    if (s === 'fout') { setTimeout(iosTik, 140); setTimeout(iosTik, 280); }
  } catch { /* geen trilfunctie */ }
}
let tikLabel: HTMLLabelElement | null = null;
function iosTik() {
  if (!tikLabel) {
    const i = Object.assign(document.createElement('input'), { type: 'checkbox', id: 'kassa-tik', tabIndex: -1 });
    i.setAttribute('switch', '');
    i.setAttribute('aria-hidden', 'true');
    tikLabel = Object.assign(document.createElement('label'), { htmlFor: 'kassa-tik' });
    tikLabel.setAttribute('aria-hidden', 'true');
    const w = Object.assign(document.createElement('div'), { className: 'tik' });
    w.append(i, tikLabel);
    document.body.append(w);
  }
  tikLabel.click();
}

// Uniek kenmerk voor één afrekening of opwaardering. Valt de verbinding weg en
// tikt de medewerker opnieuw, dan stuurt de app hetzelfde kenmerk mee en boekt
// de server niet nog een keer.
/** De kaartcode uit een gescande QR-code: nieuwe kaarten bevatten een link naar de saldo-pagina, oude alleen de code. */
export function kaartCode(t: string): string {
  const s = t.trim();
  try { if (/^https?:\/\//i.test(s)) return new URL(s).searchParams.get('saldo') ?? s; } catch { /* geen link */ }
  return s;
}

/** De code van een lid uit een gescande QR-code (link met ?lid=), anders null. */
export function lidCode(t: string): string | null {
  try { return /^https?:\/\//i.test(t.trim()) ? new URL(t.trim()).searchParams.get('lid') : null; } catch { return null; }
}

/** Uitnodiging voor een nieuwe medewerker (?uitnodiging=CODE). */
export const uitnodigingGevraagd = () => new URLSearchParams(location.search).get('uitnodiging');
/**
 * Link in de QR-code van een uitnodiging. Met een eigen certificaat (de kassa op een IP-adres)
 * gaat hij via de welkomstpagina (http), zodat een nieuwe telefoon eerst het certificaat installeert.
 */
export function uitnodigingLink(code: string) {
  const q = '?uitnodiging=' + encodeURIComponent(code);
  if (location.protocol === 'https:' && /^\d+\.\d+\.\d+\.\d+$/.test(location.hostname)) return `http://${location.hostname}/${q}`;
  return location.origin + location.pathname.replace(/[^/]*$/, '') + q;
}

/** Link naar de eigen streeplijst van een lid. */
export const lidLink = (code: string) => location.origin + location.pathname.replace(/[^/]*$/, '') + '?lid=' + encodeURIComponent(code);
export const lidGevraagd = () => new URLSearchParams(location.search).get('lid');

/** Link voor op de kaart: opent de saldo-pagina van deze kassa. */
export const saldoLink = (code: string) => location.origin + location.pathname.replace(/[^/]*$/, '') + '?saldo=' + encodeURIComponent(code);

/** Wordt de saldo-pagina gevraagd (…/saldo of ?saldo=CODE)? Dan de code (of '' om te typen), anders null. */
export function saldoGevraagd(): string | null {
  const p = new URLSearchParams(location.search).get('saldo');
  if (p != null) return p;
  return /\/saldo\/?$/.test(location.pathname) ? '' : null;
}

/** Saldo-zuil: een telefoon of tablet aan de muur waar klanten hun kaart voor houden (…/zuil of ?zuil). */
export const zuilGevraagd = () => new URLSearchParams(location.search).has('zuil') || /\/zuil\/?$/.test(location.pathname);
export const zuilLink = () => location.origin + location.pathname.replace(/[^/]*$/, '') + '?zuil';

export function nieuweSleutel(): string {
  if (typeof crypto.randomUUID === 'function') return crypto.randomUUID();
  const b = crypto.getRandomValues(new Uint8Array(16));
  b[6] = (b[6] & 0x0f) | 0x40; b[8] = (b[8] & 0x3f) | 0x80;
  const h = [...b].map((x) => x.toString(16).padStart(2, '0')).join('');
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
}

// Inloggen met een naam: intern wordt dat een e-mailadres "anna@kassa.lokaal".
// Wie een echt e-mailadres typt, logt daarmee in.
const DOMEIN = '@kassa.lokaal';
export function inlogEmail(naam: string) {
  const n = naam.trim().toLowerCase();
  if (n.includes('@')) return n;
  const slug = n.normalize('NFD').replace(/[\u0300-\u036f]/g, '').replace(/[^a-z0-9]+/g, '.').replace(/^\.+|\.+$/g, '');
  return (slug || 'gebruiker') + DOMEIN;
}
export const toonInlognaam = (email: string) => (email.endsWith(DOMEIN) ? email.slice(0, -DOMEIN.length) : email);

// ─── Types ───

export type Rol = 'wacht' | 'medewerker' | 'beheerder';
export interface Profiel { id: string; naam: string; rol: Rol; actief: boolean; aangemaakt: string }
export interface Product {
  id: number; naam: string; prijs_cent: number; categorie: string; actief: boolean; verwijderd: boolean;
  volgorde: number; voorraad_bijhouden: boolean; voorraad: number; voorraad_min: number;
}
export interface Rekening { id: number; naam: string; open: boolean; aangemaakt: string }
export interface RekeningRegel { id: number; rekening_id: number; product_id: number; naam: string; prijs_cent: number; aantal: number; ts: string }
export interface Betaling {
  methode: 'contant' | 'pin' | 'kaart' | 'lat' | 'gratis'; bedrag_cent: number; reden?: string | null; kaart_nummer?: number | null; kaart_saldo_na?: number | null;
  gegeven_cent?: number | null; wisselgeld_cent?: number | null; lid_naam?: string | null;
  // Wisselgeld dat als tegoed op een barkaart is gezet.
  op_kaart_nummer?: number | null; op_kaart_cent?: number | null; op_kaart_saldo_na?: number | null;
}
export interface Bon {
  id: number; bonnummer: number; ts: string; door_naam: string | null; rekening_naam: string | null;
  totaal_cent: number; geannuleerd: boolean; winkel: string;
  regels: { naam: string; prijs_cent: number; aantal: number }[]; betalingen: Betaling[];
}
export interface Dienst {
  id: number; geopend_ts: string; gesloten_ts: string | null; geopend_door: string | null; gesloten_door: string | null;
  beginsaldo_cent: number; omzet_cent: number; bonnen: number; contant_cent: number; pin_cent: number; kaart_cent: number;
  opwaardering_contant_cent: number; opwaardering_pin_cent: number; verwacht_cent: number;
  // Streeplijst (ontbreekt bij diensten van vóór de streeplijst).
  lat_cent?: number; afbetaald_contant_cent?: number; afbetaald_pin_cent?: number;
  gratis_cent?: number; uitgaven_cent?: number;
  geteld_cent: number | null; opmerking: string | null;
}
export interface KaartInfo { id: number; nummer: number; naam: string | null; saldo_cent: number; geblokkeerd: boolean; betaalcode: boolean }
export interface Regel { product_id: number; aantal: number }

// ─── Opmaak ───

const fmt = new Intl.NumberFormat('nl-NL', { style: 'currency', currency: 'EUR' });
export const eur = (c: number) => fmt.format(c / 100);
export const totaal = (l: { prijs_cent: number; aantal: number }[]) => l.reduce((a, r) => a + r.prijs_cent * r.aantal, 0);

/** "7,50", "7.50", "1.000" of "1.250,00" → centen. Ongeldig → NaN. */
export function naarCent(v: string): number {
  let s = v.trim().replace(/[€\s]/g, '');
  if (s.includes(',')) s = s.replace(/\./g, '').replace(',', '.'); // 1.250,00
  else if (/^\d{1,3}(\.\d{3})+$/.test(s)) s = s.replace(/\./g, ''); // 1.000 = duizend
  if (!/^\d+(\.\d{1,2})?$/.test(s)) return NaN;
  return Math.round(Number(s) * 100);
}
export const centTekst = (c: number) => (c / 100).toFixed(2).replace('.', ',');

export const tijd = (ts: string) => new Date(ts).toLocaleTimeString('nl-NL', { hour: '2-digit', minute: '2-digit' });
export const datum = (ts: string | Date) => new Date(ts).toLocaleDateString('nl-NL', { day: 'numeric', month: 'short', year: 'numeric' });
export const datumTijd = (ts: string) => `${datum(ts)} ${tijd(ts)}`;
export const methodeNaam: Record<string, string> = { contant: 'Contant', pin: 'Pin', kaart: 'Kaart', lat: 'Streeplijst', overboeking: 'Overboeking', gratis: 'Gratis' };

export function bonTekst(b: Bon) {
  const r = [b.winkel, datumTijd(b.ts), `Bon ${b.bonnummer}`];
  if (b.rekening_naam) r.push(`Rekening van ${b.rekening_naam}`);
  if (b.geannuleerd) r.push('*** GEANNULEERD ***');
  r.push('', ...b.regels.map((l) => `${l.aantal}× ${l.naam}  ${eur(l.prijs_cent * l.aantal)}`), '', `Totaal: ${eur(b.totaal_cent)}`);
  for (const p of b.betalingen) {
    r.push(`${methodeNaam[p.methode]}${p.kaart_nummer ? ' ' + p.kaart_nummer : ''}${p.lid_naam ? ' ' + p.lid_naam : ''}${p.reden ? ' (' + p.reden + ')' : ''}: ${eur(p.bedrag_cent)}`);
    if (p.op_kaart_cent) r.push(`Op kaart ${p.op_kaart_nummer}: ${eur(p.op_kaart_cent)}`);
  }
  return r.join('\n');
}

export function downloaden(naam: string, inhoud: string, type = 'text/csv;charset=utf-8') {
  const url = URL.createObjectURL(new Blob(['﻿' + inhoud], { type }));
  const a = Object.assign(document.createElement('a'), { href: url, download: naam });
  document.body.append(a);
  a.click();
  a.remove();
  // Ruim de tijd: een iPhone vraagt eerst of je wilt downloaden, en leest het bestand pas daarna.
  setTimeout(() => URL.revokeObjectURL(url), 120_000);
}
export const csvRij = (v: unknown[]) => v.map((x) => `"${String(x ?? '').replace(/"/g, '""')}"`).join(';');
