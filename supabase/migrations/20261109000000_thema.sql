-- Thema van de kassa (Beheer → Instellingen → Thema), voor alle telefoons tegelijk:
-- licht (zoals altijd, donker als de telefoon op donker staat), kroeg (donker met
-- amber, voor een schemerige bar) of groot (grote knoppen en letters, veel contrast).

alter table public.instellingen
  add column thema text not null default 'licht' check (thema in ('licht', 'kroeg', 'groot'));

create function public.thema_opslaan(p_thema text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform public._eis('beheerder');
  if p_thema is null or p_thema not in ('licht', 'kroeg', 'groot') then raise exception 'Onbekend thema'; end if;
  update public.instellingen set thema = p_thema;
  perform public._log('thema', jsonb_build_object('thema', p_thema));
end $$;
revoke execute on function public.thema_opslaan(text) from public, anon;
grant execute on function public.thema_opslaan(text) to authenticated;
