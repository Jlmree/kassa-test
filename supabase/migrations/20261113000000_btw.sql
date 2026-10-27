-- Btw (Beheer → Instellingen → Btw). Standaard uit: dan verandert er niets. Staat hij aan,
-- dan heeft elk product een tarief (21, 9 of 0 procent) en staat de btw op de bon, in het
-- rapport en in de boekhouding. Prijzen blijven inclusief btw, zoals aan de bar gewoon is.
--
-- Bij elke verkoopregel wordt het tarief van dat moment vastgelegd, zodat een later
-- gewijzigd tarief oude bonnen niet verandert. Regels van vóór het aanzetten hebben geen
-- vastgelegd tarief; daarvoor geldt het huidige tarief van het product.
--
-- Wat gratis is weggegeven, is niet verkocht: dat deel van een bon telt niet mee voor de btw.

alter table public.instellingen
  add column btw_aan boolean not null default false,
  add column btw_nummer text check (btw_nummer is null or length(btw_nummer) <= 30);
alter table public.producten add column btw_pct smallint not null default 21 check (btw_pct in (0, 9, 21));
alter table public.verkoop_regels add column btw_pct smallint check (btw_pct in (0, 9, 21));

create function public._regel_btw() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.btw_pct is null and new.product_id is not null and (select btw_aan from public.instellingen where id = 1) then
    new.btw_pct := (select btw_pct from public.producten where id = new.product_id);
  end if;
  return new;
end $$;
revoke execute on function public._regel_btw() from public, anon, authenticated;
create trigger btw_vastleggen before insert on public.verkoop_regels for each row execute function public._regel_btw();

create function public.btw_instellen(p_aan boolean, p_nummer text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform public._eis('beheerder');
  if p_aan is null then raise exception 'Kies aan of uit'; end if;
  update public.instellingen set btw_aan = p_aan, btw_nummer = nullif(trim(coalesce(p_nummer, '')), '');
  perform public._log('btw', jsonb_build_object('aan', p_aan));
end $$;
revoke execute on function public.btw_instellen(boolean, text) from public, anon;
grant execute on function public.btw_instellen(boolean, text) to authenticated;

-- Tarief van één product (p_id) of van alle producten in een categorie (p_categorie).
create function public.btw_tarief(p_pct int, p_id bigint default null, p_categorie text default null) returns int
language plpgsql security definer set search_path = '' as $$
declare n int;
begin
  perform public._eis('beheerder');
  if p_pct is null or p_pct not in (0, 9, 21) then raise exception 'Kies 21, 9 of 0 procent'; end if;
  if (p_id is null) = (p_categorie is null) then raise exception 'Kies een product of een categorie'; end if;
  update public.producten set btw_pct = p_pct
  where not verwijderd and (id = p_id or categorie = p_categorie);
  get diagnostics n = row_count;
  perform public._log('btw_tarief', jsonb_build_object('pct', p_pct, 'product', p_id, 'categorie', p_categorie, 'aantal', n));
  return n;
end $$;
revoke execute on function public.btw_tarief(int, bigint, text) from public, anon;
grant execute on function public.btw_tarief(int, bigint, text) to authenticated;

-- Btw per tarief over een periode (Beheer → Rapport).
create function public.btw_overzicht(p_van timestamptz, p_tot timestamptz) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare res jsonb;
begin
  perform public._eis('beheerder');
  with v as (
    select v.id, v.totaal_cent,
           coalesce((select sum(bedrag_cent) from public.betalingen b where b.verkoop_id = v.id and b.methode = 'gratis'), 0) as gratis
    from public.verkopen v where v.ts >= p_van and v.ts < p_tot and not v.geannuleerd
  ), r as (
    select coalesce(r.btw_pct, p.btw_pct, 21) as pct,
           r.prijs_cent * r.aantal * case when v.totaal_cent > 0 then (v.totaal_cent - v.gratis)::numeric / v.totaal_cent else 0 end as bruto
    from v join public.verkoop_regels r on r.verkoop_id = v.id left join public.producten p on p.id = r.product_id
  )
  select coalesce(jsonb_agg(x order by x.pct desc), '[]') into res from (
    select pct, round(sum(bruto))::int as bruto_cent, round(sum(bruto) * pct / (100 + pct))::int as btw_cent
    from r group by pct) x;
  return res;
end $$;
revoke execute on function public.btw_overzicht(timestamptz, timestamptz) from public, anon;
grant execute on function public.btw_overzicht(timestamptz, timestamptz) to authenticated;

-- Bon: tarief per regel, en of de btw aan staat (dan komt hij op de bon).
create or replace function public.bon(p_verkoop_id bigint) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'id', v.id, 'bonnummer', v.bonnummer, 'ts', v.ts, 'door_naam', v.door_naam,
    'rekening_naam', v.rekening_naam, 'totaal_cent', v.totaal_cent,
    'geannuleerd', v.geannuleerd, 'winkel', (select naam from public.instellingen),
    'btw_aan', (select btw_aan from public.instellingen), 'btw_nummer', (select btw_nummer from public.instellingen),
    'regels', coalesce((select jsonb_agg(jsonb_build_object('naam', r.naam, 'prijs_cent', r.prijs_cent, 'aantal', r.aantal,
                                                            'btw_pct', coalesce(r.btw_pct, p.btw_pct, 21)) order by r.id)
                        from public.verkoop_regels r left join public.producten p on p.id = r.product_id
                        where r.verkoop_id = v.id), '[]'),
    'betalingen', coalesce((select jsonb_agg(jsonb_build_object('methode', b.methode, 'bedrag_cent', b.bedrag_cent,
                              'kaart_nummer', k.nummer, 'kaart_saldo_na', b.kaart_saldo_na,
                              'gegeven_cent', b.gegeven_cent, 'wisselgeld_cent', b.wisselgeld_cent,
                              'lid_naam', l.naam,
                              'reden', b.reden, 'op_kaart_nummer', ok.nummer, 'op_kaart_cent', b.op_kaart_cent, 'op_kaart_saldo_na', b.op_kaart_saldo_na) order by b.id)
                            from public.betalingen b left join public.kaarten k on k.id = b.kaart_id
                            left join public.leden l on l.id = b.lid_id
                            left join public.kaarten ok on ok.id = b.op_kaart_id
                            where b.verkoop_id = v.id), '[]'))
  from public.verkopen v where v.id = p_verkoop_id
$$;

-- Boekhouding: tarief per bonregel en of de btw aan staat.
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

