// Tests voor de database-regels, tegen een lokale Supabase met een LEGE database.
//   SUPABASE_URL=http://localhost:54321 SUPABASE_ANON_KEY=... npm run test:db
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createClient } from '@supabase/supabase-js';

const URL = process.env.SUPABASE_URL ?? 'http://localhost:54321';
const KEY = process.env.SUPABASE_ANON_KEY;
if (!KEY) throw new Error('Zet SUPABASE_ANON_KEY');

const client = () => createClient(URL, KEY, { auth: { persistSession: false, autoRefreshToken: false } });
const run = Date.now();

async function gebruiker(naam) {
  const c = client();
  const { error } = await c.auth.signUp({ email: `${naam}-${run}@test.nl`, password: 'geheim-wachtwoord', options: { data: { naam } } });
  assert.ifError(error);
  return c;
}
async function rpc(c, fn, args) {
  const { data, error } = await c.rpc(fn, args);
  if (error) throw new Error(error.message);
  return data;
}
const faalt = (p, tekst) => assert.rejects(p, (e) => (tekst ? e.message.includes(tekst) : true));

let baas, bar, gast, producten;
const product = (naam) => producten.find((p) => p.naam === naam);

test('eerste gebruiker wordt beheerder, de rest moet wachten', async () => {
  baas = await gebruiker('Baas');
  bar = await gebruiker('Bar');
  gast = await gebruiker('Gast');
  assert.equal(await rpc(baas, 'mijn_rol'), 'beheerder');
  assert.equal(await rpc(bar, 'mijn_rol'), 'wacht');
  const { data } = await bar.from('producten').select('*');
  assert.deepEqual(data, []);
  await faalt(rpc(bar, 'rekening_maken', { p_naam: 'x' }), 'geen toegang');
});

test('anoniem ziet en mag niets', async () => {
  const anon = client();
  const { data, error } = await anon.from('producten').select('*');
  assert.ok(error || data.length === 0);
  await faalt(rpc(anon, 'afrekenen', { p_regels: [] }));
});

test('beheerder keurt medewerker goed', async () => {
  const { data: p } = await baas.from('profielen').select('id,naam');
  await rpc(baas, 'gebruiker_bijwerken', { p_id: p.find((x) => x.naam === 'Bar').id, p_rol: 'medewerker', p_actief: true });
  assert.equal(await rpc(bar, 'mijn_rol'), 'medewerker');
  producten = (await bar.from('producten').select('*')).data;
  assert.equal(producten.length, 8);
});

test('elk product heeft een voorraad', async () => {
  assert.ok(producten.every((p) => p.voorraad_bijhouden));
  // Beginstand voor de tests hieronder: van alles 100.
  for (const p of producten) await rpc(baas, 'voorraad_boeken', { p_product_id: p.id, p_aantal: 100, p_soort: 'telling' });
  const id = await rpc(baas, 'product_opslaan', { p: { naam: 'Spa rood', prijs_cent: 150, categorie: 'Drinken', voorraad: 12, voorraad_bijhouden: false } });
  const { data: nieuw } = await bar.from('producten').select('voorraad,voorraad_bijhouden').eq('id', id).single();
  assert.deepEqual(nieuw, { voorraad: 12, voorraad_bijhouden: true });
  await rpc(baas, 'product_verwijderen', { p_id: id });
});

test('rechtstreeks schrijven in tabellen kan niet', async () => {
  const { error: e1 } = await bar.from('producten').update({ prijs_cent: 1 }).eq('id', product('Bier').id);
  assert.ok(e1);
  const { error: e2 } = await baas.from('verkopen').insert({ totaal_cent: 1 });
  assert.ok(e2);
  const { error: e3 } = await baas.from('kaarten').update({ saldo_cent: 99999 }).gt('id', 0);
  assert.ok(e3);
  await faalt(rpc(bar, 'product_opslaan', { p: { naam: 'Gratis bier', prijs_cent: 0 } }), 'beheerder');
});

test('afrekenen vereist een open kassa', async () => {
  await faalt(rpc(bar, 'afrekenen', { p_regels: [{ product_id: product('Bier').id, aantal: 1 }], p_betalingen: [{ methode: 'pin' }] }), 'Open eerst');
  await rpc(bar, 'dienst_openen', { p_beginsaldo_cent: 5000 });
  await faalt(rpc(baas, 'dienst_openen', { p_beginsaldo_cent: 0 }), 'al open');
});

test('contant afrekenen met wisselgeld; de server bepaalt de prijs', async () => {
  const bon = await rpc(bar, 'afrekenen', {
    p_regels: [{ product_id: product('Bier').id, aantal: 2, prijs_cent: 1 }, { product_id: product('Chips').id, aantal: 1 }],
    p_betalingen: [{ methode: 'contant', gegeven_cent: 1000 }],
  });
  assert.equal(bon.totaal_cent, 500);
  assert.equal(bon.betalingen[0].wisselgeld_cent, 500);
  assert.equal(bon.door_naam, 'Bar');
  await faalt(rpc(bar, 'afrekenen', { p_regels: [{ product_id: product('Bier').id, aantal: 1 }], p_betalingen: [{ methode: 'contant', gegeven_cent: 100 }] }), 'te weinig');
  await faalt(rpc(bar, 'afrekenen', { p_regels: [{ product_id: product('Bier').id, aantal: -3 }], p_betalingen: [{ methode: 'pin' }] }), 'aantal');
  await faalt(rpc(bar, 'afrekenen', { p_regels: [], p_betalingen: [{ methode: 'pin' }] }), 'leeg');
  await faalt(rpc(bar, 'afrekenen', { p_regels: [{ product_id: 999999, aantal: 1 }], p_betalingen: [{ methode: 'pin' }] }), 'niet meer beschikbaar');
  await faalt(rpc(bar, 'afrekenen', { p_regels: [{ product_id: product('Bier').id, aantal: 1 }], p_betalingen: [] }), 'Kies hoe');
});

let kaart;
test('kaarten: codes geheim, opwaarderen, betalen alleen met code', async () => {
  await faalt(rpc(bar, 'kaarten_maken', { p_aantal: 2 }), 'beheerder');
  const nieuw = await rpc(baas, 'kaarten_maken', { p_aantal: 3 });
  assert.equal(nieuw.length, 3);
  assert.match(nieuw[0].code, /^[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}$/);
  kaart = nieuw[0];
  const { error } = await bar.from('kaarten').select('code');
  assert.ok(error, 'code mag niet leesbaar zijn');
  assert.equal(await rpc(bar, 'kaart_codes', { p_nummers: [kaart.nummer] }), null);

  const info = await rpc(bar, 'kaart_info', { p_zoek: String(kaart.nummer) });
  assert.equal(info.saldo_cent, 0);
  assert.equal(await rpc(bar, 'kaart_opwaarderen', { p_kaart_id: info.id, p_bedrag_cent: 1000, p_methode: 'contant' }), 1000);

  await faalt(rpc(bar, 'afrekenen', { p_regels: [{ product_id: product('Wijn').id, aantal: 1 }], p_betalingen: [{ methode: 'kaart', kaart: String(kaart.nummer) }] }), 'QR-code');
  const bon = await rpc(bar, 'afrekenen', { p_regels: [{ product_id: product('Wijn').id, aantal: 2 }], p_betalingen: [{ methode: 'kaart', kaart: kaart.code.toLowerCase().replace('-', '') }] });
  assert.equal(bon.betalingen[0].kaart_saldo_na, 500);

  // 3 wijn = 750: 500 van de kaart, 250 pin.
  const bon2 = await rpc(bar, 'afrekenen', { p_regels: [{ product_id: product('Wijn').id, aantal: 3 }], p_betalingen: [{ methode: 'kaart', kaart: kaart.code }, { methode: 'pin' }] });
  assert.deepEqual(bon2.betalingen.map((b) => [b.methode, b.bedrag_cent]), [['kaart', 500], ['pin', 250]]);
  await faalt(rpc(bar, 'afrekenen', { p_regels: [{ product_id: product('Wijn').id, aantal: 1 }], p_betalingen: [{ methode: 'kaart', kaart: kaart.code }] }), 'geen tegoed');
});

test('twee apparaten tegelijk kunnen een kaart niet dubbel afschrijven', async () => {
  const info = await rpc(bar, 'kaart_info', { p_zoek: kaart.code });
  await rpc(bar, 'kaart_opwaarderen', { p_kaart_id: info.id, p_bedrag_cent: 200, p_methode: 'pin' });
  const koop = (c) => rpc(c, 'afrekenen', { p_regels: [{ product_id: product('Bier').id, aantal: 1 }], p_betalingen: [{ methode: 'kaart', kaart: kaart.code }] });
  const res = await Promise.allSettled([koop(bar), koop(baas)]);
  assert.equal(res.filter((r) => r.status === 'fulfilled').length, 1);
  assert.equal((await rpc(bar, 'kaart_info', { p_zoek: kaart.code })).saldo_cent, 0);
});

