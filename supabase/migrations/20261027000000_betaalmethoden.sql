-- Betaalmethoden aan of uit (Beheer → Instellingen). Bijvoorbeeld een kantine
-- zonder pinautomaat zet pin uit. De database controleert het ook, zodat een
-- telefoon met een oude versie van de app geen uitgezette methode kan gebruiken.
alter table public.instellingen
  add column betaal_contant  boolean not null default true,
  add column betaal_pin      boolean not null default true,
  add column betaal_kaart    boolean not null default true,
  add column betaal_rekening boolean not null default true,
  add constraint minstens_een_betaalmethode check (betaal_contant or betaal_pin or betaal_kaart);

create function public.betaalmethoden_opslaan(p_contant boolean, p_pin boolean, p_kaart boolean, p_rekening boolean) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform public._eis('beheerder');
  if not (p_contant or p_pin or p_kaart) then raise exception 'Zet minstens één van contant, pin of kaart aan'; end if;
  update public.instellingen set betaal_contant = p_contant, betaal_pin = p_pin, betaal_kaart = p_kaart, betaal_rekening = p_rekening;
  perform public._log('betaalmethoden', jsonb_build_object('contant', p_contant, 'pin', p_pin, 'kaart', p_kaart, 'rekening', p_rekening));
end $$;
revoke execute on function public.betaalmethoden_opslaan(boolean, boolean, boolean, boolean) from public, anon;
grant execute on function public.betaalmethoden_opslaan(boolean, boolean, boolean, boolean) to authenticated;

-- Fout als deze methode uit staat.
create function public._methode_aan(p_methode text) returns void
language plpgsql stable security definer set search_path = '' as $$
declare i public.instellingen; aan boolean;
begin
  select * into i from public.instellingen where id = 1;
  aan := case p_methode
    when 'contant' then i.betaal_contant
    when 'pin' then i.betaal_pin
    when 'kaart' then i.betaal_kaart
    when 'rekening' then i.betaal_rekening
    else true
  end;
  if not aan then
    if p_methode = 'rekening' then raise exception 'Op rekening zetten staat uit (Beheer → Instellingen)'; end if;
    raise exception 'Betalen met % staat uit (Beheer → Instellingen)', p_methode;
  end if;
end $$;
revoke execute on function public._methode_aan(text) from public, anon, authenticated;

-- Afrekenen: alle betalingen moeten een methode gebruiken die aan staat. Een open
-- rekening afrekenen blijft kunnen, ook als "op rekening" intussen uit staat.
create or replace function public.afrekenen(p_regels jsonb default '[]', p_betalingen jsonb default '[]', p_rekening_id bigint default null,
                                             p_verwacht_cent int default null, p_sleutel uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare res jsonb; m text;
begin
  perform public._eis('medewerker');
  if p_sleutel is not null then
    res := public._al_gedaan(p_sleutel);
    if res is not null then return res; end if;
  end if;
  if jsonb_typeof(p_betalingen) = 'array' then
    for m in select distinct e ->> 'methode' from jsonb_array_elements(p_betalingen) e loop
      perform public._methode_aan(m);
    end loop;
  end if;
  res := public._afrekenen(p_regels, p_betalingen, p_rekening_id, p_verwacht_cent);
  if p_sleutel is not null then perform public._gedaan(p_sleutel, res); end if;
  return res;
end $$;

-- Opwaarderen: alleen als betalen met kaart aan staat, en met contant of pin als die aan staat.
create or replace function public.kaart_opwaarderen(p_kaart_id bigint, p_bedrag_cent int, p_methode text, p_sleutel uuid default null)
returns int language plpgsql security definer set search_path = '' as $$
declare res jsonb;
begin
  perform public._eis('medewerker');
  if p_sleutel is not null then
    res := public._al_gedaan(p_sleutel);
    if res is not null then return (res ->> 'saldo_cent')::int; end if;
  end if;
  perform public._methode_aan('kaart');
  perform public._methode_aan(p_methode);
  res := jsonb_build_object('saldo_cent', public._kaart_opwaarderen(p_kaart_id, p_bedrag_cent, p_methode));
  if p_sleutel is not null then perform public._gedaan(p_sleutel, res); end if;
  return (res ->> 'saldo_cent')::int;
end $$;

-- Nieuwe rekeningen en bestellingen op rekening alleen als "op rekening" aan staat.
create or replace function public.rekening_maken(p_naam text) returns bigint
language plpgsql security definer set search_path = '' as $$
declare v bigint;
begin
  perform public._eis('medewerker');
  perform public._methode_aan('rekening');
  insert into public.rekeningen (naam, door) values (trim(p_naam), auth.uid()) returning id into v;
  perform public._log('rekening_maken', jsonb_build_object('rekening', v, 'naam', trim(p_naam)));
  return v;
end $$;

alter function public.rekening_toevoegen(bigint, jsonb) rename to _rekening_toevoegen;
revoke execute on function public._rekening_toevoegen(bigint, jsonb) from public, anon, authenticated;

create function public.rekening_toevoegen(p_rekening_id bigint, p_regels jsonb) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform public._eis('medewerker');
  perform public._methode_aan('rekening');
  perform public._rekening_toevoegen(p_rekening_id, p_regels);
end $$;
revoke execute on function public.rekening_toevoegen(bigint, jsonb) from public, anon;
grant execute on function public.rekening_toevoegen(bigint, jsonb) to authenticated;
