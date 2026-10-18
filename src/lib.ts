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

function vertaal(m: string) {
  if (/Failed to fetch|NetworkError|Load failed/i.test(m)) return 'Geen verbinding met de server. Controleer het internet en probeer opnieuw.';
  if (/Invalid login credentials/i.test(m)) return 'E-mailadres of wachtwoord klopt niet';
  if (/User already registered/i.test(m)) return 'Er bestaat al een account met dit e-mailadres';
  if (/Password should be at least/i.test(m)) return 'Kies een wachtwoord van minstens 8 tekens';
  if (/rate limit/i.test(m)) return 'Te veel pogingen, wacht even en probeer opnieuw';
  if (/JWT expired/i.test(m)) return 'Je sessie is verlopen, log opnieuw in';
  return m;
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
  methode: 'contant' | 'pin' | 'kaart'; bedrag_cent: number; kaart_nummer?: number | null; kaart_saldo_na?: number | null;
  gegeven_cent?: number | null; wisselgeld_cent?: number | null;
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
  geteld_cent: number | null; opmerking: string | null;
}
export interface KaartInfo { id: number; nummer: number; saldo_cent: number; geblokkeerd: boolean; betaalcode: boolean }
export interface Regel { product_id: number; aantal: number }

// ─── Opmaak ───

const fmt = new Intl.NumberFormat('nl-NL', { style: 'currency', currency: 'EUR' });
export const eur = (c: number) => fmt.format(c / 100);
export const totaal = (l: { prijs_cent: number; aantal: number }[]) => l.reduce((a, r) => a + r.prijs_cent * r.aantal, 0);

/** "7,50", "7.50" of "1.250,00" → centen. Ongeldig → NaN. */
export function naarCent(v: string): number {
  let s = v.trim().replace(/[€\s]/g, '');
  if (!s) return NaN;
  if (s.includes(',')) s = s.replace(/\./g, '').replace(',', '.');
  const n = Number(s);
  return Number.isFinite(n) ? Math.round(n * 100) : NaN;
}
export const centTekst = (c: number) => (c / 100).toFixed(2).replace('.', ',');

export const tijd = (ts: string) => new Date(ts).toLocaleTimeString('nl-NL', { hour: '2-digit', minute: '2-digit' });
export const datum = (ts: string | Date) => new Date(ts).toLocaleDateString('nl-NL', { day: 'numeric', month: 'short', year: 'numeric' });
export const datumTijd = (ts: string) => `${datum(ts)} ${tijd(ts)}`;
export const methodeNaam: Record<string, string> = { contant: 'Contant', pin: 'Pin', kaart: 'Kaart' };

export function bonTekst(b: Bon) {
  const r = [b.winkel, datumTijd(b.ts), `Bon ${b.bonnummer}`];
  if (b.rekening_naam) r.push(`Rekening van ${b.rekening_naam}`);
  if (b.geannuleerd) r.push('*** GEANNULEERD ***');
  r.push('', ...b.regels.map((l) => `${l.aantal}× ${l.naam}  ${eur(l.prijs_cent * l.aantal)}`), '', `Totaal: ${eur(b.totaal_cent)}`);
  for (const p of b.betalingen) r.push(`${methodeNaam[p.methode]}${p.kaart_nummer ? ' ' + p.kaart_nummer : ''}: ${eur(p.bedrag_cent)}`);
  return r.join('\n');
}

export function downloaden(naam: string, inhoud: string, type = 'text/csv;charset=utf-8') {
  const url = URL.createObjectURL(new Blob(['﻿' + inhoud], { type }));
  const a = Object.assign(document.createElement('a'), { href: url, download: naam });
  document.body.append(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}
export const csvRij = (v: unknown[]) => v.map((x) => `"${String(x ?? '').replace(/"/g, '""')}"`).join(';');