test('kaart op naam; de naam gaat mee bij overzetten', async () => {
  const info = await rpc(bar, 'kaart_info', { p_zoek: kaart.code });
  await rpc(bar, 'kaart_naam', { p_kaart_id: info.id, p_naam: '  Piet de Vries ' });
  assert.equal((await rpc(bar, 'kaart_info', { p_zoek: String(kaart.nummer) })).naam, 'Piet de Vries');
  const { data } = await bar.from('kaarten').select('nummer,naam').eq('id', info.id).single();
  assert.deepEqual(data, { nummer: kaart.nummer, naam: 'Piet de Vries' });
  await faalt(rpc(gast, 'kaart_naam', { p_kaart_id: info.id, p_naam: 'x' }), 'geen toegang');
  // Overzetten naar een nieuwe kaart: tegoed én naam gaan mee.
  const [nieuw] = await rpc(baas, 'kaarten_maken', { p_aantal: 1 });
  await rpc(baas, 'kaart_overzetten', { p_van: info.id, p_naar: nieuw.code });
  assert.equal((await rpc(bar, 'kaart_info', { p_zoek: nieuw.code })).naam, 'Piet de Vries');
  // Terug naar de oude kaart voor de tests hieronder.
  await rpc(baas, 'kaart_blokkeren', { p_kaart_id: info.id, p_blok: false });
  await rpc(bar, 'kaart_naam', { p_kaart_id: info.id, p_naam: '' });
  assert.equal((await rpc(bar, 'kaart_info', { p_zoek: kaart.code })).naam, null);
});

test('geblokkeerde kaart', async () => {
  const info = await rpc(bar, 'kaart_info', { p_zoek: kaart.code });
  await rpc(bar, 'kaart_blokkeren', { p_kaart_id: info.id, p_blok: true });
  await faalt(rpc(bar, 'kaart_opwaarderen', { p_kaart_id: info.id, p_bedrag_cent: 100, p_methode: 'pin' }), 'geblokkeerd');
  await faalt(rpc(bar, 'kaart_blokkeren', { p_kaart_id: info.id, p_blok: false }), 'beheerder');
  await rpc(baas, 'kaart_blokkeren', { p_kaart_id: info.id, p_blok: false });
});

test('voorraad: levering, verkoop, rekening, annuleren', async () => {
  const bier = product('Bier').id;
  const stand = async () => (await bar.from('producten').select('voorraad').eq('id', bier).single()).data.voorraad;
  const begin = await stand();
  assert.equal(await rpc(baas, 'voorraad_boeken', { p_product_id: bier, p_aantal: 24, p_soort: 'levering' }), begin + 24);
  const bon = await rpc(bar, 'afrekenen', { p_regels: [{ product_id: bier, aantal: 2 }], p_betalingen: [{ methode: 'pin' }] });
  assert.equal(await stand(), begin + 22);
  await rpc(bar, 'verkoop_annuleren', { p_verkoop_id: bon.id });
  assert.equal(await stand(), begin + 24);
  await faalt(rpc(bar, 'verkoop_annuleren', { p_verkoop_id: bon.id }), 'al geannuleerd');
  assert.equal(await rpc(baas, 'voorraad_boeken', { p_product_id: bier, p_aantal: 20, p_soort: 'telling' }), 20);
});

test('voorraad: niet meer verkopen dan er is', async () => {
  const chips = product('Chips').id;
  await rpc(baas, 'voorraad_boeken', { p_product_id: chips, p_aantal: 2, p_soort: 'telling' });
  const stand = async () => (await bar.from('producten').select('voorraad').eq('id', chips).single()).data.voorraad;
  await faalt(rpc(bar, 'afrekenen', { p_regels: [{ product_id: chips, aantal: 3 }], p_betalingen: [{ methode: 'pin' }] }), 'Niet genoeg Chips op voorraad (nog 2)');
  const id = await rpc(bar, 'rekening_maken', { p_naam: 'Voorraadtest' });
  await faalt(rpc(bar, 'rekening_toevoegen', { p_rekening_id: id, p_regels: [{ product_id: chips, aantal: 3 }] }), 'Niet genoeg Chips');
  assert.equal(await stand(), 2);
  // Twee apparaten tegelijk: precies één van de twee lukt.
  const r = await Promise.allSettled([1, 2].map(() =>
    rpc(bar, 'afrekenen', { p_regels: [{ product_id: chips, aantal: 2 }], p_betalingen: [{ methode: 'pin' }] })));
  assert.deepEqual(r.map((x) => x.status).sort(), ['fulfilled', 'rejected']);
  assert.match(r.find((x) => x.status === 'rejected').reason.message, /Chips is op/);
  assert.equal(await stand(), 0);
  await rpc(baas, 'rekening_verwijderen', { p_rekening_id: id });
  await rpc(baas, 'voorraad_boeken', { p_product_id: chips, p_aantal: 50, p_soort: 'levering' });
});

test('rekening: opschrijven, regel schrappen, afrekenen', async () => {
  const id = await rpc(bar, 'rekening_maken', { p_naam: 'Piet' });
  await rpc(bar, 'rekening_toevoegen', { p_rekening_id: id, p_regels: [{ product_id: product('Bier').id, aantal: 3 }] });
  await rpc(baas, 'rekening_toevoegen', { p_rekening_id: id, p_regels: [{ product_id: product('Bier').id, aantal: 1 }, { product_id: product('Koffie').id, aantal: 1 }] });
  const { data: regels } = await bar.from('rekening_regels').select('*').eq('rekening_id', id);
  assert.equal(regels.length, 3);
  await rpc(bar, 'rekening_regel_verwijderen', { p_regel_id: regels.find((r) => r.naam === 'Koffie').id });
  await faalt(rpc(bar, 'rekening_verwijderen', { p_rekening_id: id }), 'lege');
  const bon = await rpc(bar, 'afrekenen', { p_rekening_id: id, p_betalingen: [{ methode: 'contant' }] });
  assert.equal(bon.totaal_cent, 800);
  assert.equal(bon.rekening_naam, 'Piet');
  assert.deepEqual(bon.regels.map((r) => [r.naam, r.aantal]), [['Bier', 4]]);
  await faalt(rpc(bar, 'afrekenen', { p_rekening_id: id, p_betalingen: [{ methode: 'pin' }] }), 'al afgerekend');
  const v = (await bar.from('producten').select('voorraad').eq('id', product('Bier').id).single()).data.voorraad;
  assert.equal(v, 16);
});

test('medewerker annuleert alleen eigen recente bon', async () => {
  const bon = await rpc(baas, 'afrekenen', { p_regels: [{ product_id: product('Koffie').id, aantal: 1 }], p_betalingen: [{ methode: 'pin' }] });
  await faalt(rpc(bar, 'verkoop_annuleren', { p_verkoop_id: bon.id }), 'beheerder');
  await rpc(baas, 'verkoop_annuleren', { p_verkoop_id: bon.id });
});

test('afrekenen weigert als het bedrag intussen is veranderd', async () => {
  const id = await rpc(bar, 'rekening_maken', { p_naam: 'Tafel 2' });
  await rpc(bar, 'rekening_toevoegen', { p_rekening_id: id, p_regels: [{ product_id: product('Koffie').id, aantal: 1 }] });
  // Het apparaat toont € 1,00; intussen boekt een ander apparaat bij.
  await rpc(baas, 'rekening_toevoegen', { p_rekening_id: id, p_regels: [{ product_id: product('Koffie').id, aantal: 1 }] });
  await faalt(rpc(bar, 'afrekenen', { p_rekening_id: id, p_betalingen: [{ methode: 'pin' }], p_verwacht_cent: 100 }), 'intussen veranderd');
  const bon = await rpc(bar, 'afrekenen', { p_rekening_id: id, p_betalingen: [{ methode: 'pin' }], p_verwacht_cent: 200 });
  assert.equal(bon.totaal_cent, 200);
});

