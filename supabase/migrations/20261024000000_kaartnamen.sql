-- Een tegoedkaart kan aan een naam gekoppeld worden (bijv. een vaste gast of
-- een lid). Betalen kan nog steeds alleen met de geheime kaartcode, niet met
-- de naam. Bij overzetten naar een nieuwe kaart gaat de naam mee.

alter table public.kaarten add column naam text check (naam is null or length(naam) between 1 and 60);
grant select (naam) on public.kaarten to authenticated;

create function public.kaart_naam(p_kaart_id bigint, p_naam text) returns void
language plpgsql security definer set search_path = '' as $$
declare k public.kaarten;
begin
  perform public._eis('medewerker');
  update public.kaarten set naam = nullif(trim(coalesce(p_naam, '')), '') where id = p_kaart_id returning * into k;
  if not found then raise exception 'Kaart niet gevonden'; end if;
  perform public._log('kaart_naam', jsonb_build_object('kaart', k.nummer, 'naam', k.naam));
end $$;
grant execute on function public.kaart_naam(bigint, text) to authenticated;

create or replace function public.kaart_info(p_zoek text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare k public.kaarten;
begin
  perform public._eis('medewerker');
  select * into k from public.kaarten where id = public._zoek_kaart(p_zoek, false);
  return jsonb_build_object('id', k.id, 'nummer', k.nummer, 'naam', k.naam, 'saldo_cent', k.saldo_cent, 'geblokkeerd', k.geblokkeerd,
    'betaalcode', length(regexp_replace(coalesce(p_zoek, ''), '[^A-Za-z0-9]', '', 'g')) = 8);
end $$;

create or replace function public.kaart_overzetten(p_van bigint, p_naar text) returns int
language plpgsql security definer set search_path = '' as $$
declare v public.kaarten; n public.kaarten;
begin
  perform public._eis('beheerder');
  select * into v from public.kaarten where id = p_van for update;
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
