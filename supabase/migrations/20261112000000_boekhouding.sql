-- Boekhouding: alle regels van een periode voor het Excel-bestand (Beheer → Rapport →
-- Boekhouding). Alleen voor beheerders. Per kalenderdag in Nederlandse tijd: van p_van
-- 00:00 tot en met p_tot 24:00. Tijden gaan als Nederlandse tijd mee (zonder tijdzone),
-- zodat het bestand dezelfde tijden toont als de kassa. De app rekent de totalen, per dag
-- en per product zelf uit deze regels uit.

create function public.boekhouding(p_van date, p_tot date) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  van timestamptz := p_van::timestamp at time zone 'Europe/Amsterdam';
  tot timestamptz := (p_tot + 1)::timestamp at time zone 'Europe/Amsterdam';
  res jsonb;
begin
  perform public._eis('beheerder');
  if p_van is null or p_tot is null or p_tot < p_van then raise exception 'Kies een periode'; end if;
  if p_tot - p_van > 800 then raise exception 'Kies een periode van hoogstens twee jaar'; end if;

  with v as (select * from public.verkopen where ts >= van and ts < tot)
  select jsonb_build_object(
    'kassa', (select naam from public.instellingen where id = 1),
    'van', p_van, 'tot', p_tot,
    'gemaakt', (now() at time zone 'Europe/Amsterdam'),

    'bonnen', coalesce((select jsonb_agg(x order by x.bon) from (
      select v.bonnummer as bon, v.ts at time zone 'Europe/Amsterdam' as ts,
             d.geopend_ts at time zone 'Europe/Amsterdam' as dienst,
             v.door_naam as medewerker, v.rekening_naam as rekening, v.totaal_cent as totaal,
             coalesce(sum(b.bedrag_cent) filter (where b.methode = 'contant'), 0) as contant,
             coalesce(sum(b.bedrag_cent) filter (where b.methode = 'pin'), 0) as pin,
             coalesce(sum(b.bedrag_cent) filter (where b.methode = 'kaart'), 0) as kaart,
             coalesce(sum(b.bedrag_cent) filter (where b.methode = 'lat'), 0) as lat,
             coalesce(sum(b.bedrag_cent) filter (where b.methode = 'gratis'), 0) as gratis,
             string_agg(distinct k.nummer::text, ', ') as kaarten,
             string_agg(distinct l.naam, ', ') as lid,
             string_agg(distinct b.reden, ', ') filter (where b.methode = 'gratis') as reden,
             v.geannuleerd, v.geannuleerd_ts at time zone 'Europe/Amsterdam' as geannuleerd_ts,
             (select naam from public.profielen where id = v.geannuleerd_door) as geannuleerd_door
      from v
      left join public.diensten d on d.id = v.dienst_id
      left join public.betalingen b on b.verkoop_id = v.id
      left join public.kaarten k on k.id = b.kaart_id
      left join public.leden l on l.id = b.lid_id
      group by v.id, v.bonnummer, v.ts, v.door_naam, v.rekening_naam, v.totaal_cent, v.geannuleerd,
               v.geannuleerd_ts, v.geannuleerd_door, d.geopend_ts) x), '[]'),

    'regels', coalesce((select jsonb_agg(x order by x.bon, x.id) from (
      select r.id, v.bonnummer as bon, v.ts at time zone 'Europe/Amsterdam' as ts, r.naam as product,
             coalesce(p.categorie, '') as categorie, r.aantal, r.prijs_cent as prijs, v.geannuleerd
      from v join public.verkoop_regels r on r.verkoop_id = v.id
      left join public.producten p on p.id = r.product_id) x), '[]'),

    -- Diensten die (deels) in de periode vallen; een dienst die doorloopt na middernacht hoort er heel bij.
    'diensten', coalesce((select jsonb_agg(public._dienst_cijfers(d.id) order by d.geopend_ts) from public.diensten d
                          where d.geopend_ts < tot and coalesce(d.gesloten_ts, now()) >= van), '[]'),

    'kaart', coalesce((select jsonb_agg(x order by x.ts, x.id) from (
      select m.id, m.ts at time zone 'Europe/Amsterdam' as ts, k.nummer as kaart, k.naam, m.soort, m.methode,
             m.bedrag_cent as bedrag, vv.bonnummer as bon
      from public.kaart_mutaties m join public.kaarten k on k.id = m.kaart_id
      left join public.verkopen vv on vv.id = m.verkoop_id
      where m.ts >= van and m.ts < tot) x), '[]'),
    'kaart_begin', (select coalesce(sum(bedrag_cent), 0) from public.kaart_mutaties where ts < van),
    'kaart_eind', (select coalesce(sum(bedrag_cent), 0) from public.kaart_mutaties where ts < tot),

    -- Streeplijst per lid: wat er openstond, wat erbij kwam, wat er is afbetaald.
    'streeplijst', coalesce((select jsonb_agg(x order by x.lid) from (
      select l.naam as lid,
        coalesce((select sum(b.bedrag_cent) from public.betalingen b join public.verkopen vv on vv.id = b.verkoop_id
                  where b.lid_id = l.id and b.methode = 'lat' and not vv.geannuleerd and vv.ts < van), 0)
        - coalesce((select sum(bedrag_cent) from public.lat_betalingen where lid_id = l.id and ts < van), 0) as begin,
        coalesce((select sum(b.bedrag_cent) from public.betalingen b join v vv on vv.id = b.verkoop_id
                  where b.lid_id = l.id and b.methode = 'lat' and not vv.geannuleerd), 0) as gestreept,
        coalesce((select sum(bedrag_cent) from public.lat_betalingen where lid_id = l.id and methode = 'contant' and ts >= van and ts < tot), 0) as contant,
        coalesce((select sum(bedrag_cent) from public.lat_betalingen where lid_id = l.id and methode = 'pin' and ts >= van and ts < tot), 0) as pin,
        coalesce((select sum(bedrag_cent) from public.lat_betalingen where lid_id = l.id and methode = 'overboeking' and ts >= van and ts < tot), 0) as overboeking
      from public.leden l) x
      where x.begin <> 0 or x.gestreept <> 0 or x.contant <> 0 or x.pin <> 0 or x.overboeking <> 0), '[]'),
    'afbetalingen', coalesce((select jsonb_agg(x order by x.ts) from (
      select a.ts at time zone 'Europe/Amsterdam' as ts, l.naam as lid, a.methode, a.bedrag_cent as bedrag, a.opmerking
      from public.lat_betalingen a join public.leden l on l.id = a.lid_id
      where a.ts >= van and a.ts < tot) x), '[]'),

    'uitgaven', coalesce((select jsonb_agg(x order by x.ts) from (
      select ts at time zone 'Europe/Amsterdam' as ts, omschrijving, bedrag_cent as bedrag, voorgeschoten_door, door_naam,
             terugbetaald_ts at time zone 'Europe/Amsterdam' as terugbetaald_ts, terugbetaald_hoe, terug_door_naam
      from public.uitgaven where verwijderd_ts is null and ts >= van and ts < tot) x), '[]'),
    -- Voorgeschoten en terugbetaald in deze periode (ook als het voorschieten eerder was).
    'terugbetaald', coalesce((select jsonb_agg(x order by x.ts) from (
      select terugbetaald_ts at time zone 'Europe/Amsterdam' as ts, omschrijving, bedrag_cent as bedrag, voorgeschoten_door, terugbetaald_hoe
      from public.uitgaven where verwijderd_ts is null and terugbetaald_ts >= van and terugbetaald_ts < tot) x), '[]'),
    'voorgeschoten_open', (select coalesce(sum(bedrag_cent), 0) from public.uitgaven
                           where verwijderd_ts is null and voorgeschoten_door is not null and ts < tot
                             and (terugbetaald_ts is null or terugbetaald_ts >= tot))
  ) into res;
  return res;
end $$;

revoke execute on function public.boekhouding(date, date) from public, anon;
grant execute on function public.boekhouding(date, date) to authenticated;
