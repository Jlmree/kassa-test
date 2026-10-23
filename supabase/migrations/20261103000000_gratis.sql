-- Gratis weggeven: een betaalmethode voor wat niet betaald wordt, met een reden
-- (bardienst, sponsor, kapot of weggegooid). De voorraad gaat omlaag, de kas
-- blijft kloppen, en in het rapport staat per reden wat er is weggegeven.
-- De beheerder zet het aan of uit, net als de andere betaalmethoden.

alter table public.instellingen add column betaal_gratis boolean not null default true;
alter table public.betalingen add column reden text check (reden is null or length(reden) between 1 and 60);
alter table public.betalingen drop constraint betalingen_methode_check;
alter table public.betalingen add constraint betalingen_methode_check check (methode in ('contant', 'pin', 'kaart', 'lat', 'gratis'));

drop function public.betaalmethoden_opslaan(boolean, boolean, boolean, boolean, boolean);
create function public.betaalmethoden_opslaan(p_contant boolean, p_pin boolean, p_kaart boolean, p_rekening boolean,
                                              p_lat boolean default true, p_gratis boolean default true) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform public._eis('beheerder');
  if not (p_contant or p_pin or p_kaart or p_lat) then raise exception 'Zet minstens één van contant, pin, kaart of streeplijst aan'; end if;
  update public.instellingen set betaal_contant = p_contant, betaal_pin = p_pin, betaal_kaart = p_kaart,
    betaal_rekening = p_rekening, betaal_lat = p_lat, betaal_gratis = p_gratis;
  perform public._log('betaalmethoden', jsonb_build_object('contant', p_contant, 'pin', p_pin, 'kaart', p_kaart,
    'rekening', p_rekening, 'lat', p_lat, 'gratis', p_gratis));
end $$;
revoke execute on function public.betaalmethoden_opslaan(boolean, boolean, boolean, boolean, boolean, boolean) from public, anon;
grant execute on function public.betaalmethoden_opslaan(boolean, boolean, boolean, boolean, boolean, boolean) to authenticated;

create or replace function public._methode_aan(p_methode text) returns void
language plpgsql stable security definer set search_path = '' as $$
declare i public.instellingen; aan boolean;
begin
  select * into i from public.instellingen where id = 1;
  aan := case p_methode
    when 'contant' then i.betaal_contant
    when 'pin' then i.betaal_pin
    when 'kaart' then i.betaal_kaart
    when 'rekening' then i.betaal_rekening
    when 'lat' then i.betaal_lat
    when 'gratis' then i.betaal_gratis
    else true
  end;
  if not aan then
    if p_methode = 'rekening' then raise exception 'Op rekening zetten staat uit (Beheer → Instellingen)'; end if;
    if p_methode = 'lat' then raise exception 'De streeplijst staat uit (Beheer → Instellingen)'; end if;
    if p_methode = 'gratis' then raise exception 'Gratis weggeven staat uit (Beheer → Instellingen)'; end if;
    raise exception 'Betalen met % staat uit (Beheer → Instellingen)', p_methode;
  end if;
end $$;

