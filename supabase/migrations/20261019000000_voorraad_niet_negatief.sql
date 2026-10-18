-- Niet meer verkopen dan er op voorraad is.
--
-- Geldt voor elk product waarvan de voorraad wordt bijgehouden, bij afrekenen
-- én bij opschrijven op een rekening. De controle zit op de tabel zelf, zodat
-- ook twee apparaten die tegelijk de laatste fles verkopen worden tegengehouden
-- (de tweede wacht op de rij-vergrendeling van de eerste en ziet dan 0).
-- Omhoog mag altijd (levering, telling, annuleren), ook vanuit een negatieve
-- stand van vóór deze wijziging.

create function public._voorraad_controle() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.voorraad_bijhouden and new.voorraad < 0 and new.voorraad < old.voorraad then
    raise exception '%', case when old.voorraad <= 0 then format('%s is op', new.naam)
      else format('Niet genoeg %s op voorraad (nog %s)', new.naam, old.voorraad) end;
  end if;
  return new;
end $$;

create trigger voorraad_niet_negatief before update of voorraad on public.producten
  for each row execute function public._voorraad_controle();
