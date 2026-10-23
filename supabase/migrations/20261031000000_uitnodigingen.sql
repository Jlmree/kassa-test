-- Uitnodigen met een QR-code: de beheerder maakt een uitnodiging (naam + rol), de
-- nieuwe medewerker scant de code, kiest een wachtwoord en is meteen binnen.
-- Een uitnodiging werkt één keer, verloopt na 24 uur en kan worden ingetrokken.
-- Zelf een account aanmaken (met goedkeuring) kan de beheerder uitzetten.

create table public.uitnodigingen (
  id            bigint generated always as identity primary key,
  code          text not null unique default encode(extensions.gen_random_bytes(16), 'hex'),
  naam          text not null check (length(trim(naam)) between 1 and 40),
  rol           text not null check (rol in ('medewerker', 'beheerder')),
  door          uuid references public.profielen,
  aangemaakt    timestamptz not null default now(),
  verloopt      timestamptz not null default now() + interval '24 hours',
  gebruikt_ts   timestamptz,
  gebruikt_door uuid references public.profielen,
  ingetrokken   boolean not null default false
);
alter table public.uitnodigingen enable row level security;
create policy lezen on public.uitnodigingen for select to authenticated using (public.is_beheerder());
grant select on public.uitnodigingen to authenticated;
create trigger wijziging after insert or update or delete on public.uitnodigingen for each statement execute function public._wijziging();

alter table public.instellingen add column zelf_aanmelden boolean not null default true;
-- Wifi van de kassa (door de installatie ingevuld), voor de wifi-code bij een uitnodiging.
alter table public.systeem add column wifi_naam text, add column wifi_wachtwoord text;

create function public.uitnodiging_maken(p_naam text, p_rol text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare u public.uitnodigingen;
begin
  perform public._eis('beheerder');
  if length(trim(coalesce(p_naam, ''))) not between 1 and 40 then raise exception 'Vul een naam in (hoogstens 40 tekens)'; end if;
  if p_rol not in ('medewerker', 'beheerder') then raise exception 'Onbekende rol'; end if;
  insert into public.uitnodigingen (naam, rol, door) values (trim(p_naam), p_rol, auth.uid()) returning * into u;
  perform public._log('uitnodiging_maken', jsonb_build_object('naam', u.naam, 'rol', u.rol));
  return jsonb_build_object('id', u.id, 'code', u.code, 'naam', u.naam, 'rol', u.rol, 'verloopt', u.verloopt);
end $$;

create function public.uitnodiging_intrekken(p_id bigint) returns void
language plpgsql security definer set search_path = '' as $$
declare u public.uitnodigingen;
begin
  perform public._eis('beheerder');
  update public.uitnodigingen set ingetrokken = true where id = p_id and gebruikt_ts is null returning * into u;
  if u.id is null then raise exception 'Deze uitnodiging is al gebruikt of bestaat niet'; end if;
  perform public._log('uitnodiging_intrekken', jsonb_build_object('naam', u.naam));
end $$;

-- Zonder inloggen: voor wie is deze uitnodiging? (Na te veel verkeerde codes even dicht.)
create function public.uitnodiging_info(p_code text) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare u public.uitnodigingen;
begin
  if public._code_geblokkeerd() then
    return jsonb_build_object('fout', 'Te veel verkeerde codes geprobeerd. Probeer het over 10 minuten opnieuw.');
  end if;
  select * into u from public.uitnodigingen where code = lower(trim(coalesce(p_code, '')));
  if not found then
    perform public._mislukt('code', public._klant_ip());
    return jsonb_build_object('fout', 'Deze uitnodiging bestaat niet. Vraag de beheerder om een nieuwe QR-code.');
  end if;
  if u.gebruikt_ts is not null then return jsonb_build_object('fout', 'Deze uitnodiging is al gebruikt. Log in met je naam en wachtwoord.'); end if;
  if u.ingetrokken or u.verloopt < now() then
    return jsonb_build_object('fout', 'Deze uitnodiging is verlopen of ingetrokken. Vraag de beheerder om een nieuwe QR-code.');
  end if;
  return jsonb_build_object('naam', u.naam, 'rol', u.rol, 'winkel', (select naam from public.instellingen where id = 1));
end $$;

-- Mag je in de app zelf een account aanmaken? (Voor het inlogscherm, zonder inloggen.)
create function public.aanmelden_open() returns boolean
language sql stable security definer set search_path = '' as $$
  select zelf_aanmelden from public.instellingen where id = 1
$$;

create function public.aanmelden_instellen(p_aan boolean) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform public._eis('beheerder');
  update public.instellingen set zelf_aanmelden = p_aan;
  perform public._log('aanmelden_instellen', jsonb_build_object('aan', p_aan));
end $$;

-- Nieuw account: met een geldige uitnodiging meteen de rol en naam daarvan.
-- Een ongeldige uitnodiging stopt het aanmaken. Zonder uitnodiging: wachten op
-- goedkeuring, of (als zelf aanmelden uit staat) een account dat uit staat en
-- niets kan; zo blijft beheerder.sh op de server ook dan werken.
create or replace function public._nieuwe_gebruiker() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  c text := nullif(trim(new.raw_user_meta_data ->> 'uitnodiging'), '');
  u public.uitnodigingen;
  i public.instellingen;
begin
  lock table public.profielen in share row exclusive mode;
  select * into i from public.instellingen where id = 1;
  if c is not null then
    select * into u from public.uitnodigingen where code = lower(c) for update;
    if not found or u.gebruikt_ts is not null or u.ingetrokken or u.verloopt < now() then
      raise exception 'Deze uitnodiging is verlopen of al gebruikt';
    end if;
    insert into public.profielen (id, naam, rol) values (new.id, u.naam, u.rol);
    update public.uitnodigingen set gebruikt_ts = now(), gebruikt_door = new.id where id = u.id;
    insert into public.logboek (door, door_naam, actie, details)
    values (new.id, u.naam, 'uitnodiging_gebruikt', jsonb_build_object('naam', u.naam, 'rol', u.rol));
    return new;
  end if;
  insert into public.profielen (id, naam, rol, actief)
  values (
    new.id,
    left(coalesce(nullif(trim(new.raw_user_meta_data ->> 'naam'), ''), split_part(new.email, '@', 1)), 40),
    case
      when not exists (select 1 from public.profielen where rol = 'beheerder') and i.eerste_account_wordt_beheerder then 'beheerder'
      else 'wacht'
    end,
    i.zelf_aanmelden or not exists (select 1 from public.profielen where rol = 'beheerder')
  );
  return new;
end $$;

revoke execute on function public.uitnodiging_maken(text, text), public.uitnodiging_intrekken(bigint), public.aanmelden_instellen(boolean)
  from public, anon;
grant execute on function public.uitnodiging_maken(text, text), public.uitnodiging_intrekken(bigint), public.aanmelden_instellen(boolean)
  to authenticated;
grant execute on function public.uitnodiging_info(text), public.aanmelden_open() to anon, authenticated;
