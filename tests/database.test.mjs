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

test('geblokkeerde kaart', async () => {
  const info = await rpc(bar, 'kaart_info', { p_zoek: kaart.code });
  await rpc(bar, 'kaart_blokkeren', { p_kaart_id: info.id, p_blok: true });
  await faalt(rpc(bar, 'kaart_opwaarderen', { p_kaart_id: info.id, p_bedrag_cent: 100, p_methode: 'pin' }), 'geblokkeerd');
  await faalt(rpc(bar, 'kaart_blokkeren', { p_kaart_id: info.id, p_blok: false }), 'beheerder');
  await rpc(baas, 'kaart_blokkeren', { p_kaart_id: info.id, p_blok: false });
});

test('voorraad: levering, verkoop, rekening, annuleren', async () => {
  const bier = product('Bier').id;
  assert.equal(await rpc(baas, 'voorraad_boeken', { p_product_id: bier, p_aantal: 24, p_soort: 'levering' }), 24);
  const bon = await rpc(bar, 'afrekenen', { p_regels: [{ product_id: bier, aantal: 2 }], p_betalingen: [{ methode: 'pin' }] });
  const stand = async () => (await bar.from('producten').select('voorraad').eq('id', bier).single()).data.voorraad;
  assert.equal(await stand(), 22);
  await rpc(bar, 'verkoop_annuleren', { p_verkoop_id: bon.id });
  assert.equal(await stand(), 24);
  await faalt(rpc(bar, 'verkoop_annuleren', { p_verkoop_id: bon.id }), 'al geannuleerd');
  assert.equal(await rpc(baas, 'voorraad_boeken', { p_product_id: bier, p_aantal: 20, p_soort: 'telling' }), 20);
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

test('kassa sluiten: verwacht = begin + contant verkocht + contant opgewaardeerd', async () => {
  // Contant: 500 (bier+chips) + 800 (rekening Piet); opwaardering contant 1000.
  const d = await rpc(bar, 'dienst_overzicht');
  assert.equal(d.verwacht_cent, 5000 + 500 + 800 + 1000);
  const dicht = await rpc(bar, 'dienst_sluiten', { p_geteld_cent: 7250, p_opmerking: 'briefje van 50 cent kwijt' });
  assert.equal(dicht.geteld_cent - dicht.verwacht_cent, -50);
  await faalt(rpc(bar, 'afrekenen', { p_regels: [{ product_id: product('Bier').id, aantal: 1 }], p_betalingen: [{ methode: 'pin' }] }), 'Open eerst');
});

test('rapport en logboek alleen voor beheerder', async () => {
  const van = new Date(Date.now() - 3600e3).toISOString(), tot = new Date(Date.now() + 3600e3).toISOString();
  await faalt(rpc(bar, 'rapport', { p_van: van, p_tot: tot }), 'beheerder');
  const r = await rpc(baas, 'rapport', { p_van: van, p_tot: tot });
  assert.equal(r.geannuleerd, 2);
  assert.ok(r.omzet_cent > 0);
  assert.equal(r.diensten.length, 1);
  assert.deepEqual((await bar.from('logboek').select('*')).data, []);
  assert.ok((await baas.from('logboek').select('*')).data.length > 0);
});

test('laatste beheerder kan zichzelf niet degraderen', async () => {
  const { data: { user } } = await baas.auth.getUser();
  await faalt(rpc(baas, 'gebruiker_bijwerken', { p_id: user.id, p_rol: 'medewerker', p_actief: true }), 'minstens één');
});
