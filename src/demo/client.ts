// Proefversie: de kassa zonder server. Een echte PostgreSQL-database (PGlite)
// draait in de browser met precies hetzelfde schema, dezelfde rechten en
// dezelfde functies als op de kassa-server. Dit bestand bootst het stukje
// Supabase na dat de app gebruikt: inloggen, lezen met .from() en .rpc().
import type { PGlite, Transaction } from '@electric-sql/pglite';
import type { SupabaseClient } from '@supabase/supabase-js';
import opzet from './opzet.sql?raw';
import vulling from './vulling.sql?raw';

const migraties = Object.entries(import.meta.glob('../../supabase/migrations/*.sql', { query: '?raw', import: 'default', eager: true }) as Record<string, string>)
  .map(([pad, sql]) => [pad.split('/').pop()!, sql] as const)
  .sort(([a], [b]) => a.localeCompare(b));

const OPSLAG = 'idb://bar-kassa-proef';
const SESSIE = 'bar-kassa-proef-sessie';

// ─── Database ───

let dbP: Promise<PGlite> | null = null;
const db = () => (dbP ??= openen().catch((e) => { dbP = null; throw e; }));

async function openen() {
  const [{ PGlite }, { pgcrypto }] = await Promise.all([import('@electric-sql/pglite'), import('@electric-sql/pglite/contrib/pgcrypto')]);
  const maak = async (opslag: boolean) => {
    try {
      if (opslag) return await PGlite.create(OPSLAG, { extensions: { pgcrypto } });
    } catch { /* geen opslag in de browser (bijv. privévenster) */ }
    return PGlite.create({ extensions: { pgcrypto } });
  };
  let d = await maak(true);
  try {
    if (await toestand(d) === 'klaar') await bijwerken(d);
    else {
      // Leeg, of half klaargezet doordat de pagina de vorige keer te vroeg dicht ging: opnieuw beginnen.
      if (await toestand(d) === 'half') { await d.close(); await wisOpslag(); d = await maak(true); }
      await klaarzetten(d);
    }
  } catch {
    // Iets klopt niet aan de opgeslagen proefdatabase: weggooien en vers beginnen.
    try { await d.close(); } catch { /* al dicht */ }
    await wisOpslag();
    d = await maak(true);
    await klaarzetten(d);
  }
  return d;
}

// 'leeg' = vers, 'klaar' = met voorbeeldgegevens, 'half' = onderbroken bij het klaarzetten.
async function toestand(d: PGlite) {
  const { rows } = await d.query<{ auth: boolean; klaar: boolean }>(`select
    exists (select 1 from pg_roles where rolname = 'authenticated') as auth,
    to_regclass('extensions.proef_migraties') is not null and to_regclass('auth.users') is not null as klaar`);
  if (!rows[0].auth) return 'leeg';
  if (!rows[0].klaar) return 'half';
  const n = await d.query<{ n: number }>(`select count(*)::int as n from auth.users`);
  return n.rows[0].n > 0 ? 'klaar' : 'half';
}

// Alles in één transactie: wordt de pagina halverwege gesloten, dan blijft er niets half achter.
async function klaarzetten(d: PGlite) {
  await d.transaction(async (tx) => {
    await tx.exec(opzet + `\ncreate table extensions.proef_migraties (naam text primary key);`);
    for (const [naam, sql] of migraties) {
      await tx.exec(sql);
      await tx.query(`insert into extensions.proef_migraties values ($1)`, [naam]);
    }
    await tx.exec(vulling);
  });
}

// Nieuwe schemawijzigingen ook in een bestaande proefdatabase doorvoeren, elk in één keer.
async function bijwerken(d: PGlite) {
  for (const [naam, sql] of migraties) {
    const { rows } = await d.query(`select 1 from extensions.proef_migraties where naam = $1`, [naam]);
    if (rows.length) continue;
    await d.transaction(async (tx) => {
      await tx.exec(sql);
      await tx.query(`insert into extensions.proef_migraties values ($1)`, [naam]);
    });
  }
}

async function wisOpslag() {
  const naam = OPSLAG.slice('idb://'.length);
  const dbs = await indexedDB.databases?.().catch(() => []) ?? [];
  const weg = [...new Set([...dbs.map((x) => x.name ?? '').filter((n) => n.endsWith(naam)), '/pglite/' + naam])];
  await Promise.all(weg.map((n) => new Promise<void>((klaar) => {
    const r = indexedDB.deleteDatabase(n);
    r.onsuccess = r.onerror = r.onblocked = () => klaar();
  })));
}

// Een query uitvoeren zoals PostgREST dat doet: als rol "authenticated" met
// het id van de ingelogde gebruiker, zodat alle rechten en regels gelden.
async function alsGebruiker<T>(sql: string, params: unknown[] = []): Promise<T> {
  const d = await db();
  return d.transaction(async (tx: Transaction) => {
    await tx.query(`select set_config('request.jwt.claim.sub', $1, true)`, [huidig()?.user.id ?? '']);
    await tx.exec('set local role authenticated');
    const { rows } = await tx.query<{ v: T }>(sql, params);
    return rows[0]?.v as T;
  });
}

