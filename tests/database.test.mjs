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
  const zet = (m) => rpc(baas, 'betaalmethoden_opslaan', { p_contant: true, p_pin: true, p_kaart: true, p_rekening: true, ...m });
  await faalt(rpc(bar, 'betaalmethoden_opslaan', { p_contant: true, p_pin: false, p_kaart: true, p_rekening: true }), 'beheerder');
  await faalt(zet({ p_contant: false, p_pin: false, p_kaart: false }), 'minstens één');
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
  assert.deepEqual(log.at(-1).details, { contant: true, pin: true, kaart: true, rekening: true });
});

test('kassa sluiten: verwacht = begin + contant verkocht + contant opgewaardeerd', async () => {
  // Contant: 500 (bier+chips) + 800 (rekening Piet) + 100 (koffie hieronder); opwaardering contant 1000.
  const laat = await rpc(bar, 'afrekenen', { p_regels: [{ product_id: product('Koffie').id, aantal: 1 }], p_betalingen: [{ methode: 'contant' }] });
  const d = await rpc(bar, 'dienst_overzicht');
  assert.equal(d.verwacht_cent, 5000 + 500 + 800 + 100 + 1000);
  const dicht = await rpc(bar, 'dienst_sluiten', { p_geteld_cent: 7350, p_opmerking: 'briefje van 50 cent kwijt' });
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
  assert.equal(r.geannuleerd, 3);
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
