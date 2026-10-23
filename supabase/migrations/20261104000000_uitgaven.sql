-- Uitgaven registreren: boodschappen of iets anders dat met geld uit de kas is
-- betaald, of dat iemand heeft voorgeschoten. Werkt ook als de kassa dicht is.
-- Geld uit de kas telt mee: staat de kassa open, dan gaat het af van wat er in
-- de la hoort; is hij dicht, dan houdt het voorstel voor het wisselgeld bij de
-- volgende opening er rekening mee. Voorgeschoten bedragen staan open tot ze
-- zijn terugbetaald (uit de kas, of overgemaakt door de penningmeester).

create table public.uitgaven (
  id                bigint generated always as identity primary key,
  ts                timestamptz not null default now(),
  omschrijving      text not null check (length(trim(omschrijving)) between 1 and 60),
  bedrag_cent       int not null check (bedrag_cent between 1 and 100000),
  voorgeschoten_door text check (voorgeschoten_door is null or length(trim(voorgeschoten_door)) between 1 and 40),
  door              uuid references public.profielen,
  door_naam         text,
  dienst_id         bigint references public.diensten,
  terugbetaald_ts   timestamptz,
  terugbetaald_hoe  text check (terugbetaald_hoe in ('kas', 'overboeking')),
  terug_door_naam   text,
  terug_dienst_id   bigint references public.diensten,
  verwijderd_ts     timestamptz
);
create index on public.uitgaven (ts);
alter table public.uitgaven enable row level security;
create policy lezen on public.uitgaven for select to authenticated using (public.mijn_rol() in ('medewerker', 'beheerder'));
grant select on public.uitgaven to authenticated;
create trigger wijziging after insert or update or delete on public.uitgaven for each statement execute function public._wijziging();

-- Elk bedrag dat uit de kas ging: een uitgave uit de kas, of een voorschot terugbetaald uit de kas.
create function public._kas_uit() returns table (ts timestamptz, bedrag_cent int, dienst_id bigint)
language sql stable security definer set search_path = '' as $$
  select ts, bedrag_cent, dienst_id from public.uitgaven where verwijderd_ts is null and voorgeschoten_door is null
  union all
  select terugbetaald_ts, bedrag_cent, terug_dienst_id from public.uitgaven
  where verwijderd_ts is null and voorgeschoten_door is not null and terugbetaald_hoe = 'kas'
$$;
revoke execute on function public._kas_uit() from public, anon, authenticated;

create function public.uitgave_registreren(p_omschrijving text, p_bedrag_cent int, p_voorgeschoten_door text default null) returns bigint
language plpgsql security definer set search_path = '' as $$
declare v bigint; w text := nullif(trim(coalesce(p_voorgeschoten_door, '')), '');
begin
  perform public._eis('medewerker');
  if length(trim(coalesce(p_omschrijving, ''))) not between 1 and 60 then raise exception 'Vul in waarvoor het was (hoogstens 60 tekens)'; end if;
  if coalesce(p_bedrag_cent, 0) not between 1 and 100000 then raise exception 'Vul een bedrag in tussen € 0,01 en € 1.000'; end if;
  if w is not null and length(w) > 40 then raise exception 'Naam is te lang'; end if;
  insert into public.uitgaven (omschrijving, bedrag_cent, voorgeschoten_door, door, door_naam, dienst_id)
  values (trim(p_omschrijving), p_bedrag_cent, w, auth.uid(), (select naam from public.profielen where id = auth.uid()),
          case when w is null then (select id from public.diensten where gesloten_ts is null) end)
  returning id into v;
  perform public._log('uitgave', jsonb_build_object('omschrijving', trim(p_omschrijving), 'bedrag_cent', p_bedrag_cent, 'voorgeschoten_door', w));
  return v;
end $$;

-- Voorschot terugbetalen: uit de kas (iedere medewerker) of overgemaakt (beheerder).
create function public.uitgave_terugbetalen(p_id bigint, p_hoe text) returns void
language plpgsql security definer set search_path = '' as $$
declare u public.uitgaven;
begin
  perform public._eis(case when p_hoe = 'overboeking' then 'beheerder' else 'medewerker' end);
  if p_hoe not in ('kas', 'overboeking') then raise exception 'Kies hoe er is terugbetaald'; end if;
  select * into u from public.uitgaven where id = p_id for update;
  if not found or u.verwijderd_ts is not null or u.voorgeschoten_door is null then raise exception 'Dit voorschot bestaat niet'; end if;
  if u.terugbetaald_ts is not null then raise exception 'Dit is al terugbetaald'; end if;
  update public.uitgaven set terugbetaald_ts = now(), terugbetaald_hoe = p_hoe,
    terug_door_naam = (select naam from public.profielen where id = auth.uid()),
    terug_dienst_id = case when p_hoe = 'kas' then (select id from public.diensten where gesloten_ts is null) end
  where id = p_id;
  perform public._log('uitgave_terugbetaald', jsonb_build_object('omschrijving', u.omschrijving, 'bedrag_cent', u.bedrag_cent,
    'aan', u.voorgeschoten_door, 'hoe', p_hoe));
