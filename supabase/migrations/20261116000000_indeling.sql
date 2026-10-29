-- Indeling van de producten (Beheer → Producten): subcategorieën binnen een categorie
-- (bijv. Drinken: Frisdrank, Alcohol), en de volgorde van categorieën en producten
-- door te slepen.
--
-- Een subcategorie is optioneel. De volgorde van de categorieën staat in de instellingen
-- (een lijst namen; een categorie die er niet in staat, komt achteraan op alfabet). De
-- volgorde binnen een categorie is het bestaande veld volgorde; slepen zet het op 10, 20, 30…
-- Een nieuw product komt achteraan in zijn categorie.

alter table public.producten
  add column subcategorie text check (subcategorie is null or length(trim(subcategorie)) between 1 and 30);
alter table public.instellingen
  add column categorie_volgorde text[] not null default '{}';

create or replace function public.product_opslaan(p jsonb) returns bigint
language plpgsql security definer set search_path = '' as $$
declare
  v bigint := (p ->> 'id')::bigint; oud public.producten; begin_voorraad int;
  cat text := coalesce(nullif(trim(p ->> 'categorie'), ''), 'Overig');
  sub text := nullif(trim(coalesce(p ->> 'subcategorie', '')), '');
begin
  perform public._eis('beheerder');
  if v is null then
    begin_voorraad := coalesce((p ->> 'voorraad')::int, 0);
    if begin_voorraad not between 0 and 100000 then raise exception 'Ongeldige voorraad'; end if;
    insert into public.producten (naam, prijs_cent, categorie, subcategorie, actief, volgorde, voorraad, voorraad_min)
    values (trim(p ->> 'naam'), (p ->> 'prijs_cent')::int, cat, sub, coalesce((p ->> 'actief')::boolean, true),
            coalesce((p ->> 'volgorde')::int,
                     (select coalesce(max(volgorde), 0) + 10 from public.producten where categorie = cat and not verwijderd)),
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
      naam = trim(p ->> 'naam'), prijs_cent = (p ->> 'prijs_cent')::int, categorie = cat,
      subcategorie = case when p ? 'subcategorie' then sub else oud.subcategorie end,
      actief = coalesce((p ->> 'actief')::boolean, true),
      -- Naar een andere categorie: achteraan daar.
      volgorde = coalesce((p ->> 'volgorde')::int, case when oud.categorie = cat then oud.volgorde
                   else (select coalesce(max(volgorde), 0) + 10 from public.producten where categorie = cat and not verwijderd) end),
      voorraad_min = coalesce((p ->> 'voorraad_min')::int, oud.voorraad_min)
    where id = v;
    if oud.prijs_cent <> (p ->> 'prijs_cent')::int then
      perform public._log('prijs_wijzigen', jsonb_build_object('product', oud.naam, 'van', oud.prijs_cent, 'naar', (p ->> 'prijs_cent')::int));
    end if;
  end if;
  return v;
end $$;

-- Volgorde na slepen: de producten in deze volgorde krijgen 10, 20, 30…
create function public.producten_volgorde(p_ids bigint[]) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform public._eis('beheerder');
  if coalesce(array_length(p_ids, 1), 0) = 0 or array_length(p_ids, 1) > 500 then raise exception 'Ongeldige volgorde'; end if;
  update public.producten p set volgorde = x.n * 10
  from unnest(p_ids) with ordinality as x(id, n) where p.id = x.id and not p.verwijderd;
end $$;
revoke execute on function public.producten_volgorde(bigint[]) from public, anon;
grant execute on function public.producten_volgorde(bigint[]) to authenticated;

-- De namen als JSON-lijst (["Drinken","Eten"]): zo komen ze van de app en de proefversie gelijk binnen.
create function public.categorie_volgorde_opslaan(p_namen jsonb) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform public._eis('beheerder');
  if jsonb_typeof(p_namen) is distinct from 'array' or jsonb_array_length(p_namen) > 100 then raise exception 'Ongeldige volgorde'; end if;
  update public.instellingen set categorie_volgorde = array(select jsonb_array_elements_text(p_namen));
end $$;
revoke execute on function public.categorie_volgorde_opslaan(jsonb) from public, anon;
grant execute on function public.categorie_volgorde_opslaan(jsonb) to authenticated;
