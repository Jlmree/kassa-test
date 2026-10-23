-- Beveiliging na een rondgang:
-- 1. Te veel mislukte pogingen worden geblokkeerd: inloggen (per account) en
--    codes op de saldo-pagina (per telefoon en voor iedereen samen).
-- 2. Leden zien hun eigen streeplijst met een eigen geheime code.
-- 3. Controle-overzicht voor de beheerder: annuleringen, kasverschillen en
--    opwaarderingen per medewerker.

-- ──────────── 1. Pogingen ────────────
create table public.pogingen (
  soort text not null,          -- 'login' of 'code'
  wie   text not null,          -- account-id of IP-adres
  ts    timestamptz not null default now()
);
create index on public.pogingen (soort, wie, ts);
alter table public.pogingen enable row level security;  -- alleen via de functies hieronder

-- Het adres van de telefoon (de webserver zet het in X-Forwarded-For; niet te vervalsen).
create function public._klant_ip() returns text
language sql stable set search_path = '' as $$
  select coalesce(trim(split_part(
    nullif(current_setting('request.headers', true), '')::json ->> 'x-forwarded-for', ',', 1)), 'onbekend')
$$;

create function public._te_veel(p_soort text, p_wie text, p_max int, p_periode interval) returns boolean
language sql stable security definer set search_path = '' as $$
  select count(*) >= p_max from public.pogingen
  where soort = p_soort and (p_wie is null or wie = p_wie) and ts > now() - p_periode
$$;

create function public._mislukt(p_soort text, p_wie text) returns void
language sql security definer set search_path = '' as $$
  delete from public.pogingen where ts < now() - interval '1 day';
  insert into public.pogingen (soort, wie) values (p_soort, p_wie);
$$;
revoke execute on function public._klant_ip(), public._te_veel(text, text, int, interval), public._mislukt(text, text)
  from public, anon, authenticated;

