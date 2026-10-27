-- Voorbeeldgegevens voor de proefversie: drie accounts, twee weken verkopen,
-- tegoedkaarten, een open kassa en twee open rekeningen.
-- Alles gaat via dezelfde functies als in de echte kassa; daarna worden de
-- tijdstippen naar de afgelopen dagen verschoven.

insert into auth.users (email, encrypted_password, raw_user_meta_data) values
  ('demo@kassa.lokaal', extensions.crypt('proef1234', extensions.gen_salt('bf', 4)), '{"naam": "Demo"}'),
  ('anna@kassa.lokaal', extensions.crypt('proef1234', extensions.gen_salt('bf', 4)), '{"naam": "Anna"}'),
  ('kees@kassa.lokaal', extensions.crypt('proef1234', extensions.gen_salt('bf', 4)), '{"naam": "Kees"}');
update public.profielen set rol = 'medewerker' where naam = 'Anna';
update public.instellingen set naam = 'Café De Proef';
-- Ruim voorraad voor twee weken verkopen; onderaan komt de echte stand.
update public.producten set voorraad = 1000;

do $$
declare
  demo uuid := (select id from auth.users where email = 'demo@kassa.lokaal');
  anna uuid := (select id from auth.users where email = 'anna@kassa.lokaal');
  -- Kansverdeling over de producten: vooral bier.
  keuze text[] := array['Bier','Bier','Bier','Bier','Bier','Frisdrank','Frisdrank','Wijn','Wijn','Koffie','Chips','Chips','Tosti kaas','Tosti ham-kaas','Bapao'];
  dag date;
  open_ts timestamptz;
  d bigint;
  v jsonb;
  regels jsonb;
  totaal int;
  wie uuid;
  log_id bigint;
  kaart text;
  n int;