test('dezelfde bestelling of opwaardering twee keer verstuurd: één keer geboekt', async () => {
  const bier = product('Bier').id;
  const stand = async () => (await bar.from('producten').select('voorraad').eq('id', bier).single()).data.voorraad;
  const begin = await stand();
  const p_sleutel = crypto.randomUUID();
  const a = { p_regels: [{ product_id: bier, aantal: 2 }], p_betalingen: [{ methode: 'pin' }], p_verwacht_cent: 400, p_sleutel };
  // Tegelijk (haperende wifi) en daarna nog eens.
  const [x, y] = await Promise.all([rpc(bar, 'afrekenen', a), rpc(bar, 'afrekenen', a)]);
  const z = await rpc(bar, 'afrekenen', a);
  assert.equal(x.bonnummer, y.bonnummer);
  assert.equal(x.bonnummer, z.bonnummer);
  assert.equal(await stand(), begin - 2);
  // Een ander kenmerk is een nieuwe bon.
  const nieuw = await rpc(bar, 'afrekenen', { ...a, p_sleutel: crypto.randomUUID() });
  assert.notEqual(nieuw.bonnummer, x.bonnummer);

  const info = await rpc(bar, 'kaart_info', { p_zoek: kaart.code });
  const o = { p_kaart_id: info.id, p_bedrag_cent: 500, p_methode: 'pin', p_sleutel: crypto.randomUUID() };
  const [s1, s2] = await Promise.all([rpc(bar, 'kaart_opwaarderen', o), rpc(bar, 'kaart_opwaarderen', o)]);
  assert.equal(s1, info.saldo_cent + 500);
  assert.equal(s2, s1);
  assert.equal((await rpc(bar, 'kaart_info', { p_zoek: kaart.code })).saldo_cent, info.saldo_cent + 500);
  // Zonder kenmerk werkt het zoals altijd (oudere app).
  assert.equal(await rpc(bar, 'kaart_opwaarderen', { p_kaart_id: info.id, p_bedrag_cent: 100, p_methode: 'pin' }), info.saldo_cent + 600);
});

test('medewerker boekt een levering in, maar telt niet', async () => {
  const cola = product('Frisdrank').id;
  const voor = (await bar.from('producten').select('voorraad').eq('id', cola).single()).data.voorraad;
  assert.equal(await rpc(bar, 'voorraad_boeken', { p_product_id: cola, p_aantal: 24, p_soort: 'levering' }), voor + 24);
  await faalt(rpc(bar, 'voorraad_boeken', { p_product_id: cola, p_aantal: 5, p_soort: 'telling' }), 'beheerder');
  const { data: log } = await baas.from('logboek').select('actie,details,door_naam').eq('actie', 'levering');
  assert.deepEqual(log.at(-1), { actie: 'levering', details: { product: 'Frisdrank', aantal: 24 }, door_naam: 'Bar' });
});

test('rapport: een verkoop na middernacht hoort bij de avond ervoor', async () => {
  const r = await rpc(baas, 'rapport', { p_van: new Date(Date.now() - 86400e3 * 2).toISOString(), p_tot: new Date(Date.now() + 3600e3).toISOString() });
  // Alle verkopen van deze test zijn "nu"; voor 06:00 vallen ze onder gisteren.
  const verwacht = new Date(Date.now() - 6 * 3600e3).toLocaleDateString('sv-SE', { timeZone: 'Europe/Amsterdam' });
  assert.deepEqual(r.per_dag.map((d) => d.dag), [verwacht]);
});

test('betaalmethoden aan of uit', async () => {
  const zet = (m) => rpc(baas, 'betaalmethoden_opslaan', { p_contant: true, p_pin: true, p_kaart: true, p_rekening: true, p_lat: true, ...m });
  await faalt(rpc(bar, 'betaalmethoden_opslaan', { p_contant: true, p_pin: false, p_kaart: true, p_rekening: true }), 'beheerder');
  await faalt(zet({ p_contant: false, p_pin: false, p_kaart: false, p_lat: false }), 'minstens één');
  const koffie = [{ product_id: product('Koffie').id, aantal: 1 }];
  // Een open rekening van vóór het uitzetten.
  const open = await rpc(bar, 'rekening_maken', { p_naam: 'Van gisteren' });
  await rpc(bar, 'rekening_toevoegen', { p_rekening_id: open, p_regels: koffie });

  await zet({ p_pin: false, p_rekening: false });
  const { data: inst } = await bar.from('instellingen').select('betaal_contant,betaal_pin,betaal_kaart,betaal_rekening').single();
  assert.deepEqual(inst, { betaal_contant: true, betaal_pin: false, betaal_kaart: true, betaal_rekening: false });
  await faalt(rpc(bar, 'afrekenen', { p_regels: koffie, p_betalingen: [{ methode: 'pin' }] }), 'Betalen met pin staat uit');
  // Ook niet als restbedrag na een kaart.
  await faalt(rpc(bar, 'afrekenen', { p_regels: koffie, p_betalingen: [{ methode: 'kaart', kaart: kaart.code }, { methode: 'pin' }] }), 'pin staat uit');
  const info = await rpc(bar, 'kaart_info', { p_zoek: kaart.code });
  await faalt(rpc(bar, 'kaart_opwaarderen', { p_kaart_id: info.id, p_bedrag_cent: 500, p_methode: 'pin' }), 'pin staat uit');
  await faalt(rpc(bar, 'rekening_maken', { p_naam: 'Nieuw' }), 'Op rekening zetten staat uit');
  await faalt(rpc(bar, 'rekening_toevoegen', { p_rekening_id: open, p_regels: koffie }), 'Op rekening zetten staat uit');
  // De open rekening kan nog wel worden afgerekend, met een methode die aan staat.
  const bon = await rpc(bar, 'afrekenen', { p_rekening_id: open, p_betalingen: [{ methode: 'kaart', kaart: kaart.code }] });
  assert.equal(bon.totaal_cent, 100);

  await zet({ p_kaart: false });
  await faalt(rpc(bar, 'afrekenen', { p_regels: koffie, p_betalingen: [{ methode: 'kaart', kaart: kaart.code }] }), 'kaart staat uit');
  await faalt(rpc(bar, 'kaart_opwaarderen', { p_kaart_id: info.id, p_bedrag_cent: 500, p_methode: 'contant' }), 'kaart staat uit');

  await zet({});
  const { data: log } = await baas.from('logboek').select('actie,details').eq('actie', 'betaalmethoden');
  assert.deepEqual(log.at(-1).details, { contant: true, pin: true, kaart: true, rekening: true, lat: true, gratis: true });
});

test('klant bekijkt zelf het saldo, alleen met de kaartcode', async () => {
  const anon = client();
  const info = await rpc(bar, 'kaart_info', { p_zoek: kaart.code });
  const s = await rpc(anon, 'kaart_saldo', { p_code: kaart.code.toLowerCase() });
  assert.equal(s.nummer, info.nummer);
  assert.equal(s.saldo_cent, info.saldo_cent);
  assert.ok(s.historie.length > 0 && s.historie.length <= 10);
  assert.deepEqual(Object.keys(s.historie[0]).sort(), ['bedrag_cent', 'soort', 'ts']);
  assert.match((await rpc(anon, 'kaart_saldo', { p_code: String(info.nummer) })).fout, /code van je kaart/);
  assert.match((await rpc(anon, 'kaart_saldo', { p_code: 'AAAA-AAAA' })).fout, /niet gevonden/);
  // Verder ziet een klant zonder account niets.
  await faalt(rpc(anon, 'kaart_info', { p_zoek: kaart.code }));
});

