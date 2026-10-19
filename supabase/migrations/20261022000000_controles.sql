-- Controles die de review vond:
-- - afrekenen: het bedrag dat het apparaat liet zien gaat mee (p_verwacht_cent); is het intussen
--   veranderd (bijboeken op een ander apparaat, prijswijziging), dan wordt er niet afgerekend.
-- - Een open dienst wordt bij afrekenen/opwaarderen vastgehouden, zodat een verkoop nooit op een
--   dienst komt die net is gesloten.
-- - Medewerkers annuleren geen bon meer na het sluiten van de kassa; een gesloten dienst houdt
--   het verwachte bedrag van het moment van tellen.
-- - Rekening-regels schrappen en rekeningen verwijderen zetten de rekening eerst vast.

create or replace function public._open_dienst() returns bigint
language plpgsql volatile security definer set search_path = '' as $$
declare v bigint;
begin
  select id into v from public.diensten where gesloten_ts is null for share;
  if v is null then
    raise exception 'Open eerst de kassa (tabblad Dienst)' using errcode = 'P0001';
  end if;
  return v;
end $$;

drop function public.afrekenen(jsonb, jsonb, bigint);
create function public.afrekenen(p_regels jsonb default '[]', p_betalingen jsonb default '[]', p_rekening_id bigint default null,
                                  p_verwacht_cent int default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_dienst bigint;
  v_id     bigint;
  v_rek    public.rekeningen;
  v_totaal int;
  v_rest   int;
  v_kaart  public.kaarten;
  v_bedrag int;
  v_b      jsonb;
  v_n      int;
  v_gegeven int;
begin
  perform public._eis('medewerker');
  v_dienst := public._open_dienst();

  if jsonb_typeof(p_betalingen) is distinct from 'array' or jsonb_typeof(p_regels) is distinct from 'array' then
    raise exception 'Ongeldige bestelling';
  end if;

  insert into public.verkopen (door, door_naam, dienst_id)
  values (auth.uid(), (select naam from public.profielen where id = auth.uid()), v_dienst)
  returning id into v_id;

  if p_rekening_id is not null then
    select * into v_rek from public.rekeningen where id = p_rekening_id for update;
    if not found or not v_rek.open then
      raise exception 'Deze rekening is al afgerekend of bestaat niet';
    end if;
    insert into public.verkoop_regels (verkoop_id, product_id, naam, prijs_cent, aantal)
    select v_id, product_id, naam, prijs_cent, sum(aantal)
    from public.rekening_regels where rekening_id = p_rekening_id
    group by product_id, naam, prijs_cent order by min(id);
    update public.rekeningen set open = false, gesloten_ts = now() where id = p_rekening_id;
    update public.verkopen set rekening_naam = v_rek.naam where id = v_id;
  else
    if exists (select 1 from jsonb_array_elements(p_regels) e
               where coalesce((e ->> 'aantal')::int, 0) not between 1 and 999) then
      raise exception 'Ongeldig aantal in de bestelling';
    end if;
    with r as (
      select (e ->> 'product_id')::bigint as pid, sum((e ->> 'aantal')::int) as aantal, min(ord) as ord
      from jsonb_array_elements(p_regels) with ordinality as x(e, ord) group by 1
    )
    insert into public.verkoop_regels (verkoop_id, product_id, naam, prijs_cent, aantal)
    select v_id, p.id, p.naam, p.prijs_cent, r.aantal
    from r join public.producten p on p.id = r.pid and p.actief and not p.verwijderd
    order by r.ord;
    get diagnostics v_n = row_count;
    if v_n <> (select count(distinct e ->> 'product_id') from jsonb_array_elements(p_regels) e) then
      raise exception 'Een product in de bestelling is niet meer beschikbaar';
    end if;
    -- Voorraad afboeken (bij een rekening gebeurde dat al bij het opschrijven).
    with r as (select product_id, sum(aantal) as a from public.verkoop_regels where verkoop_id = v_id group by 1),
    u as (update public.producten p set voorraad = p.voorraad - r.a from r
          where p.id = r.product_id and p.voorraad_bijhouden returning p.id, r.a)
    insert into public.voorraad_mutaties (product_id, aantal, reden, verkoop_id, door)
    select id, -a, 'verkoop', v_id, auth.uid() from u;
  end if;

  select coalesce(sum(prijs_cent * aantal), 0) into v_totaal from public.verkoop_regels where verkoop_id = v_id;
  if not exists (select 1 from public.verkoop_regels where verkoop_id = v_id) then
    raise exception 'De bestelling is leeg';
  end if;
  -- Is het bedrag intussen veranderd (iemand boekte bij op de rekening, of een prijs
  -- werd aangepast)? Dan niet afrekenen: er is al gepind of afgeteld voor het oude bedrag.
  if p_verwacht_cent is not null and p_verwacht_cent <> v_totaal then
    raise exception 'Het bedrag is intussen veranderd: het is nu € %. Controleer de bestelling en reken opnieuw af.',
      to_char(v_totaal / 100.0, 'FM999990.00');
  end if;
  update public.verkopen set totaal_cent = v_totaal where id = v_id;
  v_rest := v_totaal;

  -- Kaart eerst.
  if (select count(*) from jsonb_array_elements(p_betalingen) e where e ->> 'methode' = 'kaart') > 1 then
    raise exception 'Je kunt met maar één kaart tegelijk betalen';
  end if;
  select e into v_b from jsonb_array_elements(p_betalingen) e where e ->> 'methode' = 'kaart';
  if v_b is not null then
    select * into v_kaart from public.kaarten where id = public._zoek_kaart(v_b ->> 'kaart', true) for update;
    if v_kaart.geblokkeerd then raise exception 'Kaart % is geblokkeerd', v_kaart.nummer; end if;
    v_bedrag := least(v_kaart.saldo_cent, v_rest);
    if v_bedrag <= 0 and v_rest > 0 then raise exception 'Er staat geen tegoed op kaart %', v_kaart.nummer; end if;
    update public.kaarten set saldo_cent = saldo_cent - v_bedrag where id = v_kaart.id;
    insert into public.kaart_mutaties (kaart_id, bedrag_cent, soort, verkoop_id, dienst_id, door)
    values (v_kaart.id, -v_bedrag, 'betaling', v_id, v_dienst, auth.uid());
    insert into public.betalingen (verkoop_id, methode, bedrag_cent, kaart_id, kaart_saldo_na)
    values (v_id, 'kaart', v_bedrag, v_kaart.id, v_kaart.saldo_cent - v_bedrag);
    v_rest := v_rest - v_bedrag;
  end if;

  -- Restant met contant of pin.
  select count(*) into v_n from jsonb_array_elements(p_betalingen) e where e ->> 'methode' <> 'kaart';
  if v_rest > 0 then
    if v_n <> 1 then raise exception 'Kies hoe er betaald wordt (nog % open)', to_char(v_rest / 100.0, 'FM9990.00'); end if;
    select e into v_b from jsonb_array_elements(p_betalingen) e where e ->> 'methode' <> 'kaart';
    if v_b ->> 'methode' = 'contant' then
      v_gegeven := coalesce((v_b ->> 'gegeven_cent')::int, v_rest);
      if v_gegeven < v_rest then raise exception 'Er is te weinig gegeven'; end if;
      insert into public.betalingen (verkoop_id, methode, bedrag_cent, gegeven_cent, wisselgeld_cent)
      values (v_id, 'contant', v_rest, v_gegeven, v_gegeven - v_rest);
    elsif v_b ->> 'methode' = 'pin' then
      insert into public.betalingen (verkoop_id, methode, bedrag_cent) values (v_id, 'pin', v_rest);
    else
      raise exception 'Onbekende betaalmethode';
    end if;
  end if;

  return public.bon(v_id);
end $$;
revoke execute on function public.afrekenen(jsonb, jsonb, bigint, int) from public, anon;
grant execute on function public.afrekenen(jsonb, jsonb, bigint, int) to authenticated;

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

create or replace function public._dienst_cijfers(p_dienst bigint) returns jsonb
language sql stable security definer set search_path = '' as $$
  with b as (
    select b.methode, sum(b.bedrag_cent) as s from public.betalingen b
    join public.verkopen v on v.id = b.verkoop_id
    where v.dienst_id = p_dienst and not v.geannuleerd group by 1
  ), o as (
    select methode, sum(bedrag_cent) as s from public.kaart_mutaties
    where dienst_id = p_dienst and soort = 'opwaardering' group by 1
  ), d as (select * from public.diensten where id = p_dienst)
  select jsonb_build_object(
    'id', d.id, 'geopend_ts', d.geopend_ts, 'gesloten_ts', d.gesloten_ts,
    'geopend_door', (select naam from public.profielen where id = d.geopend_door),
    'gesloten_door', (select naam from public.profielen where id = d.gesloten_door),
    'beginsaldo_cent', d.beginsaldo_cent,
    'omzet_cent', (select coalesce(sum(totaal_cent), 0) from public.verkopen where dienst_id = d.id and not geannuleerd),
    'bonnen', (select count(*) from public.verkopen where dienst_id = d.id and not geannuleerd),
    'contant_cent', coalesce((select s from b where methode = 'contant'), 0),
    'pin_cent', coalesce((select s from b where methode = 'pin'), 0),
    'kaart_cent', coalesce((select s from b where methode = 'kaart'), 0),
    'opwaardering_contant_cent', coalesce((select s from o where methode = 'contant'), 0),
    'opwaardering_pin_cent', coalesce((select s from o where methode = 'pin'), 0),
    -- Een gesloten dienst houdt het bedrag van het moment van tellen.
    'verwacht_cent', coalesce(d.verwacht_cent, d.beginsaldo_cent + coalesce((select s from b where methode = 'contant'), 0)
                     + coalesce((select s from o where methode = 'contant'), 0)),
    'geteld_cent', d.geteld_cent, 'opmerking', d.opmerking)
  from d
$$;

create or replace function public.rekening_regel_verwijderen(p_regel_id bigint) returns void
language plpgsql security definer set search_path = '' as $$
declare r public.rekening_regels; v_rek bigint;
begin
  perform public._eis('medewerker');
  -- Eerst de rekening vastzetten, zodat hij niet tegelijk wordt afgerekend.
  select rekening_id into v_rek from public.rekening_regels where id = p_regel_id;
  perform 1 from public.rekeningen where id = v_rek for update;
  select rr.* into r from public.rekening_regels rr join public.rekeningen k on k.id = rr.rekening_id
  where rr.id = p_regel_id and k.open for update of rr;
  if not found then raise exception 'Deze regel bestaat niet meer'; end if;
  delete from public.rekening_regels where id = p_regel_id;
  update public.producten set voorraad = voorraad + r.aantal where id = r.product_id and voorraad_bijhouden;
  if found then
    insert into public.voorraad_mutaties (product_id, aantal, reden, door) values (r.product_id, r.aantal, 'correctie', auth.uid());
  end if;
  perform public._log('rekening_regel_verwijderen', jsonb_build_object('rekening', r.rekening_id, 'naam', r.naam, 'aantal', r.aantal, 'prijs_cent', r.prijs_cent));
end $$;

create or replace function public.rekening_verwijderen(p_rekening_id bigint) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform public._eis('medewerker');
  perform 1 from public.rekeningen where id = p_rekening_id for update;
  if exists (select 1 from public.rekening_regels where rekening_id = p_rekening_id) then
    raise exception 'Alleen een lege rekening kan worden verwijderd';
  end if;
  delete from public.rekeningen where id = p_rekening_id and open;
  perform public._log('rekening_verwijderen', jsonb_build_object('rekening', p_rekening_id));
end $$;
