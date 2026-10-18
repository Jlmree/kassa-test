-- Bar-kassa: tabellen, rechten en alle bewerkingen.
--
-- Uitgangspunt voor de beveiliging: de app mag gegevens alleen LEZEN (en dan
-- nog alleen wat bij de rol past). Alles wat iets verandert gaat via de
-- functies onderaan. Die controleren de rol, rekenen prijzen en saldo's zelf
-- uit (de app kan dus geen eigen prijs of saldo opsturen) en schrijven alles
-- in één transactie weg, zodat twee telefoons tegelijk nooit een kaart dubbel
-- kunnen afschrijven.

-- ───────────────────────────── Tabellen ─────────────────────────────

create table public.profielen (
  id         uuid primary key references auth.users on delete cascade,
  naam       text not null,
  rol        text not null default 'wacht' check (rol in ('wacht', 'medewerker', 'beheerder')),
  actief     boolean not null default true,
  aangemaakt timestamptz not null default now()
);

create table public.instellingen (
  id   int primary key default 1 check (id = 1),
  naam text not null default 'Bar'
);
insert into public.instellingen default values;

create table public.producten (
  id                 bigint generated always as identity primary key,
  naam               text not null check (length(trim(naam)) between 1 and 60),
  prijs_cent         int not null check (prijs_cent between 0 and 100000),
  categorie          text not null default 'Overig' check (length(trim(categorie)) between 1 and 30),
  actief             boolean not null default true,
  verwijderd         boolean not null default false,
  volgorde           int not null default 0,
  voorraad_bijhouden boolean not null default false,
  voorraad           int not null default 0,
  voorraad_min       int not null default 0 check (voorraad_min >= 0)
);

create table public.diensten (
  id            bigint generated always as identity primary key,
  geopend_ts    timestamptz not null default now(),
  geopend_door  uuid references public.profielen,
  beginsaldo_cent int not null check (beginsaldo_cent >= 0),
  gesloten_ts   timestamptz,
  gesloten_door uuid references public.profielen,
  geteld_cent   int,
  verwacht_cent int,
  opmerking     text
);
-- Er kan maar één dienst tegelijk open staan.
create unique index een_open_dienst on public.diensten ((true)) where gesloten_ts is null;

create table public.rekeningen (
  id          bigint generated always as identity primary key,
  naam        text not null check (length(trim(naam)) between 1 and 60),
  open        boolean not null default true,
  aangemaakt  timestamptz not null default now(),
  door        uuid references public.profielen,
  gesloten_ts timestamptz
);

create table public.rekening_regels (
  id          bigint generated always as identity primary key,
  rekening_id bigint not null references public.rekeningen on delete cascade,
  product_id  bigint not null references public.producten,
  naam        text not null,
  prijs_cent  int not null,
  aantal      int not null check (aantal > 0),
  door        uuid references public.profielen,
  ts          timestamptz not null default now()
);
create index on public.rekening_regels (rekening_id);

create sequence public.kaart_nummer;
create table public.kaarten (
  id          bigint generated always as identity primary key,
  nummer      int not null unique default nextval('public.kaart_nummer'),
  code        text not null unique,
  saldo_cent  int not null default 0 check (saldo_cent >= 0),
  geblokkeerd boolean not null default false,
  aangemaakt  timestamptz not null default now()
);

create sequence public.bon_nummer;
create table public.verkopen (
  id               bigint generated always as identity primary key,
  bonnummer        int not null unique default nextval('public.bon_nummer'),
  ts               timestamptz not null default now(),
  door             uuid references public.profielen,
  door_naam        text,
  rekening_naam    text,
  totaal_cent      int not null default 0,
  dienst_id        bigint references public.diensten,
  geannuleerd      boolean not null default false,
  geannuleerd_door uuid references public.profielen,
  geannuleerd_ts   timestamptz
);
create index on public.verkopen (ts);
create index on public.verkopen (dienst_id);

create table public.verkoop_regels (
  id         bigint generated always as identity primary key,
  verkoop_id bigint not null references public.verkopen on delete cascade,
  product_id bigint references public.producten,
  naam       text not null,
  prijs_cent int not null,
  aantal     int not null check (aantal > 0)
);
create index on public.verkoop_regels (verkoop_id);

create table public.betalingen (
  id              bigint generated always as identity primary key,
  verkoop_id      bigint not null references public.verkopen on delete cascade,
  methode         text not null check (methode in ('contant', 'pin', 'kaart')),
  bedrag_cent     int not null check (bedrag_cent >= 0),
  kaart_id        bigint references public.kaarten,
  kaart_saldo_na  int,
  gegeven_cent    int,
  wisselgeld_cent int
);
create index on public.betalingen (verkoop_id);

