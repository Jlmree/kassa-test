-- Elk product heeft een voorraad: bijhouden staat altijd aan.
--
-- Producten waarvan de voorraad nog niet werd bijgehouden, houden hun
-- huidige stand (meestal 0) en zijn dan "op" tot een beheerder ze telt
-- (Beheer → Producten → = Geteld). Een nieuw product krijgt meteen een
-- beginvoorraad.

update public.producten set voorraad_bijhouden = true where not voorraad_bijhouden;
alter table public.producten
  alter column voorraad_bijhouden set default true,
  add constraint voorraad_altijd_bijhouden check (voorraad_bijhouden);

create or replace function public.product_opslaan(p jsonb) returns bigint
language plpgsql security definer set search_path = '' as $$
declare v bigint := (p ->> 'id')::bigint; oud public.producten; begin_voorraad int;
begin
  perform public._eis('beheerder');
  if v is null then
    begin_voorraad := coalesce((p ->> 'voorraad')::int, 0);
    if begin_voorraad not between 0 and 100000 then raise exception 'Ongeldige voorraad'; end if;
    insert into public.producten (naam, prijs_cent, categorie, actief, volgorde, voorraad, voorraad_min)
    values (trim(p ->> 'naam'), (p ->> 'prijs_cent')::int, coalesce(nullif(trim(p ->> 'categorie'), ''), 'Overig'),
            coalesce((p ->> 'actief')::boolean, true), coalesce((p ->> 'volgorde')::int, 0),
            begin_voorraad, coalesce((p ->> 'voorraad_min')::int, 0))
    returning id into v;
    if begin_voorraad > 0 then
      insert into public.voorraad_mutaties (product_id, aantal, reden, door) values (v, begin_voorraad, 'telling', auth.uid());
    end if;
    perform public._log('product_nieuw', p);
  else
    select * into oud from public.producten where id = v and not verwijderd for update;
    if not found then raise exception 'Product niet gevonden'; end if;
    update public.producten set
      naam = trim(p ->> 'naam'), prijs_cent = (p ->> 'prijs_cent')::int,
      categorie = coalesce(nullif(trim(p ->> 'categorie'), ''), 'Overig'),
      actief = coalesce((p ->> 'actief')::boolean, true), volgorde = coalesce((p ->> 'volgorde')::int, oud.volgorde),
      voorraad_min = coalesce((p ->> 'voorraad_min')::int, oud.voorraad_min)
    where id = v;
    if oud.prijs_cent <> (p ->> 'prijs_cent')::int then
      perform public._log('prijs_wijzigen', jsonb_build_object('product', oud.naam, 'van', oud.prijs_cent, 'naar', (p ->> 'prijs_cent')::int));
    end if;
  end if;
  return v;
end $$;
