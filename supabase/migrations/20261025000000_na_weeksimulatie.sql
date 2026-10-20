-- Verbeteringen na een gesimuleerde week achter de bar.

-- ──────────── 1. Dezelfde bestelling niet twee keer boeken ────────────
-- Valt de wifi weg nadat de bon al op de server is, dan ziet de telefoon een
-- fout terwijl er wél is afgerekend. Tikt de medewerker opnieuw, dan stuurt de
-- app hetzelfde kenmerk (p_sleutel) mee en krijgt hij de eerste bon terug.
create table public.verzoeken (
  sleutel   uuid primary key,
  door      uuid not null,
  resultaat jsonb not null,
  ts        timestamptz not null default now()
);
create index on public.verzoeken (ts);
alter table public.verzoeken enable row level security;  -- alleen via de functies hieronder

-- Al gedaan? Dan het resultaat van toen. Het slot zorgt dat twee gelijktijdige
-- pogingen met hetzelfde kenmerk na elkaar lopen (tot het einde van de transactie).
create function public._al_gedaan(p_sleutel uuid) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
begin
  perform pg_advisory_xact_lock(hashtextextended(p_sleutel::text, 0));
  return (select resultaat from public.verzoeken where sleutel = p_sleutel and door = auth.uid());
end $$;

create function public._gedaan(p_sleutel uuid, p_resultaat jsonb) returns void
language sql security definer set search_path = '' as $$
  delete from public.verzoeken where ts < now() - interval '7 days';
  insert into public.verzoeken (sleutel, door, resultaat) values (p_sleutel, auth.uid(), p_resultaat);
$$;

alter function public.afrekenen(jsonb, jsonb, bigint, int) rename to _afrekenen;
revoke execute on function public._afrekenen(jsonb, jsonb, bigint, int) from public, anon, authenticated;

create function public.afrekenen(p_regels jsonb default '[]', p_betalingen jsonb default '[]', p_rekening_id bigint default null,
                                  p_verwacht_cent int default null, p_sleutel uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare res jsonb;
begin
  perform public._eis('medewerker');
  if p_sleutel is not null then
    res := public._al_gedaan(p_sleutel);
    if res is not null then return res; end if;
  end if;
  res := public._afrekenen(p_regels, p_betalingen, p_rekening_id, p_verwacht_cent);
  if p_sleutel is not null then perform public._gedaan(p_sleutel, res); end if;
  return res;
end $$;
grant execute on function public.afrekenen(jsonb, jsonb, bigint, int, uuid) to authenticated;

alter function public.kaart_opwaarderen(bigint, int, text) rename to _kaart_opwaarderen;
revoke execute on function public._kaart_opwaarderen(bigint, int, text) from public, anon, authenticated;

create function public.kaart_opwaarderen(p_kaart_id bigint, p_bedrag_cent int, p_methode text, p_sleutel uuid default null)
returns int language plpgsql security definer set search_path = '' as $$
declare res jsonb;
begin
  perform public._eis('medewerker');
  if p_sleutel is not null then
    res := public._al_gedaan(p_sleutel);
    if res is not null then return (res ->> 'saldo_cent')::int; end if;
  end if;
  res := jsonb_build_object('saldo_cent', public._kaart_opwaarderen(p_kaart_id, p_bedrag_cent, p_methode));
  if p_sleutel is not null then perform public._gedaan(p_sleutel, res); end if;
  return (res ->> 'saldo_cent')::int;
end $$;
grant execute on function public.kaart_opwaarderen(bigint, int, text, uuid) to authenticated;

-- ──────────── 3. Rapport: een baravond loopt door tot 06:00 ────────────
-- Verkopen na middernacht horen bij de avond ervoor, ook in "per dag".
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
    'kaarttegoed_cent', (select coalesce(sum(saldo_cent), 0) from public.kaarten where not geblokkeerd),
    'kaarten_actief', (select count(*) from public.kaarten where saldo_cent > 0 and not geblokkeerd),
    'open_rekeningen_cent', (select coalesce(sum(rr.prijs_cent * rr.aantal), 0) from public.rekening_regels rr
                             join public.rekeningen k on k.id = rr.rekening_id where k.open),
    'diensten', coalesce((select jsonb_agg(public._dienst_cijfers(d.id) order by d.geopend_ts desc)
                          from public.diensten d where d.geopend_ts >= p_van and d.geopend_ts < p_tot), '[]')
  ) into res;
  return res;
end $$;

-- ──────────── 5. Medewerkers mogen een levering inboeken ────────────
-- Tellen (de voorraad op een getal zetten) blijft voor beheerders. Een levering
-- door een medewerker komt in het logboek.
create or replace function public.voorraad_boeken(p_product_id bigint, p_aantal int, p_soort text) returns int
language plpgsql security definer set search_path = '' as $$
declare p public.producten; d int;
begin
  perform public._eis(case when p_soort = 'levering' then 'medewerker' else 'beheerder' end);
  select * into p from public.producten where id = p_product_id for update;
  if not found then raise exception 'Product niet gevonden'; end if;
  if p_soort = 'levering' then
    if p_aantal not between 1 and 100000 then raise exception 'Ongeldig aantal'; end if;
    d := p_aantal;
  elsif p_soort = 'telling' then
    if p_aantal not between 0 and 100000 then raise exception 'Ongeldig aantal'; end if;
    d := p_aantal - p.voorraad;
  else
    raise exception 'Onbekende soort';
  end if;
  update public.producten set voorraad = voorraad + d, voorraad_bijhouden = true where id = p.id;
  insert into public.voorraad_mutaties (product_id, aantal, reden, door) values (p.id, d, p_soort, auth.uid());
  if p_soort = 'levering' and not public.is_beheerder() then
    perform public._log('levering', jsonb_build_object('product', p.naam, 'aantal', d));
  end if;
  return p.voorraad + d;
end $$;