create table public.kaart_mutaties (
  id          bigint generated always as identity primary key,
  kaart_id    bigint not null references public.kaarten,
  bedrag_cent int not null,
  soort       text not null check (soort in ('opwaardering', 'betaling', 'annulering', 'overzetting')),
  methode     text check (methode in ('contant', 'pin')),
  verkoop_id  bigint references public.verkopen,
  dienst_id   bigint references public.diensten,
  door        uuid references public.profielen,
  ts          timestamptz not null default now()
);
create index on public.kaart_mutaties (ts);
create index on public.kaart_mutaties (dienst_id);

create table public.voorraad_mutaties (
  id         bigint generated always as identity primary key,
  product_id bigint not null references public.producten,
  aantal     int not null,
  reden      text not null check (reden in ('verkoop', 'rekening', 'levering', 'telling', 'annulering', 'correctie')),
  verkoop_id bigint references public.verkopen,
  door       uuid references public.profielen,
  ts         timestamptz not null default now()
);
create index on public.voorraad_mutaties (ts);

create table public.logboek (
  id        bigint generated always as identity primary key,
  ts        timestamptz not null default now(),
  door      uuid,
  door_naam text,
  actie     text not null,
  details   jsonb
);
create index on public.logboek (ts);

-- ──────────────────────────── Hulpfuncties ───────────────────────────

create function public.mijn_rol() returns text
language sql stable security definer set search_path = '' as $$
  select rol from public.profielen where id = auth.uid() and actief
$$;

create function public.is_medewerker() returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce(public.mijn_rol() in ('medewerker', 'beheerder'), false)
$$;

create function public.is_beheerder() returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce(public.mijn_rol() = 'beheerder', false)
$$;

create function public._eis(p_rol text) returns void
language plpgsql stable security definer set search_path = '' as $$
begin
  if p_rol = 'beheerder' and not public.is_beheerder() then
    raise exception 'Alleen een beheerder mag dit doen' using errcode = '42501';
  elsif not public.is_medewerker() then
    raise exception 'Je hebt (nog) geen toegang tot de kassa' using errcode = '42501';
  end if;
end $$;

create function public._log(p_actie text, p_details jsonb default null) returns void
language sql security definer set search_path = '' as $$
  insert into public.logboek (door, door_naam, actie, details)
  values (auth.uid(), (select naam from public.profielen where id = auth.uid()), p_actie, p_details)
$$;

create function public._open_dienst() returns bigint
language plpgsql stable security definer set search_path = '' as $$
declare v bigint;
begin
  select id into v from public.diensten where gesloten_ts is null;
  if v is null then
    raise exception 'Open eerst de kassa (tabblad Dienst)' using errcode = 'P0001';
  end if;
  return v;
end $$;

-- Nieuwe aanmelding: de allereerste gebruiker wordt beheerder, alle volgende
-- moeten eerst door een beheerder worden goedgekeurd.
create function public._nieuwe_gebruiker() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  lock table public.profielen in share row exclusive mode;
  insert into public.profielen (id, naam, rol)
  values (
    new.id,
    left(coalesce(nullif(trim(new.raw_user_meta_data ->> 'naam'), ''), split_part(new.email, '@', 1)), 40),
    case when exists (select 1 from public.profielen where rol = 'beheerder') then 'wacht' else 'beheerder' end
  );
  return new;
end $$;

create trigger na_aanmelden after insert on auth.users
  for each row execute function public._nieuwe_gebruiker();

-- Leesbare, moeilijk te raden kaartcode: 8 tekens zonder 0/O/1/I, bv. "K7MQ-3XRP".
create function public._kaartcode() returns text
language plpgsql volatile set search_path = '' as $$
declare
  a constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  b bytea := extensions.gen_random_bytes(8);
  s text := '';
begin
  for i in 0..7 loop
    s := s || substr(a, get_byte(b, i) % 32 + 1, 1);
    if i = 3 then s := s || '-'; end if;
  end loop;
  return s;
end $$;

create function public._zoek_kaart(p_zoek text, p_alleen_code boolean) returns bigint
language plpgsql stable security definer set search_path = '' as $$
declare
  z text := upper(regexp_replace(coalesce(p_zoek, ''), '[^A-Za-z0-9]', '', 'g'));
  v bigint;