type Fout = { message: string };
const fout = (e: unknown): Fout => ({ message: e instanceof Error ? e.message : String(e) });

// ─── Lezen: sb.from(tabel).select(...).eq(...).order(...) ───

// Gekoppelde tabellen die de app opvraagt, bijv. verkopen → betalingen(methode).
const KOPPELINGEN: Record<string, { kolom: string; veel: boolean }> = {
  'verkopen.betalingen': { kolom: 'verkoop_id', veel: true },
  'verkopen.verkoop_regels': { kolom: 'verkoop_id', veel: true },
  'rekening_regels.rekeningen': { kolom: 'rekening_id', veel: false },
};
const naam = (s: string) => {
  if (!/^[a-z_][a-z0-9_]*$/.test(s)) throw new Error('Ongeldige naam: ' + s);
  return '"' + s + '"';
};

// "a,b,kind(x,y)" → losse onderdelen, met haakjes als één geheel.
function splits(s: string) {
  const uit: string[] = [];
  let diepte = 0, huidig = '';
  for (const c of s) {
    if (c === ',' && diepte === 0) { uit.push(huidig.trim()); huidig = ''; continue; }
    if (c === '(') diepte++;
    if (c === ')') diepte--;
    huidig += c;
  }
  if (huidig.trim()) uit.push(huidig.trim());
  return uit;
}

function kolommen(tabel: string, alias: string, select: string): string {
  return splits(select).map((deel) => {
    if (deel === '*') return `${alias}.*`;
    const m = deel.match(/^([a-z_]+)(?:!inner)?\((.*)\)$/);
    if (!m) return `${alias}.${naam(deel)}`;
    const [, kind, binnen] = m;
    const k = KOPPELINGEN[`${tabel}.${kind}`];
    if (!k) throw new Error('Onbekende koppeling: ' + kind);
    const a = alias + '_' + kind;
    const rij = `(select ${kolommen(kind, a, binnen)} from public.${naam(kind)} ${a} where ${k.veel ? `${a}.${naam(k.kolom)} = ${alias}.id` : `${a}.id = ${alias}.${naam(k.kolom)}`})`;
    // json_agg/row_to_json geeft dezelfde vorm als PostgREST.
    const sql = k.veel ? `coalesce((select json_agg(r) from ${rij} r), '[]')` : `(select row_to_json(r) from ${rij} r)`;
    return `${sql} as ${naam(kind)}`;
  }).join(', ');
}

class Lezen implements PromiseLike<{ data: unknown; error: Fout | null }> {
  private kol = '*';
  private waar: string[] = [];
  private params: unknown[] = [];
  private volgorde: string[] = [];
  private max: number | null = null;
  private een: 'single' | 'maybe' | null = null;
  constructor(private tabel: string) { naam(tabel); }

  select(k = '*') { this.kol = k; return this; }
  private filter(kolom: string, op: string, waarde: unknown) {
    this.params.push(waarde === null ? null : String(waarde));
    const [t, k] = kolom.includes('.') ? kolom.split('.') : [null, kolom];
    // Filter op een gekoppelde tabel (bijv. rekeningen.open): via een subquery.
    const links = t
      ? `(select ${naam(k)} from public.${naam(t)} f where f.id = t.${naam(KOPPELINGEN[`${this.tabel}.${t}`].kolom)})`
      : `t.${naam(k)}`;
    this.waar.push(`${links} ${op} $${this.params.length}`);
    return this;
  }
  eq(k: string, v: unknown) { return this.filter(k, '=', v); }
  gt(k: string, v: unknown) { return this.filter(k, '>', v); }
  gte(k: string, v: unknown) { return this.filter(k, '>=', v); }
  lt(k: string, v: unknown) { return this.filter(k, '<', v); }
  lte(k: string, v: unknown) { return this.filter(k, '<=', v); }
  order(k: string, o?: { ascending?: boolean }) { this.volgorde.push(`t.${naam(k)} ${o?.ascending === false ? 'desc' : 'asc'}`); return this; }
  limit(n: number) { this.max = Math.max(0, Math.floor(n)); return this; }
  single() { this.een = 'single'; return this; }
  maybeSingle() { this.een = 'maybe'; return this; }

  private async uitvoeren() {
    const sql = `select coalesce(json_agg(x), '[]') as v from (select ${kolommen(this.tabel, 't', this.kol)} from public.${naam(this.tabel)} t`
      + (this.waar.length ? ' where ' + this.waar.join(' and ') : '')
      + (this.volgorde.length ? ' order by ' + this.volgorde.join(', ') : '')
      + (this.max !== null ? ' limit ' + this.max : '') + ') x';
    const rijen = await alsGebruiker<unknown[]>(sql, this.params);
    if (!this.een) return rijen;
    if (rijen.length > 1 || (this.een === 'single' && rijen.length === 0)) throw new Error('Niet gevonden');
    return rijen[0] ?? null;
  }
  then<A = { data: unknown; error: Fout | null }, B = never>(
    ok?: ((v: { data: unknown; error: Fout | null }) => A | PromiseLike<A>) | null, nok?: ((e: unknown) => B | PromiseLike<B>) | null,
  ) {
    return this.uitvoeren().then((data) => ({ data, error: null }), (e) => ({ data: null, error: fout(e) })).then(ok, nok);
  }
}