end $$;

-- Een verkeerde registratie weghalen (alleen beheerder; blijft in het logboek).
create function public.uitgave_verwijderen(p_id bigint) returns void
language plpgsql security definer set search_path = '' as $$
declare u public.uitgaven;
begin
  perform public._eis('beheerder');
  update public.uitgaven set verwijderd_ts = now() where id = p_id and verwijderd_ts is null returning * into u;
  if u.id is null then raise exception 'Deze uitgave bestaat niet (meer)'; end if;
  perform public._log('uitgave_verwijderen', jsonb_build_object('omschrijving', u.omschrijving, 'bedrag_cent', u.bedrag_cent));
end $$;

-- Voorstel voor het wisselgeld bij openen: de vorige telling min wat er sindsdien uit de kas ging.
create function public.wisselgeld_voorstel() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare d public.diensten; uit int;
begin
  perform public._eis('medewerker');
  select * into d from public.diensten where gesloten_ts is not null and geteld_cent is not null order by gesloten_ts desc limit 1;
  if not found then return null; end if;
  select coalesce(sum(bedrag_cent), 0) into uit from public._kas_uit() k where k.dienst_id is null and k.ts > d.gesloten_ts;
  return jsonb_build_object('geteld_cent', d.geteld_cent, 'uitgaven_cent', uit, 'voorstel_cent', greatest(0, d.geteld_cent - uit));
end $$;

revoke execute on function public.uitgave_registreren(text, int, text), public.uitgave_terugbetalen(bigint, text),
  public.uitgave_verwijderen(bigint), public.wisselgeld_voorstel() from public, anon;
grant execute on function public.uitgave_registreren(text, int, text), public.uitgave_terugbetalen(bigint, text),
  public.uitgave_verwijderen(bigint), public.wisselgeld_voorstel() to authenticated;

-- Kas: uitgaven uit de kas tijdens een open dienst gaan af van wat er in de la hoort.
create or replace function public._dienst_cijfers(p_dienst bigint) returns jsonb
language sql stable security definer set search_path = '' as $$
  with b as (
    select b.methode, sum(b.bedrag_cent) as s from public.betalingen b
    join public.verkopen v on v.id = b.verkoop_id
    where v.dienst_id = p_dienst and not v.geannuleerd group by 1
  ), o as (
    select methode, sum(bedrag_cent) as s from public.kaart_mutaties
    where dienst_id = p_dienst and soort = 'opwaardering' group by 1
  ), a as (
    select methode, sum(bedrag_cent) as s from public.lat_betalingen
    where dienst_id = p_dienst group by 1
  ), u as (
    select coalesce(sum(bedrag_cent), 0) as s from public._kas_uit() where dienst_id = p_dienst
  ), d as (select * from public.diensten where id = p_dienst)
  select jsonb_build_object(
    'id', d.id, 'geopend_ts', d.geopend_ts, 'gesloten_ts', d.gesloten_ts,
    'geopend_door', (select naam from public.profielen where id = d.geopend_door),
    'gesloten_door', (select naam from public.profielen where id = d.gesloten_door),
    'beginsaldo_cent', d.beginsaldo_cent,
    'omzet_cent', (select coalesce(sum(totaal_cent), 0) from public.verkopen where dienst_id = d.id and not geannuleerd),
    'bonnen', (select count(*) from public.verkopen where dienst_id = d.id and not geannuleerd),
    'contant_cent', coalesce((select s from b where methode = 'contant'), 0),
    'pin_cent', coalesce((select s from b where methode = 'pin'), 0),
    'kaart_cent', coalesce((select s from b where methode = 'kaart'), 0),
    'lat_cent', coalesce((select s from b where methode = 'lat'), 0),
    'gratis_cent', coalesce((select s from b where methode = 'gratis'), 0),
    'uitgaven_cent', (select s from u),
    'afbetaald_contant_cent', coalesce((select s from a where methode = 'contant'), 0),
    'afbetaald_pin_cent', coalesce((select s from a where methode = 'pin'), 0),
    'opwaardering_contant_cent', coalesce((select s from o where methode = 'contant'), 0),
    'opwaardering_pin_cent', coalesce((select s from o where methode = 'pin'), 0),
    -- Een gesloten dienst houdt het bedrag van het moment van tellen.
    'verwacht_cent', coalesce(d.verwacht_cent, d.beginsaldo_cent + coalesce((select s from b where methode = 'contant'), 0)
                     + coalesce((select s from o where methode = 'contant'), 0)
                     + coalesce((select s from a where methode = 'contant'), 0)
                     - (select s from u)),
    'geteld_cent', d.geteld_cent, 'opmerking', d.opmerking)
  from d