test('streeplijst: op de lat, afbetalen, maandoverzicht', async () => {
  const koffie = product('Koffie').id, bier = product('Bier').id;
  const piet = await rpc(bar, 'lid_opslaan', { p_id: null, p_naam: 'Piet Lid' });
  await faalt(rpc(bar, 'lid_opslaan', { p_id: null, p_naam: ' piet lid ' }), 'staat al');
  await faalt(rpc(bar, 'lid_opslaan', { p_id: piet, p_naam: 'Piet', p_actief: true }), 'beheerder');
  const stand = async () => (await bar.from('producten').select('voorraad').eq('id', bier).single()).data.voorraad;
  const voor = await stand();
  const bon = await rpc(bar, 'afrekenen', { p_regels: [{ product_id: bier, aantal: 2 }], p_betalingen: [{ methode: 'lat', lid: piet }], p_verwacht_cent: 400 });
  assert.deepEqual(bon.betalingen.map((b) => [b.methode, b.bedrag_cent, b.lid_naam]), [['lat', 400, 'Piet Lid']]);
  assert.equal(await stand(), voor - 2);
  // Kaart eerst, de rest op de lat.
  const tegoed = (await rpc(bar, 'kaart_info', { p_zoek: kaart.code })).saldo_cent;
  const n = Math.floor(tegoed / 100) + 1;   // net meer koffie dan er tegoed is
  const b2 = await rpc(bar, 'afrekenen', { p_regels: [{ product_id: koffie, aantal: n }], p_betalingen: [{ methode: 'kaart', kaart: kaart.code }, { methode: 'lat', lid: piet }] });
  assert.deepEqual(b2.betalingen.map((b) => [b.methode, b.bedrag_cent]), [['kaart', tegoed], ['lat', n * 100 - tegoed]]);
  const open = 400 + n * 100 - tegoed;
  let lijst = await rpc(bar, 'streeplijst');
  assert.equal(lijst.find((l) => l.id === piet).open_cent, open);
  // Annuleren haalt het streepje weg.
  const b3 = await rpc(bar, 'afrekenen', { p_regels: [{ product_id: koffie, aantal: 1 }], p_betalingen: [{ methode: 'lat', lid: piet }] });
  await rpc(bar, 'verkoop_annuleren', { p_verkoop_id: b3.id });
  assert.equal((await rpc(bar, 'lid_historie', { p_lid: piet })).open_cent, open);

  // Afbetalen: contant telt mee in de la, niet meer dan er openstaat, overboeking alleen beheerder.
  const la = (await rpc(bar, 'dienst_overzicht')).verwacht_cent;
  assert.equal(await rpc(bar, 'lat_afbetalen', { p_lid: piet, p_bedrag_cent: 300, p_methode: 'contant' }), open - 300);
  const d = await rpc(bar, 'dienst_overzicht');
  assert.equal(d.verwacht_cent, la + 300);
  assert.equal(d.afbetaald_contant_cent, 300);
  assert.ok(d.lat_cent >= open);
  await faalt(rpc(bar, 'lat_afbetalen', { p_lid: piet, p_bedrag_cent: open, p_methode: 'pin' }), 'meer afbetalen kan niet');
  await faalt(rpc(bar, 'lat_afbetalen', { p_lid: piet, p_bedrag_cent: 10, p_methode: 'overboeking' }), 'beheerder');
  assert.equal(await rpc(baas, 'lat_afbetalen', { p_lid: piet, p_bedrag_cent: open - 300, p_methode: 'overboeking', p_opmerking: 'incasso' }), 0);
  const h = await rpc(bar, 'lid_historie', { p_lid: piet });
  assert.deepEqual(h.regels.map((r) => r.soort).sort(), ['afbetaald', 'afbetaald', 'streep', 'streep']);

  const maand = await rpc(baas, 'streeplijst_maand', { p_maand: new Date().toISOString().slice(0, 10) });
  assert.deepEqual(maand.find((m) => m.id === piet), { id: piet, naam: 'Piet Lid', actief: true, gestreept_cent: open, keer: 2, afbetaald_cent: open, open_cent: 0 });
  await faalt(rpc(bar, 'streeplijst_maand', { p_maand: '2026-10-01' }), 'beheerder');

  // Uit de lijst gehaald, of de streeplijst uitgezet: niet meer strepen.
  await rpc(baas, 'lid_opslaan', { p_id: piet, p_naam: 'Piet Lid', p_actief: false });
  await faalt(rpc(bar, 'afrekenen', { p_regels: [{ product_id: koffie, aantal: 1 }], p_betalingen: [{ methode: 'lat', lid: piet }] }), 'niet meer op de streeplijst');
  await rpc(baas, 'lid_opslaan', { p_id: piet, p_naam: 'Piet Lid', p_actief: true });
  await rpc(baas, 'betaalmethoden_opslaan', { p_contant: true, p_pin: true, p_kaart: true, p_rekening: true, p_lat: false });
  await faalt(rpc(bar, 'afrekenen', { p_regels: [{ product_id: koffie, aantal: 1 }], p_betalingen: [{ methode: 'lat', lid: piet }] }), 'streeplijst staat uit');
  await rpc(baas, 'betaalmethoden_opslaan', { p_contant: true, p_pin: true, p_kaart: true, p_rekening: true, p_lat: true });
  await faalt(rpc(bar, 'afrekenen', { p_regels: [{ product_id: koffie, aantal: 1 }], p_betalingen: [{ methode: 'lat' }] }), 'Kies een lid');
});

test('kassa sluiten: verwacht = begin + contant verkocht + contant opgewaardeerd', async () => {
  // Contant: 500 (bier+chips) + 800 (rekening Piet) + 100 (koffie hieronder); opwaardering contant 1000.
  const laat = await rpc(bar, 'afrekenen', { p_regels: [{ product_id: product('Koffie').id, aantal: 1 }], p_betalingen: [{ methode: 'contant' }] });
  const d = await rpc(bar, 'dienst_overzicht');
  // + 300 contant afbetaald van de streeplijst.
  assert.equal(d.verwacht_cent, 5000 + 500 + 800 + 100 + 1000 + 300);
  const dicht = await rpc(bar, 'dienst_sluiten', { p_geteld_cent: 7650, p_opmerking: 'briefje van 50 cent kwijt' });
  assert.equal(dicht.geteld_cent - dicht.verwacht_cent, -50);
  await faalt(rpc(bar, 'afrekenen', { p_regels: [{ product_id: product('Bier').id, aantal: 1 }], p_betalingen: [{ methode: 'pin' }] }), 'Open eerst');
  // Na het tellen: een medewerker annuleert geen bon meer; als de beheerder het doet, blijft de telling staan.
  await faalt(rpc(bar, 'verkoop_annuleren', { p_verkoop_id: laat.id }), 'al gesloten');
  await rpc(baas, 'verkoop_annuleren', { p_verkoop_id: laat.id });
  const r = await rpc(baas, 'rapport', { p_van: new Date(Date.now() - 3600e3).toISOString(), p_tot: new Date(Date.now() + 3600e3).toISOString() });
  assert.equal(r.diensten.find((x) => x.id === dicht.id).verwacht_cent, dicht.verwacht_cent);
});

test('rapport en logboek alleen voor beheerder', async () => {
  const van = new Date(Date.now() - 3600e3).toISOString(), tot = new Date(Date.now() + 3600e3).toISOString();
  await faalt(rpc(bar, 'rapport', { p_van: van, p_tot: tot }), 'beheerder');
  const r = await rpc(baas, 'rapport', { p_van: van, p_tot: tot });
  assert.equal(r.geannuleerd, 4);
  assert.ok(r.omzet_cent > 0);
  assert.equal(r.diensten.length, 1);
  assert.deepEqual((await bar.from('logboek').select('*')).data, []);
  assert.ok((await baas.from('logboek').select('*')).data.length > 0);
});

test('laatste beheerder kan zichzelf niet degraderen', async () => {
  const { data: { user } } = await baas.auth.getUser();
  await faalt(rpc(baas, 'gebruiker_bijwerken', { p_id: user.id, p_rol: 'medewerker', p_actief: true }), 'minstens één');
});

test('inloggen met een naam (intern naam@kassa.lokaal)', async () => {
  const c = client();
  const email = `piet.${run}@kassa.lokaal`;
  const { error } = await c.auth.signUp({ email, password: 'geheim-wachtwoord', options: { data: { naam: 'Piet' } } });
  assert.ifError(error);
  const d = client();
  assert.ifError((await d.auth.signInWithPassword({ email, password: 'geheim-wachtwoord' })).error);
  assert.equal(await rpc(d, 'mijn_rol'), 'wacht');
});

test('beheerder stelt een nieuw wachtwoord in', async () => {
  const { data: p } = await baas.from('profielen').select('id,naam');
  const id = p.find((x) => x.naam === 'Bar').id;
  await faalt(rpc(bar, 'wachtwoord_instellen', { p_id: id, p_wachtwoord: 'nieuw-wachtwoord' }), 'beheerder');
  await faalt(rpc(baas, 'wachtwoord_instellen', { p_id: id, p_wachtwoord: 'kort' }), '8 tekens');
  await rpc(baas, 'wachtwoord_instellen', { p_id: id, p_wachtwoord: 'nieuw-wachtwoord' });
  const c = client();
  assert.ifError((await c.auth.signInWithPassword({ email: `bar-${run}@test.nl`, password: 'nieuw-wachtwoord' })).error);
  assert.ok((await c.auth.signInWithPassword({ email: `bar-${run}@test.nl`, password: 'geheim-wachtwoord' })).error);
});

test('wijzigingsteller loopt op bij elke wijziging', async () => {
  const anon = client();
  assert.equal(await rpc(anon, 'versie').catch(() => null), null);
  const v1 = await rpc(bar, 'versie');
  await rpc(bar, 'rekening_maken', { p_naam: 'Teller' });
  const v2 = await rpc(bar, 'versie');
  assert.ok(v2 > v1);
});

test('lid ziet de eigen streeplijst met een eigen code', async () => {
  const anon = client();
  const lid = (await rpc(bar, 'streeplijst')).find((l) => l.naam === 'Piet Lid');
  const code = await rpc(bar, 'lid_code', { p_lid: lid.id });
  assert.match(code, /^[A-Z0-9]{4}-[A-Z0-9]{4}$/);
  const o = await rpc(anon, 'lid_overzicht', { p_code: code });
  assert.equal(o.naam, 'Piet Lid');
  assert.equal(o.open_cent, 0);
  assert.ok(o.regels.some((r) => r.soort === 'streep' && r.door_naam === 'Bar'));
  // Nieuwe code: de oude werkt niet meer.
  await faalt(rpc(bar, 'lid_nieuwe_code', { p_lid: lid.id }), 'beheerder');
  const nieuw = await rpc(baas, 'lid_nieuwe_code', { p_lid: lid.id });
  assert.notEqual(nieuw, code);
  assert.match((await rpc(anon, 'lid_overzicht', { p_code: code })).fout, /niet gevonden/);
  assert.equal((await rpc(anon, 'lid_overzicht', { p_code: nieuw })).naam, 'Piet Lid');
  await faalt(rpc(anon, 'lid_code', { p_lid: lid.id }));
});