begin
  if length(z) = 8 then
    select id into v from public.kaarten where replace(code, '-', '') = z;
  elsif not p_alleen_code and z ~ '^[0-9]{1,7}$' then
    select id into v from public.kaarten where nummer = z::int;
  end if;
  if v is null then
    raise exception '%', case when p_alleen_code and z ~ '^[0-9]+$'
      then 'Scan de QR-code of typ de kaartcode (het kaartnummer is niet genoeg om te betalen)'
      else 'Kaart niet gevonden' end;
  end if;
  return v;
end $$;

-- ────────────────────────────── Bon ──────────────────────────────

-- Gewone (invoker) functie: wat je mag zien wordt door de leesregels bepaald.
create function public.bon(p_verkoop_id bigint) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'id', v.id, 'bonnummer', v.bonnummer, 'ts', v.ts, 'door_naam', v.door_naam,
    'rekening_naam', v.rekening_naam, 'totaal_cent', v.totaal_cent,
    'geannuleerd', v.geannuleerd, 'winkel', (select naam from public.instellingen),
    'regels', coalesce((select jsonb_agg(jsonb_build_object('naam', r.naam, 'prijs_cent', r.prijs_cent, 'aantal', r.aantal) order by r.id)
                        from public.verkoop_regels r where r.verkoop_id = v.id), '[]'),
    'betalingen', coalesce((select jsonb_agg(jsonb_build_object('methode', b.methode, 'bedrag_cent', b.bedrag_cent,
                              'kaart_nummer', k.nummer, 'kaart_saldo_na', b.kaart_saldo_na,
                              'gegeven_cent', b.gegeven_cent, 'wisselgeld_cent', b.wisselgeld_cent) order by b.id)
                            from public.betalingen b left join public.kaarten k on k.id = b.kaart_id
                            where b.verkoop_id = v.id), '[]'))
  from public.verkopen v where v.id = p_verkoop_id
$$;

-- ──────────────────────────── Afrekenen ────────────────────────────

-- p_regels:     [{"product_id": 1, "aantal": 2}, ...]  (genegeerd bij een rekening)
-- p_betalingen: [{"methode": "kaart", "kaart": "K7MQ-3XRP"}, {"methode": "contant", "gegeven_cent": 2000}]
--               Een kaart gaat altijd eerst; het restant moet met precies één
--               andere methode (contant of pin) worden betaald.
create function public.afrekenen(p_regels jsonb default '[]', p_betalingen jsonb default '[]', p_rekening_id bigint default null)
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
    else
      raise exception 'Onbekende betaalmethode';
    end if;
  end if;

  return public.bon(v_id);
end $$;

-- ─────────────────────────── Rekeningen ───────────────────────────

create function public.rekening_maken(p_naam text) returns bigint
language plpgsql security definer set search_path = '' as $$
declare v bigint;
begin
  perform public._eis('medewerker');
  insert into public.rekeningen (naam, door) values (trim(p_naam), auth.uid()) returning id into v;
  perform public._log('rekening_maken', jsonb_build_object('rekening', v, 'naam', trim(p_naam)));
  return v;
end $$;

