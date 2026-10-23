-- Kaarten verwijderen en opruimen. Een kaart wordt nooit echt gewist (oude bonnen,
-- opwaarderingen en kastellingen verwijzen ernaar), maar krijgt de status
-- verwijderd: weg uit de lijst, scannen en betalen kan niet meer, het nummer
-- komt niet opnieuw voor. Tegoed op een verwijderde kaart vervalt en wordt
-- geboekt (soort 'vervallen'), zodat het in het rapport staat.
-- Opruimen: in één keer alle kaarten zonder tegoed die 12 maanden niet zijn
-- gebruikt. Kaarten mét tegoed gaan nooit vanzelf weg.

alter table public.kaarten
  add column verwijderd_ts timestamptz,
  add column laatst_gebruikt timestamptz not null default now();
update public.kaarten k set laatst_gebruikt = greatest(k.aangemaakt, (select max(ts) from public.kaart_mutaties m where m.kaart_id = k.id));
grant select (verwijderd_ts, laatst_gebruikt) on public.kaarten to authenticated;

alter table public.kaart_mutaties drop constraint kaart_mutaties_soort_check;
alter table public.kaart_mutaties add constraint kaart_mutaties_soort_check
  check (soort in ('opwaardering', 'betaling', 'annulering', 'overzetting', 'vervallen'));

-- Laatst gebruikt = de laatste mutatie (of het aanmaken), ook als een tijd later wordt aangepast.
create function public._kaart_gebruikt() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  update public.kaarten k set laatst_gebruikt = greatest(k.aangemaakt, (select max(ts) from public.kaart_mutaties m where m.kaart_id = k.id))
  where k.id = new.kaart_id;
  return null;
end $$;
create trigger gebruikt after insert or update of ts on public.kaart_mutaties for each row execute function public._kaart_gebruikt();

-- Een verwijderde kaart is niet meer te vinden om mee te betalen, op te waarderen of in te zien.
create or replace function public._zoek_kaart(p_zoek text, p_alleen_code boolean) returns bigint
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
  if exists (select 1 from public.kaarten where id = v and verwijderd_ts is not null) then
    raise exception 'Kaart % is verwijderd', (select nummer from public.kaarten where id = v);
  end if;
  return v;
end $$;

create or replace function public._kaart_opwaarderen(p_kaart_id bigint, p_bedrag_cent int, p_methode text) returns int
language plpgsql security definer set search_path = '' as $$
declare k public.kaarten; v_dienst bigint;
begin
  perform public._eis('medewerker');
  v_dienst := public._open_dienst();
  if p_bedrag_cent not between 1 and 50000 then raise exception 'Kies een bedrag tussen € 0,01 en € 500'; end if;
  if p_methode not in ('contant', 'pin') then raise exception 'Onbekende betaalmethode'; end if;
  select * into k from public.kaarten where id = p_kaart_id for update;
  if not found then raise exception 'Kaart niet gevonden'; end if;
  if k.verwijderd_ts is not null then raise exception 'Kaart % is verwijderd', k.nummer; end if;
  if k.geblokkeerd then raise exception 'Kaart % is geblokkeerd', k.nummer; end if;
  update public.kaarten set saldo_cent = saldo_cent + p_bedrag_cent where id = k.id;
  insert into public.kaart_mutaties (kaart_id, bedrag_cent, soort, methode, dienst_id, door)
  values (k.id, p_bedrag_cent, 'opwaardering', p_methode, v_dienst, auth.uid());
  return k.saldo_cent + p_bedrag_cent;
end $$;