test('controle per medewerker, alleen voor beheerder', async () => {
  const van = new Date(Date.now() - 86400e3).toISOString(), tot = new Date(Date.now() + 3600e3).toISOString();
  await faalt(rpc(bar, 'controle', { p_van: van, p_tot: tot }), 'beheerder');
  const c = await rpc(baas, 'controle', { p_van: van, p_tot: tot });
  const b = c.medewerkers.find((m) => m.naam === 'Bar');
  assert.ok(b.bonnen > 0 && b.omzet_cent > 0);
  assert.ok(b.geannuleerd >= 1);
  assert.equal(b.diensten, 1);
  assert.equal(b.kasverschil_cent, -50);
  assert.equal(b.tekorten, 1);
  assert.equal(b.afbetaald_contant_cent, 300);
  assert.ok(c.annuleringen.length >= 4);
  assert.deepEqual(c.tekorten.map((t) => [t.verschil_cent, t.gesloten_door]), [[-50, 'Bar']]);
});

test('uitnodigen met een QR-code: één keer, 24 uur, intrekbaar', async () => {
  const anon = client();
  await faalt(rpc(bar, 'uitnodiging_maken', { p_naam: 'Jan', p_rol: 'medewerker' }), 'beheerder');
  const u = await rpc(baas, 'uitnodiging_maken', { p_naam: `Jan ${run}`, p_rol: 'medewerker' });
  assert.match(u.code, /^[0-9a-f]{32}$/);
  assert.deepEqual(await rpc(anon, 'uitnodiging_info', { p_code: u.code }), { naam: `Jan ${run}`, rol: 'medewerker', winkel: 'Bar' });
  // Account aanmaken met de uitnodiging: meteen medewerker, geen goedkeuring nodig.
  const jan = client();
  const email = `jan.${run}@kassa.lokaal`;
  assert.ifError((await jan.auth.signUp({ email, password: 'geheim-wachtwoord', options: { data: { naam: 'Iets anders', uitnodiging: u.code } } })).error);
  assert.equal(await rpc(jan, 'mijn_rol'), 'medewerker');
  const { data: p } = await baas.from('profielen').select('naam,rol,actief').eq('naam', `Jan ${run}`).single();
  assert.deepEqual(p, { naam: `Jan ${run}`, rol: 'medewerker', actief: true });
  // Nog een keer gebruiken kan niet.
  assert.match((await rpc(anon, 'uitnodiging_info', { p_code: u.code })).fout, /al gebruikt/);
  const { error } = await client().auth.signUp({ email: `piet.${run}@kassa.lokaal`, password: 'geheim-wachtwoord', options: { data: { uitnodiging: u.code } } });
  assert.ok(error);
  // Ingetrokken of verlopen: niet meer te gebruiken.
  const v = await rpc(baas, 'uitnodiging_maken', { p_naam: 'Kim', p_rol: 'beheerder' });
  await rpc(baas, 'uitnodiging_intrekken', { p_id: v.id });
  assert.match((await rpc(anon, 'uitnodiging_info', { p_code: v.code })).fout, /verlopen of ingetrokken/);
  assert.ok((await client().auth.signUp({ email: `kim.${run}@kassa.lokaal`, password: 'geheim-wachtwoord', options: { data: { uitnodiging: v.code } } })).error);
  assert.match((await rpc(anon, 'uitnodiging_info', { p_code: 'f'.repeat(32) })).fout, /bestaat niet/);
  const { data: log } = await baas.from('logboek').select('actie,door_naam').eq('actie', 'uitnodiging_gebruikt');
  assert.equal(log.at(-1).door_naam, `Jan ${run}`);
});

test('zelf aanmelden uit: een account zonder uitnodiging staat uit', async () => {
  const anon = client();
  assert.equal(await rpc(anon, 'aanmelden_open'), true);
  await faalt(rpc(bar, 'aanmelden_instellen', { p_aan: false }), 'beheerder');
  await rpc(baas, 'aanmelden_instellen', { p_aan: false });
  assert.equal(await rpc(anon, 'aanmelden_open'), false);
  const c = client();
  assert.ifError((await c.auth.signUp({ email: `vreemd-${run}@test.nl`, password: 'geheim-wachtwoord', options: { data: { naam: 'Vreemde' } } })).error);
  assert.equal(await rpc(c, 'mijn_rol'), null);   // een account dat uit staat heeft geen rol
  const { data: p } = await baas.from('profielen').select('rol,actief').eq('naam', 'Vreemde').single();
  assert.deepEqual(p, { rol: 'wacht', actief: false });
  await rpc(baas, 'aanmelden_instellen', { p_aan: true });
});

test('na 10 verkeerde wachtwoorden op slot; nieuw wachtwoord van de beheerder haalt het eraf', async () => {
  const email = `slot-${run}@test.nl`;
  const c = client();
  assert.ifError((await c.auth.signUp({ email, password: 'goed-wachtwoord', options: { data: { naam: 'Slot' } } })).error);
  for (let i = 0; i < 10; i++) await client().auth.signInWithPassword({ email, password: 'fout-' + i });
  const { error } = await client().auth.signInWithPassword({ email, password: 'goed-wachtwoord' });
  assert.match(error?.message ?? '', /Te veel verkeerde wachtwoorden/);
  const { data: p } = await baas.from('profielen').select('id,naam');
  await rpc(baas, 'wachtwoord_instellen', { p_id: p.find((x) => x.naam === 'Slot').id, p_wachtwoord: 'nieuw-wachtwoord' });
  assert.ifError((await client().auth.signInWithPassword({ email, password: 'nieuw-wachtwoord' })).error);
});

test('na te veel verkeerde codes is de saldo-pagina even dicht', async () => {
  const anon = client();
  for (let i = 0; i < 10; i++) await rpc(anon, 'kaart_saldo', { p_code: `ZZZZ-ZZ${String(i).padStart(2, '2')}` });
  assert.match((await rpc(anon, 'kaart_saldo', { p_code: kaart.code })).fout, /Te veel verkeerde codes/);
  assert.match((await rpc(anon, 'lid_overzicht', { p_code: kaart.code })).fout, /Te veel verkeerde codes/);
  assert.match((await rpc(anon, 'bon_bekijken', { p_code: 'f'.repeat(24) })).fout, /Te veel verkeerde codes/);
});

test('te weinig wisselgeld: de rest als tegoed op een barkaart', async () => {
  await rpc(bar, 'dienst_openen', { p_beginsaldo_cent: 1000 });
  const [k] = await rpc(baas, 'kaarten_maken', { p_aantal: 1 });
  const bier = [{ product_id: product('Bier').id, aantal: 3 }];   // 3 × 200 = 600
  const bon = await rpc(bar, 'afrekenen', { p_regels: bier, p_betalingen: [{ methode: 'contant', gegeven_cent: 5000, rest_kaart: k.code }] });
  const [b] = bon.betalingen;
  assert.deepEqual([b.bedrag_cent, b.gegeven_cent, b.wisselgeld_cent, b.op_kaart_cent, b.op_kaart_saldo_na, b.op_kaart_nummer],
    [600, 5000, 0, 4400, 4400, k.nummer]);
  const info = await rpc(bar, 'kaart_info', { p_zoek: k.code });
  assert.equal(info.saldo_cent, 4400);
  // Het hele briefje zit in de la: 600 verkocht + 4400 contant opgewaardeerd.
  let d = await rpc(bar, 'dienst_overzicht');
  assert.equal(d.verwacht_cent, 1000 + 5000);
  assert.equal(d.opwaardering_contant_cent, 4400);
  // Bon annuleren: de 600 gaat terug, het tegoed op de kaart blijft staan.
  await rpc(bar, 'verkoop_annuleren', { p_verkoop_id: bon.id });
  assert.equal((await rpc(bar, 'kaart_info', { p_zoek: k.code })).saldo_cent, 4400);
  d = await rpc(bar, 'dienst_overzicht');
  assert.equal(d.verwacht_cent, 1000 + 4400);
  // Alleen met de echte kaartcode, niet op een geblokkeerde kaart, niet als kaart uit staat.
  await faalt(rpc(bar, 'afrekenen', { p_regels: bier, p_betalingen: [{ methode: 'contant', gegeven_cent: 1000, rest_kaart: String(k.nummer) }] }), 'QR-code');
  await rpc(bar, 'kaart_blokkeren', { p_kaart_id: info.id, p_blok: true });
  await faalt(rpc(bar, 'afrekenen', { p_regels: bier, p_betalingen: [{ methode: 'contant', gegeven_cent: 1000, rest_kaart: k.code }] }), 'geblokkeerd');
  await rpc(baas, 'kaart_blokkeren', { p_kaart_id: info.id, p_blok: false });
  const zet = (m) => rpc(baas, 'betaalmethoden_opslaan', { p_contant: true, p_pin: true, p_kaart: true, p_rekening: true, p_lat: true, ...m });
  await zet({ p_kaart: false });
  await faalt(rpc(bar, 'afrekenen', { p_regels: bier, p_betalingen: [{ methode: 'contant', gegeven_cent: 1000, rest_kaart: k.code }] }), 'kaart staat uit');
  await zet({});
  // Gepast betaald: er gaat niets op de kaart.
  const gepast = await rpc(bar, 'afrekenen', { p_regels: bier, p_betalingen: [{ methode: 'contant', gegeven_cent: 600, rest_kaart: k.code }] });
  assert.equal(gepast.betalingen[0].op_kaart_cent, null);
  assert.equal((await rpc(bar, 'kaart_info', { p_zoek: k.code })).saldo_cent, 4400);
  await rpc(bar, 'dienst_sluiten', { p_geteld_cent: 1000 + 4400 + 600 });
});

