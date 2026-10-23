-- Streeplijst per lid: leden zetten hun bestelling "op de lat" en betalen later,
-- bijvoorbeeld aan het eind van de maand (contant, pin of overboeking).
-- Een streepje is gewoon een verkoop (omzet en voorraad tellen meteen) met als
-- betaalmethode 'lat'; wat een lid nog moet = streepjes − afbetalingen.

create table public.leden (
  id         bigint generated always as identity primary key,
  naam       text not null check (length(trim(naam)) between 1 and 60),
  actief     boolean not null default true,
  aangemaakt timestamptz not null default now()
);
create unique index leden_naam_uniek on public.leden (lower(trim(naam)));

alter table public.betalingen drop constraint betalingen_methode_check;
alter table public.betalingen add constraint betalingen_methode_check check (methode in ('contant', 'pin', 'kaart', 'lat'));
alter table public.betalingen add column lid_id bigint references public.leden;
create index on public.betalingen (lid_id) where lid_id is not null;

create table public.lat_betalingen (
  id          bigint generated always as identity primary key,
  lid_id      bigint not null references public.leden,
  bedrag_cent int not null check (bedrag_cent between 1 and 10000000),
  methode     text not null check (methode in ('contant', 'pin', 'overboeking')),
  dienst_id   bigint references public.diensten,
  door        uuid references public.profielen,
  opmerking   text,
  ts          timestamptz not null default now()
);
create index on public.lat_betalingen (lid_id);
create index on public.lat_betalingen (dienst_id);

alter table public.leden enable row level security;
alter table public.lat_betalingen enable row level security;
create policy lezen on public.leden for select to authenticated using (public.is_medewerker());
create policy lezen on public.lat_betalingen for select to authenticated using (public.is_medewerker());
grant select on public.leden, public.lat_betalingen to authenticated;
create trigger wijziging after insert or update or delete on public.leden for each statement execute function public._wijziging();
create trigger wijziging after insert or update or delete on public.lat_betalingen for each statement execute function public._wijziging();

-- Streeplijst als betaalmethode (Beheer → Instellingen → Betaalmethoden).
alter table public.instellingen add column betaal_lat boolean not null default true;
alter table public.instellingen drop constraint minstens_een_betaalmethode;
alter table public.instellingen add constraint minstens_een_betaalmethode check (betaal_contant or betaal_pin or betaal_kaart or betaal_lat);

drop function public.betaalmethoden_opslaan(boolean, boolean, boolean, boolean);
create function public.betaalmethoden_opslaan(p_contant boolean, p_pin boolean, p_kaart boolean, p_rekening boolean, p_lat boolean default true) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform public._eis('beheerder');
  if not (p_contant or p_pin or p_kaart or p_lat) then raise exception 'Zet minstens één van contant, pin, kaart of streeplijst aan'; end if;
  update public.instellingen set betaal_contant = p_contant, betaal_pin = p_pin, betaal_kaart = p_kaart, betaal_rekening = p_rekening, betaal_lat = p_lat;
  perform public._log('betaalmethoden', jsonb_build_object('contant', p_contant, 'pin', p_pin, 'kaart', p_kaart, 'rekening', p_rekening, 'lat', p_lat));
end $$;
revoke execute on function public.betaalmethoden_opslaan(boolean, boolean, boolean, boolean, boolean) from public, anon;
grant execute on function public.betaalmethoden_opslaan(boolean, boolean, boolean, boolean, boolean) to authenticated;

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
    else true
  end;
  if not aan then
    if p_methode = 'rekening' then raise exception 'Op rekening zetten staat uit (Beheer → Instellingen)'; end if;
    if p_methode = 'lat' then raise exception 'De streeplijst staat uit (Beheer → Instellingen)'; end if;
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
      insert into public.betalingen (verkoop_id, methode, bedrag_cent, gegeven_cent, wisselgeld_cent)
      values (v_id, 'contant', v_rest, v_gegeven, v_gegeven - v_rest);
    elsif v_b ->> 'methode' = 'pin' then
      insert into public.betalingen (verkoop_id, methode, bedrag_cent) values (v_id, 'pin', v_rest);
    elsif v_b ->> 'methode' = 'lat' then
      -- Op de streeplijst van een lid: later afrekenen (lat_afbetalen).
      select * into v_lid from public.leden where id = (v_b ->> 'lid')::bigint;
      if not found then raise exception 'Kies een lid voor de streeplijst'; end if;
      if not v_lid.actief then raise exception '% staat niet meer op de streeplijst', v_lid.naam; end if;
      insert into public.betalingen (verkoop_id, methode, bedrag_cent, lid_id) values (v_id, 'lat', v_rest, v_lid.id);
    else
      raise exception 'Onbekende betaalmethode';
    end if;
  end if;

  return public.bon(v_id);