create or replace function public.kaart_overzetten(p_van bigint, p_naar text) returns int
language plpgsql security definer set search_path = '' as $$
declare v public.kaarten; n public.kaarten;
begin
  perform public._eis('beheerder');
  select * into v from public.kaarten where id = p_van for update;
  if v.verwijderd_ts is not null then raise exception 'Kaart % is verwijderd', v.nummer; end if;
  select * into n from public.kaarten where id = public._zoek_kaart(p_naar, false) for update;
  if v.id = n.id then raise exception 'Kies een andere kaart'; end if;
  if n.geblokkeerd then raise exception 'Kaart % is geblokkeerd', n.nummer; end if;
  update public.kaarten set saldo_cent = 0, geblokkeerd = true where id = v.id;
  update public.kaarten set saldo_cent = saldo_cent + v.saldo_cent, naam = coalesce(naam, v.naam) where id = n.id;
  insert into public.kaart_mutaties (kaart_id, bedrag_cent, soort, door) values
    (v.id, -v.saldo_cent, 'overzetting', auth.uid()), (n.id, v.saldo_cent, 'overzetting', auth.uid());
  perform public._log('kaart_overzetten', jsonb_build_object('van', v.nummer, 'naar', n.nummer, 'bedrag_cent', v.saldo_cent));
  return n.saldo_cent + v.saldo_cent;
end $$;

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
        select m.ts, m.bedrag_cent, m.soort from public.kaart_mutaties m
        where m.kaart_id = k.id order by m.ts desc limit 10) x), '[]'));
end $$;

-- Eén kaart verwijderen. p_saldo_cent = het saldo dat de beheerder zag: is het
-- intussen veranderd (er werd net mee betaald), dan niet.
create function public.kaart_verwijderen(p_kaart_id bigint, p_saldo_cent int) returns void
language plpgsql security definer set search_path = '' as $$
declare k public.kaarten;
begin
  perform public._eis('beheerder');
  select * into k from public.kaarten where id = p_kaart_id for update;
  if not found then raise exception 'Kaart niet gevonden'; end if;
  if k.verwijderd_ts is not null then raise exception 'Kaart % is al verwijderd', k.nummer; end if;
  if k.saldo_cent <> coalesce(p_saldo_cent, -1) then
    raise exception 'Het saldo van kaart % is intussen veranderd. Kijk opnieuw.', k.nummer;
  end if;
  if k.saldo_cent > 0 then
    insert into public.kaart_mutaties (kaart_id, bedrag_cent, soort, dienst_id, door)
    values (k.id, -k.saldo_cent, 'vervallen', (select id from public.diensten where gesloten_ts is null limit 1), auth.uid());
  end if;
  update public.kaarten set saldo_cent = 0, verwijderd_ts = now() where id = k.id;
  perform public._log('kaart_verwijderen', jsonb_build_object('kaart', k.nummer, 'naam', k.naam, 'vervallen_cent', k.saldo_cent));
end $$;

-- Wat opruimen zou doen: kaarten die 12 maanden niet zijn gebruikt.
create function public.kaarten_opruimen_overzicht() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  perform public._eis('beheerder');
  return jsonb_build_object(
    'leeg', (select count(*) from public.kaarten
             where verwijderd_ts is null and saldo_cent = 0 and laatst_gebruikt < now() - interval '12 months'),
    'met_tegoed', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'nummer', nummer, 'naam', naam,
                              'saldo_cent', saldo_cent, 'laatst_gebruikt', laatst_gebruikt) order by nummer)
                            from public.kaarten
                            where verwijderd_ts is null and saldo_cent > 0 and laatst_gebruikt < now() - interval '12 months'), '[]'));
end $$;

-- Opruimen: alle kaarten zonder tegoed die 12 maanden niet zijn gebruikt.
create function public.kaarten_opruimen() returns int
language plpgsql security definer set search_path = '' as $$
declare n int;
begin
  perform public._eis('beheerder');
  update public.kaarten set verwijderd_ts = now()
  where verwijderd_ts is null and saldo_cent = 0 and laatst_gebruikt < now() - interval '12 months';
  get diagnostics n = row_count;
  if n > 0 then perform public._log('kaarten_opruimen', jsonb_build_object('aantal', n)); end if;
  return n;
end $$;

revoke execute on function public.kaart_verwijderen(bigint, int), public.kaarten_opruimen_overzicht(), public.kaarten_opruimen()
  from public, anon;
grant execute on function public.kaart_verwijderen(bigint, int), public.kaarten_opruimen_overzicht(), public.kaarten_opruimen()
  to authenticated;
revoke execute on function public._kaart_gebruikt() from public, anon, authenticated;

-- Rapport: met het vervallen tegoed.
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
