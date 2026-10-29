-- Streeplijst afbetalen met de barkaart (Streeplijst → lid → Met barkaart). Het tegoed gaat
-- van de kaart af en de streeplijst omlaag; er komt geen geld in de kas. Op de kaart staat
-- het als een gewone betaling (soort 'betaling'), gekoppeld aan de afbetaling, zodat de
-- saldo-pagina "Streeplijst afbetaald" toont en de boekhouding sluitend blijft.
-- Overgemaakt (overboeking) verdwijnt uit de app; wat al zo is afbetaald, blijft staan.

alter table public.lat_betalingen drop constraint lat_betalingen_methode_check;
alter table public.lat_betalingen add constraint lat_betalingen_methode_check check (methode in ('contant', 'pin', 'overboeking', 'kaart'));
alter table public.lat_betalingen add column kaart_id bigint references public.kaarten;
alter table public.kaart_mutaties add column lat_betaling_id bigint references public.lat_betalingen;

drop function public.lat_afbetalen(bigint, int, text, text);
create function public.lat_afbetalen(p_lid bigint, p_bedrag_cent int, p_methode text, p_opmerking text default null, p_kaart text default null)
returns int
language plpgsql security definer set search_path = '' as $$
declare l public.leden; k public.kaarten; v_dienst bigint; v_id bigint;
begin
  perform public._eis(case when p_methode = 'overboeking' then 'beheerder' else 'medewerker' end);
  if p_methode not in ('contant', 'pin', 'overboeking', 'kaart') then raise exception 'Onbekende betaalmethode'; end if;
  if p_methode in ('contant', 'pin') then
    perform public._methode_aan(p_methode);
    v_dienst := public._open_dienst();
  elsif p_methode = 'kaart' then
    perform public._methode_aan('kaart');
    -- Geen geld in de la, dus de kassa hoeft niet open; staat hij open, dan hoort het bij die dienst.
    v_dienst := (select id from public.diensten where gesloten_ts is null order by geopend_ts desc limit 1);
  end if;
  select * into l from public.leden where id = p_lid for update;
  if not found then raise exception 'Lid niet gevonden'; end if;
  if p_bedrag_cent is null or p_bedrag_cent < 1 then raise exception 'Vul een bedrag in'; end if;
  if p_bedrag_cent > public._lid_open(p_lid) then
    raise exception '% moet nog € %; meer afbetalen kan niet', l.naam, to_char(public._lid_open(p_lid) / 100.0, 'FM999990.00');
  end if;
  if p_methode = 'kaart' then
    select * into k from public.kaarten where id = public._zoek_kaart(p_kaart, true) for update;
    if k.geblokkeerd then raise exception 'Kaart % is geblokkeerd', k.nummer; end if;
    if k.saldo_cent < p_bedrag_cent then
      raise exception 'Op kaart % staat € %; zoveel kun je er hoogstens mee afbetalen', k.nummer, to_char(k.saldo_cent / 100.0, 'FM999990.00');
    end if;
  end if;
  insert into public.lat_betalingen (lid_id, bedrag_cent, methode, dienst_id, door, opmerking, kaart_id)
  values (p_lid, p_bedrag_cent, p_methode, v_dienst, auth.uid(), nullif(trim(p_opmerking), ''), k.id)
  returning id into v_id;
  if p_methode = 'kaart' then
    update public.kaarten set saldo_cent = saldo_cent - p_bedrag_cent where id = k.id;
    insert into public.kaart_mutaties (kaart_id, bedrag_cent, soort, dienst_id, door, lat_betaling_id)
    values (k.id, -p_bedrag_cent, 'betaling', v_dienst, auth.uid(), v_id);
  end if;
  perform public._log('lat_afbetalen', jsonb_build_object('naam', l.naam, 'bedrag_cent', p_bedrag_cent, 'methode', p_methode, 'kaart', k.nummer));
  return public._lid_open(p_lid);
end $$;
revoke execute on function public.lat_afbetalen(bigint, int, text, text, text) from public, anon;
grant execute on function public.lat_afbetalen(bigint, int, text, text, text) to authenticated;

-- Saldo-pagina: een afbetaling van de streeplijst heet zo.
create or replace function public.kaart_saldo(p_code text) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare
  z text := upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g'));
  k public.kaarten;
begin
  if public._code_geblokkeerd() then
    return jsonb_build_object('fout', 'Te veel verkeerde codes geprobeerd. Probeer het over 10 minuten opnieuw.');
  end if;
  if length(z) <> 8 then return jsonb_build_object('fout', 'Typ de code van je kaart (8 tekens, bijvoorbeeld ABCD-EFGH)'); end if;
  select * into k from public.kaarten where replace(code, '-', '') = z;
  if not found then
    perform public._mislukt('code', public._klant_ip());
    return jsonb_build_object('fout', 'Deze kaart is niet gevonden. Klopt de code?');
  end if;
  if k.verwijderd_ts is not null then return jsonb_build_object('fout', 'Deze kaart is niet meer in gebruik.'); end if;
  return jsonb_build_object(
    'nummer', k.nummer, 'naam', k.naam, 'saldo_cent', k.saldo_cent, 'geblokkeerd', k.geblokkeerd,
    'winkel', (select naam from public.instellingen where id = 1),
    'historie', coalesce((
      select jsonb_agg(x order by x.ts desc) from (
        select m.ts, m.bedrag_cent, m.soort, m.methode, v.bonnummer as bon,
               case when m.lat_betaling_id is not null then 'Streeplijst afbetaald'
                    else (select string_agg(r.aantal || '× ' || r.naam, ', ' order by r.id) from public.verkoop_regels r where r.verkoop_id = v.id) end as wat,
               case when v.ts >= now() - interval '90 days' then v.deel_code end as bon_code
        from public.kaart_mutaties m left join public.verkopen v on v.id = m.verkoop_id
        where m.kaart_id = k.id order by m.ts desc limit 50) x), '[]'));
end $$;

-- Boekhouding: afbetaald met de barkaart als eigen kolom bij de streeplijst.
create or replace function public.boekhouding(p_van date, p_tot date) returns jsonb
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
    'btw_aan', (select btw_aan from public.instellingen where id = 1),
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
             coalesce(p.categorie, '') as categorie, r.aantal, r.prijs_cent as prijs, v.geannuleerd,
             coalesce(r.btw_pct, p.btw_pct, 21) as btw
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
        coalesce((select sum(bedrag_cent) from public.lat_betalingen where lid_id = l.id and methode = 'overboeking' and ts >= van and ts < tot), 0) as overboeking,
        coalesce((select sum(bedrag_cent) from public.lat_betalingen where lid_id = l.id and methode = 'kaart' and ts >= van and ts < tot), 0) as kaart
      from public.leden l) x
      where x.begin <> 0 or x.gestreept <> 0 or x.contant <> 0 or x.pin <> 0 or x.overboeking <> 0 or x.kaart <> 0), '[]'),
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