begin
  perform set_config('request.jwt.claim.sub', demo::text, true);
  -- Eerst de kaarten, los van welke dagen de bar open was.
  perform public.kaarten_maken(20);
  -- Vaste codes voor de voorbeeldkaarten 1 t/m 20: zo werken geprinte proefkaarten op elk
  -- apparaat en ook na Wissen (de database van de proefversie staat per browser).
  update public.kaarten k set code = (array['KDJN-N4GQ', 'BB94-4CF5', 'Q9PS-2MN9', 'W4JS-ZWFA', 'HPTV-NTFV', 'K2WZ-G22W', 'Y5UK-CR2X', 'VNDD-QB8J', 'JRVN-TQ7F', 'WX23-3XH3', 'YU9A-EHQ7', 'Y8CL-UDXJ', 'QERQ-P7UJ', '2YNC-SJX4', 'LQAP-WZFM', '48AK-HY3G', 'AWJT-LRM7', 'LZDS-UM9M', 'K2JL-K3LM', 'F26V-GBHW'])[k.nummer] where k.nummer between 1 and 20;
  -- Leden voor de streeplijst.
  perform public.lid_opslaan(null, x) from unnest(array['Bram', 'Daan', 'Eva', 'Fatima', 'Henk', 'Iris', 'Joost', 'Lotte', 'Mark', 'Noor', 'Sander', 'Yara']) x;
  for i in reverse 14..0 loop
    -- proef.vandaag: alleen voor de test, die alle weekdagen nabootst.
    dag := coalesce(nullif(current_setting('proef.vandaag', true), '')::date, (now() at time zone 'Europe/Amsterdam')::date) - i;
    -- Maandag en dinsdag dicht.
    continue when i > 0 and extract(isodow from dag) in (1, 2);
    log_id := coalesce((select max(id) from public.logboek), 0);
    wie := case when random() < 0.5 then demo else anna end;
    perform set_config('request.jwt.claim.sub', wie::text, true);
    d := public.dienst_openen(10000);
    -- Kaarten opwaarderen.
    for k in 1..(1 + floor(random() * 3))::int loop
      perform public.kaart_opwaarderen((select id from public.kaarten order by random() limit 1),
        (array[1000, 2000, 2500])[1 + floor(random() * 3)::int], case when random() < 0.6 then 'contant' else 'pin' end);
    end loop;
    n := case when extract(isodow from dag) in (5, 6) then 30 else 14 end + floor(random() * 10)::int;
    if i = 0 then n := 9; end if;
    for j in 1..n loop
      select jsonb_agg(jsonb_build_object('product_id', p.id, 'aantal', 1 + floor(random() * 2.4)::int)), sum(p.prijs_cent)
        into regels from (select distinct keuze[1 + floor(random() * array_length(keuze, 1))::int] as naam
                          from generate_series(1, 1 + floor(random() * 3)::int)) x
        join public.producten p on p.naam = x.naam;
      kaart := case when random() < 0.2 then
        (select code from public.kaarten where saldo_cent > 0 and not geblokkeerd order by random() limit 1) end;
      v := public.afrekenen(regels,
        case
          when kaart is not null then jsonb_build_array(jsonb_build_object('methode', 'kaart', 'kaart', kaart), jsonb_build_object('methode', 'contant'))
          when random() < 0.25 then jsonb_build_array(jsonb_build_object('methode', 'lat', 'lid', (select id from public.leden order by random() limit 1)))
          when random() < 0.55 then jsonb_build_array(jsonb_build_object('methode', 'contant', 'gegeven_cent', 5000))
          else jsonb_build_array(jsonb_build_object('methode', 'pin'))
        end, null);
    end loop;
    -- Een drankje voor de bardienst, af en toe voor een sponsor of iets kapot.
    if random() < 0.6 then
      perform public.afrekenen(jsonb_build_array(jsonb_build_object('product_id', (select id from public.producten where naam = 'Bier'), 'aantal', 2)),
        jsonb_build_array(jsonb_build_object('methode', 'gratis',
          'reden', (array['Bardienst', 'Bardienst', 'Bardienst', 'Sponsor', 'Kapot of weggegooid'])[1 + floor(random() * 5)::int])), null);
    end if;
    -- Af en toe betaalt een lid de streeplijst contant af.
    if random() < 0.4 then
      perform public.lat_afbetalen(l.id, public._lid_open(l.id), 'contant')
      from (select id from public.leden where public._lid_open(id) > 0 order by random() limit 1) l;
    end if;
    if i = 0 then
      -- Vandaag: kassa blijft open; verkopen in het afgelopen uur.
      update public.verkopen set ts = now() - random() * interval '60 minutes' where dienst_id = d;
      update public.diensten set geopend_ts = now() - interval '75 minutes' where id = d;
    else
      perform public.dienst_sluiten((public.dienst_overzicht() ->> 'verwacht_cent')::int
        + (array[0, 0, 0, -50, 100, -200])[1 + floor(random() * 6)::int]);
      open_ts := (dag + time '19:00') at time zone 'Europe/Amsterdam';
      update public.diensten set geopend_ts = open_ts, gesloten_ts = open_ts + interval '5 hours 10 minutes' where id = d;
      update public.verkopen set ts = open_ts + random() * interval '5 hours' where dienst_id = d;
      update public.kaart_mutaties set ts = open_ts + random() * interval '5 hours' where dienst_id = d;
      update public.lat_betalingen set ts = open_ts + random() * interval '5 hours' where dienst_id = d;
      update public.logboek set ts = open_ts + interval '5 hours 10 minutes' where id > log_id;
    end if;
    update public.voorraad_mutaties m set ts = v.ts from public.verkopen v where v.id = m.verkoop_id and v.dienst_id = d;
  end loop;

  -- Twee open rekeningen.
  perform public.rekening_toevoegen(public.rekening_maken('Piet'),
    (select jsonb_agg(jsonb_build_object('product_id', id, 'aantal', 2)) from public.producten where naam in ('Bier', 'Chips')));
  perform public.rekening_toevoegen(public.rekening_maken('Tafel 4'),
    (select jsonb_agg(jsonb_build_object('product_id', id, 'aantal', a)) from
      (select id, case naam when 'Wijn' then 3 else 1 end as a from public.producten where naam in ('Wijn', 'Tosti ham-kaas', 'Koffie')) x));
  update public.rekening_regels set ts = now() - random() * interval '45 minutes';
  update public.rekeningen set aangemaakt = now() - interval '50 minutes';

  -- Een kaart die kwijt is.
  update public.kaarten set geblokkeerd = true where nummer = 13;
  -- Een paar kaarten op naam.
  update public.kaarten k set naam = v.naam
  from (values (1, 'Piet de Vries'), (3, 'Fam. Jansen'), (5, 'Voetbal JO11'), (11, 'Sandra'), (12, 'Kees Bakker'), (13, 'Ruud')) as v(nummer, naam)
  where k.nummer = v.nummer;

  -- Boodschappen: een keer uit de kas, een keer voorgeschoten (nog terug te betalen).
  insert into public.uitgaven (ts, omschrijving, bedrag_cent, door, door_naam) values
    (now() - interval '6 days', 'Boodschappen', 6840, demo, 'Demo');
  insert into public.uitgaven (ts, omschrijving, bedrag_cent, voorgeschoten_door, door, door_naam) values
    (now() - interval '2 days', 'Chips en frisdrank', 2395, 'Henk', anna, 'Anna');

  -- Kaarten van vorig seizoen die al ruim een jaar niet zijn gebruikt (om op te ruimen).
  insert into public.kaarten (code, aangemaakt, naam)
  select public._kaartcode(), now() - interval '15 months', null from generate_series(1, 7);
  update public.kaarten set naam = 'Oud lid' where nummer = (select max(nummer) from public.kaarten);
  update public.kaarten set saldo_cent = 450 where nummer = (select max(nummer) from public.kaarten);
  insert into public.kaart_mutaties (kaart_id, bedrag_cent, soort, methode, ts)
  select id, 450, 'opwaardering', 'contant', now() - interval '14 months' from public.kaarten where nummer = (select max(nummer) from public.kaarten);
  update public.kaarten set laatst_gebruikt = now() - interval '14 months' where aangemaakt < now() - interval '1 year';
end $$;

-- Voorraad op een geloofwaardige stand; frisdrank bijna op, bapao op.
update public.producten p set voorraad = v.voorraad, voorraad_min = v.min
from (values ('Bier', 41, 24), ('Frisdrank', 8, 12), ('Wijn', 17, 6), ('Koffie', 140, 30),
             ('Chips', 23, 10), ('Tosti kaas', 12, 5), ('Tosti ham-kaas', 9, 5), ('Bapao', 0, 4)) as v(naam, voorraad, min)
where p.naam = v.naam;
