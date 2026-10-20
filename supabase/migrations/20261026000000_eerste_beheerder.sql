-- Wie wordt de eerste beheerder?
-- Vroeger werd het eerste account dat in de app werd aangemaakt beheerder. Op een
-- server die via internet bereikbaar is, kan een onbekende je dan voor zijn.
-- Nu maakt de installatie de beheerder aan op de server zelf (kassas.sh beheerder)
-- en zet daarna deze instelling uit: een account uit de app wordt dan nooit meer
-- vanzelf beheerder.
-- Bestaande kassa's houden het oude gedrag tot de installatie opnieuw draait.
alter table public.instellingen add column eerste_account_wordt_beheerder boolean not null default true;

create or replace function public._nieuwe_gebruiker() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  lock table public.profielen in share row exclusive mode;
  insert into public.profielen (id, naam, rol)
  values (
    new.id,
    left(coalesce(nullif(trim(new.raw_user_meta_data ->> 'naam'), ''), split_part(new.email, '@', 1)), 40),
    case
      when not exists (select 1 from public.profielen where rol = 'beheerder')
           and (select eerste_account_wordt_beheerder from public.instellingen where id = 1) then 'beheerder'
      else 'wacht'
    end
  );
  return new;
end $$;
