-- Bijwerken vanuit de app (Beheer → Instellingen).
--
-- De app installeert zelf nooit iets. Een beheerder zet hier alleen een
-- verzoek klaar; het hulpprogramma bijwerker.sh op de kassa-server (draait
-- elke minuut als root) voert het uit en schrijft de voortgang terug.

create table public.systeem (
  id            int primary key default 1 check (id = 1),
  versie        text,                 -- geïnstalleerde versie; leeg = geen bijwerker op deze server
  nieuwste      text,                 -- nieuwste versie op GitHub
  gecontroleerd timestamptz,
  verzoek       text check (verzoek in ('controleren', 'bijwerken')),
  verzoek_ts    timestamptz,
  status        text not null default 'klaar' check (status in ('klaar', 'bezig', 'mislukt')),
  melding       text,
  bijgewerkt_ts timestamptz
);
insert into public.systeem default values;

alter table public.systeem enable row level security;
create policy lezen on public.systeem for select to authenticated using (public.is_beheerder());
grant select on public.systeem to authenticated;

create function public.systeem_verzoek(p_soort text) returns void
language plpgsql security definer set search_path = '' as $$
declare s public.systeem;
begin
  perform public._eis('beheerder');
  if p_soort not in ('controleren', 'bijwerken') then raise exception 'Onbekend verzoek'; end if;
  select * into s from public.systeem where id = 1 for update;
  if s.versie is null then raise exception 'Bijwerken kan alleen op de kassa-server'; end if;
  if s.status = 'bezig' then raise exception 'Er loopt al een update'; end if;
  update public.systeem set verzoek = p_soort, verzoek_ts = now(),
    melding = case p_soort when 'bijwerken' then 'De update start binnen een minuut…' else 'Zoeken naar een nieuwe versie…' end
  where id = 1;
  if p_soort = 'bijwerken' then
    perform public._log('bijwerken', jsonb_build_object('van', s.versie, 'naar', s.nieuwste));
  end if;
end $$;

grant execute on function public.systeem_verzoek(text) to authenticated;