test('kaart verwijderen: tegoed vervalt en staat in het rapport; opruimen na 12 maanden', async () => {
  await rpc(bar, 'dienst_openen', { p_beginsaldo_cent: 0 });
  const [k] = await rpc(baas, 'kaarten_maken', { p_aantal: 1 });
  const info = await rpc(bar, 'kaart_info', { p_zoek: k.code });
  await rpc(bar, 'kaart_opwaarderen', { p_kaart_id: info.id, p_bedrag_cent: 750, p_methode: 'contant' });
  await faalt(rpc(bar, 'kaart_verwijderen', { p_kaart_id: info.id, p_saldo_cent: 750 }), 'beheerder');
  // Het saldo dat de beheerder zag klopt niet meer: niet verwijderen.
  await faalt(rpc(baas, 'kaart_verwijderen', { p_kaart_id: info.id, p_saldo_cent: 0 }), 'intussen veranderd');
  await rpc(baas, 'kaart_verwijderen', { p_kaart_id: info.id, p_saldo_cent: 750 });
  await faalt(rpc(baas, 'kaart_verwijderen', { p_kaart_id: info.id, p_saldo_cent: 0 }), 'al verwijderd');
  // Weg uit de lijst, niet meer te scannen, niet meer te betalen of op te waarderen.
  const { data: lijst } = await bar.from('kaarten').select('id').is('verwijderd_ts', null);
  assert.ok(!lijst.some((x) => x.id === info.id));
  await faalt(rpc(bar, 'kaart_info', { p_zoek: k.code }), 'verwijderd');
  await faalt(rpc(bar, 'afrekenen', { p_regels: [{ product_id: product('Koffie').id, aantal: 1 }], p_betalingen: [{ methode: 'kaart', kaart: k.code }] }), 'verwijderd');
  await faalt(rpc(bar, 'kaart_opwaarderen', { p_kaart_id: info.id, p_bedrag_cent: 500, p_methode: 'contant' }), 'verwijderd');
  // Het vervallen tegoed staat in het rapport en de geschiedenis; de kas telt het niet.
  const r = await rpc(baas, 'rapport', { p_van: new Date(Date.now() - 3600e3).toISOString(), p_tot: new Date(Date.now() + 3600e3).toISOString() });
  assert.equal(r.vervallen_cent, 750);
  const h = await rpc(baas, 'kaart_historie', { p_kaart_id: info.id });
  assert.deepEqual(h.map((x) => [x.soort, x.bedrag_cent]), [['vervallen', -750], ['opwaardering', 750]]);
  assert.equal((await rpc(bar, 'dienst_overzicht')).verwacht_cent, 750);
  const { data: log } = await baas.from('logboek').select('actie,details').eq('actie', 'kaart_verwijderen');
  assert.equal(log.at(-1).details.vervallen_cent, 750);
  // Opruimen: net gebruikte kaarten blijven staan, en alleen een beheerder mag het.
  await faalt(rpc(bar, 'kaarten_opruimen'), 'beheerder');
  const o = await rpc(baas, 'kaarten_opruimen_overzicht');
  assert.deepEqual([o.leeg, o.met_tegoed], [0, []]);
  assert.equal(await rpc(baas, 'kaarten_opruimen'), 0);
  // Het nummer komt niet opnieuw voor.
  const [n] = await rpc(baas, 'kaarten_maken', { p_aantal: 1 });
  assert.ok(n.nummer > k.nummer);
  await rpc(bar, 'dienst_sluiten', { p_geteld_cent: 750 });
});

test('gratis weggeven: voorraad omlaag, kas klopt, reden in rapport en logboek', async () => {
  await rpc(bar, 'dienst_openen', { p_beginsaldo_cent: 1000 });
  const voor = (await bar.from('producten').select('voorraad').eq('id', product('Bier').id).single()).data.voorraad;
  const bier = [{ product_id: product('Bier').id, aantal: 2 }];
  await faalt(rpc(bar, 'afrekenen', { p_regels: bier, p_betalingen: [{ methode: 'gratis' }] }), 'waarom');
  const bon = await rpc(bar, 'afrekenen', { p_regels: bier, p_betalingen: [{ methode: 'gratis', reden: 'Bardienst' }] });
  assert.deepEqual(bon.betalingen.map((b) => [b.methode, b.bedrag_cent, b.reden]), [['gratis', 400, 'Bardienst']]);
  assert.equal((await bar.from('producten').select('voorraad').eq('id', product('Bier').id).single()).data.voorraad, voor - 2);
  const d = await rpc(bar, 'dienst_overzicht');
  assert.deepEqual([d.verwacht_cent, d.gratis_cent], [1000, 400]);
  const r = await rpc(baas, 'rapport', { p_van: new Date(Date.now() - 3600e3).toISOString(), p_tot: new Date(Date.now() + 3600e3).toISOString() });
  assert.deepEqual([r.gratis_cent, r.gratis_per_reden], [400, [{ reden: 'Bardienst', aantal: 1, bedrag_cent: 400 }]]);
  const { data: log } = await baas.from('logboek').select('actie,door_naam,details').eq('actie', 'gratis');
  assert.deepEqual([log.at(-1).door_naam, log.at(-1).details.reden, log.at(-1).details.bedrag_cent], ['Bar', 'Bardienst', 400]);
  // Uit te zetten door de beheerder.
  const zet = (m) => rpc(baas, 'betaalmethoden_opslaan', { p_contant: true, p_pin: true, p_kaart: true, p_rekening: true, p_lat: true, ...m });
  await zet({ p_gratis: false });
  await faalt(rpc(bar, 'afrekenen', { p_regels: bier, p_betalingen: [{ methode: 'gratis', reden: 'Sponsor' }] }), 'Gratis weggeven staat uit');
  await zet({});
  await rpc(bar, 'dienst_sluiten', { p_geteld_cent: 1000 });
});

test('uitgaven: uit de kas of voorgeschoten; kas en wisselgeld-voorstel kloppen', async () => {
  await faalt(rpc(gast, 'uitgave_registreren', { p_omschrijving: 'Boodschappen', p_bedrag_cent: 100 }));
  // Kassa dicht: boodschappen uit de kas. Het voorstel bij openen = vorige telling min de uitgave.
  const vorig = (await rpc(bar, 'wisselgeld_voorstel')).geteld_cent;
  await rpc(bar, 'uitgave_registreren', { p_omschrijving: 'Boodschappen', p_bedrag_cent: 2500 });
  assert.deepEqual(await rpc(bar, 'wisselgeld_voorstel'), { geteld_cent: vorig, uitgaven_cent: 2500, voorstel_cent: Math.max(0, vorig - 2500) });
  // Iemand schiet voor: staat open, telt niet in de kas.
  const v = await rpc(bar, 'uitgave_registreren', { p_omschrijving: 'Boodschappen', p_bedrag_cent: 4500, p_voorgeschoten_door: 'Jan' });
  assert.equal((await rpc(bar, 'wisselgeld_voorstel')).uitgaven_cent, 2500);
  await faalt(rpc(bar, 'uitgave_registreren', { p_omschrijving: ' ', p_bedrag_cent: 100 }), 'waarvoor');
  // Kassa open: terugbetalen uit de kas gaat af van wat er in de la hoort.
  await rpc(bar, 'dienst_openen', { p_beginsaldo_cent: 10000 });
  await faalt(rpc(bar, 'uitgave_terugbetalen', { p_id: v, p_hoe: 'overboeking' }), 'beheerder');
  await rpc(bar, 'uitgave_terugbetalen', { p_id: v, p_hoe: 'kas' });
  await faalt(rpc(bar, 'uitgave_terugbetalen', { p_id: v, p_hoe: 'kas' }), 'al terugbetaald');
  await rpc(bar, 'uitgave_registreren', { p_omschrijving: 'IJs', p_bedrag_cent: 1000 });
  let d = await rpc(bar, 'dienst_overzicht');
  assert.deepEqual([d.uitgaven_cent, d.verwacht_cent], [5500, 10000 - 5500]);
  // Verkeerd geregistreerd: alleen de beheerder haalt het weg; de kas telt het dan niet meer.
  const { data: lijst } = await bar.from('uitgaven').select('id,omschrijving').is('verwijderd_ts', null).order('id');
  const ijs = lijst.find((x) => x.omschrijving === 'IJs');
  await faalt(rpc(bar, 'uitgave_verwijderen', { p_id: ijs.id }), 'beheerder');
  await rpc(baas, 'uitgave_verwijderen', { p_id: ijs.id });
  d = await rpc(bar, 'dienst_overzicht');
  assert.equal(d.verwacht_cent, 10000 - 4500);
  const r = await rpc(baas, 'rapport', { p_van: new Date(Date.now() - 3600e3).toISOString(), p_tot: new Date(Date.now() + 3600e3).toISOString() });
  assert.deepEqual([r.uitgaven_cent, r.uitgaven_per_reden, r.voorgeschoten_open_cent], [7000, [{ reden: 'Boodschappen', aantal: 2, bedrag_cent: 7000 }], 0]);
  const { data: log } = await baas.from('logboek').select('actie').in('actie', ['uitgave', 'uitgave_terugbetaald', 'uitgave_verwijderen']);
  assert.equal(log.length, 5);
  await rpc(bar, 'dienst_sluiten', { p_geteld_cent: 5500 });
});