// ─── Functies: sb.rpc(naam, { p_x: ... }) ───

async function rpc(fn: string, args: Record<string, unknown> = {}) {
  try {
    const namen = Object.keys(args);
    const params = namen.map((k) => {
      const w = args[k];
      if (w === null || w === undefined) return null;
      // Lijst met getallen → Postgres-array (int[]); al het andere → JSON.
      if (Array.isArray(w) && w.length > 0 && w.every((x) => typeof x === 'number')) return '{' + w.join(',') + '}';
      return typeof w === 'object' ? JSON.stringify(w) : String(w);
    });
    const sql = `select to_json(public.${naam(fn)}(${namen.map((k, i) => `${naam(k)} => $${i + 1}`).join(', ')})) as v`;
    return { data: await alsGebruiker(sql, params), error: null };
  } catch (e) {
    return { data: null, error: fout(e) };
  }
}

// ─── Inloggen ───

interface Sessie { user: { id: string; email: string } }
type Luisteraar = (gebeurtenis: string, s: Sessie | null) => void;
const luisteraars = new Set<Luisteraar>();

function sessie(): Sessie | null {
  try { return JSON.parse(localStorage.getItem(SESSIE) ?? 'null') as Sessie | null; } catch { return null; }
}
function zetSessie(s: Sessie | null) {
  try { if (s) localStorage.setItem(SESSIE, JSON.stringify(s)); else localStorage.removeItem(SESSIE); } catch { /* geen opslag */ }
  geheugen = s;
  luisteraars.forEach((l) => l(s ? 'SIGNED_IN' : 'SIGNED_OUT', s));
}
// Voor als localStorage niet werkt: dan alleen zolang de pagina open is.
let geheugen: Sessie | null = null;
const huidig = () => sessie() ?? geheugen;

async function zoek(email: string, ww: string) {
  const d = await db();
  const { rows } = await d.query<{ id: string; email: string }>(
    `select id, email from auth.users where email = lower($1) and encrypted_password = extensions.crypt($2, encrypted_password)`, [email, ww]);
  return rows[0] ?? null;
}

const auth = {
  async getSession() {
    const s = huidig();
    if (!s) return { data: { session: null }, error: null };
    // Bestaat dit account nog? Na opnieuw klaarzetten hoort een oude inlog er niet meer bij.
    try {
      const { rows } = await (await db()).query(`select 1 from auth.users where id = $1`, [s.user.id]);
      if (!rows.length) { zetSessie(null); return { data: { session: null }, error: null }; }
    } catch { /* database start niet: het inlogscherm meldt dat */ }
    return { data: { session: s }, error: null };
  },
  onAuthStateChange(f: Luisteraar) {
    luisteraars.add(f);
    return { data: { subscription: { unsubscribe: () => luisteraars.delete(f) } } };
  },
  async signInWithPassword({ email, password }: { email: string; password: string }) {
    try {
      const u = await zoek(email, password);
      if (!u) return { data: { session: null }, error: { message: 'Invalid login credentials' } };
      const s = { user: u };
      zetSessie(s);
      return { data: { session: s }, error: null };
    } catch (e) { return { data: { session: null }, error: fout(e) }; }
  },
  async signUp({ email, password, options }: { email: string; password: string; options?: { data?: Record<string, unknown> } }) {
    try {
      const d = await db();
      const { rows } = await d.query<{ id: string; email: string }>(
        `insert into auth.users (email, encrypted_password, raw_user_meta_data)
         values (lower($1), extensions.crypt($2, extensions.gen_salt('bf', 4)), $3) on conflict (email) do nothing returning id, email`,
        [email, password, JSON.stringify(options?.data ?? {})]);
      if (!rows[0]) return { data: { session: null }, error: { message: 'User already registered' } };
      const s = { user: rows[0] };
      zetSessie(s);
      return { data: { session: s }, error: null };
    } catch (e) { return { data: { session: null }, error: fout(e) }; }
  },
  async updateUser({ password }: { password?: string }) {
    const s = huidig();
    if (!s || !password) return { data: null, error: { message: 'Niet ingelogd' } };
    const d = await db();
    await d.query(`update auth.users set encrypted_password = extensions.crypt($2, extensions.gen_salt('bf', 4)), updated_at = now() where id = $1`, [s.user.id, password]);
    return { data: { user: s.user }, error: null };
  },
  async signOut() { zetSessie(null); return { error: null }; },
};

export const proefClient = { from: (t: string) => new Lezen(t), rpc, auth } as unknown as SupabaseClient;

// Alles wissen en opnieuw beginnen met de voorbeeldgegevens.
export async function proefOpnieuw() {
  zetSessie(null);
  try { (await dbP)?.close(); } catch { /* al dicht */ }
  dbP = null;
  await wisOpslag();
  location.reload();
}

// Database alvast laden terwijl het inlogscherm getoond wordt.
export const proefLaden = () => db().then(() => undefined);
