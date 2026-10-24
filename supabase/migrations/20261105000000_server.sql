-- Kassa op een gehuurde server, eventueel met meerdere kassa's op één server.
--
-- - Back-up downloaden: backup.sh zet de nieuwste back-up versleuteld klaar op een
--   geheim pad; een beheerder downloadt hem in de app (Beheer → Instellingen).
-- - Bijwerken vanuit de app geldt voor de hele server en kan daarom alleen bij de
--   eerste kassa; bij de andere kassa's zet de installatie bijwerken_mag uit.

alter table public.systeem
  add column bijwerken_mag  boolean not null default true,
  add column backup_pad     text,          -- geheim deel van het downloadadres
  add column backup_bestand text,          -- naam van de nieuwste versleutelde back-up
  add column backup_ts      timestamptz;

create or replace function public.systeem_verzoek(p_soort text) returns void
language plpgsql security definer set search_path = '' as $$
declare s public.systeem;
begin
  perform public._eis('beheerder');
  if p_soort not in ('controleren', 'bijwerken') then raise exception 'Onbekend verzoek'; end if;
  select * into s from public.systeem where id = 1 for update;
  if s.versie is null then raise exception 'Bijwerken kan alleen op de kassa-server'; end if;
  if p_soort = 'bijwerken' and not s.bijwerken_mag then
    raise exception 'Op deze server staan meerdere kassa''s; bijwerken doet de beheerder van de server';
  end if;
  if s.status = 'bezig' then raise exception 'Er loopt al een update'; end if;
  update public.systeem set verzoek = p_soort, verzoek_ts = now(),
    melding = case p_soort when 'bijwerken' then 'De update start binnen een minuut…' else 'Zoeken naar een nieuwe versie…' end
  where id = 1;
  if p_soort = 'bijwerken' then
    perform public._log('bijwerken', jsonb_build_object('van', s.versie, 'naar', s.nieuwste));
  end if;
end $$;