test('loterij: loten per avond of per € 10, uitsluiten, prijs als tegoed buiten de kas; recap', async () => {
  const [a, b, c] = await rpc(baas, 'kaarten_maken', { p_aantal: 3 });
  await rpc(bar, 'dienst_openen', { p_beginsaldo_cent: 0 });
  const info = (k) => rpc(bar, 'kaart_info', { p_zoek: String(k.nummer) });
  for (const k of [a, b]) await rpc(bar, 'kaart_opwaarderen', { p_kaart_id: (await info(k)).id, p_bedrag_cent: 2500, p_methode: 'contant' });
  const koffie = (k) => rpc(bar, 'afrekenen', { p_regels: [{ product_id: product('Koffie').id, aantal: 1 }], p_betalingen: [{ methode: 'kaart', kaart: k.code }] });
  await koffie(a); await koffie(a); await koffie(b);

  // De baravond van nu (loopt tot 06:00), in Nederlandse tijd.
  const vandaag = new Date(Date.now() - 6 * 3600e3).toLocaleDateString('sv-SE', { timeZone: 'Europe/Amsterdam' });
  const args = { p_van: vandaag, p_tot: vandaag, p_manier: 'dagen', p_max: 10 };
  const nrs = [a, b, c].map((k) => k.nummer);
  const mijn = (v) => v.lijst.filter((x) => nrs.includes(x.nummer)).map((x) => [x.nummer, x.loten]).sort();
  await faalt(rpc(bar, 'loterij_voorbeeld', args), 'beheerder');
  // Twee keer betaald op dezelfde avond = 1 lot; nooit betaald = niet mee.
  assert.deepEqual(mijn(await rpc(baas, 'loterij_voorbeeld', args)), [[a.nummer, 1], [b.nummer, 1]].sort());
  // Per € 10 opgewaardeerd: € 25 = 2 loten, met een maximum.
  assert.deepEqual(mijn(await rpc(baas, 'loterij_voorbeeld', { ...args, p_manier: 'opwaarderen' })), [[a.nummer, 2], [b.nummer, 2]].sort());
  assert.deepEqual(mijn(await rpc(baas, 'loterij_voorbeeld', { ...args, p_manier: 'opwaarderen', p_max: 1 })), [[a.nummer, 1], [b.nummer, 1]].sort());
  await faalt(rpc(baas, 'loterij_voorbeeld', { ...args, p_max: 0 }), 'maximum');

  // Alle andere kaarten uitgesloten: alleen a doet mee, dus a wint. De prijs komt als tegoed op de kaart, niet in de kas.
  const v = await rpc(baas, 'loterij_voorbeeld', args);
  const anderen = v.lijst.map((x) => x.nummer).filter((n) => n !== a.nummer);
  const saldo = (await info(a)).saldo_cent;
  const verwacht = (await rpc(bar, 'dienst_overzicht')).verwacht_cent;
  await faalt(rpc(bar, 'loterij_trekken', { ...args, p_uitgesloten: anderen }), 'beheerder');
  const u = await rpc(baas, 'loterij_trekken', { ...args, p_uitgesloten: anderen, p_prijs_cent: 500, p_omschrijving: 'Gratis rondje' });
  assert.deepEqual([u.nummer, u.loten, u.totaal, u.deelnemers, u.prijs_cent], [a.nummer, 1, 1, 1, 500]);
  assert.equal((await info(a)).saldo_cent, saldo + 500);
  assert.equal((await rpc(bar, 'dienst_overzicht')).verwacht_cent, verwacht);
  const { data: log } = await baas.from('logboek').select('details').eq('actie', 'loterij');
  assert.equal(log.at(-1).details.kaart, a.nummer);
  // Een trekking is achteraf niet te veranderen, en medewerkers zien ze niet.
  const { error } = await baas.from('loterij_trekkingen').update({ prijs_cent: 1 }).gt('id', 0);
  assert.ok(error);
  assert.deepEqual((await bar.from('loterij_trekkingen').select('id')).data, []);
  await faalt(rpc(baas, 'loterij_trekken', { ...args, p_van: '2020-01-01', p_tot: '2020-01-31' }), 'geen kaarten');

  // Recap van vandaag: de koffie staat erin; alleen voor de beheerder.
  await faalt(rpc(bar, 'recap', { p_van: vandaag, p_tot: vandaag }), 'beheerder');
  const r = await rpc(baas, 'recap', { p_van: vandaag, p_tot: vandaag });
  assert.ok(r.bonnen >= 3 && r.top.some((t) => t.naam === 'Koffie'));
  assert.ok(r.kaarten_gebruikt >= 2 && r.opgewaardeerd_cent >= 5000);
  await rpc(bar, 'dienst_sluiten', { p_geteld_cent: verwacht });
});

test('boekhouding: alles van een periode, sluitend; alleen voor de beheerder', async () => {
  const vandaag = new Date().toLocaleDateString('sv-SE', { timeZone: 'Europe/Amsterdam' });
  await faalt(rpc(bar, 'boekhouding', { p_van: vandaag, p_tot: vandaag }), 'beheerder');
  await faalt(rpc(baas, 'boekhouding', { p_van: vandaag, p_tot: '2020-01-01' }), 'periode');
  const jaarGeleden = new Date(Date.now() - 365 * 86400e3).toLocaleDateString('sv-SE', { timeZone: 'Europe/Amsterdam' });
  await faalt(rpc(baas, 'boekhouding', { p_van: '2020-01-01', p_tot: vandaag }), 'twee jaar');
  const d = await rpc(baas, 'boekhouding', { p_van: jaarGeleden, p_tot: vandaag });
  const { count } = await baas.from('verkopen').select('*', { count: 'exact', head: true });
  assert.equal(d.bonnen.length, count);
  // Elke bon: betalingen = totaal, regels = totaal.
  for (const b of d.bonnen) {
    assert.equal(b.contant + b.pin + b.kaart + b.lat + b.gratis, b.totaal, `bon ${b.bon}`);
    const r = d.regels.filter((x) => x.bon === b.bon).reduce((a, x) => a + x.prijs * x.aantal, 0);
    assert.equal(r, b.totaal, `regels bon ${b.bon}`);
  }
  // Kaarttegoed: begin + alle mutaties = eind = wat er nu op de kaarten staat.
  assert.equal(d.kaart_begin + d.kaart.reduce((a, x) => a + x.bedrag, 0), d.kaart_eind);
  const { data: kaarten } = await baas.from('kaarten').select('saldo_cent');
  assert.equal(d.kaart_eind, kaarten.reduce((a, k) => a + k.saldo_cent, 0));
  assert.ok(d.diensten.length > 0 && d.uitgaven.length > 0);
});