-- Wachtwoordcontrole van het inlogsysteem (Supabase Auth roept dit bij elke poging aan,
-- zie GOTRUE_HOOK_PASSWORD_VERIFICATION_ATTEMPT_* in de installatie). Na 10 verkeerde
-- wachtwoorden in 10 minuten is dat account 10 minuten op slot, ook met het goede wachtwoord.
create function public.hook_password_verification_attempt(event jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare u text := event ->> 'user_id';
begin
  if public._te_veel('login', u, 10, interval '10 minutes') then
    return jsonb_build_object('decision', 'reject', 'should_logout_user', false,
      'message', 'Te veel verkeerde wachtwoorden. Probeer het over 10 minuten opnieuw, of vraag een beheerder om een nieuw wachtwoord.');
  end if;
  if not coalesce((event ->> 'valid')::boolean, false) then perform public._mislukt('login', u); end if;
  return jsonb_build_object('decision', 'continue');
end $$;
revoke execute on function public.hook_password_verification_attempt(jsonb) from public, anon, authenticated;
-- Het inlogsysteem gebruikt de rol supabase_auth_admin (die bestaat niet in de proefversie).
do $$ begin
  if exists (select from pg_roles where rolname = 'supabase_auth_admin') then
    grant usage on schema public to supabase_auth_admin;
    grant execute on function public.hook_password_verification_attempt(jsonb) to supabase_auth_admin;
  end if;
end $$;

-- Een beheerder die een nieuw wachtwoord instelt, haalt het account ook van slot.
create or replace function public.wachtwoord_instellen(p_id uuid, p_wachtwoord text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform public._eis('beheerder');
  if length(coalesce(p_wachtwoord, '')) < 8 then raise exception 'Kies een wachtwoord van minstens 8 tekens'; end if;
  update auth.users set encrypted_password = extensions.crypt(p_wachtwoord, extensions.gen_salt('bf')), updated_at = now()
  where id = p_id;
  if not found then raise exception 'Gebruiker niet gevonden'; end if;
  delete from public.pogingen where soort = 'login' and wie = p_id::text;
  perform public._log('wachtwoord_instellen', jsonb_build_object('gebruiker', (select naam from public.profielen where id = p_id)));
end $$;

-- Codes op de saldo-pagina: 10 verkeerde per telefoon, of 100 voor iedereen samen, per 10 minuten.
-- Een fout gaat terug als {"fout": "..."} in plaats van een foutmelding, zodat de poging bewaard blijft.
create function public._code_geblokkeerd() returns boolean
language sql stable security definer set search_path = '' as $$
  select public._te_veel('code', public._klant_ip(), 10, interval '10 minutes')
      or public._te_veel('code', null, 100, interval '10 minutes')
$$;
revoke execute on function public._code_geblokkeerd() from public, anon, authenticated;

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
  return jsonb_build_object(
    'nummer', k.nummer, 'naam', k.naam, 'saldo_cent', k.saldo_cent, 'geblokkeerd', k.geblokkeerd,
    'winkel', (select naam from public.instellingen where id = 1),
    'historie', coalesce((
      select jsonb_agg(x order by x.ts desc) from (
        select m.ts, m.bedrag_cent, m.soort from public.kaart_mutaties m
        where m.kaart_id = k.id order by m.ts desc limit 10) x), '[]'));
end $$;

-- ──────────── 2. Leden zien hun eigen streeplijst ────────────
alter table public.leden add column code text not null unique default public._kaartcode();

-- De code van een lid, om de QR-code te laten zien of te printen.
create function public.lid_code(p_lid bigint) returns text
language plpgsql stable security definer set search_path = '' as $$
begin
  perform public._eis('medewerker');
  return (select code from public.leden where id = p_lid);
end $$;

-- Nieuwe code (de oude werkt dan niet meer), bijvoorbeeld als iemand anders hem heeft.
create function public.lid_nieuwe_code(p_lid bigint) returns text
language plpgsql security definer set search_path = '' as $$
declare c text;
begin
  perform public._eis('beheerder');
  update public.leden set code = public._kaartcode() where id = p_lid returning code into c;
  if c is null then raise exception 'Lid niet gevonden'; end if;
  perform public._log('lid_nieuwe_code', jsonb_build_object('naam', (select naam from public.leden where id = p_lid)));
  return c;
end $$;

-- Zonder inloggen: de eigen streeplijst, met wie er heeft ingeschonken.
create function public.lid_overzicht(p_code text) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare
  z text := upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g'));
  l public.leden;
begin
  if public._code_geblokkeerd() then
    return jsonb_build_object('fout', 'Te veel verkeerde codes geprobeerd. Probeer het over 10 minuten opnieuw.');
  end if;
  select * into l from public.leden where length(z) = 8 and replace(code, '-', '') = z;
  if not found then
    perform public._mislukt('code', public._klant_ip());
    return jsonb_build_object('fout', 'Deze code is niet gevonden. Vraag aan de bar om je eigen QR-code.');
  end if;
  return jsonb_build_object(
    'naam', l.naam, 'open_cent', public._lid_open(l.id), 'winkel', (select naam from public.instellingen where id = 1),
    'maand_cent', (select coalesce(sum(b.bedrag_cent), 0) from public.betalingen b join public.verkopen v on v.id = b.verkoop_id
      where b.lid_id = l.id and b.methode = 'lat' and not v.geannuleerd
        and v.ts >= date_trunc('month', now() at time zone 'Europe/Amsterdam') at time zone 'Europe/Amsterdam'),
    'regels', coalesce((select jsonb_agg(x order by x.ts desc) from (
      (select v.ts, 'streep' as soort, b.bedrag_cent, v.bonnummer, v.door_naam,
         (select string_agg(r.aantal || '× ' || r.naam, ', ' order by r.id) from public.verkoop_regels r where r.verkoop_id = v.id) as wat
       from public.betalingen b join public.verkopen v on v.id = b.verkoop_id
       where b.lid_id = l.id and b.methode = 'lat' and not v.geannuleerd order by v.ts desc limit 50)
      union all
      (select a.ts, 'afbetaald', a.bedrag_cent, null, null, a.methode
       from public.lat_betalingen a where a.lid_id = l.id order by a.ts desc limit 20)) x), '[]'));
end $$;

revoke execute on function public.lid_code(bigint), public.lid_nieuwe_code(bigint) from public, anon;
grant execute on function public.lid_code(bigint), public.lid_nieuwe_code(bigint) to authenticated;
grant execute on function public.kaart_saldo(text), public.lid_overzicht(text) to anon, authenticated;

-- ──────────── 3. Controle per medewerker ────────────
create function public.controle(p_van timestamptz, p_tot timestamptz) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  perform public._eis('beheerder');
  return jsonb_build_object(
    'medewerkers', coalesce((select jsonb_agg(x order by x.omzet_cent desc) from (
      select p.id, p.naam,
        (select count(*) from public.verkopen v where v.door = p.id and v.ts >= p_van and v.ts < p_tot) as bonnen,
        (select coalesce(sum(totaal_cent), 0) from public.verkopen v where v.door = p.id and not v.geannuleerd and v.ts >= p_van and v.ts < p_tot) as omzet_cent,
        (select count(*) from public.verkopen v where v.door = p.id and v.geannuleerd and v.ts >= p_van and v.ts < p_tot) as geannuleerd,
        (select coalesce(sum(totaal_cent), 0) from public.verkopen v where v.door = p.id and v.geannuleerd and v.ts >= p_van and v.ts < p_tot) as geannuleerd_cent,
        (select coalesce(sum(b.bedrag_cent), 0) from public.verkopen v join public.betalingen b on b.verkoop_id = v.id
          where v.door = p.id and v.geannuleerd and b.methode = 'contant' and v.ts >= p_van and v.ts < p_tot) as geannuleerd_contant_cent,
        (select count(*) from public.diensten d where d.gesloten_door = p.id and d.gesloten_ts >= p_van and d.gesloten_ts < p_tot) as diensten,
        (select coalesce(sum(d.geteld_cent - d.verwacht_cent), 0) from public.diensten d
          where d.gesloten_door = p.id and d.gesloten_ts >= p_van and d.gesloten_ts < p_tot) as kasverschil_cent,
        (select count(*) from public.diensten d where d.gesloten_door = p.id and d.geteld_cent < d.verwacht_cent
          and d.gesloten_ts >= p_van and d.gesloten_ts < p_tot) as tekorten,
        (select coalesce(sum(bedrag_cent), 0) from public.kaart_mutaties m where m.door = p.id and m.soort = 'opwaardering'
          and m.methode = 'contant' and m.ts >= p_van and m.ts < p_tot) as opgewaardeerd_contant_cent,
        (select coalesce(sum(bedrag_cent), 0) from public.kaart_mutaties m where m.door = p.id and m.soort = 'opwaardering'
          and m.methode = 'pin' and m.ts >= p_van and m.ts < p_tot) as opgewaardeerd_pin_cent,
        (select coalesce(sum(b.bedrag_cent), 0) from public.verkopen v join public.betalingen b on b.verkoop_id = v.id
          where v.door = p.id and not v.geannuleerd and b.methode = 'lat' and v.ts >= p_van and v.ts < p_tot) as gestreept_cent,
        (select coalesce(sum(bedrag_cent), 0) from public.lat_betalingen a where a.door = p.id and a.methode = 'contant'
          and a.ts >= p_van and a.ts < p_tot) as afbetaald_contant_cent
      from public.profielen p) x
      where x.bonnen > 0 or x.diensten > 0 or x.opgewaardeerd_contant_cent > 0 or x.opgewaardeerd_pin_cent > 0 or x.afbetaald_contant_cent > 0), '[]'),
    'annuleringen', coalesce((select jsonb_agg(x order by x.ts desc) from (
      select v.bonnummer, v.ts, v.totaal_cent, v.door_naam, v.geannuleerd_ts,
        (select naam from public.profielen where id = v.geannuleerd_door) as geannuleerd_door,
        (select string_agg(distinct b.methode, ', ') from public.betalingen b where b.verkoop_id = v.id) as methoden
      from public.verkopen v where v.geannuleerd and v.ts >= p_van and v.ts < p_tot order by v.ts desc limit 100) x), '[]'),
    'tekorten', coalesce((select jsonb_agg(x order by x.gesloten_ts desc) from (
      select d.id, d.gesloten_ts, d.geteld_cent - d.verwacht_cent as verschil_cent, d.opmerking,
        (select naam from public.profielen where id = d.geopend_door) as geopend_door,
        (select naam from public.profielen where id = d.gesloten_door) as gesloten_door
      from public.diensten d where d.geteld_cent <> d.verwacht_cent and d.gesloten_ts >= p_van and d.gesloten_ts < p_tot
      order by d.gesloten_ts desc limit 100) x), '[]'));
end $$;
revoke execute on function public.controle(timestamptz, timestamptz) from public, anon;
grant execute on function public.controle(timestamptz, timestamptz) to authenticated;