end $$;

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


-- Bon: bij een streepje de naam van het lid.
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
                              'lid_naam', l.naam) order by b.id)
                            from public.betalingen b left join public.kaarten k on k.id = b.kaart_id
                            left join public.leden l on l.id = b.lid_id
                            where b.verkoop_id = v.id), '[]'))
  from public.verkopen v where v.id = p_verkoop_id
$$;

-- Wat elk lid nog moet: streepjes (niet geannuleerd) min afbetalingen.
create function public._lid_open(p_lid bigint) returns int
language sql stable security definer set search_path = '' as $$
  select (coalesce((select sum(b.bedrag_cent) from public.betalingen b join public.verkopen v on v.id = b.verkoop_id
                    where b.lid_id = p_lid and b.methode = 'lat' and not v.geannuleerd), 0)
        - coalesce((select sum(bedrag_cent) from public.lat_betalingen where lid_id = p_lid), 0))::int
$$;
revoke execute on function public._lid_open(bigint) from public, anon, authenticated;

-- Alle leden met wat ze nog moeten en wat ze deze maand hebben gestreept.
create function public.streeplijst() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  perform public._eis('medewerker');
  return coalesce((select jsonb_agg(x order by lower(x.naam)) from (
    select l.id, l.naam, l.actief, public._lid_open(l.id) as open_cent,
      (select coalesce(sum(b.bedrag_cent), 0) from public.betalingen b join public.verkopen v on v.id = b.verkoop_id
        where b.lid_id = l.id and b.methode = 'lat' and not v.geannuleerd
          and v.ts >= date_trunc('month', now() at time zone 'Europe/Amsterdam') at time zone 'Europe/Amsterdam') as maand_cent,
      (select max(v.ts) from public.betalingen b join public.verkopen v on v.id = b.verkoop_id where b.lid_id = l.id) as laatst
    from public.leden l) x), '[]');
end $$;

-- Een lid toevoegen (medewerker) of wijzigen (beheerder).
create function public.lid_opslaan(p_id bigint, p_naam text, p_actief boolean default true) returns bigint
language plpgsql security definer set search_path = '' as $$
declare v bigint := p_id; n text := trim(coalesce(p_naam, ''));
begin
  perform public._eis(case when p_id is null then 'medewerker' else 'beheerder' end);
  if length(n) not between 1 and 60 then raise exception 'Vul een naam in (hoogstens 60 tekens)'; end if;
  if exists (select 1 from public.leden where lower(trim(naam)) = lower(n) and id is distinct from p_id) then
    raise exception '% staat al op de streeplijst', n;
  end if;
  if v is null then
    insert into public.leden (naam) values (n) returning id into v;
    perform public._log('lid_nieuw', jsonb_build_object('naam', n));
  else
    update public.leden set naam = n, actief = p_actief where id = v;
    if not found then raise exception 'Lid niet gevonden'; end if;
    perform public._log('lid_wijzigen', jsonb_build_object('naam', n, 'actief', p_actief));
  end if;
  return v;
end $$;

-- Geschiedenis van één lid: streepjes en afbetalingen, nieuwste eerst.
create function public.lid_historie(p_lid bigint) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  perform public._eis('medewerker');
  return jsonb_build_object('open_cent', public._lid_open(p_lid), 'regels', coalesce((select jsonb_agg(x order by x.ts desc) from (
    (select v.ts, 'streep' as soort, b.bedrag_cent, v.id as verkoop_id, v.bonnummer, v.door_naam,
       (select string_agg(r.aantal || '× ' || r.naam, ', ' order by r.id) from public.verkoop_regels r where r.verkoop_id = v.id) as wat
     from public.betalingen b join public.verkopen v on v.id = b.verkoop_id
     where b.lid_id = p_lid and b.methode = 'lat' and not v.geannuleerd order by v.ts desc limit 100)
    union all
    (select a.ts, 'afbetaald', a.bedrag_cent, null, null, p.naam, a.methode || coalesce(' · ' || a.opmerking, '')
     from public.lat_betalingen a left join public.profielen p on p.id = a.door
     where a.lid_id = p_lid order by a.ts desc limit 100)) x), '[]'));