create function public.rekening_toevoegen(p_rekening_id bigint, p_regels jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare v_rek public.rekeningen; v_n int;
begin
  perform public._eis('medewerker');
  select * into v_rek from public.rekeningen where id = p_rekening_id for update;
  if not found or not v_rek.open then raise exception 'Deze rekening is al afgerekend of bestaat niet'; end if;
  if jsonb_typeof(p_regels) is distinct from 'array' or jsonb_array_length(p_regels) = 0
     or exists (select 1 from jsonb_array_elements(p_regels) e where coalesce((e ->> 'aantal')::int, 0) not between 1 and 999) then
    raise exception 'Ongeldige bestelling';
  end if;
  with r as (
    select (e ->> 'product_id')::bigint as pid, sum((e ->> 'aantal')::int) as aantal, min(ord) as ord
    from jsonb_array_elements(p_regels) with ordinality as x(e, ord) group by 1
  ), ins as (
    insert into public.rekening_regels (rekening_id, product_id, naam, prijs_cent, aantal, door)
    select p_rekening_id, p.id, p.naam, p.prijs_cent, r.aantal, auth.uid()
    from r join public.producten p on p.id = r.pid and p.actief and not p.verwijderd
    order by r.ord
    returning product_id, aantal
  ), u as (
    update public.producten p set voorraad = p.voorraad - ins.aantal from ins
    where p.id = ins.product_id and p.voorraad_bijhouden returning p.id, ins.aantal
  ), m as (
    insert into public.voorraad_mutaties (product_id, aantal, reden, door)
    select id, -aantal, 'rekening', auth.uid() from u
  )
  select count(*) into v_n from ins;
  if v_n <> (select count(distinct e ->> 'product_id') from jsonb_array_elements(p_regels) e) then
    raise exception 'Een product in de bestelling is niet meer beschikbaar';
  end if;
end $$;

create function public.rekening_regel_verwijderen(p_regel_id bigint) returns void
language plpgsql security definer set search_path = '' as $$
declare r public.rekening_regels;
begin
  perform public._eis('medewerker');
  select rr.* into r from public.rekening_regels rr join public.rekeningen k on k.id = rr.rekening_id
  where rr.id = p_regel_id and k.open for update of rr;
  if not found then raise exception 'Deze regel bestaat niet meer'; end if;
  delete from public.rekening_regels where id = p_regel_id;
  update public.producten set voorraad = voorraad + r.aantal where id = r.product_id and voorraad_bijhouden;
  if found then
    insert into public.voorraad_mutaties (product_id, aantal, reden, door) values (r.product_id, r.aantal, 'correctie', auth.uid());
  end if;
  perform public._log('rekening_regel_verwijderen', jsonb_build_object('rekening', r.rekening_id, 'naam', r.naam, 'aantal', r.aantal, 'prijs_cent', r.prijs_cent));
end $$;

create function public.rekening_verwijderen(p_rekening_id bigint) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform public._eis('medewerker');
  if exists (select 1 from public.rekening_regels where rekening_id = p_rekening_id) then
    raise exception 'Alleen een lege rekening kan worden verwijderd';
  end if;
  delete from public.rekeningen where id = p_rekening_id and open;
  perform public._log('rekening_verwijderen', jsonb_build_object('rekening', p_rekening_id));
end $$;

-- ──────────────────────────── Annuleren ────────────────────────────

-- Beheerders altijd; medewerkers alleen hun eigen bon binnen 15 minuten.
create function public.verkoop_annuleren(p_verkoop_id bigint) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v public.verkopen;
begin
  perform public._eis('medewerker');
  select * into v from public.verkopen where id = p_verkoop_id for update;
  if not found then raise exception 'Bon niet gevonden'; end if;
  if v.geannuleerd then raise exception 'Deze bon is al geannuleerd'; end if;
  if not public.is_beheerder() and (v.door is distinct from auth.uid() or v.ts < now() - interval '15 minutes') then
    raise exception 'Alleen een beheerder kan deze bon nog annuleren' using errcode = '42501';
  end if;

  update public.verkopen set geannuleerd = true, geannuleerd_door = auth.uid(), geannuleerd_ts = now() where id = v.id;

  with r as (select product_id, sum(aantal) as a from public.verkoop_regels where verkoop_id = v.id group by 1),
  u as (update public.producten p set voorraad = p.voorraad + r.a from r
        where p.id = r.product_id and p.voorraad_bijhouden returning p.id, r.a)
  insert into public.voorraad_mutaties (product_id, aantal, reden, verkoop_id, door)
  select id, a, 'annulering', v.id, auth.uid() from u;

  with b as (select kaart_id, sum(bedrag_cent) as a from public.betalingen
             where verkoop_id = v.id and methode = 'kaart' and bedrag_cent > 0 group by 1),
  u as (update public.kaarten k set saldo_cent = k.saldo_cent + b.a from b where k.id = b.kaart_id returning k.id, b.a)
  insert into public.kaart_mutaties (kaart_id, bedrag_cent, soort, verkoop_id, door)
  select id, a, 'annulering', v.id, auth.uid() from u;

  perform public._log('verkoop_annuleren', jsonb_build_object('bon', v.bonnummer, 'totaal_cent', v.totaal_cent));
  return public.bon(v.id);
end $$;

-- ───────────────────────────── Kaarten ─────────────────────────────

create function public.kaarten_maken(p_aantal int) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare res jsonb;
begin
  perform public._eis('beheerder');
  if p_aantal not between 1 and 200 then raise exception 'Kies tussen 1 en 200 kaarten'; end if;
  with n as (
    insert into public.kaarten (code) select public._kaartcode() from generate_series(1, p_aantal)
    returning nummer, code
  ) select jsonb_agg(jsonb_build_object('nummer', nummer, 'code', code) order by nummer) into res from n;
  perform public._log('kaarten_maken', jsonb_build_object('aantal', p_aantal));
  return res;
end $$;

-- Codes opnieuw opvragen om kaarten (opnieuw) te printen.
create function public.kaart_codes(p_nummers int[]) returns jsonb
language sql security definer set search_path = '' as $$
  select case when public.is_beheerder() then
    coalesce((select jsonb_agg(jsonb_build_object('nummer', nummer, 'code', code) order by nummer)
              from public.kaarten where nummer = any(p_nummers)), '[]')
  end
$$;

-- Opzoeken op QR-code, kaartcode of kaartnummer (alleen om in te zien/op te waarderen).
create function public.kaart_info(p_zoek text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare k public.kaarten;
begin
  perform public._eis('medewerker');
  select * into k from public.kaarten where id = public._zoek_kaart(p_zoek, false);
  return jsonb_build_object('id', k.id, 'nummer', k.nummer, 'saldo_cent', k.saldo_cent, 'geblokkeerd', k.geblokkeerd,
    'betaalcode', length(regexp_replace(coalesce(p_zoek, ''), '[^A-Za-z0-9]', '', 'g')) = 8);
end $$;

create function public.kaart_opwaarderen(p_kaart_id bigint, p_bedrag_cent int, p_methode text) returns int
language plpgsql security definer set search_path = '' as $$
declare k public.kaarten; v_dienst bigint;
begin
  perform public._eis('medewerker');
  v_dienst := public._open_dienst();
  if p_bedrag_cent not between 1 and 50000 then raise exception 'Kies een bedrag tussen € 0,01 en € 500'; end if;
  if p_methode not in ('contant', 'pin') then raise exception 'Onbekende betaalmethode'; end if;
  select * into k from public.kaarten where id = p_kaart_id for update;
  if not found then raise exception 'Kaart niet gevonden'; end if;
  if k.geblokkeerd then raise exception 'Kaart % is geblokkeerd', k.nummer; end if;
  update public.kaarten set saldo_cent = saldo_cent + p_bedrag_cent where id = k.id;
  insert into public.kaart_mutaties (kaart_id, bedrag_cent, soort, methode, dienst_id, door)
  values (k.id, p_bedrag_cent, 'opwaardering', p_methode, v_dienst, auth.uid());
  return k.saldo_cent + p_bedrag_cent;
end $$;

-- Blokkeren mag iedereen (kaart kwijt), deblokkeren alleen een beheerder.
create function public.kaart_blokkeren(p_kaart_id bigint, p_blok boolean) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform public._eis(case when p_blok then 'medewerker' else 'beheerder' end);
  update public.kaarten set geblokkeerd = p_blok where id = p_kaart_id;
  perform public._log(case when p_blok then 'kaart_blokkeren' else 'kaart_deblokkeren' end,
    jsonb_build_object('kaart', (select nummer from public.kaarten where id = p_kaart_id)));
end $$;

-- Tegoed van een kwijtgeraakte kaart naar een nieuwe zetten; de oude wordt geblokkeerd.
create function public.kaart_overzetten(p_van bigint, p_naar text) returns int
language plpgsql security definer set search_path = '' as $$
declare v public.kaarten; n public.kaarten;
begin
  perform public._eis('beheerder');
  select * into v from public.kaarten where id = p_van for update;
  select * into n from public.kaarten where id = public._zoek_kaart(p_naar, false) for update;
  if v.id = n.id then raise exception 'Kies een andere kaart'; end if;
  if n.geblokkeerd then raise exception 'Kaart % is geblokkeerd', n.nummer; end if;
  update public.kaarten set saldo_cent = 0, geblokkeerd = true where id = v.id;
  update public.kaarten set saldo_cent = saldo_cent + v.saldo_cent where id = n.id;
  insert into public.kaart_mutaties (kaart_id, bedrag_cent, soort, door) values
    (v.id, -v.saldo_cent, 'overzetting', auth.uid()), (n.id, v.saldo_cent, 'overzetting', auth.uid());
  perform public._log('kaart_overzetten', jsonb_build_object('van', v.nummer, 'naar', n.nummer, 'bedrag_cent', v.saldo_cent));
  return n.saldo_cent + v.saldo_cent;
end $$;

-- Laatste bewegingen van één kaart (alleen beheerder).
create function public.kaart_historie(p_kaart_id bigint) returns jsonb
language sql security definer set search_path = '' as $$
  select case when public.is_beheerder() then coalesce((
    select jsonb_agg(x order by x.ts desc) from (
      select m.ts, m.bedrag_cent, m.soort, m.methode, v.bonnummer, p.naam as door_naam
      from public.kaart_mutaties m
      left join public.verkopen v on v.id = m.verkoop_id
      left join public.profielen p on p.id = m.door
      where m.kaart_id = p_kaart_id order by m.ts desc limit 50) x), '[]') end
$$;

-- ──────────────────────── Producten & voorraad ────────────────────────

create function public.product_opslaan(p jsonb) returns bigint
language plpgsql security definer set search_path = '' as $$
declare v bigint := (p ->> 'id')::bigint; oud public.producten;
begin
  perform public._eis('beheerder');
  if v is null then
    insert into public.producten (naam, prijs_cent, categorie, actief, volgorde, voorraad_bijhouden, voorraad_min)
    values (trim(p ->> 'naam'), (p ->> 'prijs_cent')::int, coalesce(nullif(trim(p ->> 'categorie'), ''), 'Overig'),
            coalesce((p ->> 'actief')::boolean, true), coalesce((p ->> 'volgorde')::int, 0),
            coalesce((p ->> 'voorraad_bijhouden')::boolean, false), coalesce((p ->> 'voorraad_min')::int, 0))
    returning id into v;
    perform public._log('product_nieuw', p);
  else
    select * into oud from public.producten where id = v and not verwijderd for update;
    if not found then raise exception 'Product niet gevonden'; end if;
    update public.producten set
      naam = trim(p ->> 'naam'), prijs_cent = (p ->> 'prijs_cent')::int,
      categorie = coalesce(nullif(trim(p ->> 'categorie'), ''), 'Overig'),
      actief = coalesce((p ->> 'actief')::boolean, true), volgorde = coalesce((p ->> 'volgorde')::int, oud.volgorde),
      voorraad_bijhouden = coalesce((p ->> 'voorraad_bijhouden')::boolean, false),
      voorraad_min = coalesce((p ->> 'voorraad_min')::int, 0)
    where id = v;
    if oud.prijs_cent <> (p ->> 'prijs_cent')::int then
      perform public._log('prijs_wijzigen', jsonb_build_object('product', oud.naam, 'van', oud.prijs_cent, 'naar', (p ->> 'prijs_cent')::int));
    end if;
  end if;
  return v;
end $$;

-- Producten worden niet echt gewist, zodat oude bonnen en rapporten blijven kloppen.
create function public.product_verwijderen(p_id bigint) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform public._eis('beheerder');
  update public.producten set verwijderd = true, actief = false where id = p_id;
  perform public._log('product_verwijderen', jsonb_build_object('product', (select naam from public.producten where id = p_id)));
end $$;

-- 'levering': p_aantal erbij. 'telling': de voorraad wordt p_aantal (na tellen).
create function public.voorraad_boeken(p_product_id bigint, p_aantal int, p_soort text) returns int
language plpgsql security definer set search_path = '' as $$
declare p public.producten; d int;
begin
  perform public._eis('beheerder');
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
  return p.voorraad + d;
end $$;

-- ─────────────────────────── Diensten (kasopmaak) ───────────────────────────

create function public.dienst_openen(p_beginsaldo_cent int) returns bigint
language plpgsql security definer set search_path = '' as $$
declare v bigint;
begin
  perform public._eis('medewerker');
  if p_beginsaldo_cent not between 0 and 1000000 then raise exception 'Ongeldig bedrag'; end if;
  if exists (select 1 from public.diensten where gesloten_ts is null) then raise exception 'De kassa is al open'; end if;
  insert into public.diensten (geopend_door, beginsaldo_cent) values (auth.uid(), p_beginsaldo_cent) returning id into v;
  perform public._log('dienst_openen', jsonb_build_object('dienst', v, 'beginsaldo_cent', p_beginsaldo_cent));
  return v;
end $$;

create function public._dienst_cijfers(p_dienst bigint) returns jsonb
language sql stable security definer set search_path = '' as $$
  with b as (
    select b.methode, sum(b.bedrag_cent) as s from public.betalingen b
    join public.verkopen v on v.id = b.verkoop_id
    where v.dienst_id = p_dienst and not v.geannuleerd group by 1
  ), o as (
    select methode, sum(bedrag_cent) as s from public.kaart_mutaties
    where dienst_id = p_dienst and soort = 'opwaardering' group by 1
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
    'opwaardering_contant_cent', coalesce((select s from o where methode = 'contant'), 0),
    'opwaardering_pin_cent', coalesce((select s from o where methode = 'pin'), 0),
    'verwacht_cent', d.beginsaldo_cent + coalesce((select s from b where methode = 'contant'), 0)
                     + coalesce((select s from o where methode = 'contant'), 0),
    'geteld_cent', d.geteld_cent, 'opmerking', d.opmerking)
  from d
$$;

create function public.dienst_overzicht() returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  perform public._eis('medewerker');
  return public._dienst_cijfers((select id from public.diensten where gesloten_ts is null));
end $$;

create function public.dienst_sluiten(p_geteld_cent int, p_opmerking text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v bigint; c jsonb;
begin
  perform public._eis('medewerker');
  select id into v from public.diensten where gesloten_ts is null for update;
  if v is null then raise exception 'De kassa is niet open'; end if;
  if p_geteld_cent not between 0 and 10000000 then raise exception 'Ongeldig bedrag'; end if;
  c := public._dienst_cijfers(v);
  update public.diensten set gesloten_ts = now(), gesloten_door = auth.uid(), geteld_cent = p_geteld_cent,
    verwacht_cent = (c ->> 'verwacht_cent')::int, opmerking = nullif(trim(p_opmerking), '')
  where id = v;
  perform public._log('dienst_sluiten', jsonb_build_object('dienst', v, 'verwacht_cent', c -> 'verwacht_cent',
    'geteld_cent', p_geteld_cent, 'verschil_cent', p_geteld_cent - (c ->> 'verwacht_cent')::int));
  return public._dienst_cijfers(v);
end $$;

-- ──────────────────────────── Beheer ────────────────────────────

create function public.gebruiker_bijwerken(p_id uuid, p_rol text, p_actief boolean) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform public._eis('beheerder');
  if p_rol not in ('wacht', 'medewerker', 'beheerder') then raise exception 'Onbekende rol'; end if;
  lock table public.profielen in share row exclusive mode;
  update public.profielen set rol = p_rol, actief = p_actief where id = p_id;
  if not exists (select 1 from public.profielen where rol = 'beheerder' and actief) then
    raise exception 'Er moet minstens één actieve beheerder overblijven';
  end if;
  perform public._log('gebruiker_bijwerken', jsonb_build_object('gebruiker', (select naam from public.profielen where id = p_id), 'rol', p_rol, 'actief', p_actief));
end $$;

create function public.mijn_naam_wijzigen(p_naam text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null or length(trim(p_naam)) not between 1 and 40 then raise exception 'Ongeldige naam'; end if;
  update public.profielen set naam = trim(p_naam) where id = auth.uid();
end $$;

create function public.instellingen_opslaan(p_naam text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform public._eis('beheerder');
  if length(trim(p_naam)) not between 1 and 60 then raise exception 'Ongeldige naam'; end if;
  update public.instellingen set naam = trim(p_naam);
end $$;

-- ──────────────────────────── Rapport ────────────────────────────

create function public.rapport(p_van timestamptz, p_tot timestamptz) returns jsonb
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
        (select (ts at time zone 'Europe/Amsterdam')::date as dag, count(*) as bonnen, sum(totaal_cent) as bedrag_cent from ok group by 1) x), '[]'),
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

-- ──────────────────────────── Wachtwoorden ────────────────────────────

-- Een beheerder kan het wachtwoord van een medewerker opnieuw instellen
-- (er is geen e-mail nodig, dus dit werkt ook op een lokale server).
create function public.wachtwoord_instellen(p_id uuid, p_wachtwoord text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform public._eis('beheerder');
  if length(coalesce(p_wachtwoord, '')) < 8 then raise exception 'Kies een wachtwoord van minstens 8 tekens'; end if;
  update auth.users set encrypted_password = extensions.crypt(p_wachtwoord, extensions.gen_salt('bf')), updated_at = now()
  where id = p_id;
  if not found then raise exception 'Gebruiker niet gevonden'; end if;
  perform public._log('wachtwoord_instellen', jsonb_build_object('gebruiker', (select naam from public.profielen where id = p_id)));
end $$;

-- ──────────────────────────── Wijzigingsteller ────────────────────────────

-- Elke wijziging hoogt een teller op. Apparaten vragen die teller elke paar
-- seconden op en laden alleen opnieuw als hij veranderd is.
create sequence public.wijziging;

create function public._wijziging() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform nextval('public.wijziging');
  return null;
end $$;

create trigger wijziging after insert or update or delete on public.producten for each statement execute function public._wijziging();
create trigger wijziging after insert or update or delete on public.rekeningen for each statement execute function public._wijziging();
create trigger wijziging after insert or update or delete on public.rekening_regels for each statement execute function public._wijziging();
create trigger wijziging after insert or update or delete on public.verkopen for each statement execute function public._wijziging();
create trigger wijziging after insert or update or delete on public.diensten for each statement execute function public._wijziging();
create trigger wijziging after insert or update or delete on public.kaarten for each statement execute function public._wijziging();
create trigger wijziging after insert or update or delete on public.instellingen for each statement execute function public._wijziging();
create trigger wijziging after insert or update or delete on public.profielen for each statement execute function public._wijziging();

create function public.versie() returns bigint
language sql stable security definer set search_path = '' as $$
  select case when auth.uid() is not null then (select last_value from public.wijziging) end
$$;

-- ──────────────────────────── Leesrechten ────────────────────────────

alter table public.profielen         enable row level security;
alter table public.instellingen      enable row level security;
alter table public.producten         enable row level security;
alter table public.diensten          enable row level security;
alter table public.rekeningen        enable row level security;
alter table public.rekening_regels   enable row level security;
alter table public.kaarten           enable row level security;
alter table public.verkopen          enable row level security;
alter table public.verkoop_regels    enable row level security;
alter table public.betalingen        enable row level security;
alter table public.kaart_mutaties    enable row level security;
alter table public.voorraad_mutaties enable row level security;
alter table public.logboek           enable row level security;

create policy lezen on public.profielen for select to authenticated using (id = auth.uid() or public.is_medewerker());
create policy lezen on public.instellingen for select to authenticated using (public.is_medewerker());
create policy lezen on public.producten for select to authenticated using (public.is_medewerker());
create policy lezen on public.diensten for select to authenticated using (public.is_medewerker());
create policy lezen on public.rekeningen for select to authenticated using (public.is_medewerker());
create policy lezen on public.rekening_regels for select to authenticated using (public.is_medewerker());
create policy lezen on public.kaarten for select to authenticated using (public.is_medewerker());
-- Medewerkers zien alleen de bonnen van het afgelopen etmaal; beheerders alles.
create policy lezen on public.verkopen for select to authenticated
  using (public.is_beheerder() or (public.is_medewerker() and ts > now() - interval '24 hours'));
create policy lezen on public.verkoop_regels for select to authenticated
  using (exists (select 1 from public.verkopen v where v.id = verkoop_id));
create policy lezen on public.betalingen for select to authenticated
  using (exists (select 1 from public.verkopen v where v.id = verkoop_id));
create policy lezen on public.kaart_mutaties for select to authenticated using (public.is_beheerder());
create policy lezen on public.voorraad_mutaties for select to authenticated using (public.is_beheerder());
create policy lezen on public.logboek for select to authenticated using (public.is_beheerder());

-- Niemand schrijft rechtstreeks in de tabellen; alleen via de functies hierboven.
revoke all on all tables in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
grant select on public.profielen, public.instellingen, public.producten, public.diensten, public.rekeningen,
  public.rekening_regels, public.verkopen, public.verkoop_regels, public.betalingen, public.kaart_mutaties,
  public.voorraad_mutaties, public.logboek to authenticated;
-- De geheime kaartcode is niet leesbaar; alleen een beheerder kan hem via kaart_codes() opvragen.
grant select (id, nummer, saldo_cent, geblokkeerd, aangemaakt) on public.kaarten to authenticated;

revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function
  public.mijn_rol(), public.is_medewerker(), public.is_beheerder(), public.bon(bigint),
  public.afrekenen(jsonb, jsonb, bigint),
  public.rekening_maken(text), public.rekening_toevoegen(bigint, jsonb),
  public.rekening_regel_verwijderen(bigint), public.rekening_verwijderen(bigint),
  public.verkoop_annuleren(bigint),
  public.kaarten_maken(int), public.kaart_codes(int[]), public.kaart_info(text),
  public.kaart_opwaarderen(bigint, int, text), public.kaart_blokkeren(bigint, boolean),
  public.kaart_overzetten(bigint, text), public.kaart_historie(bigint),
  public.product_opslaan(jsonb), public.product_verwijderen(bigint), public.voorraad_boeken(bigint, int, text),
  public.dienst_openen(int), public.dienst_overzicht(), public.dienst_sluiten(int, text),
  public.gebruiker_bijwerken(uuid, text, boolean), public.mijn_naam_wijzigen(text),
  public.instellingen_opslaan(text), public.rapport(timestamptz, timestamptz),
  public.wachtwoord_instellen(uuid, text), public.versie()
to authenticated;

-- Ook voor functies die later worden toegevoegd: standaard niet uitvoerbaar.
alter default privileges in schema public revoke execute on functions from public, anon, authenticated;

-- ──────────────────────────── Startmenu ────────────────────────────

insert into public.producten (naam, prijs_cent, categorie, volgorde) values
  ('Tosti kaas', 200, 'Eten', 1), ('Tosti ham-kaas', 250, 'Eten', 2), ('Bapao', 200, 'Eten', 3),
  ('Frisdrank', 150, 'Drinken', 1), ('Bier', 200, 'Drinken', 2), ('Wijn', 250, 'Drinken', 3),
  ('Koffie', 100, 'Drinken', 4), ('Chips', 100, 'Snacks', 1);