$$;

-- Rapport: met de uitgaven.
create or replace function public.rapport(p_van timestamptz, p_tot timestamptz) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare res jsonb;
begin
  perform public._eis('beheerder');
  with v as (select * from public.verkopen where ts >= p_van and ts < p_tot),
  ok as (select * from v where not geannuleerd),
  r as (select r.* from public.verkoop_regels r join ok on ok.id = r.verkoop_id),
  b as (select b.* from public.betalingen b join ok on ok.id = b.verkoop_id),
  o as (select * from public.kaart_mutaties where soort = 'opwaardering' and ts >= p_van and ts < p_tot)
  select jsonb_build_object(
    'omzet_cent', (select coalesce(sum(totaal_cent), 0) from ok),
    'bonnen', (select count(*) from ok),
    'geannuleerd', (select count(*) from v where geannuleerd),
    'geannuleerd_cent', (select coalesce(sum(totaal_cent), 0) from v where geannuleerd),
    'per_methode', coalesce((select jsonb_agg(x order by x.bedrag_cent desc) from
        (select methode, sum(bedrag_cent) as bedrag_cent from b group by 1) x), '[]'),
    'per_product', coalesce((select jsonb_agg(x order by x.bedrag_cent desc) from
        (select naam, sum(aantal) as aantal, sum(aantal * prijs_cent) as bedrag_cent from r group by 1) x), '[]'),
    'per_medewerker', coalesce((select jsonb_agg(x order by x.bedrag_cent desc) from
        (select coalesce(door_naam, '?') as naam, count(*) as bonnen, sum(totaal_cent) as bedrag_cent from ok group by 1) x), '[]'),
    'per_dag', coalesce((select jsonb_agg(x order by x.dag) from
        (select ((ts at time zone 'Europe/Amsterdam') - interval '6 hours')::date as dag, count(*) as bonnen, sum(totaal_cent) as bedrag_cent
         from ok group by 1) x), '[]'),
    'per_uur', coalesce((select jsonb_agg(x order by x.uur) from
        (select extract(hour from ts at time zone 'Europe/Amsterdam')::int as uur, count(*) as bonnen, sum(totaal_cent) as bedrag_cent from ok group by 1) x), '[]'),
    'opwaarderingen', coalesce((select jsonb_agg(x) from
        (select methode, count(*) as aantal, sum(bedrag_cent) as bedrag_cent from o group by 1) x), '[]'),
    -- Tegoed dat is vervallen doordat de beheerder een kaart met tegoed verwijderde.
    -- Weggegeven (methode gratis), per reden. Telt mee in de omzet (de waarde van wat over de bar ging).
    'gratis_cent', (select coalesce(sum(bedrag_cent), 0) from b where methode = 'gratis'),
    'gratis_per_reden', coalesce((select jsonb_agg(x order by x.bedrag_cent desc) from
        (select reden, count(*) as aantal, sum(bedrag_cent) as bedrag_cent from b where methode = 'gratis' group by 1) x), '[]'),
    -- Uitgaven (boodschappen e.d.), per omschrijving, en wat er nog terugbetaald moet worden.
    'uitgaven_cent', (select coalesce(sum(bedrag_cent), 0) from public.uitgaven where verwijderd_ts is null and ts >= p_van and ts < p_tot),
    'uitgaven_per_reden', coalesce((select jsonb_agg(x order by x.bedrag_cent desc) from
        (select omschrijving as reden, count(*) as aantal, sum(bedrag_cent) as bedrag_cent from public.uitgaven
         where verwijderd_ts is null and ts >= p_van and ts < p_tot group by 1) x), '[]'),
    'voorgeschoten_open_cent', (select coalesce(sum(bedrag_cent), 0) from public.uitgaven
                                where verwijderd_ts is null and voorgeschoten_door is not null and terugbetaald_ts is null),
    'vervallen_cent', (select coalesce(-sum(bedrag_cent), 0) from public.kaart_mutaties
                       where soort = 'vervallen' and ts >= p_van and ts < p_tot),
    'kaarttegoed_cent', (select coalesce(sum(saldo_cent), 0) from public.kaarten where not geblokkeerd),
    'kaarten_actief', (select count(*) from public.kaarten where saldo_cent > 0 and not geblokkeerd),
    'open_rekeningen_cent', (select coalesce(sum(rr.prijs_cent * rr.aantal), 0) from public.rekening_regels rr
                             join public.rekeningen k on k.id = rr.rekening_id where k.open),
    'diensten', coalesce((select jsonb_agg(public._dienst_cijfers(d.id) order by d.geopend_ts desc)
                          from public.diensten d where d.geopend_ts >= p_van and d.geopend_ts < p_tot), '[]')
  ) into res;
  return res;
end $$;