end $$;

-- Een lid betaalt (een deel van) de streeplijst. Contant en pin gaan via de open
-- kassa (contant telt mee in de la); een overboeking boekt alleen een beheerder af.
create function public.lat_afbetalen(p_lid bigint, p_bedrag_cent int, p_methode text, p_opmerking text default null) returns int
language plpgsql security definer set search_path = '' as $$
declare l public.leden; v_dienst bigint;
begin
  perform public._eis(case when p_methode = 'overboeking' then 'beheerder' else 'medewerker' end);
  if p_methode not in ('contant', 'pin', 'overboeking') then raise exception 'Onbekende betaalmethode'; end if;
  if p_methode <> 'overboeking' then
    perform public._methode_aan(p_methode);
    v_dienst := public._open_dienst();
  end if;
  select * into l from public.leden where id = p_lid for update;
  if not found then raise exception 'Lid niet gevonden'; end if;
  if p_bedrag_cent is null or p_bedrag_cent < 1 then raise exception 'Vul een bedrag in'; end if;
  if p_bedrag_cent > public._lid_open(p_lid) then
    raise exception '% moet nog € %; meer afbetalen kan niet', l.naam, to_char(public._lid_open(p_lid) / 100.0, 'FM999990.00');
  end if;
  insert into public.lat_betalingen (lid_id, bedrag_cent, methode, dienst_id, door, opmerking)
  values (p_lid, p_bedrag_cent, p_methode, v_dienst, auth.uid(), nullif(trim(p_opmerking), ''));
  perform public._log('lat_afbetalen', jsonb_build_object('naam', l.naam, 'bedrag_cent', p_bedrag_cent, 'methode', p_methode));
  return public._lid_open(p_lid);
end $$;

-- Maandoverzicht voor de beheerder (bijv. voor de incasso): per lid de streepjes
-- en afbetalingen in die maand en wat er nu nog openstaat.
create function public.streeplijst_maand(p_maand date) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare van timestamptz := date_trunc('month', p_maand)::timestamp at time zone 'Europe/Amsterdam';
        tot timestamptz := (date_trunc('month', p_maand) + interval '1 month')::timestamp at time zone 'Europe/Amsterdam';
begin
  perform public._eis('beheerder');
  return coalesce((select jsonb_agg(x order by lower(x.naam)) from (
    select l.id, l.naam, l.actief,
      (select coalesce(sum(b.bedrag_cent), 0) from public.betalingen b join public.verkopen v on v.id = b.verkoop_id
        where b.lid_id = l.id and b.methode = 'lat' and not v.geannuleerd and v.ts >= van and v.ts < tot) as gestreept_cent,
      (select count(*) from public.betalingen b join public.verkopen v on v.id = b.verkoop_id
        where b.lid_id = l.id and b.methode = 'lat' and not v.geannuleerd and v.ts >= van and v.ts < tot) as keer,
      (select coalesce(sum(bedrag_cent), 0) from public.lat_betalingen where lid_id = l.id and ts >= van and ts < tot) as afbetaald_cent,
      public._lid_open(l.id) as open_cent
    from public.leden l) x
    where x.gestreept_cent > 0 or x.afbetaald_cent > 0 or x.open_cent <> 0), '[]');
end $$;

revoke execute on function public.streeplijst(), public.lid_opslaan(bigint, text, boolean), public.lid_historie(bigint),
  public.lat_afbetalen(bigint, int, text, text), public.streeplijst_maand(date) from public, anon;
grant execute on function public.streeplijst(), public.lid_opslaan(bigint, text, boolean), public.lid_historie(bigint),
  public.lat_afbetalen(bigint, int, text, text), public.streeplijst_maand(date) to authenticated;
