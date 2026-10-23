// Proefversie: de database in de browser (PGlite) moet op elke dag van de week
// goed klaargezet worden, met dezelfde migraties als de echte kassa.
//   npm run test:proef
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { PGlite } from '@electric-sql/pglite';
import { pgcrypto } from '@electric-sql/pglite/contrib/pgcrypto';

const lees = (p) => fs.readFileSync(new URL('../' + p, import.meta.url), 'utf8');
const opzet = lees('src/demo/opzet.sql');
const vulling = lees('src/demo/vulling.sql');
const migraties = fs.readdirSync(new URL('../supabase/migrations/', import.meta.url)).sort()
  .map((n) => lees('supabase/migrations/' + n));

// Zoals src/demo/client.ts: alles in één transactie.
async function klaarzetten(vandaag) {
  const d = await PGlite.create({ extensions: { pgcrypto } });
  await d.transaction(async (tx) => {
    await tx.exec(opzet);
    for (const sql of migraties) await tx.exec(sql);
    await tx.query(`select set_config('proef.vandaag', $1, true)`, [vandaag]);
    await tx.exec(vulling);
  });
  return d;
}

// Als ingelogde gebruiker, zoals de app (rol authenticated, rechten gelden).
async function als(d, email, sql) {
  const { rows: [u] } = await d.query(`select id from auth.users where email = $1`, [email]);
  return d.transaction(async (tx) => {
    await tx.query(`select set_config('request.jwt.claim.sub', $1, true)`, [u.id]);
    await tx.exec('set local role authenticated');
    return (await tx.query(sql)).rows[0].v;
  });
}

// Zeven opeenvolgende dagen = elke weekdag één keer (19 oktober 2026 is een maandag).
for (let i = 0; i < 7; i++) {
  const dag = new Date(Date.UTC(2026, 9, 19 + i)).toISOString().slice(0, 10);
  test(`klaarzetten op ${dag}`, async () => {
    const d = await klaarzetten(dag);
    const { rows } = await d.query(`select email, encrypted_password = extensions.crypt('proef1234', encrypted_password) as ok
                                    from auth.users order by email`);
    assert.deepEqual(rows.map((r) => [r.email, r.ok]),
      [['anna@kassa.lokaal', true], ['demo@kassa.lokaal', true], ['kees@kassa.lokaal', true]]);
    // 20 kaarten van dit seizoen + 7 oude om op te ruimen.
    assert.equal((await d.query(`select count(*)::int as n from public.kaarten`)).rows[0].n, 27);
    assert.equal((await d.query(`select count(*)::int as n from public.kaarten where laatst_gebruikt < now() - interval '12 months'`)).rows[0].n, 7);
    assert.ok((await d.query(`select count(*)::int as n from public.verkopen`)).rows[0].n > 50);
    // Inloggen als Demo werkt: de kassa is open en er is een rapport.
    const dienst = await als(d, 'demo@kassa.lokaal', `select to_json(public.dienst_overzicht()) as v`);
    assert.ok(dienst && dienst.bonnen > 0);
    const r = await als(d, 'demo@kassa.lokaal', `select to_json(public.rapport(now() - interval '30 days', now() + interval '1 day')) as v`);
    assert.ok(r.omzet_cent > 0);
    // Kees wacht nog op goedkeuring en ziet niets.
    assert.equal(await als(d, 'kees@kassa.lokaal', `select to_json(public.versie()) as v`) !== undefined, true);
    await assert.rejects(als(d, 'kees@kassa.lokaal', `select to_json(public.dienst_overzicht()) as v`));
    await d.close();
  });
}
