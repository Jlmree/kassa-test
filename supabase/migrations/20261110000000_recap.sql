-- Recap: de cijfers van een periode (bijv. het seizoen) in één keer, voor Beheer → Recap.
-- Alleen voor beheerders. Tijden in Nederlandse tijd. Geannuleerde bonnen tellen niet mee;
-- gratis weggegeven telt wel als verkocht, maar niet als omzet.

create function public._recap_kern(p_van timestamptz, p_tot timestamptz) returns jsonb
language sql stable security definer set search_path = '' as $$
  with v as (
    select * from public.verkopen where ts >= p_van and ts < p_tot and not geannuleerd
  )
  select jsonb_build_object(
    'bonnen', (select count(*) from v),
    'omzet_cent', (select coalesce(sum(b.bedrag_cent), 0) from public.betalingen b join v on v.id = b.verkoop_id where b.methode <> 'gratis'),
    'artikelen', (select coalesce(sum(r.aantal), 0) from public.verkoop_regels r join v on v.id = r.verkoop_id)
  )
$$;

create function public.recap(p_van date, p_tot date) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  van timestamptz := (p_van::timestamp) at time zone 'Europe/Amsterdam';
  tot timestamptz := ((p_tot + 1)::timestamp) at time zone 'Europe/Amsterdam';
  res jsonb;
begin
  perform public._eis('beheerder');
  if p_van is null or p_tot is null or p_tot < p_van then raise exception 'Kies een periode'; end if;
  if p_tot - p_van > 800 then raise exception 'Kies een periode van hoogstens twee jaar'; end if;

  with v as (
    select *, ts at time zone 'Europe/Amsterdam' as lt from public.verkopen
    where ts >= van and ts < tot and not geannuleerd
  ),
  r as (select r.* from public.verkoop_regels r join v on v.id = r.verkoop_id),
  d as (select * from public.diensten where geopend_ts >= van and geopend_ts < tot)
  select public._recap_kern(van, tot) || jsonb_build_object(
    'van', p_van, 'tot', p_tot,
    'vorige', public._recap_kern(van - (tot - van), van),
    'eerste_bon', (select min(ts) from v),
    'top', coalesce((select jsonb_agg(x order by aantal desc, naam) from (
      select naam, sum(aantal) as aantal from r group by naam order by sum(aantal) desc, naam limit 5) x), '[]'),
    -- "Bier" in de naam of de categorie: glazen van 0,25 liter.
    'bier', (select coalesce(sum(r.aantal), 0) from r left join public.producten p on p.id = r.product_id
             where r.naam ilike '%bier%' or p.categorie ilike '%bier%'),
    'drukste_dag', (select jsonb_build_object('dag', lt::date, 'bonnen', count(*))
                    from v group by lt::date order by count(*) desc, lt::date limit 1),
    'drukste_kwartier', (select jsonb_build_object('van', k, 'bonnen', n) from (
                           select date_trunc('hour', lt) + interval '15 min' * floor(extract(minute from lt) / 15) as k, count(*) as n
                           from v group by 1 order by 2 desc, 1 limit 1) x),
    -- Per weekdag (1 = maandag) en uur: aantal bonnen.
    'klok', coalesce((select jsonb_agg(jsonb_build_object('dag', dag, 'uur', uur, 'bonnen', n))
                      from (select extract(isodow from lt)::int as dag, extract(hour from lt)::int as uur, count(*) as n from v group by 1, 2) k), '[]'),
    'diensten', (select count(*) from d),
    'kas_klopt', (select count(*) from d where gesloten_ts is not null and geteld_cent = verwacht_cent),
    'langste_dienst_min', (select round(extract(epoch from max(gesloten_ts - geopend_ts)) / 60) from d where gesloten_ts is not null),
    'kaarten_gebruikt', (select count(distinct m.kaart_id) from public.kaart_mutaties m where m.ts >= van and m.ts < tot and m.soort = 'betaling'),
    'opgewaardeerd_cent', (select coalesce(sum(bedrag_cent), 0) from public.kaart_mutaties where ts >= van and ts < tot and soort = 'opwaardering'),
    'populair_opwaardeerbedrag', (select bedrag_cent from public.kaart_mutaties where ts >= van and ts < tot and soort = 'opwaardering'
                                  group by bedrag_cent order by count(*) desc, bedrag_cent desc limit 1),
    'vrijwilligers', coalesce((select jsonb_agg(x order by diensten desc, naam) from (
      select p.naam, count(*) as diensten from d join public.profielen p on p.id = d.geopend_door
      group by p.naam order by count(*) desc, p.naam limit 3) x), '[]'),
    'medewerkers', (select count(distinct door) from v)
  ) into res;
  return res;
end $$;

revoke execute on function public._recap_kern(timestamptz, timestamptz) from public, anon, authenticated;
revoke execute on function public.recap(date, date) from public, anon;
grant execute on function public.recap(date, date) to authenticated;
