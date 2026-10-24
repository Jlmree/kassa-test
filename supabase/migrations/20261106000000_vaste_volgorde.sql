-- Geen "deadlock" meer als telefoons tegelijk afrekenen.
--
-- Afrekenen, iets op een rekening zetten en een bon annuleren passen de voorraad
-- van meerdere producten aan. Deden twee telefoons dat tegelijk in een andere
-- volgorde (bier dan chips, en chips dan bier), dan wachtten ze op elkaar en brak
-- de database er één af (gevonden met een stresstest: 1 keer op 3800 bonnen).
-- Nu worden de producten vooraf vastgezet, altijd op volgorde van id; een tweede
-- telefoon wacht dan gewoon even tot de eerste klaar is.

create function public._producten_vastzetten(p_ids bigint[]) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform 1 from public.producten where id = any(p_ids) order by id for update;
end $$;
revoke execute on function public._producten_vastzetten(bigint[]) from public, anon, authenticated;

-- De producten van een bestelling (regels uit de app) en van een rekening.
create function public._producten_van(p_regels jsonb, p_rekening_id bigint default null) returns bigint[]
language sql stable security definer set search_path = '' as $$
  select coalesce(array_agg(distinct id), '{}') from (
    select (r ->> 'product_id')::bigint as id from jsonb_array_elements(coalesce(p_regels, '[]')) r where r ? 'product_id'
    union
    select product_id from public.rekening_regels where rekening_id = p_rekening_id
  ) x where id is not null
$$;
revoke execute on function public._producten_van(jsonb, bigint) from public, anon, authenticated;

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
  -- Alle betalingen moeten een methode gebruiken die aan staat (zie 20261027000000_betaalmethoden.sql).
  if jsonb_typeof(p_betalingen) = 'array' then
    for m in select distinct e ->> 'methode' from jsonb_array_elements(p_betalingen) e loop
      perform public._methode_aan(m);
    end loop;
  end if;
  perform public._producten_vastzetten(public._producten_van(p_regels, p_rekening_id));
  res := public._afrekenen(p_regels, p_betalingen, p_rekening_id, p_verwacht_cent);
  if p_sleutel is not null then perform public._gedaan(p_sleutel, res); end if;
  return res;
end $$;

create or replace function public.rekening_toevoegen(p_rekening_id bigint, p_regels jsonb) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform public._eis('medewerker');
  perform public._methode_aan('rekening');
  perform public._producten_vastzetten(public._producten_van(p_regels));
  perform public._rekening_toevoegen(p_rekening_id, p_regels);
end $$;

create or replace function public.verkoop_annuleren(p_verkoop_id bigint) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v public.verkopen;
begin
  perform public._eis('medewerker');
  select * into v from public.verkopen where id = p_verkoop_id for update;
  if not found then raise exception 'Bon niet gevonden'; end if;
  if v.geannuleerd then raise exception 'Deze bon is al geannuleerd'; end if;
  if not public.is_beheerder() and (v.door is distinct from auth.uid() or v.ts < now() - interval '15 minutes') then
    raise exception 'Alleen een beheerder kan deze bon nog annuleren' using errcode = '42501';
  end if;
  -- Na het tellen en sluiten van de kassa klopt de kasopmaak anders niet meer.
  if not public.is_beheerder() and not exists (select 1 from public.diensten where id = v.dienst_id and gesloten_ts is null) then
    raise exception 'De kassa is al gesloten; alleen een beheerder kan deze bon nog annuleren' using errcode = '42501';
  end if;

  perform public._producten_vastzetten(array(select distinct product_id from public.verkoop_regels where verkoop_id = v.id));
  update public.verkopen set geannuleerd = true, geannuleerd_door = auth.uid(), geannuleerd_ts = now() where id = v.id;

  with r as (select product_id, sum(aantal) as a from public.verkoop_regels where verkoop_id = v.id group by 1),
  u as (update public.producten p set voorraad = p.voorraad + r.a from r
        where p.id = r.product_id and p.voorraad_bijhouden returning p.id, r.a)
  insert into public.voorraad_mutaties (product_id, aantal, reden, verkoop_id, door)
  select id, a, 'annulering', v.id, auth.uid() from u;

  with b as (select kaart_id, sum(bedrag_cent) as a from public.betalingen
             where verkoop_id = v.id and methode = 'kaart' and bedrag_cent > 0 group by 1),
  u as (update public.kaarten k set saldo_cent = k.saldo_cent + b.a from b where k.id = b.kaart_id returning k.id, b.a)
  insert into public.kaart_mutaties (kaart_id, bedrag_cent, soort, verkoop_id, door)
  select id, a, 'annulering', v.id, auth.uid() from u;

  perform public._log('verkoop_annuleren', jsonb_build_object('bon', v.bonnummer, 'totaal_cent', v.totaal_cent));
  return public.bon(v.id);
end $$;