test('btw: standaard uit; aan = tarief per product, vastgelegd op de bon, per tarief in het rapport', async () => {
  await rpc(bar, 'dienst_openen', { p_beginsaldo_cent: 0 });
  const bier = product('Bier'), fris = product('Frisdrank');
  const bestel = [{ product_id: bier.id, aantal: 1 }, { product_id: fris.id, aantal: 2 }];
  const contant = [{ methode: 'contant', bedrag_cent: 500, gegeven_cent: 500 }];
  // Uit: geen btw op de bon, niets vastgelegd.
  let bon = await rpc(bar, 'afrekenen', { p_regels: bestel, p_betalingen: contant });
  assert.equal(bon.btw_aan, false);
  const { data: oud } = await baas.from('verkoop_regels').select('btw_pct').eq('verkoop_id', bon.id);
  assert.deepEqual(oud.map((r) => r.btw_pct), [null, null]);
  // Alleen de beheerder zet hem aan en kiest tarieven.
  await faalt(rpc(bar, 'btw_instellen', { p_aan: true, p_nummer: null }), 'beheerder');
  await rpc(baas, 'btw_instellen', { p_aan: true, p_nummer: ' NL001234567B01 ' });
  await faalt(rpc(baas, 'btw_tarief', { p_pct: 15, p_id: fris.id }), '21, 9 of 0');
  assert.ok(await rpc(baas, 'btw_tarief', { p_pct: 21, p_categorie: 'Drinken' }) >= 2);
  assert.equal(await rpc(baas, 'btw_tarief', { p_pct: 9, p_id: fris.id }), 1);
  const uur = { p_van: new Date(Date.now() - 3600e3).toISOString(), p_tot: new Date(Date.now() + 3600e3).toISOString() };
  const bruto = (o, pct) => o.find((x) => x.pct === pct)?.bruto_cent ?? 0;
  const voor = await rpc(baas, 'btw_overzicht', uur);
  bon = await rpc(bar, 'afrekenen', { p_regels: bestel, p_betalingen: contant });
  assert.deepEqual([bon.btw_aan, bon.btw_nummer, bon.regels.map((r) => r.btw_pct)], [true, 'NL001234567B01', [21, 9]]);
  // Gratis weggegeven telt niet mee voor de btw.
  await rpc(bar, 'afrekenen', { p_regels: [{ product_id: bier.id, aantal: 1 }], p_betalingen: [{ methode: 'gratis', reden: 'Bardienst' }] });
  const na = await rpc(baas, 'btw_overzicht', uur);
  assert.deepEqual([bruto(na, 21) - bruto(voor, 21), bruto(na, 9) - bruto(voor, 9)], [200, 300]);
  for (const x of na) assert.equal(x.btw_cent, Math.round((x.bruto_cent * x.pct) / (100 + x.pct)));
  // Tarief later anders: de bon houdt het tarief van het moment van verkopen.
  await rpc(baas, 'btw_tarief', { p_pct: 21, p_id: fris.id });
  assert.deepEqual((await rpc(bar, 'bon', { p_verkoop_id: bon.id })).regels.map((r) => r.btw_pct), [21, 9]);
  const vandaag = new Date().toLocaleDateString('sv-SE', { timeZone: 'Europe/Amsterdam' });
  const d = await rpc(baas, 'boekhouding', { p_van: vandaag, p_tot: vandaag });
  assert.equal(d.btw_aan, true);
  assert.deepEqual(d.regels.filter((r) => r.bon === bon.bonnummer).map((r) => r.btw), [21, 9]);
  await faalt(rpc(bar, 'btw_overzicht', uur), 'beheerder');
  await rpc(baas, 'btw_instellen', { p_aan: false, p_nummer: null });
  await rpc(bar, 'dienst_sluiten', { p_geteld_cent: (await rpc(bar, 'dienst_overzicht')).verwacht_cent });
});

test('bon via QR-code: alleen met de geheime code, zonder inloggen', async () => {
  await rpc(bar, 'dienst_openen', { p_beginsaldo_cent: 0 });
  const bon = await rpc(bar, 'afrekenen', { p_regels: [{ product_id: product('Koffie').id, aantal: 2 }], p_betalingen: [{ methode: 'pin', bedrag_cent: 200 }] });
  assert.match(bon.deel_code, /^[0-9a-f]{24}$/);
  // Een andere telefoon dan die bij de saldo-test geblokkeerd is.
  const anon = createClient(URL, KEY, { auth: { persistSession: false, autoRefreshToken: false }, global: { headers: { 'x-forwarded-for': '10.1.2.3' } } });
  const b = await rpc(anon, 'bon_bekijken', { p_code: bon.deel_code });
  assert.deepEqual([b.bonnummer, b.totaal_cent, b.regels.map((r) => r.naam), b.id, b.deel_code], [bon.bonnummer, 200, ['Koffie'], undefined, undefined]);
  assert.match((await rpc(anon, 'bon_bekijken', { p_code: 'f'.repeat(24) })).fout, /niet gevonden/);
  assert.match((await rpc(anon, 'bon_bekijken', { p_code: '1234' })).fout, /klopt niet/);
  // Twee bonnen, twee verschillende codes.
  const bon2 = await rpc(bar, 'afrekenen', { p_regels: [{ product_id: product('Koffie').id, aantal: 1 }], p_betalingen: [{ methode: 'pin', bedrag_cent: 100 }] });
  assert.notEqual(bon2.deel_code, bon.deel_code);
  await rpc(bar, 'dienst_sluiten', { p_geteld_cent: (await rpc(bar, 'dienst_overzicht')).verwacht_cent });
});

test('indeling: subcategorie, volgorde door slepen, nieuw product achteraan, categorievolgorde', async () => {
  const id = await rpc(baas, 'product_opslaan', { p: { naam: 'Cola', prijs_cent: 250, categorie: 'Drinken', subcategorie: ' Frisdrank ', voorraad: 5 } });
  const lees = async () => (await baas.from('producten').select('id,naam,subcategorie,volgorde').eq('categorie', 'Drinken').eq('verwijderd', false).order('volgorde')).data;
  let d = await lees();
  assert.equal(d.at(-1).id, id, 'nieuw product achteraan');
  assert.equal(d.at(-1).subcategorie, 'Frisdrank');
  // Slepen: Cola vooraan.
  await faalt(rpc(bar, 'producten_volgorde', { p_ids: [id] }), 'beheerder');
  await rpc(baas, 'producten_volgorde', { p_ids: [id, ...d.filter((x) => x.id !== id).map((x) => x.id)] });
  d = await lees();
  assert.deepEqual([d[0].id, d[0].volgorde, d[1].volgorde], [id, 10, 20]);
  // Opslaan zonder subcategorie laat hem staan; leeg maakt hem weg.
  await rpc(baas, 'product_opslaan', { p: { id, naam: 'Cola', prijs_cent: 260, categorie: 'Drinken' } });
  assert.equal((await lees()).find((x) => x.id === id).subcategorie, 'Frisdrank');
  await rpc(baas, 'product_opslaan', { p: { id, naam: 'Cola', prijs_cent: 260, categorie: 'Drinken', subcategorie: '' } });
  assert.equal((await lees()).find((x) => x.id === id).subcategorie, null);
  await rpc(baas, 'categorie_volgorde_opslaan', { p_namen: ['Snacks', 'Drinken'] });
  const { data: inst } = await bar.from('instellingen').select('categorie_volgorde').single();
  assert.deepEqual(inst.categorie_volgorde, ['Snacks', 'Drinken']);
  await rpc(baas, 'product_verwijderen', { p_id: id });
});

// Als laatste: maakt alles leeg.
test('kassa leegmaken: alleen de beheerder, met LEEGMAKEN; logboek en accounts blijven', async () => {
  await faalt(rpc(bar, 'kassa_leegmaken', { p_bevestiging: 'LEEGMAKEN' }), 'beheerder');
  await faalt(rpc(baas, 'kassa_leegmaken', { p_bevestiging: 'leeg' }), 'LEEGMAKEN');
  await rpc(baas, 'thema_opslaan', { p_thema: 'kroeg' });
  const r = await rpc(baas, 'kassa_leegmaken', { p_bevestiging: 'LEEGMAKEN', p_medewerkers: true, p_instellingen: true });
  assert.ok(r.bonnen > 0 && r.producten > 0 && r.kaarten > 0);
  for (const t of ['producten', 'kaarten', 'verkopen', 'diensten', 'leden', 'rekeningen', 'uitgaven', 'kaart_mutaties']) {
    const { count, error } = await baas.from(t).select('id', { count: 'exact', head: true });
    assert.equal(error, null, t);
    assert.equal(count, 0, t);
  }
  const { data: inst } = await baas.from('instellingen').select('naam,thema').single();
  assert.deepEqual(inst, { naam: 'Bar', thema: 'licht' });
  // De beheerder blijft, de anderen staan uit en kunnen niets meer.
  const { data: ik } = await baas.from('profielen').select('actief').eq('naam', 'Baas').single();
  assert.equal(ik.actief, true);
  await faalt(rpc(bar, 'dienst_openen', { p_beginsaldo_cent: 0 }));
  const { data: log } = await baas.from('logboek').select('actie,details').eq('actie', 'kassa_leegmaken');
  assert.equal(log.at(-1).details.bonnen, r.bonnen);
  // Opnieuw beginnen: bon 1 en kaart 1.
  await rpc(baas, 'dienst_openen', { p_beginsaldo_cent: 0 });
  const id = await rpc(baas, 'product_opslaan', { p: { naam: 'Bier', prijs_cent: 250, categorie: 'Drinken', voorraad: 10 } });
  const bon = await rpc(baas, 'afrekenen', { p_regels: [{ product_id: id, aantal: 1 }], p_betalingen: [{ methode: 'pin', bedrag_cent: 250 }] });
  assert.equal(bon.bonnummer, 1);
  assert.equal((await rpc(baas, 'kaarten_maken', { p_aantal: 1 }))[0].nummer, 1);
});