create or replace function public._afrekenen(p_regels jsonb default '[]', p_betalingen jsonb default '[]', p_rekening_id bigint default null,
                                              p_verwacht_cent int default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_dienst bigint;
  v_id     bigint;
  v_rek    public.rekeningen;
  v_totaal int;
  v_rest   int;
  v_kaart  public.kaarten;
  v_bedrag int;
  v_b      jsonb;
  v_n      int;
  v_gegeven int;
  v_lid    public.leden;
  v_over   int := 0;
  v_op     public.kaarten;
  v_reden  text;
begin
  perform public._eis('medewerker');
  v_dienst := public._open_dienst();

  if jsonb_typeof(p_betalingen) is distinct from 'array' or jsonb_typeof(p_regels) is distinct from 'array' then
    raise exception 'Ongeldige bestelling';
  end if;

  insert into public.verkopen (door, door_naam, dienst_id)
  values (auth.uid(), (select naam from public.profielen where id = auth.uid()), v_dienst)
  returning id into v_id;

  if p_rekening_id is not null then
    select * into v_rek from public.rekeningen where id = p_rekening_id for update;
    if not found or not v_rek.open then
      raise exception 'Deze rekening is al afgerekend of bestaat niet';
    end if;
    insert into public.verkoop_regels (verkoop_id, product_id, naam, prijs_cent, aantal)
    select v_id, product_id, naam, prijs_cent, sum(aantal)
    from public.rekening_regels where rekening_id = p_rekening_id
    group by product_id, naam, prijs_cent order by min(id);
    update public.rekeningen set open = false, gesloten_ts = now() where id = p_rekening_id;
    update public.verkopen set rekening_naam = v_rek.naam where id = v_id;
  else
    if exists (select 1 from jsonb_array_elements(p_regels) e
               where coalesce((e ->> 'aantal')::int, 0) not between 1 and 999) then
      raise exception 'Ongeldig aantal in de bestelling';
    end if;
    with r as (
      select (e ->> 'product_id')::bigint as pid, sum((e ->> 'aantal')::int) as aantal, min(ord) as ord
      from jsonb_array_elements(p_regels) with ordinality as x(e, ord) group by 1
    )
    insert into public.verkoop_regels (verkoop_id, product_id, naam, prijs_cent, aantal)
    select v_id, p.id, p.naam, p.prijs_cent, r.aantal
    from r join public.producten p on p.id = r.pid and p.actief and not p.verwijderd
    order by r.ord;
    get diagnostics v_n = row_count;
    if v_n <> (select count(distinct e ->> 'product_id') from jsonb_array_elements(p_regels) e) then
      raise exception 'Een product in de bestelling is niet meer beschikbaar';
    end if;
    -- Voorraad afboeken (bij een rekening gebeurde dat al bij het opschrijven).
    with r as (select product_id, sum(aantal) as a from public.verkoop_regels where verkoop_id = v_id group by 1),
    u as (update public.producten p set voorraad = p.voorraad - r.a from r
          where p.id = r.product_id and p.voorraad_bijhouden returning p.id, r.a)
    insert into public.voorraad_mutaties (product_id, aantal, reden, verkoop_id, door)
    select id, -a, 'verkoop', v_id, auth.uid() from u;
  end if;

  select coalesce(sum(prijs_cent * aantal), 0) into v_totaal from public.verkoop_regels where verkoop_id = v_id;
  if not exists (select 1 from public.verkoop_regels where verkoop_id = v_id) then
    raise exception 'De bestelling is leeg';
  end if;
  -- Is het bedrag intussen veranderd (iemand boekte bij op de rekening, of een prijs
  -- werd aangepast)? Dan niet afrekenen: er is al gepind of afgeteld voor het oude bedrag.
  if p_verwacht_cent is not null and p_verwacht_cent <> v_totaal then
    raise exception 'Het bedrag is intussen veranderd: het is nu € %. Controleer de bestelling en reken opnieuw af.',
      to_char(v_totaal / 100.0, 'FM999990.00');
  end if;
  update public.verkopen set totaal_cent = v_totaal where id = v_id;
  v_rest := v_totaal;

  -- Kaart eerst.
  if (select count(*) from jsonb_array_elements(p_betalingen) e where e ->> 'methode' = 'kaart') > 1 then
    raise exception 'Je kunt met maar één kaart tegelijk betalen';
  end if;
  select e into v_b from jsonb_array_elements(p_betalingen) e where e ->> 'methode' = 'kaart';
  if v_b is not null then
    select * into v_kaart from public.kaarten where id = public._zoek_kaart(v_b ->> 'kaart', true) for update;
    if v_kaart.geblokkeerd then raise exception 'Kaart % is geblokkeerd', v_kaart.nummer; end if;
    v_bedrag := least(v_kaart.saldo_cent, v_rest);
    if v_bedrag <= 0 and v_rest > 0 then raise exception 'Er staat geen tegoed op kaart %', v_kaart.nummer; end if;
    update public.kaarten set saldo_cent = saldo_cent - v_bedrag where id = v_kaart.id;
    insert into public.kaart_mutaties (kaart_id, bedrag_cent, soort, verkoop_id, dienst_id, door)
    values (v_kaart.id, -v_bedrag, 'betaling', v_id, v_dienst, auth.uid());
    insert into public.betalingen (verkoop_id, methode, bedrag_cent, kaart_id, kaart_saldo_na)
    values (v_id, 'kaart', v_bedrag, v_kaart.id, v_kaart.saldo_cent - v_bedrag);
    v_rest := v_rest - v_bedrag;
  end if;

  -- Restant met contant of pin.
  select count(*) into v_n from jsonb_array_elements(p_betalingen) e where e ->> 'methode' <> 'kaart';
  if v_rest > 0 then
    if v_n <> 1 then raise exception 'Kies hoe er betaald wordt (nog % open)', to_char(v_rest / 100.0, 'FM9990.00'); end if;
    select e into v_b from jsonb_array_elements(p_betalingen) e where e ->> 'methode' <> 'kaart';
    if v_b ->> 'methode' = 'contant' then
      v_gegeven := coalesce((v_b ->> 'gegeven_cent')::int, v_rest);
      if v_gegeven < v_rest then raise exception 'Er is te weinig gegeven'; end if;
      -- Te weinig wisselgeld in de la: wat over is als tegoed op een barkaart.
      -- Dat is een gewone contante opwaardering (telt mee in de la) en blijft
      -- staan als de bon later wordt geannuleerd.
      if nullif(trim(v_b ->> 'rest_kaart'), '') is not null and v_gegeven > v_rest then
        perform public._methode_aan('kaart');
        v_over := v_gegeven - v_rest;
        if v_over > 50000 then raise exception 'Je kunt hoogstens € 500 op een kaart zetten'; end if;
        select * into v_op from public.kaarten where id = public._zoek_kaart(v_b ->> 'rest_kaart', true) for update;
        if v_op.geblokkeerd then raise exception 'Kaart % is geblokkeerd', v_op.nummer; end if;
        update public.kaarten set saldo_cent = saldo_cent + v_over where id = v_op.id;
        insert into public.kaart_mutaties (kaart_id, bedrag_cent, soort, methode, verkoop_id, dienst_id, door)
        values (v_op.id, v_over, 'opwaardering', 'contant', v_id, v_dienst, auth.uid());
      end if;
      insert into public.betalingen (verkoop_id, methode, bedrag_cent, gegeven_cent, wisselgeld_cent, op_kaart_id, op_kaart_cent, op_kaart_saldo_na)
      values (v_id, 'contant', v_rest, v_gegeven, v_gegeven - v_rest - v_over, v_op.id, nullif(v_over, 0), v_op.saldo_cent + v_over);
    elsif v_b ->> 'methode' = 'pin' then
      insert into public.betalingen (verkoop_id, methode, bedrag_cent) values (v_id, 'pin', v_rest);
    elsif v_b ->> 'methode' = 'lat' then
      -- Op de streeplijst van een lid: later afrekenen (lat_afbetalen).
      select * into v_lid from public.leden where id = (v_b ->> 'lid')::bigint;
      if not found then raise exception 'Kies een lid voor de streeplijst'; end if;
      if not v_lid.actief then raise exception '% staat niet meer op de streeplijst', v_lid.naam; end if;
      insert into public.betalingen (verkoop_id, methode, bedrag_cent, lid_id) values (v_id, 'lat', v_rest, v_lid.id);
    elsif v_b ->> 'methode' = 'gratis' then
      -- Weggegeven (bardienst, sponsor, kapot): voorraad gaat omlaag, er komt geen geld binnen.
      v_reden := left(nullif(trim(v_b ->> 'reden'), ''), 60);
      if v_reden is null then raise exception 'Kies waarom het gratis is'; end if;
      insert into public.betalingen (verkoop_id, methode, bedrag_cent, reden) values (v_id, 'gratis', v_rest, v_reden);
      perform public._log('gratis', jsonb_build_object('bon', (select bonnummer from public.verkopen where id = v_id),
        'bedrag_cent', v_rest, 'reden', v_reden));
    else
      raise exception 'Onbekende betaalmethode';
    end if;
  end if;

  return public.bon(v_id);
end $$;

-- Bon: met de reden bij gratis.
create or replace function public.bon(p_verkoop_id bigint) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'id', v.id, 'bonnummer', v.bonnummer, 'ts', v.ts, 'door_naam', v.door_naam,
    'rekening_naam', v.rekening_naam, 'totaal_cent', v.totaal_cent,
    'geannuleerd', v.geannuleerd, 'winkel', (select naam from public.instellingen),
    'regels', coalesce((select jsonb_agg(jsonb_build_object('naam', r.naam, 'prijs_cent', r.prijs_cent, 'aantal', r.aantal) order by r.id)
                        from public.verkoop_regels r where r.verkoop_id = v.id), '[]'),
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
    'afbetaald_contant_cent', coalesce((select s from a where methode = 'contant'), 0),
    'afbetaald_pin_cent', coalesce((select s from a where methode = 'pin'), 0),
    'opwaardering_contant_cent', coalesce((select s from o where methode = 'contant'), 0),
    'opwaardering_pin_cent', coalesce((select s from o where methode = 'pin'), 0),
    -- Een gesloten dienst houdt het bedrag van het moment van tellen.
    'verwacht_cent', coalesce(d.verwacht_cent, d.beginsaldo_cent + coalesce((select s from b where methode = 'contant'), 0)
                     + coalesce((select s from o where methode = 'contant'), 0)
                     + coalesce((select s from a where methode = 'contant'), 0)),
    'geteld_cent', d.geteld_cent, 'opmerking', d.opmerking)
  from d
$$;

-- Rapport: met wat er gratis is weggegeven.
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
